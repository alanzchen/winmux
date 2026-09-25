@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class NewWindowWorkspaceTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        // A window id cached as closed by an earlier test would be restored instead of detected.
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        config.openNewWindowsInNewWorkspace = true
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
        savedWorkspaceRuntime.routingInFlightWindowIds.insert(window.windowId)
        defer { savedWorkspaceRuntime.routingInFlightWindowIds.remove(window.windowId) }

        XCTAssertFalse(shouldMoveNewWindowToNewWorkspace(window, detectedIn: workspace, isNewRegularWindow: true))
    }
}
