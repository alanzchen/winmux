@testable import AppBundle
import AppKit
import Common
import XCTest

/// Tabs mode never shows an ordinary tab with no window: not in the list, search, groups, counts or
/// drop targets, and tab navigation passes it by. A pin may be empty and shown. An empty tab keeps
/// everything saved about it, and shows again as soon as a window belongs to it.
@MainActor
final class WorkspaceTabsNoEmptyOrdinaryTabTest: XCTestCase {
    private var defaultAppIsFrontmost: (@MainActor (Window) -> Bool)?
    private var clock = savedTestNow
    private let editorId = "com.test.editor"
    private lazy var editor = TestApp(pid: 501, bundleId: editorId, name: "Editor", launchDate: savedTestNow.addingTimeInterval(-86400))
    private let other = TestApp(pid: 600, bundleId: "com.test.other", name: "Other")
    private lazy var running: [String: [SavedRunningApp]] = [
        editorId: [SavedRunningApp(pid: 501, launchDate: savedTestNow.addingTimeInterval(-86400))],
        "com.test.other": [SavedRunningApp(pid: 600, launchDate: savedTestNow.addingTimeInterval(-86400))],
    ]

    override func setUp() async throws {
        defaultAppIsFrontmost = newWindowAppIsFrontmost
        setUpWorkspacesForTests()
        resetWorkspaceTabsForTests()
        savedWorkspaceRuntime.environment = SavedWorkspaceEnvironment(
            now: { [unowned self] in clock },
            runningApps: { [unowned self] in running },
            openApplication: { _, _ in false },
            frontmostAppBundleId: { nil },
        )
        savedWorkspaceRuntime.runtimeReadyAt = clock.addingTimeInterval(-3600)
        workspaceSidebarOrganizationStore = .init()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        NewWindowIntentRegistry.shared.resetForTests()
        newWindowAppIsFrontmost = { _ in false }
    }

    override func tearDown() async throws {
        if let defaultAppIsFrontmost { newWindowAppIsFrontmost = defaultAppIsFrontmost }
        setServerReadOnlyForTests(false)
        NewWindowIntentRegistry.shared.resetForTests()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
    }

    /// Tabs a, b and c, in that order, with a in use. b has the editor's window 2; a and c have
    /// another app's windows 1 and 3.
    private func threeTabs() -> (a: Workspace, b: Workspace, c: Workspace, window: TestWindow) {
        let a = focus.workspace
        let b = Workspace.get(byName: "tab-b")
        let c = Workspace.get(byName: "tab-c")
        _ = TestWindow.new(id: 1, parent: a.rootTilingContainer, app: other)
        let window = TestWindow.new(id: 2, parent: b.rootTilingContainer, app: editor, title: "Notes")
        _ = TestWindow.new(id: 3, parent: c.rootTilingContainer, app: other)
        XCTAssertTrue(a.allLeafWindowsRecursive[0].focusWindow())
        Workspace.reconcileWorkspaceState()
        captureSavedWorkspaces(facts: savedTestFacts(now: clock, runningApps: running))
        return (a, b, c, window)
    }

    private func rename(_ tab: Workspace, _ label: String = "Notes") throws {
        try saveWorkspaceForSidebar(workspaceName: tab.name, displayName: label)
        captureSavedWorkspaces(facts: savedTestFacts(now: clock, runningApps: running))
    }

    private func move(_ window: Window, to tab: Workspace) {
        window.bind(to: tab.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        Workspace.reconcileWorkspaceState()
    }

    /// The tabs the Tabs list shows, as its own listing gives them.
    private func listed() async -> [String] {
        await updateWorkspaceSidebarModel()
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.workspaces = TrayMenuModel.shared.workspaceSidebarWorkspaces
        return snapshot.tabsListedWorkspacesByProject.values.joined().map(\.name)
    }

    private func assertListed(_ tab: Workspace, _ isListed: Bool, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) async {
        let names = await listed()
        XCTAssertEqual(names.contains(tab.name), isListed, "\(message) listed: \(names)", file: file, line: line)
    }

    // MARK: Empty ordinary tabs aren't shown

    func testASavedTabWhoseLastWindowMovedOutIsHiddenThenShownWhenAWindowIsBack() async throws {
        let (_, b, c, window) = threeTabs()
        try rename(b)
        let record = savedWorkspaceStore.record(named: b.name)
        move(window, to: c)
        await assertListed(b, false, "Empty")
        XCTAssertEqual(savedWorkspaceStore.record(named: b.name)?.displayName, record?.displayName, "Its record stays")
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[b.name], "Notes", "and its label")
        move(window, to: b)
        await assertListed(b, true, "A window is back")
    }

    func testASavedTabWaitingForItsWindowsAfterWinMuxStartsIsHiddenUntilTheyComeBack() async throws {
        let a = focus.workspace
        _ = TestWindow.new(id: 1, parent: a.rootTilingContainer, app: other)
        let layout = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [
            savedSlot("notes", bundleId: editorId, title: "Notes", windowId: 2, pid: 501),
        ]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "tab-b", displayName: "Notes", layout: layout))
        config.workspaceSidebar.workspaceLabels["tab-b"] = "Notes"
        savedWorkspaceRuntime.runtimeReadyAt = clock.addingTimeInterval(-10)
        materializeSavedWorkspaceNames()
        Workspace.reconcileWorkspaceState()
        let b = try XCTUnwrap(Workspace.existing(byName: "tab-b"))
        await assertListed(b, false, "Its window hasn't come back yet")
        XCTAssertEqual(savedWorkspaceStore.record(named: b.name)?.layout.allSlots.count, 1, "Its saved place waits")

        let back = TestWindow.new(id: 2, parent: a.rootTilingContainer, app: editor, title: "Notes")
        let restored = try await restoreOrDetectNewWindow(back, isRegularWindow: true)
        XCTAssertTrue(restored)
        XCTAssertTrue(back.nodeWorkspace === b)
        await assertListed(b, true, "Its window came back")
    }

    func testASavedTabWhoseLastWindowClosesDuringTheStartupRestoreIsHidden() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        savedWorkspaceRuntime.runtimeReadyAt = clock.addingTimeInterval(-10)
        window.removeClosedWindowFromTree()
        Workspace.reconcileWorkspaceState()
        await assertListed(b, false)
        XCTAssertNotNil(savedWorkspaceStore.record(named: b.name), "Kept for the restore")
    }

    func testReadOnlyModeHidesAnEmptySavedTabAndChangesNothingSaved() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        setServerReadOnlyForTests(true)
        savedWorkspaceStore = SavedWorkspaceStore(file: savedWorkspaceStore.file, url: nil, readOnlyReason: "read-only")
        let record = savedWorkspaceStore.record(named: b.name)
        window.removeClosedWindowFromTree()
        Workspace.reconcileWorkspaceState()
        await assertListed(b, false)
        XCTAssertEqual(savedWorkspaceStore.record(named: b.name), record)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[b.name], "Notes")
    }

    func testAConfiguredPersistentTabIsHiddenWhileEmptyAndItsConfigStays() async throws {
        let (_, b, c, window) = threeTabs()
        config.persistentWorkspaces = [b.name]
        move(window, to: c)
        await assertListed(b, false)
        XCTAssertTrue(Workspace.existing(byName: b.name) === b, "The workspace stays")
        XCTAssertEqual(config.persistentWorkspaces, [b.name])
        move(window, to: b)
        await assertListed(b, true)
    }

    func testANewTabWaitingForItsWindowIsntShownUntilTheWindowArrives() async throws {
        let (a, _, _, _) = threeTabs()
        let newTab = newTabWorkspace(projectId: a.projectId, monitor: a.workspaceMonitor).workspace
        XCTAssertTrue(newTab.focusWorkspace())
        await assertListed(newTab, false, "Waiting for its window")

        let registry = NewWindowIntentRegistry.shared
        var outcome: NewWindowRequestOutcome?
        let intent = try XCTUnwrap(registry.register(bundleId: editorId, pid: 501, targetWorkspace: newTab,
            preexistingWindowIds: [2], focusGeneration: focusChangeGeneration, completion: { outcome = $0 }))
        XCTAssertTrue(registry.isPending(intentId: intent.id), "Its creation goes on")
        let window = TestWindow.new(id: 20, parent: macosPopupWindowsContainer, app: editor)
        let tab = try XCTUnwrap(registry.claim(windowId: 20, pid: 501, bundleId: editorId, firstSeenUptime: registry.now()))
        XCTAssertTrue(tab === newTab)
        let binding = newWindowIntentBinding(targetWorkspace: tab)
        window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
        XCTAssertTrue(window.nodeWorkspace === newTab)
        XCTAssertEqual(outcome, .placed(windowId: 20))
        await assertListed(newTab, true)
    }

    func testTheTabInUseLeftEmptyIsUnlistedAndStaysOnScreen() async throws {
        let (_, b, c, window) = threeTabs()
        try rename(b)
        move(window, to: c)
        // The tab in use with no window, as after WinMux starts before its windows are back.
        XCTAssertTrue(b.focusWorkspace())
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(b.isVisible, "No jump: the display stays on it")
        XCTAssertTrue(focus.workspace === b)
        await assertListed(b, false)
    }

    // MARK: Still shown

    func testMinimizedHiddenAppAndFullScreenWindowsKeepTheirTabsShown() async throws {
        let (_, b, c, window) = threeTabs()
        try rename(b)
        window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: b.name)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let hidden = try XCTUnwrap(c.allLeafWindowsRecursive.first)
        hidden.bind(to: c.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        let d = Workspace.get(byName: "tab-d")
        _ = TestWindow.new(id: 4, parent: d.macOsNativeFullscreenWindowsContainer, app: other)
        Workspace.reconcileWorkspaceState()
        let names = await listed()
        XCTAssertEqual(names.filter { [b.name, c.name, d.name].contains($0) }, [b.name, c.name, d.name])
    }

    func testAnEmptyPinIsStillShown() async throws {
        let (_, b, _, window) = threeTabs()
        try setWorkspaceSidebarTabFavorite(b, true)
        window.removeClosedWindowFromTree()
        Workspace.reconcileWorkspaceState()
        await assertListed(b, true, "A pin may be empty")
    }

    func testSidebarModeStillShowsAnEmptySavedWorkspace() async throws {
        let (_, b, c, window) = threeTabs()
        config.workspaceSidebar.mode = .sidebar
        try rename(b)
        move(window, to: c)
        await updateWorkspaceSidebarModel()
        let row = TrayMenuModel.shared.workspaceSidebarWorkspaces.first { $0.name == b.name }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.isLeftEmpty, false)
    }

    // MARK: Navigation

    func testTabNavigationAndTheClosingTabsNeighbourPassAHiddenTabBy() async throws {
        let (a, b, c, window) = threeTabs()
        try rename(b)
        move(window, to: c)
        XCTAssertFalse(numberedWorkspaceNavigationTabs(current: a).contains(b), "Not numbered")
        XCTAssertTrue(getNextPrevWorkspace(current: a, isNext: true, wrapAround: false, stdin: nil) === c, "Next is c")
        XCTAssertTrue(getNextPrevWorkspace(current: c, isNext: false, wrapAround: false, stdin: nil) === a, "Previous is a")
        let first = try XCTUnwrap(a.allLeafWindowsRecursive.first)
        first.removeClosedWindowFromTree()
        XCTAssertTrue(focus.workspace === c, "Closing a's last window moves to c, past hidden b")
    }

    // MARK: Numbers in a command sequence

    /// Runs commands as a keybinding does, one sequence.
    private func runSequence(_ raws: [String]) async throws {
        let commands = try raws.map { try XCTUnwrap(parseCommand($0).cmdOrNil, $0) }
        _ = try await commands.runCmdSeq(.defaultEnv, .emptyStdin)
    }

    func testAMoveThenFollowByNumberGoesToTheSameTabWhenTheMoveEmptiesASavedTab() async throws {
        let (a, b, _, _) = threeTabs()
        try rename(a, "Mail")
        let window = try XCTUnwrap(a.allLeafWindowsRecursive.first)
        XCTAssertTrue(window.focusWindow())
        try await runSequence(["move-node-to-workspace 2", "workspace 2"])
        XCTAssertTrue(window.nodeWorkspace === b, "Moved to tab 2, b")
        XCTAssertTrue(focus.workspace === b, "and followed it there")
        await assertListed(a, false, "a is empty now")
    }

    func testAMoveToANewNumberThenFollowGoesToTheNewTabWhenTheMoveEmptiesASavedTab() async throws {
        let (a, b, c, _) = threeTabs()
        try rename(a, "Mail")
        let window = try XCTUnwrap(a.allLeafWindowsRecursive.first)
        XCTAssertTrue(window.focusWindow())
        try await runSequence(["move-node-to-workspace 4", "workspace 4"])
        let tab = try XCTUnwrap(window.nodeWorkspace)
        XCTAssertFalse([a, b, c].contains { $0 === tab }, "A new tab 4")
        XCTAssertTrue(focus.workspace === tab, "and followed it there")
    }

    func testNextAndPreviousFromTheHiddenTabInUseKeepItsPlace() async throws {
        let (a, b, c, window) = threeTabs()
        try rename(b)
        move(window, to: c)
        XCTAssertTrue(b.focusWorkspace())
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(getNextPrevWorkspace(current: b, isNext: true, wrapAround: false, stdin: nil) === c)
        XCTAssertTrue(getNextPrevWorkspace(current: b, isNext: false, wrapAround: false, stdin: nil) === a)
    }
}
