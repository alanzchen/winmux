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
