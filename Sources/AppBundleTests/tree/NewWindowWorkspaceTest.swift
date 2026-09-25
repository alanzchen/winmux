@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class NewWindowWorkspaceTest: XCTestCase {
    private var defaultAppIsFrontmost: (@MainActor (Window) -> Bool)?

    override func setUp() async throws {
        defaultAppIsFrontmost = newWindowAppIsFrontmost
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        // A window id cached as closed by an earlier test would be restored instead of detected.
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        config.openNewWindowsInNewWorkspace = true
        newWindowAppIsFrontmost = { _ in false }
    }

    override func tearDown() async throws {
        if let defaultAppIsFrontmost { newWindowAppIsFrontmost = defaultAppIsFrontmost }
        config = defaultConfig
    }

    func testOptionIsOffByDefaultAndParses() {
        XCTAssertFalse(defaultConfig.openNewWindowsInNewWorkspace)
        let (parsed, errors) = parseConfig("open-new-windows-in-new-workspace = true")
        XCTAssertEqual(errors.descriptions, [])
        XCTAssertTrue(parsed.openNewWindowsInNewWorkspace)
    }

    func testNewWindowGetsItsOwnWorkspaceInTheSameProject() async throws {
        let workspace = focus.workspace
        let existing = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let window = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        let restored = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertFalse(restored)
        let target = try XCTUnwrap(window.nodeWorkspace)
        XCTAssertFalse(target === workspace)
        XCTAssertEqual(target.projectId, workspace.projectId)
        XCTAssertEqual(target.allLeafWindowsRecursive.map(\.windowId), [2])
        XCTAssertTrue(existing.nodeWorkspace === workspace, "Other windows stay where they are")
    }

    func testOptionOffKeepsNewWindowsInTheCurrentWorkspace() async throws {
        config.openNewWindowsInNewWorkspace = false
        let workspace = focus.workspace
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let window = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertTrue(window.nodeWorkspace === workspace)
    }

    func testFirstWindowInAnEmptyWorkspaceStays() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertTrue(window.nodeWorkspace === workspace)
    }

    func testDialogsAndStartupWindowsStay() async throws {
        let workspace = focus.workspace
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let dialog = TestWindow.new(id: 2, parent: workspace)
        _ = try await restoreOrDetectNewWindow(dialog, isRegularWindow: false)
        XCTAssertTrue(dialog.nodeWorkspace === workspace)

        let startupWindow = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        try await $_isStartup.withValue(true) {
            _ = try await restoreOrDetectNewWindow(startupWindow, isRegularWindow: true)
        }
        XCTAssertTrue(startupWindow.nodeWorkspace === workspace, "Windows open before WinMux starts keep their layout")
    }

    func testOnWindowDetectedRulesPlaceWindowsFirst() async throws {
        let (parsed, errors) = parseConfig("""
        [[on-window-detected]]
        if.app-id = 'bobko.WinMux.test-app'
        run = ['move-node-to-workspace mail']
        """)
        XCTAssertEqual(errors.descriptions, [])
        config.onWindowDetected = parsed.onWindowDetected
        config.openNewWindowsInNewWorkspace = true
        let workspace = focus.workspace
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let window = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertEqual(window.nodeWorkspace?.name, "mail")
    }

    func testNewWindowLeavesAnAutoAddedTabGroup() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        root.layout = .tabGroup
        _ = TestWindow.new(id: 1, parent: root)
        let window = TestWindow.new(id: 2, parent: root)

        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertFalse(window.nodeWorkspace === workspace)
        XCTAssertEqual(root.children.count, 1)
    }

    func testWindowsWaitingForSavedWorkspaceTitlesStay() async throws {
        let workspace = focus.workspace
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let window = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        savedWorkspaceRuntime.windowsAwaitingTitle[window.windowId] = SavedTitleWait(since: savedWorkspaceRuntime.now, pid: window.app.pid)
        defer { savedWorkspaceRuntime.windowsAwaitingTitle[window.windowId] = nil }

        moveNewWindowToNewWorkspaceIfNeeded(window, detectedIn: workspace, isNewRegularWindow: true)

        XCTAssertTrue(window.nodeWorkspace === workspace, "Saved workspaces will place it once its title arrives")
    }

    func testAPromotedPopupCountsAsNewOnlyWhileRecent() async throws {
        let workspace = focus.workspace
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let old = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        old.firstSeenAt = Date().addingTimeInterval(-60)
        try await runCallbacksAfterPopupPromotion(old, mayPresent: true)
        XCTAssertTrue(old.nodeWorkspace === workspace, "A window in use for a minute is not moved as new")

        let fresh = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        try await runCallbacksAfterPopupPromotion(fresh, mayPresent: false)
        XCTAssertFalse(fresh.nodeWorkspace === workspace,
            "A just-opened window promoted from a popup moves even if its app wasn't frontmost")
    }

    func testFocusFollowsOnlyAWindowFromTheAppInUse() async throws {
        let workspace = focus.workspace
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let background = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        _ = try await restoreOrDetectNewWindow(background, isRegularWindow: true)
        XCTAssertFalse(background.nodeWorkspace === workspace)
        XCTAssertTrue(focus.workspace === workspace, "A background app's window does not take focus")

        newWindowAppIsFrontmost = { _ in true }
        let foreground = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        _ = try await restoreOrDetectNewWindow(foreground, isRegularWindow: true)
        let target = try XCTUnwrap(foreground.nodeWorkspace)
        XCTAssertFalse(target === workspace)
        XCTAssertTrue(focus.workspace === target, "The window you just opened stays in view")
        XCTAssertTrue(focus.windowOrNil === foreground)
    }
}
