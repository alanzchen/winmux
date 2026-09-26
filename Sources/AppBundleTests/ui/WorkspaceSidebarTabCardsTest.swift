import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarTabCardsTest: XCTestCase {
    override func tearDown() {
        config = defaultConfig
        super.tearDown()
    }

    func testMostWorkspacesAreASingleTabAndTwoWindowsShareOne() {
        let one = workspace("1", windows: [window(1, "Inbox")])
        let two = workspace("2", windows: [window(2, "Draft"), window(3, "Notes")])
        let three = workspace("3", windows: [window(4, "a"), window(5, "b"), window(6, "c")])
        XCTAssertEqual(workspaceSidebarTabPresentation(one), .single(window(1, "Inbox")))
        XCTAssertEqual(workspaceSidebarTabPresentation(two), .split(window(2, "Draft"), window(3, "Notes")))
        XCTAssertEqual(workspaceSidebarTabPresentation(workspace("4", windows: [])), .empty, "A new tab waiting for an app")
        XCTAssertEqual(workspaceSidebarTabPresentation(three), .folder)

        XCTAssertEqual(workspaceSidebarTabPresentation(workspace("Mail", windows: [window(1, "Inbox")], generated: false)), .folder,
            "A name you gave it stays visible")
        var saved = one
        saved.savedState = WorkspaceSidebarSavedState(isPinnedToDisplay: false, homeDisplayName: nil, isHomeConnected: true,
            isForceAssignedByConfig: false, missingAppNames: [])
        XCTAssertEqual(workspaceSidebarTabPresentation(saved), .folder)
        XCTAssertEqual(workspaceSidebarTabPresentation(one, showsProjectContext: true), .folder)
        XCTAssertEqual(workspaceSidebarTabPresentation(one, isRenaming: true), .folder, "Renaming happens in the folder header")
        XCTAssertEqual(workspaceSidebarTabPresentation(two, isSearching: true), .folder,
            "A search's matches stay under the workspace they're in")
        let stack = WorkspaceSidebarTabGroupViewModel(representativeWindowId: 7, workspaceName: "5", title: "Stack",
            windowCount: 2, isFocused: false, tabs: [window(7, "x")], allWindows: [window(7, "x"), window(8, "y")])
        let stacked = WorkspaceSidebarWorkspaceViewModel(name: "5", projectId: workspaceProjectDefaultId, displayName: "5",
            sidebarLabel: "", isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: false,
            isVisible: false, items: [.init(kind: .tabGroup(stack))])
        XCTAssertEqual(workspaceSidebarTabPresentation(stacked), .folder, "A stack shows as a group")
    }

    func testMenusDontStackSeparatorsWhenOptionalEntriesAreMissing() {
        let entries: [WorkspaceSidebarWorkspaceMenuEntry] = [.separator, .init(title: "A"), .separator, .separator,
            .init(title: "B"), .separator]
        XCTAssertEqual(workspaceSidebarMenuWithoutStraySeparators(entries).map(\.title), ["A", "", "B"])
    }

    func testDropsOnATabPickItsSideAndItsEdgesAreGapsBetweenTabs() {
        XCTAssertEqual(workspaceSidebarTabDropPlacement(pointX: 10, targetMidX: 50, subject: .window, optionHeld: false), .left)
        XCTAssertEqual(workspaceSidebarTabDropPlacement(pointX: 80, targetMidX: 50, subject: .window, optionHeld: false), .right)
        XCTAssertEqual(workspaceSidebarTabDropPlacement(pointX: 80, targetMidX: 50, subject: .window, optionHeld: true), .stack)
        XCTAssertEqual(workspaceSidebarTabDropPlacement(pointX: 80, targetMidX: 50, subject: .group, optionHeld: true), .right,
            "A stack being dragged can't join another stack")

        let frame = CGRect(x: 0, y: 100, width: 260, height: workspaceSidebarTabRowHeight)
        let targets = workspaceSidebarTabDropTargets(workspaceName: "2", frame: frame,
            gapTarget: (workspaceProjectDefaultId, "monitor:0,0"))
        let surface = CGRect(x: 0, y: 0, width: 260, height: 400)
        func kind(atY y: CGFloat) -> WorkspaceSidebarDropTargetKind? {
            workspaceSidebarLocalDropTarget(at: CGPoint(x: 130, y: y), targets: targets, surface: surface)?.kind
        }
        let before = WorkspaceSidebarDropTargetKind.tabGap(projectId: workspaceProjectDefaultId, monitorScopeId: "monitor:0,0",
            gap: WorkspaceSidebarTabGap(workspaceName: "2", isAfter: false))
        let after = WorkspaceSidebarDropTargetKind.tabGap(projectId: workspaceProjectDefaultId, monitorScopeId: "monitor:0,0",
            gap: WorkspaceSidebarTabGap(workspaceName: "2", isAfter: true))
        XCTAssertEqual(kind(atY: 99), before, "Just above the tab")
        XCTAssertEqual(kind(atY: 103), before)
        XCTAssertEqual(kind(atY: 115), .workspace("2"), "The middle takes the tab itself")
        XCTAssertEqual(kind(atY: 128), after)
        XCTAssertEqual(workspaceSidebarTabDropTargets(workspaceName: "2", frame: frame, gapTarget: nil).map(\.kind),
            [.workspace("2")], "Another project's workspace takes no drops between tabs")

        // A window dragged in from the screen resolves with a generous hit slop, which would
        // let the thin gap bands cover the whole tab; it ignores them.
        let slop = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        XCTAssertEqual(workspaceSidebarLocalDropTarget(at: CGPoint(x: 130, y: 115), targets: targets, surface: surface,
            hitSlop: slop, includesTabGaps: false)?.kind, .workspace("2"))
    }

    func testSeparateIntoTabsIsOfferedInTabsModeForSeveralWindows() {
        let two = workspace("2", windows: [window(2, "Draft"), window(3, "Notes")])
        var context = WorkspaceSidebarWorkspaceMenuContext(monitorCount: 1)
        XCTAssertFalse(workspaceSidebarWorkspaceMenuEntries(two, context: context).contains { $0.title == "Separate into Tabs" })
        context.separatesIntoTabs = true
        XCTAssertTrue(workspaceSidebarWorkspaceMenuEntries(two, context: context).contains {
            $0.title == "Separate into Tabs" && $0.command == .send(.separateWorkspaceIntoTabs("2"))
        })
        XCTAssertFalse(workspaceSidebarWorkspaceMenuEntries(workspace("1", windows: [window(1, "Inbox")]), context: context)
            .contains { $0.title == "Separate into Tabs" }, "One window is already one tab")
    }

    func testSeparatingKeepsTheWindowInUseAndGivesTheOthersTabsInOrder() {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        let workspace = focus.workspace
        let next = Workspace.get(byName: "after")
        _ = TestWindow.new(id: 9, parent: next.rootTilingContainer)
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let inUse = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        _ = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        let floating = TestWindow.new(id: 4, parent: workspace)
        XCTAssertTrue(inUse.focusWindow())

        separateWorkspaceIntoTabs(workspace)

        XCTAssertEqual(workspace.allLeafWindowsRecursive.map(\.windowId), [2])
        let order = orderedWorkspaces(in: workspace.projectId)
        XCTAssertEqual(order.map { $0.allLeafWindowsRecursive.map(\.windowId) }, [[2], [1], [3], [4], [9]],
            "Each window after the one in use, in layout order, before the next tab")
        XCTAssertTrue(focus.windowOrNil === inUse)
        XCTAssertTrue(floating.isFloating, "A floating window stays floating in its tab")
    }

    func testClosingAnEmptyTabMovesOnButTheOnlyTabStays() {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        let empty = focus.workspace
        XCTAssertTrue(empty.isEffectivelyEmpty)
        let elsewhere = Workspace.get(byName: "elsewhere")
        elsewhere.assignProject("other-project")
        _ = TestWindow.new(id: 2, parent: elsewhere.rootTilingContainer)
        closeEmptyTab(empty)
        XCTAssertNotNil(Workspace.existing(byName: empty.name), "The only tab of its project stays")

        let other = Workspace.get(byName: "other")
        _ = TestWindow.new(id: 1, parent: other.rootTilingContainer)
        closeEmptyTab(empty)
        XCTAssertTrue(focus.workspace === other)
        XCTAssertNil(Workspace.existing(byName: empty.name))
    }

    func testDragPreviewShowsTheSideATabJoinsAndWhereItWouldBeInserted() throws {
        var fixture = tabsFixture()
        var preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 4, label: "Paper draft", appName: "TextEdit",
            targetWorkspaceName: "1", targetsNewWorkspace: false, isTabGroup: false, windowCount: 1)
        fixture.dropPreview = preview
        let plain = try render(fixture, name: "tabs-drop-plain.png")
        preview.targetPlacement = .left
        fixture.dropPreview = preview
        let left = try render(fixture, name: "tabs-drop-left.png")
        preview.targetPlacement = .right
        fixture.dropPreview = preview
        let right = try render(fixture, name: "tabs-drop-right.png")
        XCTAssertNotEqual(left, right, "The highlight shows which half")
        XCTAssertNotEqual(right, plain)
        var gapPreview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 4, label: "Paper draft", appName: "TextEdit",
            targetWorkspaceName: nil, targetsNewWorkspace: false, targetProjectId: workspaceProjectDefaultId,
            isTabGroup: false, windowCount: 1)
        gapPreview.targetGap = WorkspaceSidebarTabGap(workspaceName: "2", isAfter: true)
        fixture.dropPreview = gapPreview
        let gap = try render(fixture, name: "tabs-drop-gap.png")
        XCTAssertNotEqual(right, gap)
    }

    private func render(_ fixture: WorkspaceSidebarSnapshot, name: String) throws -> Data {
        let view = WorkspaceSidebarView(snapshot: fixture, reduceMotionOverride: true, reduceTransparencyOverride: true)
        let host = NSHostingView(rootView: view.sidebarContent(expansionProgress: 1, layout: fixture.configuration)
            .coordinateSpace(name: "workspaceSidebarContent")
            .frame(width: 280, height: 300)
            .background(Color(red: 0.12, green: 0.13, blue: 0.16)))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 300)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = projectRoot.appendingPathComponent(".build/sidebar-tabs-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name))
        return png
    }

    private func tabsFixture() -> WorkspaceSidebarSnapshot {
        var fixture = WorkspaceSidebarSnapshot.empty
        fixture.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 44, expandedWidth: 280,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false,
            chromeStyle: .solid, solidChromeColor: .midnight, solidChromeCustomColor: "#191B20",
            showAppIcons: false, usesTabsList: true, alwaysExpanded: true)
        fixture.visibleWidth = 280
        fixture.targetMonitorScopeId = "monitor:0,0"
        fixture.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: "#7BA3C9", emoji: "🔬")]
        fixture.workspaces = [
            workspace("1", windows: [window(1, "WinMux — GitHub")]),
            workspace("2", windows: [window(2, "zsh — winmux", app: "Terminal", bundleId: "com.apple.Terminal")]),
            workspace("3", windows: [window(4, "Paper draft", app: "TextEdit", bundleId: "com.apple.TextEdit")], visible: true),
        ]
        return fixture
    }

    func testTabsRenderAsSingleRowsSplitsAndFoldersThatAllTakeDrops() throws {
        var fixture = WorkspaceSidebarSnapshot.empty
        fixture.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 44, expandedWidth: 280,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false,
            chromeStyle: .solid, solidChromeColor: .midnight, solidChromeCustomColor: "#191B20",
            showAppIcons: false, usesTabsList: true, alwaysExpanded: true)
        fixture.visibleWidth = 280
        fixture.targetMonitorScopeId = "monitor:0,0"
        fixture.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: "#7BA3C9", emoji: "🔬")]
        fixture.workspaces = [
            workspace("1", windows: [window(1, "WinMux — GitHub", focused: true)], visible: true),
            workspace("2", windows: [window(2, "zsh — winmux", app: "Terminal", bundleId: "com.apple.Terminal"),
                window(3, "Sidebar ideas", app: "Notes", bundleId: "com.apple.Notes")]),
            workspace("3", windows: [window(4, "Paper draft", app: "TextEdit", bundleId: "com.apple.TextEdit")]),
            workspace("4", windows: []),
            workspace("Reading", windows: [window(5, "Dia review"), window(6, "Arc spaces"), window(7, "Notes", app: "Notes",
                bundleId: "com.apple.Notes")], generated: false),
        ]
        let view = WorkspaceSidebarView(snapshot: fixture, reduceMotionOverride: true, reduceTransparencyOverride: true)
        let probe = CardsDropTargetProbe()
        let content = view.sidebarContent(expansionProgress: 1, layout: fixture.configuration)
            .coordinateSpace(name: "workspaceSidebarContent")
            .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { probe.targets = $0 }
            .frame(width: 280, height: 520)
            .background(Color(red: 0.12, green: 0.13, blue: 0.16))
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 520)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()

        for workspace in fixture.workspaces {
            let target = try XCTUnwrap(probe.targets.first { $0.kind == .workspace(workspace.name) }, workspace.name)
            if workspace.name != "Reading" {
                XCTAssertLessThanOrEqual(target.frame.height, workspaceSidebarTabRowHeight + 6,
                    "Workspace \(workspace.name) is one row, with no folder header")
            }
            XCTAssertEqual(target.acceptsSides, ["1", "2", "3"].contains(workspace.name),
                "Only a tab with a window takes a drop on one of its halves, not an empty tab or a folder: \(workspace.name)")
        }

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = projectRoot.appendingPathComponent(".build/sidebar-tabs-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("tabs-browser.png"))
    }

    // MARK: - Fixtures

    private func window(_ id: UInt32, _ title: String, focused: Bool = false, app: String = "Safari",
                        bundleId: String? = "com.apple.Safari") -> WorkspaceSidebarWindowViewModel {
        WorkspaceSidebarWindowViewModel(windowId: id, workspaceName: "1", appName: app, appBundleId: bundleId,
            appBundlePath: nil, title: title, isFocused: focused)
    }

    private func workspace(_ name: String, windows: [WorkspaceSidebarWindowViewModel], generated: Bool = true,
                           visible: Bool = false) -> WorkspaceSidebarWorkspaceViewModel {
        WorkspaceSidebarWorkspaceViewModel(name: name, projectId: workspaceProjectDefaultId, displayName: name,
            sidebarLabel: "", isGeneratedName: generated, monitorScopeId: "monitor:0,0", monitorName: nil,
            isFocused: visible, isVisible: visible, items: windows.map { .init(kind: .window($0)) })
    }
}

@MainActor
private final class CardsDropTargetProbe {
    var targets: [WorkspaceSidebarDropTargetFrame] = []
}
