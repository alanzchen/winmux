import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarCollectionsTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
    }

    override func tearDown() {
        config = defaultConfig
        workspaceSidebarOrganizationStore = .init()
    }

    func testGroupingAndUngroupingKeepWindowLayoutsAndFocus() throws {
        let a = focus.workspace
        let left = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        _ = TestWindow.new(id: 2, parent: a.rootTilingContainer)
        let b = Workspace.get(byName: "second")
        _ = TestWindow.new(id: 3, parent: b.rootTilingContainer)
        XCTAssertTrue(left.focusWindow())
        let before = a.rootTilingContainer.layoutDescription
        let group = try workspaceSidebarOrganizationStore.create(projectId: a.projectId, workspaceNames: [a.name, b.name])
        XCTAssertEqual(a.rootTilingContainer.layoutDescription, before)
        XCTAssertEqual(b.allLeafWindowsRecursive.map(\.windowId), [3])
        XCTAssertTrue(focus.windowOrNil === left)
        try workspaceSidebarOrganizationStore.update { $0.collections.removeAll { $0.id == group.id } }
        XCTAssertEqual(a.rootTilingContainer.layoutDescription, before)
        XCTAssertTrue(focus.windowOrNil === left)
    }

    func testCollectionsAndAppearanceSurviveReloadAndModeChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("organization.json")
        let store = WorkspaceSidebarOrganizationStore(url: url)
        let group = try store.create(projectId: "work", workspaceNames: ["one", "two"])
        try store.edit(group.id) { $0.name = "Engineering"; $0.colorHex = "#009AD0"; $0.emoji = "💻"; $0.isCollapsed = true }
        try store.update { $0.workspaces["one"] = .init(colorHex: "#DE85A3", emoji: "🌸", isFavorite: false) }
        let loaded = WorkspaceSidebarOrganizationStore.load(url: url)
        XCTAssertNil(loaded.readOnlyReason)
        XCTAssertEqual(loaded.state, store.state)
        workspaceSidebarOrganizationStore = loaded
        config.workspaceSidebar.mode = .dock
        XCTAssertFalse(config.usesBrowserTabs)
        config.workspaceSidebar.mode = .tabs
        XCTAssertEqual(workspaceSidebarConfiguration().tabCollections, store.state.collections)
    }

    func testCorruptAndNewerFilesArePreservedAndFailedWritesAreNotPublished() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for contents in ["broken", "{\"version\":99}"] {
            try Data(contents.utf8).write(to: url)
            let store = WorkspaceSidebarOrganizationStore.load(url: url)
            XCTAssertNotNil(store.readOnlyReason)
            XCTAssertThrowsError(try store.create(projectId: "work", workspaceNames: ["one"]))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), contents)
        }
        let failed = WorkspaceSidebarOrganizationStore(url: url.appendingPathComponent("cannot-write.json"))
        XCTAssertThrowsError(try failed.create(projectId: "work", workspaceNames: ["one"]))
        XCTAssertTrue(failed.state.collections.isEmpty)
    }

    func testMovingMembershipIsUniqueAndRejectsOtherProjects() throws {
        let store = WorkspaceSidebarOrganizationStore()
        let first = try store.create(projectId: "work", workspaceNames: ["one", "two"])
        let second = try store.create(projectId: "work", workspaceNames: ["three"])
        try store.assign("two", projectId: "work", to: second.id)
        XCTAssertEqual(store.state.collections.first { $0.id == first.id }?.workspaceNames, ["one"])
        XCTAssertEqual(store.collection(containing: "two")?.id, second.id)
        XCTAssertThrowsError(try store.assign("two", projectId: "personal", to: first.id))
        XCTAssertEqual(store.collection(containing: "two")?.id, second.id)
    }

    func testGroupMoveAndDeletionKeepWorkspaceIdentityAndSplits() throws {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        _ = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        XCTAssertTrue(first.focusWindow())
        let group = try workspaceSidebarOrganizationStore.create(projectId: workspace.projectId, workspaceNames: [])
        try assignWorkspaceToSidebarCollection(workspace, collectionId: group.id)
        XCTAssertTrue(workspace.isSaved, "Grouped tabs reserve their names across relaunch")
        let tree = workspace.rootTilingContainer.layoutDescription
        let destination = createWorkspaceProject()
        try moveWorkspaceSidebarCollection(group.id, to: destination.id)
        XCTAssertEqual(workspace.projectId, destination.id)
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: workspace.name)?.projectId, destination.id)
        XCTAssertEqual(workspace.rootTilingContainer.layoutDescription, tree)
        XCTAssertTrue(focus.windowOrNil === first)
        try deleteWorkspaceProject(destination.id)
        XCTAssertTrue(workspaceSidebarOrganizationStore.state.collections.isEmpty)
    }

    func testGroupSearchKeepsSplitAndAppearance() throws {
        let snapshot = fixture()
        let group = WorkspaceTabCollection(projectId: "default", name: "Website Eng", workspaceNames: ["2"])
        let result = workspaceSidebarFilteredWorkspacesByProject(["default": snapshot.workspaces], projects: snapshot.projects,
            query: "website", collections: [group])["default"] ?? []
        XCTAssertEqual(result.map(\.name), ["2"])
        XCTAssertEqual(result.first?.items.count, 2)
        let favorite = workspaceSidebarFilteredWorkspacesByProject(["default": snapshot.workspaces], projects: snapshot.projects,
            query: "Mail")["default"]?.first
        XCTAssertEqual(favorite?.appearance.isFavorite, true)
    }

    func testForgettingASavedTabClearsMetadataBeforeItsNameCanBeReused() throws {
        let workspace = focus.workspace
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let group = try workspaceSidebarOrganizationStore.create(projectId: workspace.projectId, workspaceNames: [])
        try assignWorkspaceToSidebarCollection(workspace, collectionId: group.id)
        try workspaceSidebarOrganizationStore.update { $0.workspaces[workspace.name] = .init(emoji: "💻") }
        XCTAssertTrue(try forgetSavedWorkspace(workspace))
        XCTAssertNil(workspaceSidebarOrganizationStore.collection(containing: workspace.name))
        XCTAssertNil(workspaceSidebarOrganizationStore.state.workspaces[workspace.name])
        XCTAssertEqual(workspace.allLeafWindowsRecursive.map(\.windowId), [1])
    }

    func testCancellingNewGroupedTabRemovesItsSavedPlaceholder() throws {
        let original = focus.workspace
        _ = TestWindow.new(id: 1, parent: original.rootTilingContainer)
        let group = try workspaceSidebarOrganizationStore.create(projectId: original.projectId, workspaceNames: [])
        var tab = newTabWorkspace(projectId: original.projectId, monitor: original.workspaceMonitor)
        tab.discardsSavedPlaceholderOnCancel = true
        try assignWorkspaceToSidebarCollection(tab.workspace, collectionId: group.id)
        XCTAssertTrue(tab.workspace.focusWorkspace())
        closeUnusedNewTab(tab)
        XCTAssertNil(Workspace.existing(byName: tab.workspace.name))
        XCTAssertFalse(savedWorkspaceStore.contains(workspaceName: tab.workspace.name))
        XCTAssertTrue(workspaceSidebarOrganizationStore.state.collections[0].workspaceNames.isEmpty)
        XCTAssertTrue(focus.workspace === original)

        var used = newTabWorkspace(projectId: original.projectId, monitor: original.workspaceMonitor)
        used.discardsSavedPlaceholderOnCancel = true
        try assignWorkspaceToSidebarCollection(used.workspace, collectionId: group.id)
        _ = TestWindow.new(id: 2, parent: used.workspace.rootTilingContainer)
        closeUnusedNewTab(used)
        XCTAssertTrue(Workspace.existing(byName: used.workspace.name) === used.workspace, "An opened window always protects its tab")
    }

    func testNewGroupTabIsFreshAndFollowsGroupInsteadOfCurrentTab() throws {
        let current = focus.workspace
        let member = Workspace.get(byName: "member")
        _ = TestWindow.new(id: 1, parent: member.rootTilingContainer)
        let group = try workspaceSidebarOrganizationStore.create(projectId: current.projectId, workspaceNames: [member.name])
        let tab = try XCTUnwrap(newTabInSidebarCollection(group.id, monitor: current.workspaceMonitor))
        XCTAssertFalse(tab.workspace === current, "An empty current tab is never hijacked into the group")
        XCTAssertFalse(current.isSaved)
        XCTAssertTrue(tab.previous === current)
        let order = orderedWorkspaces(in: current.projectId)
        XCTAssertEqual(order.firstIndex(of: tab.workspace), try XCTUnwrap(order.firstIndex(of: member)) + 1)
        closeUnusedNewTab(tab)
        XCTAssertFalse(savedWorkspaceStore.contains(workspaceName: tab.workspace.name))
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections[0].workspaceNames, [member.name])
    }

    func testNewGroupTabCancellationReturnsAcrossProjectBoundaries() throws {
        let current = focus.workspace
        _ = TestWindow.new(id: 1, parent: current.rootTilingContainer)
        let project = createWorkspaceProject()
        let group = try workspaceSidebarOrganizationStore.create(projectId: project.id, workspaceNames: [])
        let tab = try XCTUnwrap(newTabInSidebarCollection(group.id, monitor: current.workspaceMonitor))
        XCTAssertTrue(tab.workspace.focusWorkspace())
        Workspace.reconcileWorkspaceState()
        closeUnusedNewTab(tab)
        XCTAssertTrue(focus.workspace === current)
        XCTAssertFalse(savedWorkspaceStore.contains(workspaceName: tab.workspace.name))
    }

    func testWholeTabGapDropAcrossDisplaysKeepsItsSavedIdentity() throws {
        let laptop = SavedWorkspaceTestMonitor(id: 1, name: "Laptop", x: 0, isMain: true, uuid: "LAPTOP", isBuiltin: true)
        let display = SavedWorkspaceTestMonitor(id: 2, name: "Display", x: 1920, uuid: "DISPLAY")
        setMonitorsForTests([laptop, display])
        defer { setMonitorsForTests(nil) }
        let source = focus.workspace
        let window = TestWindow.new(id: 1, parent: source.rootTilingContainer)
        XCTAssertTrue(laptop.setActiveWorkspace(source))
        let target = Workspace.get(byName: "target")
        _ = TestWindow.new(id: 2, parent: target.rootTilingContainer)
        XCTAssertTrue(display.setActiveWorkspace(target))
        let group = try workspaceSidebarOrganizationStore.create(projectId: source.projectId, workspaceNames: [])
        try assignWorkspaceToSidebarCollection(source, collectionId: group.id)
        try workspaceSidebarOrganizationStore.update { $0.workspaces[source.name] = .init(colorHex: "#009AD0", emoji: "💻") }
        applyTabGapDrop(sourceNode: window, sourceWindow: window, projectId: source.projectId, monitor: display,
            gap: .init(workspaceName: target.name, isAfter: true, collectionId: group.id))
        XCTAssertTrue(window.nodeWorkspace === source)
        XCTAssertTrue(source.isSaved)
        XCTAssertTrue(display.activeWorkspace === source)
        XCTAssertFalse(laptop.activeWorkspace === source)
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces[source.name]?.emoji, "💻")
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: source.name)?.id, group.id)
        XCTAssertEqual(source.allLeafWindowsRecursive.map(\.windowId), [1])
    }

    func testGapDropsMoveMembershipAndSplitWindowsWithoutChangingOthers() throws {
        let first = focus.workspace
        let left = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        _ = TestWindow.new(id: 2, parent: first.rootTilingContainer)
        let anchor = Workspace.get(byName: "anchor")
        _ = TestWindow.new(id: 3, parent: anchor.rootTilingContainer)
        let group = try workspaceSidebarOrganizationStore.create(projectId: first.projectId, workspaceNames: [anchor.name])
        applyTabGapDrop(sourceNode: left, sourceWindow: left, projectId: first.projectId, monitor: first.workspaceMonitor,
            gap: .init(workspaceName: anchor.name, isAfter: true, collectionId: group.id))
        let extracted = try XCTUnwrap(left.nodeWorkspace)
        XCTAssertFalse(extracted === first)
        XCTAssertEqual(first.allLeafWindowsRecursive.map(\.windowId), [2])
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: extracted.name)?.id, group.id)
        XCTAssertTrue(extracted.isSaved)
        applyTabGapDrop(sourceNode: left, sourceWindow: left, projectId: first.projectId, monitor: first.workspaceMonitor,
            gap: .init(workspaceName: first.name, isAfter: false))
        XCTAssertTrue(left.nodeWorkspace === extracted)
        XCTAssertNil(workspaceSidebarOrganizationStore.collection(containing: extracted.name))
        XCTAssertEqual(anchor.allLeafWindowsRecursive.map(\.windowId), [3])
    }

    func testEditorPanelSupportsAppearanceChangesAndDismissal() throws {
        var names: [String] = []
        var colors: [String?] = []
        let model = WorkspaceSidebarIdentityMenuModel(name: "Design", color: nil, emoji: nil,
            rename: { names.append($0) }, setColor: { colors.append($0) }, setEmoji: { _ in }, entries: [])
        let editor = WorkspaceSidebarIdentityMenu()
        defer { editor.close(commit: false) }
        editor.open(model, at: CGPoint(x: 300, y: 500), selectName: true)
        XCTAssertGreaterThan(try XCTUnwrap(editor.panel).frame.width, 250, "Initial layout precedes presentation")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        let panel = try XCTUnwrap(editor.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(panel.firstResponder is NSTextView, "Renaming uses a native text editor with keyboard focus")
        XCTAssertGreaterThan(panel.frame.width, 250)
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        let auxiliary = NSPanel(contentRect: CGRect(x: 600, y: 400, width: 80, height: 80),
            styleMask: .titled, backing: .buffered, defer: false)
        auxiliary.makeKeyAndOrderFront(nil)
        editor.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        XCTAssertTrue(panel.isVisible, "A tracking submenu can temporarily own keyboard focus")
        auxiliary.orderOut(nil)
        panel.makeKey()
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        model.chooseColor("#009AD0")
        XCTAssertTrue(panel.isVisible, "Swatches keep the native editor open")
        model.name = "Discard this draft"
        editor.close(commit: false)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(names.isEmpty)
        XCTAssertEqual(colors, ["#009AD0"])
        model.name = "  Engineering  "
        editor.open(model, at: CGPoint(x: 300, y: 500), selectName: true)
        editor.close(commit: true)
        XCTAssertEqual(names, ["Engineering"])
        editor.open(model, at: CGPoint(x: 300, y: 500), selectName: true)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertNil(editor.panel, "Keyboard app switches dismiss the floating editor")
    }

    func testUngroupedRowsAreTheDefaultAndSplitsStayInsideOneRow() {
        let tabs = fixture().workspaces
        XCTAssertEqual(workspaceSidebarTabSections(workspaces: tabs, collections: [], projectId: "default").count, tabs.count)
        let group = WorkspaceTabCollection(projectId: "default", workspaceNames: ["2", "3"])
        let sections = workspaceSidebarTabSections(workspaces: tabs, collections: [group], projectId: "default")
        XCTAssertEqual(sections.count, tabs.count - 1)
        guard case .collection(_, let members) = sections[1] else { return XCTFail("Group at its first member") }
        XCTAssertEqual(members.map(\.name), ["2", "3"])
        guard case .split = workspaceSidebarTabPresentation(members[0]) else { return XCTFail("Split remains one row") }
    }

    func testTabsHasIndependentPersistentDefault() {
        config.workspaceSidebar.alwaysExpanded = false
        XCTAssertTrue(config.workspaceSidebar.pinsSidebarOpen)
        XCTAssertEqual(workspaceSidebarReservedWidth(config.workspaceSidebar), CGFloat(config.workspaceSidebar.width))
        config.workspaceSidebar.tabsAlwaysExpanded = false
        XCTAssertFalse(config.workspaceSidebar.pinsSidebarOpen)
        config.workspaceSidebar.mode = .sidebar
        XCTAssertFalse(config.workspaceSidebar.pinsSidebarOpen)
        config.workspaceSidebar.alwaysExpanded = true
        XCTAssertTrue(config.workspaceSidebar.pinsSidebarOpen)
        let (parsed, errors) = parseConfig("[workspace-sidebar]\nmode = 'tabs'\nalways-expanded = false")
        XCTAssertEqual(errors.descriptions, [])
        XCTAssertTrue(parsed.workspaceSidebar.pinsSidebarOpen)
    }

    func testMigratingStacksPreservesFocusAndSplitSubtrees() throws {
        let workspace = focus.workspace
        let stack = workspace.rootTilingContainer
        stack.layout = .tabGroup
        let split = TilingContainer(parent: stack, adaptiveWeight: WEIGHT_AUTO, .h, .tiles, index: INDEX_BIND_LAST)
        let one = TestWindow.new(id: 1, parent: split)
        let two = TestWindow.new(id: 2, parent: split)
        let selected = TestWindow.new(id: 3, parent: stack)
        XCTAssertTrue(selected.focusWindow())
        migrateWindowStacksToSidebarTabs()
        XCTAssertTrue(focus.windowOrNil === selected)
        XCTAssertEqual(workspace.allLeafWindowsRecursive.map(\.windowId), [3])
        XCTAssertTrue(one.nodeWorkspace === two.nodeWorkspace)
        XCTAssertFalse(one.nodeWorkspace === workspace)
        XCTAssertTrue(one.parent === two.parent)
        XCTAssertEqual((one.parent as? TilingContainer)?.layout, .tiles)
        let count = Workspace.all.count
        migrateWindowStacksToSidebarTabs()
        XCTAssertEqual(Workspace.all.count, count, "Migration is idempotent")
    }

    func testOtherModesRetainStacksAndTabsCannotCreateNewOnes() {
        let workspace = focus.workspace
        let one = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let two = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        createOrAppendWindowTabStack(sourceWindow: one, onto: two)
        XCTAssertEqual(workspace.rootTilingContainer.children.count, 2)
        config.workspaceSidebar.mode = .sidebar
        createOrAppendWindowTabStack(sourceWindow: one, onto: two)
        migrateWindowStacksToSidebarTabs()
        XCTAssertEqual((one.parent as? TilingContainer)?.layout, .tabGroup)
        XCTAssertEqual(workspaceSidebarTabDropPlacement(pointX: 10, targetMidX: 20, subject: .window, optionHeld: true), .left)
    }

    func testIdentityEditingCommitsTrimmedNameAndPaletteWithoutClosing() {
        var names: [String] = []
        var colors: [String?] = []
        var emojis: [String?] = []
        let model = WorkspaceSidebarIdentityMenuModel(name: "Work", color: nil, emoji: nil,
            rename: { names.append($0) }, setColor: { colors.append($0) }, setEmoji: { emojis.append($0) }, entries: [])
        model.name = "  Design  "
        model.chooseColor("#009AD0")
        model.chooseEmoji("✏️")
        model.commitName()
        XCTAssertEqual(names, ["Design"])
        XCTAssertEqual(colors, ["#009AD0"])
        XCTAssertEqual(emojis, ["✏️"])
        XCTAssertEqual(workspaceSidebarEmojiMatches("pencil").map(\.emoji), ["✏️"])
        XCTAssertEqual(workspaceSidebarEmojiMatches("🦄").map(\.emoji), ["🦄"])
    }

    func testRenderSidebarAndSharedEditorInBothAppearances() throws {
        var snapshot = fixture()
        snapshot.configuration.tabCollections = [
            .init(id: "engineering", projectId: "default", name: "Website Eng", colorHex: "#BA8400", workspaceNames: ["2", "3"]),
            .init(id: "marketing", projectId: "default", name: "Spring Marketing", colorHex: "#C65F88", workspaceNames: ["4", "5"]),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let view = WorkspaceSidebarView(snapshot: snapshot, reduceMotionOverride: true, reduceTransparencyOverride: true)
            try render(view.sidebarContent(expansionProgress: 1, layout: snapshot.configuration).environment(\.colorScheme, scheme),
                width: 280, height: 670, name: "collections-\(scheme).png")
            let model = WorkspaceSidebarIdentityMenuModel(name: "Design Sketches", color: "#E8B000", emoji: nil,
                rename: { _ in }, setColor: { _ in }, setEmoji: { _ in },
                entries: [.init(title: "Move Group to", children: [.init(title: "Personal")]), .init(title: "Ungroup Tabs"),
                    .separator, .init(title: "New Tab in Group")])
            model.showsIcons = true
            model.query = "pencil"
            try render(WorkspaceSidebarIdentityMenuView(model: model).environment(\.colorScheme, scheme),
                width: 530, height: 330, name: "identity-menu-\(scheme).png")
        }
    }

    private func render(_ view: some View, width: CGFloat, height: CGFloat, name: String) throws {
        let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = projectRoot.appendingPathComponent(".build/sidebar-tabs-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }

    private func fixture() -> WorkspaceSidebarSnapshot {
        var result = WorkspaceSidebarSnapshot.empty
        result.configuration = .init(collapsedWidth: 44, expandedWidth: 280, topPadding: 12,
            showMonitorSelector: false, showsClock: false, showsSeconds: false, showsDate: false, showsWeekday: false,
            showsStatusPills: false, chromeStyle: .solid, solidChromeColor: .midnight, solidChromeCustomColor: "#191B20",
            usesTabsList: true, alwaysExpanded: true)
        result.visibleWidth = 280
        result.targetMonitorScopeId = "monitor:0,0"
        result.projects = [.init(id: "default", displayName: "Work", colorHex: "#6FAABE", emoji: nil)]
        let titles = [["Mail"], ["Editor", "Preview"], ["Kickoff Doc"], ["Marketing plan"], ["Spring campaign"]]
        for (index, names) in titles.enumerated() {
            let workspaceName = "\(index + 1)"
            var items: [WorkspaceSidebarItemViewModel] = []
            for (offset, title) in names.enumerated() {
                let window = WorkspaceSidebarWindowViewModel(windowId: UInt32(index * 2 + offset + 1),
                    workspaceName: workspaceName, appName: "Safari", appBundleId: "com.apple.Safari",
                    appBundlePath: nil, title: title, isFocused: index == 2)
                items.append(.init(kind: .window(window)))
            }
            let workspace = WorkspaceSidebarWorkspaceViewModel(name: workspaceName, projectId: "default",
                displayName: names.joined(separator: " / "), sidebarLabel: "", isGeneratedName: true,
                monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: index == 2, isVisible: index == 2,
                items: items, appearance: .init(isFavorite: index == 0))
            result.workspaces.append(workspace)
        }
        return result
    }
}
