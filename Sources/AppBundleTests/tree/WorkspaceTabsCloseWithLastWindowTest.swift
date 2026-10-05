@testable import AppBundle
import AppKit
import Common
import XCTest

/// Tabs mode: a tab that isn't pinned closes once its last window closes, rather than staying
/// greyed, whether it's saved (renamed, grouped, made from a topic) or not, and whether its app
/// keeps running or quits.
@MainActor
final class WorkspaceTabsCloseWithLastWindowTest: XCTestCase {
    private var defaultAppIsFrontmost: (@MainActor (Window) -> Bool)?
    private var clock = savedTestNow
    private let editorId = "com.test.editor"
    /// Running since long before WinMux started, so it's never armed.
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

    /// Tabs a, b and c, in that order, with a on screen. b has the editor's window 2; a and c have
    /// another app's windows 1 and 3.
    private func threeTabs() -> (a: Workspace, b: Workspace, c: Workspace, window: Window) {
        let a = focus.workspace
        let b = Workspace.get(byName: "tab-b")
        let c = Workspace.get(byName: "tab-c")
        _ = TestWindow.new(id: 1, parent: a.rootTilingContainer, app: other)
        let window = TestWindow.new(id: 2, parent: b.rootTilingContainer, app: editor, title: "Notes")
        _ = TestWindow.new(id: 3, parent: c.rootTilingContainer, app: other)
        XCTAssertTrue(a.allLeafWindowsRecursive[0].focusWindow())
        Workspace.reconcileWorkspaceState()
        captureSavedWorkspaces(facts: facts())
        return (a, b, c, window)
    }

    private func facts() -> SavedWorkspaceCaptureFacts {
        savedTestFacts(now: clock, runningApps: running)
    }

    private func rename(_ tab: Workspace, _ label: String = "Notes") throws {
        try saveWorkspaceForSidebar(workspaceName: tab.name, displayName: label)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[tab.name], label)
        XCTAssertTrue(tab.isKeptWhenEmpty)
        captureSavedWorkspaces(facts: facts())
    }

    /// The window closes, as the refresh that no longer finds it handles it.
    private func close(_ window: Window) {
        window.removeClosedWindowFromTree()
        Workspace.reconcileWorkspaceState()
    }

    /// Time passes, and something refreshes.
    private func later(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
        Workspace.reconcileWorkspaceState()
    }

    /// The editor quits.
    private func editorQuits() {
        running[editorId] = nil
    }

    private func assertClosed(_ tab: Workspace, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(Workspace.existing(byName: tab.name), "The tab closed", file: file, line: line)
        XCTAssertNil(savedWorkspaceStore.record(named: tab.name), "Its saved record went with it", file: file, line: line)
        XCTAssertNil(config.workspaceSidebar.workspaceLabels[tab.name], "and its label", file: file, line: line)
        XCTAssertNil(workspaceSidebarOrganizationStore.state.workspaces[tab.name], file: file, line: line)
        XCTAssertNil(workspaceSidebarOrganizationStore.collection(containing: tab.name), "and its place in a group",
            file: file, line: line)
    }

    private func assertStays(_ tab: Workspace, saved: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(Workspace.existing(byName: tab.name) === tab, "The tab stays", file: file, line: line)
        if saved { XCTAssertNotNil(savedWorkspaceStore.record(named: tab.name), file: file, line: line) }
    }

    // MARK: It closes

    func testARenamedTabClosesWhenItsLastWindowClosesWhileItsAppKeepsRunning() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        later(2)
        assertClosed(b)
    }

    func testAnAutomaticTabInAGroupClosesWithoutWaitingForTheClosedWindowsGrace() throws {
        let (_, b, c, window) = threeTabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: b.projectId, workspaceNames: [])
        try assignWorkspaceToSidebarCollection(b, collectionId: group.id, keepWhenEmpty: false)
        try assignWorkspaceToSidebarCollection(c, collectionId: group.id)
        captureSavedWorkspaces(facts: facts())
        XCTAssertEqual(savedWorkspaceStore.record(named: b.name)?.layout.allSlots.count, 1)
        close(window)
        later(2)
        XCTAssertLessThan(2, SavedWorkspaceTiming.closedWindowGrace)
        assertClosed(b)
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections.first?.workspaceNames, [c.name],
            "The group keeps its other tab")
    }

    func testATabInAGroupOfItsOwnClosesAndTheGroupFollowsItsUsualRules() throws {
        let (_, b, _, window) = threeTabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: b.projectId, workspaceNames: [])
        try assignWorkspaceToSidebarCollection(b, collectionId: group.id)
        XCTAssertTrue(b.isKeptWhenEmpty, "Grouping saves the tab")
        close(window)
        later(2)
        assertClosed(b)
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections.map(\.id), [group.id],
            "An empty group stays, as when its last tab is moved out")
    }

    func testATabMadeFromATopicClosesLikeAnyOther() throws {
        let (_, b, _, window) = threeTabs()
        try ensureSavedWorkspaceRecord(b, keepWhenEmpty: true)
        close(window)
        later(2)
        assertClosed(b)
    }

    func testATabClosesWhenItsAppQuits() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        editorQuits()
        close(window)
        later(2)
        assertClosed(b)
    }

    func testATabWhoseOnlyWindowWasMinimizedClosesWhenItsAppQuits() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: b.name)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        later(2)
        assertStays(b)
        editorQuits()
        close(window)
        later(2)
        assertClosed(b)
    }

    func testAnUnsavedTabStillClosesAtOnce() {
        let (_, b, _, window) = threeTabs()
        close(window)
        XCTAssertNil(Workspace.existing(byName: b.name), "As before: nothing of it is saved")
    }

    // MARK: Focus

    func testClosingTheTabInUseMovesFocusToTheNextTabAsForAnyTab() throws {
        let (_, b, c, window) = threeTabs()
        try rename(b)
        XCTAssertTrue(window.focusWindow())
        close(window)
        XCTAssertTrue(focus.workspace === c, "The next tab, as closing a browser tab does")
        later(2)
        assertClosed(b)
        XCTAssertTrue(c.isVisible)
    }

    func testATabClosingOnAnotherDisplayGivesThatDisplayToItsNextTabWithoutTakingFocus() throws {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT", isBuiltin: true)
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        let (a, b, c, window) = threeTabs()
        c.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(b))
        XCTAssertTrue(a.allLeafWindowsRecursive[0].focusWindow())
        try rename(b)
        close(window)
        later(2)
        XCTAssertTrue(right.activeWorkspace === c, "The other display shows its next tab")
        XCTAssertTrue(focus.workspace === a, "Focus stays where it was")
        assertClosed(b)
    }

    // MARK: It stays

    func testPinnedTabsStayAsTheirAppsHomes() throws {
        let (_, b, c, window) = threeTabs()
        try setWorkspaceSidebarTabFavorite(b, true)
        try setWorkspaceSidebarTabPinScope(c, .allProjects, projectId: c.projectId)
        close(window)
        close(c.allLeafWindowsRecursive[0])
        later(2)
        assertStays(b)
        assertStays(c)
    }

    func testAConfiguredPersistentWorkspaceStays() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        config.persistentWorkspaces = [b.name]
        close(window)
        later(2)
        assertStays(b)
    }

    func testMinimizedHiddenAndFullScreenWindowsStillCount() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: b.name)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        later(2)
        assertStays(b)
        window.bind(to: b.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        later(2)
        assertStays(b)
        window.bind(to: b.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        later(2)
        assertStays(b)
    }

    func testATabWhoseLastWindowMovedToAnotherTabStaysAsBefore() throws {
        let (_, b, c, window) = threeTabs()
        try rename(b)
        window.bind(to: c.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        later(2)
        assertStays(b)
    }

    func testNothingClosesDuringTheStartupRestoreThenTheTabCloses() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        savedWorkspaceRuntime.runtimeReadyAt = clock.addingTimeInterval(-10)
        close(window)
        later(2)
        assertStays(b)
        later(SavedWorkspaceTiming.restoreWindow)
        assertClosed(b)
    }

    func testATabWaitingForAWindowItAskedForStaysUntilTheRequestEnds() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        let intent = try XCTUnwrap(NewWindowIntentRegistry.shared.register(bundleId: editorId, pid: 501, targetWorkspace: b,
            preexistingWindowIds: [2], focusGeneration: 0))
        close(window)
        later(2)
        assertStays(b)
        NewWindowIntentRegistry.shared.cancel(intentId: intent.id)
        later(0)
        assertClosed(b)
    }

    func testANewTabWaitingForItsFirstWindowStays() throws {
        let (_, b, _, _) = threeTabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: b.projectId, workspaceNames: [])
        let newTab = try XCTUnwrap(newTabInSidebarCollection(group.id, monitor: b.workspaceMonitor))
        XCTAssertTrue(newTab.workspace.focusWorkspace())
        later(2)
        assertStays(newTab.workspace)
        XCTAssertTrue(focus.workspace === newTab.workspace)
    }

    func testReadOnlyModeChangesNothing() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        setServerReadOnlyForTests(true)
        savedWorkspaceStore = SavedWorkspaceStore(file: savedWorkspaceStore.file, url: nil, readOnlyReason: "read-only")
        close(window)
        later(2)
        assertStays(b)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[b.name], "Notes")
    }

    func testAWindowThatVanishesWhileTheScreenIsLockedDoesntCloseItsTab() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        savedWorkspaceRuntime.suspensions.insert(.screenLocked)
        close(window)
        later(2)
        resumeSavedWorkspaceCapture(after: .screenLocked)
        later(2)
        assertStays(b)
    }

    // MARK: The sidebar

    func testATabWaitingToCloseIsntListed() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        later(0.25)
        await updateWorkspaceSidebarModel()
        XCTAssertFalse(TrayMenuModel.shared.workspaceSidebarWorkspaces.contains { $0.name == b.name },
            "Not greyed in the list while it closes")
    }

    // MARK: Afterwards

    func testAClosedTabDoesntComeBackFromSavedState() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        editorQuits()
        close(window)
        later(2)
        captureSavedWorkspaces(facts: facts())
        materializeSavedWorkspaceNames()
        later(SavedWorkspaceTiming.closedWindowGrace)
        assertClosed(b)
        XCTAssertFalse(savedWorkspaceStore.hasSlots(bundleId: editorId), "No saved place waits for the editor")
    }

    func testTheRelaunchedAppsWindowOpensInANewTab() async throws {
        let (a, b, _, window) = threeTabs()
        try rename(b)
        editorQuits()
        close(window)
        later(2)
        let launched = clock
        running[editorId] = [SavedRunningApp(pid: 502, launchDate: launched)]
        let relaunched = TestApp(pid: 502, bundleId: editorId, name: "Editor", launchDate: launched)
        XCTAssertTrue(a.focusWorkspace())
        let next = TestWindow.new(id: 20, parent: a.rootTilingContainer, app: relaunched, title: "Notes")
        let restored = try await restoreOrDetectNewWindow(next, isRegularWindow: true)
        XCTAssertFalse(restored, "No saved place takes it")
        let tab = try XCTUnwrap(next.nodeWorkspace)
        XCTAssertFalse(tab === a || tab.name == b.name, "It opens in a new tab: \(tab.name)")
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [20])
    }

    func testTheRelaunchedAppsWindowGoesToItsEmptyPin() async throws {
        let (a, b, _, window) = threeTabs()
        var record = SavedWorkspaceRecord(workspaceName: "pin")
        record.launchApps = [SavedLaunchApp(bundleId: editorId)]
        savedWorkspaceStore.insert(record)
        materializeSavedWorkspaceNames()
        let pin = try XCTUnwrap(Workspace.existing(byName: "pin"))
        try setWorkspaceSidebarTabFavorite(pin, true)
        try rename(b)
        editorQuits()
        close(window)
        later(2)
        assertClosed(b)
        let launched = clock
        running[editorId] = [SavedRunningApp(pid: 502, launchDate: launched)]
        let relaunched = TestApp(pid: 502, bundleId: editorId, name: "Editor", launchDate: launched)
        XCTAssertTrue(a.focusWorkspace())
        let next = TestWindow.new(id: 20, parent: a.rootTilingContainer, app: relaunched, title: "Notes")
        _ = try await restoreOrDetectNewWindow(next, isRegularWindow: true)
        XCTAssertTrue(next.nodeWorkspace === pin, "The pin is the editor's home")
    }
}
