import AppKit
@testable import AppBundle
import Common
import XCTest

/// Audit F5: the shared drop preview belongs to the panel showing it. A retired or hidden panel
/// takes only its own drop with it. Audit F3: the Tabs commit contract a frozen preview runs into.
@MainActor
final class WorkspaceSidebarCrossDisplayPreviewTest: XCTestCase {
    private let otherDisplay = "monitor:1920.0,0.0"

    override func setUp() async throws {
        setUpWorkspacesForTests()
    }

    override func tearDown() async throws {
        clearWorkspaceSidebarDropPreview()
        setWorkspaceSidebarDropPreviewOwnerScopeIdForTests(nil)
        setMonitorsForTests(nil)
        config = defaultConfig
        try await super.tearDown()
    }

    func testAPanelGoingAwayKeepsAnotherPanelsPreview() {
        let preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 1, label: "a", appName: "App",
            targetWorkspaceName: "one", targetsNewWorkspace: false, isTabGroup: false, windowCount: 1)
        XCTAssertFalse(workspaceSidebarDropPreviewBelongs(toPanel: "monitor:0.0,0.0", preview: preview, ownerScopeId: otherDisplay))
        XCTAssertTrue(workspaceSidebarDropPreviewBelongs(toPanel: otherDisplay, preview: preview, ownerScopeId: otherDisplay))
        XCTAssertTrue(workspaceSidebarDropPreviewBelongs(toPanel: "monitor:0.0,0.0", preview: preview, ownerScopeId: nil),
            "Without a known owner, as before")
        var scoped = preview
        scoped = .init(sourceWindowId: 1, label: "a", appName: "App", targetWorkspaceName: nil, targetsNewWorkspace: true,
            targetMonitorScopeId: otherDisplay, isTabGroup: false, windowCount: 1)
        XCTAssertFalse(workspaceSidebarDropPreviewBelongs(toPanel: "monitor:0.0,0.0", preview: scoped, ownerScopeId: nil))
    }

    func testADisconnectedDisplaysPanelRetiresWithoutTakingTheOtherPreview() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let wasEnabled = TrayMenuModel.shared.isEnabled
        defer { TrayMenuModel.shared.isEnabled = wasEnabled }
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        let left = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Left",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true)
        let right = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Right",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        setMonitorsForTests([left, right])
        WorkspaceSidebarPanel.refreshAll()
        defer {
            setMonitorsForTests(nil)
            WorkspaceSidebarPanel.refreshAll()
        }
        let leftScope = workspaceSidebarMonitorScopeId(for: left)
        let rightScope = workspaceSidebarMonitorScopeId(for: right)
        XCTAssertNotNil(WorkspaceSidebarPanel.panel(for: rightScope))

        let preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 1, label: "a", appName: "App",
            targetWorkspaceName: "one", targetsNewWorkspace: false, isTabGroup: false, windowCount: 1)
        TrayMenuModel.shared.workspaceSidebarDropPreview = preview
        setWorkspaceSidebarDropPreviewOwnerScopeIdForTests(leftScope)
        setMonitorsForTests([left])
        WorkspaceSidebarPanel.refreshAll()
        XCTAssertNil(WorkspaceSidebarPanel.panel(for: rightScope), "The gone display's panel is retired")
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview, preview, "The left panel's drop stays")
        for _ in 0 ..< 3 { WorkspaceSidebarPanel.refreshAll() }
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview, preview, "Later refreshes don't touch it either")

        setMonitorsForTests([left, right])
        WorkspaceSidebarPanel.refreshAll()
        setWorkspaceSidebarDropPreviewOwnerScopeIdForTests(rightScope)
        setMonitorsForTests([left])
        WorkspaceSidebarPanel.refreshAll()
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "Its own drop goes with the retired panel")
    }

    // MARK: F3: the Tabs commit contract a frozen preview runs into

    /// A Tabs drop commits only what the last preview showed. If another display's panel never
    /// got a preview, because no drag event refreshed it, the release there drops nothing.
    func testATabsReleaseOnAPanelWhosePreviewWasNeverShownDropsNothing() {
        let controller = WorkspaceSidebarTabSplitHoverController.shared
        defer { controller.reset() }
        let shownOnSource = WorkspaceSidebarDropTarget(kind: .workspace("left"),
            rect: Rect(topLeftX: 0, topLeftY: 100, width: 200, height: 36), acceptsSides: true)
        controller.noteDisplayed(source: 7, hitKind: shownOnSource.kind, target: shownOnSource, placement: nil)
        let onOtherDisplay = WorkspaceSidebarDropTarget(kind: .workspace("right"),
            rect: Rect(topLeftX: 1920, topLeftY: 100, width: 200, height: 36), acceptsSides: true)
        XCTAssertNil(controller.commitTarget(source: 7, hitTarget: onOtherDisplay, point: CGPoint(x: 2000, y: 110)))
        XCTAssertEqual(controller.commitTarget(source: 7, hitTarget: shownOnSource, point: CGPoint(x: 10, y: 110))?.kind,
            shownOnSource.kind)
    }
}
