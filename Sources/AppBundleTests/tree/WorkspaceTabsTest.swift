@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class WorkspaceTabsTest: XCTestCase {
    private var defaultAppIsFrontmost: (@MainActor (Window) -> Bool)?

    override func setUp() async throws {
        defaultAppIsFrontmost = newWindowAppIsFrontmost
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        newWindowAppIsFrontmost = { _ in true }
    }

    override func tearDown() async throws {
        if let defaultAppIsFrontmost { newWindowAppIsFrontmost = defaultAppIsFrontmost }
        config = defaultConfig
    }

    /// Tabs a, b, and c in that order, each with one window, with b's window focused.
    private func threeTabs() -> (a: Workspace, b: Workspace, c: Workspace) {
        let a = focus.workspace
        _ = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        let b = Workspace.get(byName: "tab-b")
        let c = Workspace.get(byName: "tab-c")
        _ = TestWindow.new(id: 3, parent: c.rootTilingContainer)
        XCTAssertTrue(TestWindow.new(id: 2, parent: b.rootTilingContainer).focusWindow())
        XCTAssertEqual(order(), [a, b, c].map(\.name))
        return (a, b, c)
    }

    private func order() -> [String] { orderedWorkspaces(in: focus.workspace.projectId).map(\.name) }

    func testNewWindowsOpenAsTabsByDefaultOnlyInTabsMode() {
        XCTAssertTrue(config.opensNewWindowsInNewWorkspace)
        config.openNewWindowsInNewWorkspace = false
        XCTAssertFalse(config.opensNewWindowsInNewWorkspace, "Turning it off in Settings or the config file wins")
        config.openNewWindowsInNewWorkspace = nil
        config.workspaceSidebar.mode = .sidebar
        XCTAssertFalse(config.opensNewWindowsInNewWorkspace)
        config.workspaceSidebar.mode = .tabs
        config.workspaceSidebar.enabled = false
        XCTAssertFalse(config.opensNewWindowsInNewWorkspace, "Without the sidebar there are no tabs")

        let (parsed, errors) = parseConfig("""
            [workspace-sidebar]
            enabled = true
            mode = 'tabs'
            """)
        XCTAssertEqual(errors.descriptions, [])
        XCTAssertTrue(parsed.opensNewWindowsInNewWorkspace)
    }

    func testANewWindowOpensAsATabRightAfterTheTabItOpenedFrom() async throws {
        let (_, b, c) = threeTabs()
        let window = TestWindow.new(id: 4, parent: b.rootTilingContainer)

        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        let tab = try XCTUnwrap(window.nodeWorkspace)
        XCTAssertFalse(tab === b)
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [4])
        XCTAssertEqual(order().firstIndex(of: tab.name), order().firstIndex(of: b.name).map { $0 + 1 })
        XCTAssertEqual(order().last, c.name)
        XCTAssertTrue(focus.windowOrNil === window, "The app in use opened it, so it's the tab you see")
    }

    func testExistingWindowsBecomeSeparateTabsAtStartupWithoutStealingFocus() async throws {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertTrue(first.focusWindow())
        try await $_isStartup.withValue(true) {
            _ = try await restoreOrDetectNewWindow(first, isRegularWindow: true)
            XCTAssertTrue(first.nodeWorkspace === workspace, "The first window already has its own tab")
            for id: UInt32 in 2...5 {
                let window = TestWindow.new(id: id, parent: workspace.rootTilingContainer)
                _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
                XCTAssertEqual(window.nodeWorkspace?.allLeafWindowsRecursive.map(\.windowId), [id])
                XCTAssertTrue(focus.windowOrNil === first, "Enumerating existing windows must not activate each one")
            }
            XCTAssertFalse(shouldApplySmartLayoutAtStartup(didLoadPersistedFrozenWorld: false),
                "Tabs mode must never apply the legacy startup stack heuristic")
        }
        XCTAssertEqual(orderedWorkspaces(in: workspace.projectId).filter { !$0.isEffectivelyEmpty }.count, 5)
    }

    func testStartupTabsStayOnTheDisplayWhereTheirWindowsWereDetected() async throws {
        let main = SavedWorkspaceTestMonitor(id: 1, name: "Main", x: 0, isMain: true, uuid: nil)
        let secondary = SavedWorkspaceTestMonitor(id: 2, name: "Secondary", x: 1920, uuid: nil)
        setMonitorsForTests([main, secondary])
        defer { setMonitorsForTests(nil) }
        Workspace.reconcileWorkspaceState()
        let focused = TestWindow.new(id: 1, parent: main.activeWorkspace.rootTilingContainer)
        XCTAssertTrue(focused.focusWindow())
        let origin = secondary.activeWorkspace
        try await $_isStartup.withValue(true) {
            for id: UInt32 in 2...4 {
                let window = TestWindow.new(id: id, parent: origin.rootTilingContainer)
                _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
                XCTAssertEqual(window.nodeWorkspace?.allLeafWindowsRecursive.map(\.windowId), [id])
                XCTAssertEqual(window.nodeMonitor?.rect, secondary.rect)
                XCTAssertTrue(focus.windowOrNil === focused)
            }
        }
        XCTAssertTrue(secondary.activeWorkspace === origin)
    }

    func testStartupSessionActivatesTheNativeFocusedTabEvenWhenRegisteredLater() async throws {
        let previousApp = appForTests
        let wasEnabled = TrayMenuModel.shared.isEnabled
        defer {
            appForTests = previousApp
            TrayMenuModel.shared.isEnabled = wasEnabled
            setBlockingRefreshOverridesForTests()
        }
        appForTests = TestApp.shared
        TrayMenuModel.shared.isEnabled = true
        let origin = focus.workspace
        let first = TestWindow.new(id: 1, parent: origin.rootTilingContainer)
        XCTAssertTrue(first.focusWindow())
        let nativeFocused = TestWindow.new(id: 3, parent: origin.rootTilingContainer)
        try await $_isStartup.withValue(true) {
            _ = try await restoreOrDetectNewWindow(nativeFocused, isRegularWindow: true)
        }
        XCTAssertFalse(nativeFocused.nodeWorkspace === origin)
        TestApp.shared.focusedWindow = nativeFocused
        setBlockingRefreshOverridesForTests(refresh: {
            let another = TestWindow.new(id: 4, parent: origin.rootTilingContainer)
            _ = try await restoreOrDetectNewWindow(another, isRegularWindow: true)
        }, normalizeLayoutReason: {})

        try await runRefreshSessionBlocking(.startup, layoutWorkspaces: false)

        XCTAssertTrue(focus.windowOrNil === nativeFocused)
        XCTAssertTrue(mainMonitor.activeWorkspace === nativeFocused.nodeWorkspace,
            "Startup resolves native focus before hiding any inactive tabs")
    }

    func testStartupSessionMigratesRestoredLegacyStacksToTabs() async throws {
        let previousApp = appForTests
        let wasEnabled = TrayMenuModel.shared.isEnabled
        defer {
            appForTests = previousApp
            TrayMenuModel.shared.isEnabled = wasEnabled
            setBlockingRefreshOverridesForTests()
            replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        }
        appForTests = TestApp.shared
        TrayMenuModel.shared.isEnabled = true
        let legacy = focus.workspace
        let stack = legacy.rootTilingContainer
        stack.layout = .tabGroup
        let windows = (1...4).map { TestWindow.new(id: UInt32($0), parent: stack) }
        let saved = snapshotCurrentFrozenWorld()
        XCTAssertEqual(saved.workspaces.first?.rootTilingNode.layout, .tabGroup)
        replaceClosedWindowsCache(saved)
        let staging = Workspace.get(byName: "staging")
        for window in windows { window.bind(to: staging.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST) }
        // getNativeFocusObservation restores the native focused window before updating
        // logical focus. All fixture windows are already registered and restored together.
        try await $_isStartup.withValue(true) {
            _ = try await restoreOrDetectNewWindow(windows[2], isRegularWindow: true)
        }
        XCTAssertEqual(legacy.rootTilingContainer.layout, .tabGroup, "The frozen stack must be restored before migration")
        TestApp.shared.focusedWindow = windows[2]
        setBlockingRefreshOverridesForTests(refresh: {}, normalizeLayoutReason: {})

        try await runRefreshSessionBlocking(.startup, layoutWorkspaces: false)

        for window in windows {
            XCTAssertEqual(window.nodeWorkspace?.allLeafWindowsRecursive.map(\.windowId), [window.windowId])
            XCTAssertEqual(window.nodeWorkspace?.rootTilingContainer.layout, .tiles)
        }
        XCTAssertTrue(focus.windowOrNil === windows[2])
        XCTAssertTrue(mainMonitor.activeWorkspace === windows[2].nodeWorkspace)
    }

    func testTabsModeIgnoresLegacyDefaultStackLayoutForNewWorkspaces() {
        config.defaultRootContainerLayout = .tabGroup
        let tab = createWorkspace(after: focus.workspace, projectId: focus.workspace.projectId, monitor: mainMonitor)
        XCTAssertEqual(tab.rootTilingContainer.layout, .tiles)
    }

    func testTabsModeDoesNotAutomaticallyAddWindowsToALegacyStack() {
        config.autoAddNewWindowsToTabGroup = true
        let workspace = focus.workspace
        let stack = TilingContainer(parent: workspace.rootTilingContainer, adaptiveWeight: 1, .h, .tabGroup, index: 0)
        XCTAssertTrue(TestWindow.new(id: 1, parent: stack).focusWindow())
        XCTAssertFalse(bindingDataForNewRegularWindow(workspace, window: nil).parent === stack)
    }

    func testStartupPreservesRestoredSplitTabs() async throws {
        let split = focus.workspace
        let first = TestWindow.new(id: 1, parent: split.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: split.rootTilingContainer)
        replaceClosedWindowsCache(snapshotCurrentFrozenWorld())
        defer { replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: [])) }
        let staging = Workspace.get(byName: "staging")
        for window in [first, second] {
            window.bind(to: staging.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        }
        try await $_isStartup.withValue(true) {
            for window in [first, second] {
                let restored = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
                XCTAssertTrue(restored)
                XCTAssertTrue(window.nodeWorkspace === split)
            }
        }
        XCTAssertEqual(split.rootTilingContainer.layout, .tiles)
        XCTAssertEqual(split.allLeafWindowsRecursive.map(\.windowId), [1, 2])
    }

    func testNewTabOpensAfterTheCurrentTabAndReusesAnEmptyOne() {
        let (a, b, _) = threeTabs()
        let newTab = newTabWorkspace(projectId: b.projectId, monitor: b.workspaceMonitor)
        XCTAssertFalse(newTab.workspace === b)
        XCTAssertTrue(newTab.previous === b)
        XCTAssertEqual(order()[2], newTab.workspace.name, "Right after the current tab")
        XCTAssertTrue(newTab.workspace.focusWorkspace())

        let again = newTabWorkspace(projectId: b.projectId, monitor: b.workspaceMonitor)
        XCTAssertTrue(again.workspace === newTab.workspace, "New Tab on an empty tab reuses it")
        XCTAssertEqual(order().count, 4)
        _ = a
    }

    func testDismissingTheLauncherClosesItsEmptyTab() {
        let (_, b, _) = threeTabs()
        let newTab = newTabWorkspace(projectId: b.projectId, monitor: b.workspaceMonitor)
        XCTAssertTrue(newTab.workspace.focusWorkspace())

        closeUnusedNewTab(newTab)
        pruneEmptyWorkspaces()

        XCTAssertTrue(focus.workspace === b, "Back to the tab you came from")
        XCTAssertNil(Workspace.existing(byName: newTab.workspace.name))
    }

    func testANewTabStaysOnceSomethingOpensInItOrYouHaveMovedOn() {
        let (a, b, _) = threeTabs()
        let used = newTabWorkspace(projectId: b.projectId, monitor: b.workspaceMonitor)
        XCTAssertTrue(used.workspace.focusWorkspace())
        _ = TestWindow.new(id: 5, parent: used.workspace.rootTilingContainer)
        closeUnusedNewTab(used)
        XCTAssertTrue(focus.workspace === used.workspace)

        let left = newTabWorkspace(projectId: b.projectId, monitor: b.workspaceMonitor)
        XCTAssertTrue(left.workspace.focusWorkspace())
        XCTAssertTrue(a.focusWorkspace())
        closeUnusedNewTab(left)
        XCTAssertTrue(focus.workspace === a, "You clicked another tab; the launcher doesn't pull you back")
    }

    func testClosingTheLastWindowOfATabMovesToTheNextTab() throws {
        let (a, b, c) = threeTabs()
        let closing = try XCTUnwrap(b.allLeafWindowsRecursive.first)
        XCTAssertEqual(replacementAfterClosing(closing)?.workspace, c, "The next tab")

        XCTAssertTrue(try XCTUnwrap(c.allLeafWindowsRecursive.first).focusWindow())
        let last = try XCTUnwrap(c.allLeafWindowsRecursive.first)
        XCTAssertEqual(replacementAfterClosing(last)?.workspace, b, "The last tab moves back to the previous one")

        let emptyB = try XCTUnwrap(b.allLeafWindowsRecursive.first)
        emptyB.unbindFromParent()
        XCTAssertEqual(replacementAfterClosing(last)?.workspace, a, "skipping tabs with no windows")
        emptyB.bind(to: b.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func testAPinnedTabAndOtherModesKeepTheEmptyWorkspace() throws {
        let (_, b, _) = threeTabs()
        config.persistentWorkspaces = [b.name]
        let closing = try XCTUnwrap(b.allLeafWindowsRecursive.first)
        XCTAssertEqual(replacementAfterClosing(closing)?.workspace, b, "A kept workspace stays, like a pinned tab")

        config.persistentWorkspaces = []
        XCTAssertTrue(closing.focusWindow())
        config.workspaceSidebar.mode = .sidebar
        XCTAssertEqual(replacementAfterClosing(closing)?.workspace, b, "Sidebar mode keeps today's behavior")
    }

    func testWindowsOpenedTogetherKeepTheirOrderAfterTheirTab() {
        let (a, b, c) = threeTabs()
        let first = createWorkspaceForNewWindow(openedFrom: b, monitor: b.workspaceMonitor, now: 10)
        let second = createWorkspaceForNewWindow(openedFrom: b, monitor: b.workspaceMonitor, now: 10.5)
        XCTAssertEqual(order(), [a.name, b.name, first.name, second.name, c.name], "In the order they opened, not reversed")
        let later = createWorkspaceForNewWindow(openedFrom: b, monitor: b.workspaceMonitor, now: 20)
        XCTAssertEqual(order()[2], later.name, "A window opened later goes right after its tab again")
    }

    func testReusingTheEmptyTabOnScreenIsntANewTab() {
        let (_, b, _) = threeTabs()
        let created = newTabWorkspace(projectId: b.projectId, monitor: b.workspaceMonitor)
        XCTAssertTrue(created.isNew)
        XCTAssertTrue(created.workspace.focusWorkspace())
        let reused = newTabWorkspace(projectId: b.projectId, monitor: b.workspaceMonitor)
        XCTAssertFalse(reused.isNew, "Closing the launcher there doesn't close a tab the user was already on")
    }

    func testAWindowDroppedOnNewTabGoesRightAfterItsTab() throws {
        let (a, b, c) = threeTabs()
        let window = try XCTUnwrap(b.allLeafWindowsRecursive.first)
        let tab = workspaceForDropOnNewTab(projectId: b.projectId, monitor: b.workspaceMonitor, sourceWindow: window)
        XCTAssertEqual(order(), [a.name, b.name, tab.name, c.name])
    }

    func testRestoringTheNewWindowsDefaultUnsetsItInsteadOfPinningIt() {
        let field = SettingsCatalog.field("open-new-windows-in-new-workspace")
        XCTAssertEqual(field.read(config), .bool(true), "Settings shows it on in Tabs mode")
        XCTAssertEqual(field.defaultValue(for: config), .bool(true))
        config.workspaceSidebar.mode = .sidebar
        XCTAssertEqual(field.defaultValue(for: config), .bool(false))

        let text = "open-new-windows-in-new-workspace = false\nmiddle-click-closes-windows = true\n"
        let restored = updateSettingsScalarConfig(in: text, section: nil, key: "open-new-windows-in-new-workspace",
            renderedValue: settingsUnsetRenderedValue)
        XCTAssertEqual(restored, "middle-click-closes-windows = true\n")
        XCTAssertEqual(updateSettingsScalarConfig(in: restored, section: nil, key: "open-new-windows-in-new-workspace",
            renderedValue: settingsUnsetRenderedValue), restored, "Nothing to remove adds nothing")

        XCTAssertEqual(field.isSet?(config), false)
        config.openNewWindowsInNewWorkspace = true
        XCTAssertEqual(field.isSet?(config), true, "Restoring it then has a key to remove, even if its value matches")
    }

    func testATabDroppedOnAnotherGoesOnTheSideItWasDropped() throws {
        let (a, b, _) = threeTabs()
        let target = try XCTUnwrap(a.allLeafWindowsRecursive.first)
        let dropped = try XCTUnwrap(b.allLeafWindowsRecursive.first)

        applyTabDrop(sourceNode: dropped, sourceWindow: dropped, targetWorkspace: a, placement: .left)

        XCTAssertEqual(a.rootTilingContainer.children.map { ($0 as? Window)?.windowId }, [dropped.windowId, target.windowId])
        XCTAssertTrue(focus.windowOrNil === dropped, "The combined tab comes forward with the dropped window")
        XCTAssertTrue(b.allLeafWindowsRecursive.isEmpty)

        applyTabDrop(sourceNode: dropped, sourceWindow: dropped, targetWorkspace: a, placement: .right)
        XCTAssertEqual(a.rootTilingContainer.children.map { ($0 as? Window)?.windowId }, [target.windowId, dropped.windowId])
    }

    func testLegacyStackDropBecomesASplitInTabsMode() throws {
        let (a, b, _) = threeTabs()
        let target = try XCTUnwrap(a.allLeafWindowsRecursive.first)
        let dropped = try XCTUnwrap(b.allLeafWindowsRecursive.first)

        applyTabDrop(sourceNode: dropped, sourceWindow: dropped, targetWorkspace: a, placement: .stack)

        let stack = try XCTUnwrap(dropped.parent as? TilingContainer)
        XCTAssertEqual(stack.layout, .tiles)
        XCTAssertTrue(target.parent === stack)
        XCTAssertTrue(focus.windowOrNil === dropped)
    }

    func testDroppingAWholeTabBetweenTabsMovesIt() throws {
        let (a, b, c) = threeTabs()
        let window = try XCTUnwrap(c.allLeafWindowsRecursive.first)

        applyTabGapDrop(sourceNode: window, sourceWindow: window, projectId: c.projectId, monitor: c.workspaceMonitor,
            gap: WorkspaceSidebarTabGap(workspaceName: a.name, isAfter: false))

        XCTAssertEqual(order(), [c, a, b].map(\.name), "The tab moves; no workspace is created")
        XCTAssertTrue(window.nodeWorkspace === c)
    }

    func testDroppingOneWindowOfASplitBetweenTabsGivesItATabThere() throws {
        let (a, b, c) = threeTabs()
        let second = TestWindow.new(id: 7, parent: a.rootTilingContainer)

        applyTabGapDrop(sourceNode: second, sourceWindow: second, projectId: a.projectId, monitor: a.workspaceMonitor,
            gap: WorkspaceSidebarTabGap(workspaceName: b.name, isAfter: true))

        let tab = try XCTUnwrap(second.nodeWorkspace)
        XCTAssertFalse(tab === a)
        XCTAssertEqual(order(), [a.name, b.name, tab.name, c.name])
        XCTAssertTrue(focus.windowOrNil === second)
        XCTAssertEqual(a.allLeafWindowsRecursive.count, 1)
    }

    func testAWholeTabDroppedNextToAClosedTabStaysPut() throws {
        let (a, b, c) = threeTabs()
        let window = try XCTUnwrap(c.allLeafWindowsRecursive.first)
        applyTabGapDrop(sourceNode: window, sourceWindow: window, projectId: c.projectId, monitor: c.workspaceMonitor,
            gap: WorkspaceSidebarTabGap(workspaceName: "closed-meanwhile", isAfter: true))
        XCTAssertEqual(order(), [a, b, c].map(\.name), "No stray workspace, nothing moved")
        XCTAssertTrue(window.nodeWorkspace === c)
    }

    func testMovingAWorkspaceAfterAnotherKeepsTheRest() {
        let (a, b, c) = threeTabs()
        winMuxWorkspaceState.moveWorkspace(a.id, after: c.id)
        XCTAssertEqual(order(), [b, c, a].map(\.name))
        winMuxWorkspaceState.moveWorkspace(a.id, after: b.id)
        XCTAssertEqual(order(), [b, a, c].map(\.name))
    }

    private func replacementAfterClosing(_ window: Window) -> LiveFocus? {
        let workspace = window.nodeWorkspace
        let current = focus
        window.unbindFromParent()
        defer { if let workspace { window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST) } }
        return focusAfterWindowClosure(
            closingWindow: window,
            deadWindowWorkspace: workspace,
            currentFocus: current,
            previousFocus: nil,
            previousPreviousFocus: nil,
            refreshSnapshotCloseFallback: nil,
            refreshSnapshotPreviousFocus: nil,
            refreshSnapshotPreviousPreviousFocus: nil,
            previousFocusedWorkspace: nil,
            previousFocusedWorkspaceDate: .distantPast,
        )
    }
}
