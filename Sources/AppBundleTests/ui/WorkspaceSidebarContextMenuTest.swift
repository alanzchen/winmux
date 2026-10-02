import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

/// Every right-click in the sidebar opens one native menu family; the editor only edits.
@MainActor
final class WorkspaceSidebarContextMenuTest: XCTestCase {
    private var previousWorkspaces: [WorkspaceSidebarWorkspaceViewModel] = []
    private var previousProjects: [WorkspaceSidebarProjectViewModel] = []
    private var previousPresent: ((NSMenu, WorkspaceSidebarIdentityMenu.Origin) -> Void)?
    private var presented: [(menu: NSMenu, origin: WorkspaceSidebarIdentityMenu.Origin)] = []

    override func setUp() async throws {
        setUpWorkspacesForTests()
        workspaceSidebarOrganizationStore = .init()
        config.workspaceSidebar = .init(enabled: true, mode: .tabs)
        previousWorkspaces = TrayMenuModel.shared.workspaceSidebarWorkspaces
        previousProjects = TrayMenuModel.shared.workspaceSidebarProjects
        previousPresent = WorkspaceSidebarIdentityMenu.shared.presentNativeMenu
        TrayMenuModel.shared.workspaceSidebarProjects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil)]
        presented = []
        // Record menus instead of tracking them, which would wait for a person.
        WorkspaceSidebarIdentityMenu.shared.presentNativeMenu = { [weak self] menu, origin in self?.presented.append((menu, origin)) }
    }

    override func tearDown() async throws {
        WorkspaceSidebarIdentityMenu.shared.close(commit: false)
        if let previousPresent { WorkspaceSidebarIdentityMenu.shared.presentNativeMenu = previousPresent }
        TrayMenuModel.shared.workspaceSidebarWorkspaces = previousWorkspaces
        TrayMenuModel.shared.workspaceSidebarProjects = previousProjects
        WorkspaceSidebarTabSelection.shared.clear()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
        try await super.tearDown()
    }

    private func tab(_ name: String, ids: [UInt32], label: String = "", generated: Bool = false,
                     pinned: Bool = false, color: String? = nil, titles: [String]? = nil) -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: name, projectId: workspaceProjectDefaultId, displayName: label.isEmpty ? "Workspace \(name)" : label,
            sidebarLabel: label, isGeneratedName: generated, monitorScopeId: "monitor:0,0", monitorName: "Main",
            isFocused: false, isVisible: false, items: ids.enumerated().map { index, id in
                .init(kind: .window(.init(windowId: id, workspaceName: name, appName: "TextEdit", appBundleId: nil,
                    appBundlePath: "/System/Applications/TextEdit.app", title: titles?[index] ?? "Doc \(id).txt", isFocused: false)))
            }, appearance: .init(colorHex: color, isFavorite: pinned))
    }

    /// Titles by group, without separators, so a test reads like the menu.
    private func groups(_ entries: [WorkspaceSidebarAppMenuEntry]) -> [[String]] {
        workspaceSidebarMenuWithoutStraySeparators(entries).split(whereSeparator: \.isSeparator).map { $0.map(\.title) }
    }

    private func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items + menu.items.compactMap(\.submenu).flatMap(items)
    }

    // MARK: Structure

    func testTabMenuGroupsItsItemsAndEndsWithWhatRemovesThem() {
        let single = workspaceSidebarWorkspaceIdentityMenuModel(tab("one", ids: [1]), windowId: 1, send: { _ in })
        XCTAssertEqual(groups(single.entries), [
            ["Pin Tab", "Pin to All Projects", "Add to Group"],
            ["Keep Tab When Empty"],
            ["Rename…", "Color", "Change Icon…"],
            ["Close Window"],
        ], "One project and no other tab: no empty Move to Project or Split with")

        let member = workspaceSidebarWorkspaceIdentityMenuModel(tab("pair", ids: [1, 2]), windowId: 2, send: { _ in })
        XCTAssertEqual(groups(member.entries), [
            ["Pin Tab", "Pin to All Projects", "Add to Group"],
            ["Move “Doc 2.txt” to New Tab", "Separate into Tabs"],
            ["Keep Tab When Empty"],
            ["Rename…", "Color", "Change Icon…"],
            ["Close Window", "Close All Windows in Split…"],
        ])

        let whole = workspaceSidebarWorkspaceIdentityMenuModel(tab("pair", ids: [1, 2]), send: { _ in })
        XCTAssertEqual(groups(whole.entries).last, ["Close All Windows in Split…"],
            "The split's own label acts on the whole tab, never on one of its windows")
        XCTAssertFalse(whole.entries.contains { $0.title.hasPrefix("Move “") })

        let empty = workspaceSidebarWorkspaceIdentityMenuModel(tab("empty", ids: []), send: { _ in })
        XCTAssertEqual(groups(empty.entries).last, ["Close Empty Tab"])
        XCTAssertTrue(empty.entries.filter(\.isDestructive).allSatisfy { entry in
            groups(empty.entries).last?.contains(entry.title) == true
        })
    }

    func testAddToGroupAlwaysOffersANewGroupAndMoveToProjectOnlyWithSomewhereToGo() throws {
        let one = workspaceSidebarWorkspaceIdentityMenuModel(tab("one", ids: [1]), windowId: 1, send: { _ in })
        XCTAssertEqual(one.entries.first { $0.title == "Add to Group" }?.children.map(\.title), ["New Group…", ""])
        XCTAssertFalse(one.entries.contains { $0.title == "Move to Project" })

        TrayMenuModel.shared.workspaceSidebarProjects.append(.init(id: "design", displayName: "Design", colorHex: nil, emoji: "🎨"))
        var sent: [WorkspaceSidebarAction] = []
        let two = workspaceSidebarWorkspaceIdentityMenuModel(tab("one", ids: [1]), windowId: 1, send: { sent.append($0) })
        let move = try XCTUnwrap(two.entries.first { $0.title == "Move to Project" })
        XCTAssertEqual(move.children.map(\.title), ["🎨 Design"])
        move.children.first?.perform?()
        XCTAssertEqual(sent, [.moveWorkspace("one", toProject: "design")])
    }

    func testProjectAndGroupMenusKeepTheirOwnActionsAroundTheAppearance() throws {
        let project = try XCTUnwrap(workspaceSidebarIdentityMenuModel(.project(workspaceProjectDefaultId)))
        XCTAssertEqual(groups(project.entries), [
            ["Switch to Project", "New Project"],
            ["Rename…", "Color", "Change Icon…"],
            ["Delete Project"],
        ])
        let group = try workspaceSidebarOrganizationStore.create(projectId: workspaceProjectDefaultId, workspaceNames: [])
        let menu = try XCTUnwrap(workspaceSidebarIdentityMenuModel(.collection(group.id)))
        XCTAssertEqual(groups(menu.entries), [
            ["Collapse Group", "New Tab in Group"],
            ["Rename…", "Color", "Change Icon…"],
            ["Ungroup Tabs"],
        ])
        XCTAssertFalse(menu.entries.contains { $0.isDestructive }, "Ungrouping keeps the tabs")
    }

    func testAppMenuNamesTheWindowItsControlsActOnAndQuitsLast() throws {
        let owner = Workspace.get(byName: "one")
        _ = TestWindow.new(id: 1, parent: owner.rootTilingContainer)
        let app = try XCTUnwrap(buildWorkspaceSidebarAppSummaries(for: owner).first)
        let entries = workspaceSidebarAppMenu(workspaceName: owner.name, app: app)
        XCTAssertEqual(entries.first?.kind, .header)
        let heading = try XCTUnwrap(entries.firstIndex { $0.title.hasPrefix("Window · ") })
        XCTAssertEqual(entries[heading].kind, .header)
        let section = entries[(heading + 1)...].prefix { !$0.isSeparator }.map(\.title)
        XCTAssertEqual(section.last, "Close Window", "Close stays with the window it closes")
        XCTAssertFalse(entries.contains { $0.title.hasPrefix("Window:") }, "No submenu just for the current window")
    }

    // MARK: Native rendering

    func testNativeMenusShowDisabledItemsDisabledAndHaveNoShortcuts() throws {
        // Before, an explicit text color made disabled rows, such as the default project's Delete,
        // look enabled.
        let project = try XCTUnwrap(workspaceSidebarIdentityMenuModel(.project(workspaceProjectDefaultId)))
        let delete = try XCTUnwrap(project.entries.first { $0.title == "Delete Project" })
        XCTAssertFalse(delete.enabled)
        XCTAssertNotNil(delete.help)
        let menu = workspaceSidebarNativeAppMenu(project.entries + [
            .init(title: "Move", enabled: false, children: [.init(title: "Somewhere")]),
        ])
        XCTAssertEqual(menu.items.first { $0.title == "Delete Project" }?.isEnabled, false)
        XCTAssertEqual(menu.items.first { $0.title == "Delete Project" }?.toolTip, delete.help)
        XCTAssertEqual(menu.items.first { $0.title == "Move" }?.isEnabled, false, "Disabled submenus too")
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertTrue(items(menu).allSatisfy { $0.keyEquivalent.isEmpty }, "Context menus show no shortcuts")
        XCTAssertFalse(menu.items.first!.isSeparatorItem)
        XCTAssertFalse(menu.items.last!.isSeparatorItem)
    }

    func testHeadersAreSectionHeadersAndNotChoices() {
        let menu = workspaceSidebarNativeAppMenu([.header("2 Tabs"), .init(title: "Pin 2 Tabs")])
        // A section header can't be chosen; before macOS 14 a disabled item stands in for it.
        if #available(macOS 14, *) { XCTAssertTrue(menu.items[0].isSectionHeader) }
        else { XCTAssertFalse(menu.items[0].isEnabled) }
        XCTAssertNil(menu.items[0].action)
    }

    func testLongNamesKeepTheirEndsAndTheirFullNameForTooltipsAndVoiceOver() {
        let long = "Quarterly planning notes for the Northwind migration project (final draft v3).txt"
        let short = workspaceSidebarMenuName(long)
        XCTAssertEqual(short.count, 40)
        XCTAssertTrue(short.hasPrefix("Quarterly planning notes"))
        XCTAssertTrue(short.hasSuffix("draft v3).txt"), "Keeps the end, where a file's type is")
        XCTAssertEqual(workspaceSidebarMenuName("Alpha.txt"), "Alpha.txt")
        XCTAssertEqual(workspaceSidebarMenuName(String(repeating: "👩🏽‍💻", count: 50)).count, 40, "Whole emoji only")

        let entry = WorkspaceSidebarAppMenuEntry.named(long) { "Move “\($0)” to New Tab" }
        XCTAssertEqual(entry.title, "Move “\(short)” to New Tab", "Only the name is shortened, never the command")
        XCTAssertEqual(entry.fullTitle, "Move “\(long)” to New Tab")
        let item = workspaceSidebarNativeAppMenu([entry]).items[0]
        XCTAssertEqual(item.toolTip, entry.fullTitle)
        XCTAssertEqual(item.accessibilityLabel(), entry.fullTitle)

        // Two names that shorten alike show in full, so choosing between them stays safe.
        let twin = long.replacingOccurrences(of: "Northwind", with: "Southwind")
        let menu = workspaceSidebarNativeAppMenu([.named(long), .named(twin), .named("Alpha.txt")])
        XCTAssertEqual(menu.items.map(\.title), [long, twin, "Alpha.txt"])
    }

    // MARK: Colors

    private func model(color: String?, colors: @escaping (String?) -> Void) -> WorkspaceSidebarIdentityMenuModel {
        WorkspaceSidebarIdentityMenuModel(name: "Work", color: color, emoji: nil, rename: { _ in }, setColor: colors,
            setEmoji: { _ in }, entries: [.init(title: "Pin Tab")])
    }

    func testThePaletteIsOneChoiceAndOnlyANewColorIsWritten() throws {
        var written: [String?] = []
        let model = model(color: "#009AD0") { written.append($0) }
        let menu = workspaceSidebarNativeAppMenu(model.entries)
        let carrier = try XCTUnwrap(menu.items.first { $0.title == "Color" })
        let palette = try XCTUnwrap(carrier.submenu)
        if #available(macOS 14, *) {
            XCTAssertEqual(palette.presentationStyle, .palette)
            XCTAssertEqual(palette.selectionMode, .selectOne)
        }
        XCTAssertEqual(palette.items.map(\.title), ["Default"] + workspaceSidebarIdentityColors.map(\.name))
        XCTAssertEqual(Set(palette.items.compactMap { $0.target.map(ObjectIdentifier.init) }).count, 1,
            "AppKit groups a selection by its target and action")
        XCTAssertEqual(Set(palette.items.compactMap(\.action)).count, 1)
        XCTAssertEqual(palette.items.filter { $0.state == .on }.map(\.title), ["Blue"])
        XCTAssertTrue(palette.items.allSatisfy { $0.image != nil && $0.toolTip == $0.title })
        XCTAssertTrue(written.isEmpty, "Opening the menu writes nothing")

        palette.performActionForItem(at: palette.items.firstIndex { $0.title == "Blue" }!)
        XCTAssertTrue(written.isEmpty, "Choosing the current color again changes nothing")
        palette.performActionForItem(at: palette.items.firstIndex { $0.title == "Red" }!)
        palette.performActionForItem(at: 0)
        XCTAssertEqual(written, ["#D75A6B", nil], "One write per choice; Default means no color")
    }

    func testACustomColorChecksNoPresetAndStaysUntilOneIsChosen() {
        var written: [String?] = []
        let custom = model(color: "#123456") { written.append($0) }
        XCTAssertEqual(custom.colorChoices.filter(\.checked).map(\.title), [])
        XCTAssertEqual(model(color: nil) { _ in }.colorChoices.filter(\.checked).map(\.title), ["Default"])
        XCTAssertEqual(model(color: "#00b894") { _ in }.colorChoices.filter(\.checked).map(\.title), ["Green"],
            "Compared as colors, not as text")
        _ = workspaceSidebarNativeAppMenu(custom.entries)
        XCTAssertTrue(written.isEmpty)
        XCTAssertEqual(custom.color, "#123456")
    }

    // MARK: Names

    func testAnUnnamedTabStartsWithAnEmptyNameShowingWhatTheListCallsIt() {
        var renamed: [String] = []
        let unnamed = workspaceSidebarWorkspaceIdentityMenuModel(tab("3", ids: [5], generated: true), send: {
            if case .renameWorkspace(_, let name) = $0 { renamed.append(name) }
        })
        XCTAssertEqual(unnamed.name, "", "Not the internal “Workspace 3”")
        XCTAssertEqual(unnamed.placeholder, "Doc 5.txt")
        unnamed.chooseColor("#009AD0")
        unnamed.commitName()
        XCTAssertTrue(renamed.isEmpty, "The placeholder is never saved as a name")
        unnamed.name = "  Notes  "
        unnamed.commitName()
        XCTAssertEqual(renamed, ["Notes"])

        let split = workspaceSidebarWorkspaceIdentityMenuModel(tab("4", ids: [6, 7], generated: true), send: { _ in })
        XCTAssertEqual(split.placeholder, "Doc 6.txt · Doc 7.txt")
        XCTAssertEqual(workspaceSidebarWorkspaceIdentityMenuModel(tab("5", ids: [8], label: "Mail", generated: true),
            send: { _ in }).name, "Mail")
        XCTAssertEqual(workspaceSidebarWorkspaceIdentityMenuModel(tab("inbox", ids: [9]), send: { _ in }).name,
            "Workspace inbox", "A name someone chose stays in the field")
        config.workspaceSidebar = .init(enabled: true, mode: .sidebar)
        XCTAssertEqual(workspaceSidebarWorkspaceIdentityMenuModel(tab("3", ids: [5], generated: true), send: { _ in }).name,
            "Workspace 3", "The sidebar shows workspace names")
    }

    // MARK: Routes

    func testTheDockRouteShowsTheMenuLaterAndRenameOpensTheEditor() throws {
        let menu = WorkspaceSidebarIdentityMenu()
        var shown: [NSMenu] = []
        menu.presentNativeMenu = { menu, origin in
            guard case .point = origin else { return XCTFail("No click to track") }
            shown.append(menu)
        }
        defer { menu.close(commit: false) }
        // As in the app, only the menu holds the model once it's shown, and the menu is gone
        // once it closes: the event loop drains its autorelease pool before the editor opens.
        weak var released: WorkspaceSidebarIdentityMenuModel?
        autoreleasepool {
            let model = WorkspaceSidebarIdentityMenuModel(name: "Work", color: nil, emoji: nil, rename: { _ in },
                setColor: { _ in }, setEmoji: { _ in }, entries: [.init(title: "Pin Tab")])
            released = model
            menu.open(model, at: CGPoint(x: 300, y: 500), selectName: false)
        }
        XCTAssertNil(menu.panel, "Right-clicking no longer opens the editor")
        XCTAssertTrue(shown.isEmpty, "Accessibility and Dock callers return before the menu tracks")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(shown.first?.items.map(\.title), ["Pin Tab", "", "Rename…", "Color", "Change Icon…"])
        autoreleasepool {
            guard let native = shown.first, let rename = native.items.firstIndex(where: { $0.title == "Rename…" }) else { return }
            native.performActionForItem(at: rename)
            shown = []
        }
        XCTAssertNil(menu.panel, "The editor waits for the menu to go")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let panel = try XCTUnwrap(menu.panel, "Rename… still opens the editor after the menu is released")
        XCTAssertTrue(panel.firstResponder is NSTextView, "Rename… opens the editor with the name ready to type")
        let model = try XCTUnwrap(released)
        XCTAssertFalse(model.showsIcons)

        menu.close(commit: false)
        model.showsIcons = true
        menu.open(model, at: CGPoint(x: 300, y: 500), selectName: false)
        XCTAssertNotNil(menu.panel, "Choosing an icon still opens the editor directly")
    }

    func testRenameAndChangeIconStillOpenTheEditorOnceTheMenuIsGone() {
        var opened: [(model: WorkspaceSidebarIdentityMenuModel, showsIcons: Bool)] = []
        weak var released: WorkspaceSidebarIdentityMenuModel?
        autoreleasepool {
            // In the app, the menu's items are all that hold the model, and they go when it closes.
            let model = WorkspaceSidebarIdentityMenuModel(name: "Work", color: nil, emoji: nil, rename: { _ in },
                setColor: { _ in }, setEmoji: { _ in }, entries: [])
            model.openEditor = { opened.append(($0, $1)) }
            released = model
            model.entries.first { $0.title == "Change Icon…" }?.perform?()
        }
        XCTAssertTrue(opened.isEmpty, "Only after the menu has closed")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first?.model === released)
        XCTAssertEqual(opened.first?.showsIcons, true)
    }

    func testChangeIconOpensTheEditorReadyToSearchIcons() throws {
        let menu = WorkspaceSidebarIdentityMenu()
        defer { menu.close(commit: false) }
        let model = WorkspaceSidebarIdentityMenuModel(name: "Work", color: nil, emoji: nil, rename: { _ in },
            setColor: { _ in }, setEmoji: { _ in }, entries: [])
        model.showsIcons = true
        menu.openEditor(model, at: CGPoint(x: 300, y: 500), selectName: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let editor = try XCTUnwrap(try XCTUnwrap(menu.panel).firstResponder as? NSTextView)
        XCTAssertEqual((editor.delegate as? NSTextField)?.placeholderString, "Search emoji or paste one",
            "Typing searches icons, not the name")
    }

    func testANewerMenuOrTheEditorCancelsAMenuStillWaitingToOpen() {
        let menu = WorkspaceSidebarIdentityMenu()
        var shown = 0
        menu.presentNativeMenu = { _, _ in shown += 1 }
        defer { menu.close(commit: false) }
        let model = WorkspaceSidebarIdentityMenuModel(name: "Work", color: nil, emoji: nil, rename: { _ in },
            setColor: { _ in }, setEmoji: { _ in }, entries: [])
        menu.open(model, at: .zero, selectName: false)
        menu.open(model, at: .zero, selectName: false)
        menu.openEditor(model, at: CGPoint(x: 300, y: 500), selectName: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(shown, 0)
        menu.close(commit: false)
        menu.open(model, at: .zero, selectName: false)
        menu.open(model, at: .zero, selectName: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(shown, 1, "Only the latest request opens")
    }

    func testAQueuedEditorGivesWayToANewerMenu() {
        let menu = WorkspaceSidebarIdentityMenu()
        var shown: [NSMenu] = []
        menu.presentNativeMenu = { menu, _ in shown.append(menu) }
        defer { menu.close(commit: false) }
        let first = WorkspaceSidebarIdentityMenuModel(name: "First", color: nil, emoji: nil, rename: { _ in },
            setColor: { _ in }, setEmoji: { _ in }, entries: [])
        let second = WorkspaceSidebarIdentityMenuModel(name: "Second", color: nil, emoji: nil, rename: { _ in },
            setColor: { _ in }, setEmoji: { _ in }, entries: [])
        menu.open(first, at: .zero, selectName: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        first.entries.first { $0.title == "Rename…" }?.perform?()
        // Before the queued editor opens, another item's menu is asked for.
        menu.open(second, at: .zero, selectName: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertNil(menu.panel, "The older item's editor doesn't replace the newer menu")
        XCTAssertEqual(shown.count, 2)
        second.entries.first { $0.title == "Rename…" }?.perform?()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertNotNil(menu.panel)
        XCTAssertEqual(menu.panel.flatMap { ($0.contentView as? NSHostingView<WorkspaceSidebarIdentityMenuView>)?.rootView.model.name }, "Second")
    }

    func testTheSidebarStaysOpenWhileOneOfTheseMenusTracks() {
        var visibleWhileTracking: Bool?
        WorkspaceSidebarIdentityMenu.shared.presentNativeMenu = { _, _ in visibleWhileTracking = WorkspaceSidebarIdentityMenu.isVisible }
        WorkspaceSidebarIdentityMenu.shared.show(NSMenu(), at: .zero)
        XCTAssertNil(visibleWhileTracking)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(visibleWhileTracking, true, "Even with the pointer elsewhere, as from VoiceOver")
        XCTAssertFalse(WorkspaceSidebarIdentityMenu.isVisible)
    }

    func testShowMenuWithoutAClickOpensAtTheControlForItsSidebar() throws {
        let window = NSWindow(contentRect: CGRect(x: 200, y: 300, width: 240, height: 100), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let control = NSView(frame: CGRect(x: 20, y: 30, width: 200, height: 36))
        window.contentView?.addSubview(control)
        let anchor = WorkspaceSidebarMenuAnchor()
        XCTAssertNil(anchor.point)
        anchor.view = control
        XCTAssertEqual(anchor.point, CGPoint(x: 220, y: 330), "Its bottom-left corner on screen, not the pointer")
        XCTAssertNil(anchor.monitorScopeId, "Outside a sidebar there's no sidebar display to act for")

        TrayMenuModel.shared.workspaceSidebarWorkspaces = [tab("one", ids: [7])]
        WorkspaceSidebarIdentityMenu.show(.tab("one", windowId: 7), from: anchor)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        guard case .point(let point) = try XCTUnwrap(presented.last).origin else { return XCTFail("No click") }
        XCTAssertEqual(point, CGPoint(x: 220, y: 330))

        // A sidebar's own display, not the pointer's, is what its menu's actions are for.
        var scopes: [String?] = []
        let model = try XCTUnwrap(WorkspaceSidebarIdentityMenu.model(for: .project(workspaceProjectDefaultId),
            at: CGPoint(x: 5000, y: 5000), scope: "monitor:1728,0", sendAction: { _, scope in scopes.append(scope) }))
        model.entries.first { $0.title == "Switch to Project" }?.perform?()
        XCTAssertEqual(scopes, ["monitor:1728,0"])
    }

    func testLongDisplayAndWorkspaceNamesAreShortenedButKeepWhatTheySay() {
        let display = "Studio Display (Conference Room B, 3rd floor, east wing)"
        var workspace = tab("code", ids: [1])
        workspace.savedState = nil
        let tabs = workspaceSidebarWorkspaceMenuEntries(workspace, context: .init(monitorCount: 2,
            currentDisplayName: display, currentDisplayHasIdentity: false, separatesIntoTabs: true))
        let keepOn = tabs.first { $0.title.hasPrefix("Keep on") }
        XCTAssertEqual(keepOn?.title, "Keep on “\(workspaceSidebarMenuName(display))” (Display Not Recognized)")
        XCTAssertEqual(keepOn?.fullTitle, "Keep on “\(display)” (Display Not Recognized)")
        XCTAssertEqual(keepOn?.enabled, false)
        let item = workspaceSidebarNativeAppMenu(tabs.map { workspaceSidebarAppMenuEntry($0, send: { _ in }) })
            .items.first { $0.title.hasPrefix("Keep on") }
        XCTAssertEqual(item?.toolTip, keepOn?.fullTitle)
        let header = WorkspaceSidebarAppMenuEntry.header(named: "A workspace with a rather long display name here") { "TextEdit · \($0)" }
        XCTAssertEqual(header.kind, .header)
        XCTAssertEqual(header.fullTitle, "TextEdit · A workspace with a rather long display name here")
        XCTAssertLessThan(header.title.count, header.fullTitle?.count ?? 0)
    }

    func testOnlyARightClickOrControlClickOpensTheMenu() throws {
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        XCTAssertTrue(workspaceSidebarOpensContextMenu(try event(.rightMouseDown)))
        XCTAssertTrue(workspaceSidebarOpensContextMenu(try event(.leftMouseDown, .control)))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseDown] {
            XCTAssertFalse(workspaceSidebarOpensContextMenu(try event(type)), "\(type) reaches the row")
        }
        XCTAssertFalse(workspaceSidebarOpensContextMenu(try event(.leftMouseDown, .command)))
    }

    func testClicksReachTheRowWhileARightClickOpensItsOwnMenu() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        TrayMenuModel.shared.workspaceSidebarWorkspaces = [tab("one", ids: [7]), tab("two", ids: [8])]
        var clicks = 0
        let size = CGSize(width: 240, height: 40)
        let row = Button { clicks += 1 } label: { Color.gray.frame(width: size.width, height: size.height) }
            .buttonStyle(.plain)
            .modifier(WorkspaceSidebarTabRowMenu(target: .tab("one", windowId: 7), close: {}))
        let host = NSHostingView(rootView: row.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 300, y: 200), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let location = host.convert(CGPoint(x: 120, y: 20), to: nil)
        func send(_ types: [NSEvent.EventType], _ flags: NSEvent.ModifierFlags = []) throws {
            for type in types {
                NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)), atStart: false)
            }
            let deadline = Date().addingTimeInterval(0.2)
            while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp],
                until: deadline, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }

        try send([.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(clicks, 1, "A click goes to the row, which selects the tab")
        XCTAssertTrue(presented.isEmpty)

        try send([.rightMouseDown, .rightMouseUp])
        XCTAssertEqual(clicks, 1, "A right-click doesn't select")
        let menu = try XCTUnwrap(presented.last)
        guard case .click = menu.origin else { return XCTFail("Tracks with the right-click") }
        XCTAssertEqual(menu.menu.items.first?.title, "Pin Tab")
        XCTAssertEqual(menu.menu.items.last?.title, "Close Window")

        try send([.leftMouseDown, .leftMouseUp], .control)
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(presented.count, 2, "Control-click is a right-click")

        // An app's menu, too, is built when it opens and shown the same way.
        var built = 0
        let app = NSHostingView(rootView: Color.gray.frame(width: size.width, height: size.height)
            .modifier(WorkspaceSidebarNativeContextMenu { built += 1; return [.header("TextEdit · Code"), .init(title: "Quit TextEdit")] }))
        window.contentView = app
        app.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(built, 0, "Not while drawing")
        try send([.rightMouseDown, .rightMouseUp])
        XCTAssertEqual(built, 1)
        XCTAssertEqual(presented.last?.menu.items.map(\.title), ["TextEdit · Code", "Quit TextEdit"])
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // One of several chosen tabs opens the menu for all of them.
        let selection = WorkspaceSidebarTabSelection.shared
        _ = selection.handleClick(on: "one", modifiers: .command, order: ["one", "two"], active: "two")
        XCTAssertTrue(selection.isMultiple)
        try send([.rightMouseDown, .rightMouseUp])
        XCTAssertEqual(presented.last?.menu.items.first?.title, "2 Tabs")
    }

    /// The sidebar panel isn't key until something in it needs the keyboard, so a click there
    /// is its "first mouse", which AppKit gives only to views that accept it. Its hosting view
    /// does; the menu's trigger has to as well, or a Control-click opens nothing.
    func testControlClickOnARowOfTheNonKeySidebarOpensTheSameMenuAsARightClick() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        TrayMenuModel.shared.workspaceSidebarWorkspaces = [tab("one", ids: [7])]
        var clicks = 0
        var dragChanges = 0
        var dragEnds = 0
        let size = CGSize(width: 240, height: 40)
        let row = Button { clicks += 1 } label: { Color.gray.frame(width: size.width, height: size.height) }
            .buttonStyle(.plain)
            .highPriorityGesture(DragGesture(minimumDistance: 4)
                .onChanged { _ in dragChanges += 1 }
                .onEnded { _ in dragEnds += 1 })
            .modifier(WorkspaceSidebarTabRowMenu(target: .tab("one", windowId: 7), close: {}))
        let panel = SidebarLikePanel(contentRect: CGRect(origin: CGPoint(x: 300, y: 200), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = FirstMouseHostingView(rootView: AnyView(row.frame(width: size.width, height: size.height)))
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(panel.isKeyWindow)
        func send(_ steps: [(NSEvent.EventType, CGFloat)], _ flags: NSEvent.ModifierFlags = []) throws {
            for (type, x) in steps {
                NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: host.convert(CGPoint(x: x, y: 20), to: nil),
                    modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)), atStart: false)
            }
            let deadline = Date().addingTimeInterval(0.25)
            while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp],
                until: deadline, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }

        try send([(.leftMouseDown, 120), (.leftMouseUp, 120)], .control)
        let control = try XCTUnwrap(presented.last, "A Control-click opens the row's menu while the sidebar isn't key")
        guard case .click = control.origin else { return XCTFail("It tracks with the click") }
        XCTAssertEqual(clicks, 0, "and doesn't select the tab")

        try send([(.rightMouseDown, 120), (.rightMouseUp, 120)])
        XCTAssertEqual(presented.count, 2)
        XCTAssertEqual(presented.map { $0.menu.items.map(\.title) }.first, presented.map { $0.menu.items.map(\.title) }.last,
            "The same menu, for the same tab, as a right-click")

        panel.orderOut(nil)
        panel.orderFrontRegardless()
        try send([(.leftMouseDown, 120), (.leftMouseUp, 120)])
        XCTAssertEqual(clicks, 1, "A plain click still reaches the row")
        try send([(.leftMouseDown, 60), (.leftMouseDragged, 90), (.leftMouseDragged, 140), (.leftMouseUp, 140)])
        XCTAssertGreaterThan(dragChanges, 0, "and so does a drag")
        XCTAssertEqual(dragEnds, 1)
        XCTAssertEqual(presented.count, 2, "Neither opens a menu")
    }
}

/// Like the sidebar: a panel that can become key, without activating the app.
private final class SidebarLikePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
