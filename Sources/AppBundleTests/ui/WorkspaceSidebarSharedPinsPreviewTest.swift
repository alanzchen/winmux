import AppKit
@testable import AppBundle
import Combine
import Common
import XCTest

/// With shared pins, one pin is drawn on several displays' panels. Only the panel showing the
/// drop lights it; the others keep only what's dragged, so its row still dims there.
@MainActor
final class WorkspaceSidebarSharedPinsPreviewTest: XCTestCase {
    private let left = "monitor:0.0,0.0"
    private let right = "monitor:1920.0,0.0"

    override func tearDown() async throws {
        clearWorkspaceSidebarDropPreview()
        setWorkspaceSidebarDropPreviewOwnerScopeIdForTests(nil)
        MousePointerTracker.shared.reset()
        setMonitorsForTests(nil)
        config = defaultConfig
        try await super.tearDown()
    }

    func testOnlyTheOwnerPanelLightsASharedPin() {
        let preview = pinPreview(list: left)
        XCTAssertEqual(workspaceSidebarPanelDropPreview(preview, panelScopeId: left, ownerId: left, sharesPinnedTabs: true), preview)
        XCTAssertEqual(workspaceSidebarPanelDropPreview(preview, panelScopeId: right, ownerId: left, sharesPinnedTabs: true),
            preview.sourceOnly)
        XCTAssertEqual(workspaceSidebarPanelDropPreview(preview, panelScopeId: right, ownerId: left, sharesPinnedTabs: false),
            preview, "Without shared pins, every panel as before")
    }

    /// A missing owner never means every panel.
    func testWithoutAKnownOwnerOnlyTheNamedListLightsIt() {
        let named = pinPreview(list: right)
        XCTAssertEqual(workspaceSidebarPanelDropPreview(named, panelScopeId: right, ownerId: nil, sharesPinnedTabs: true), named)
        XCTAssertEqual(workspaceSidebarPanelDropPreview(named, panelScopeId: left, ownerId: nil, sharesPinnedTabs: true),
            named.sourceOnly)
        let join = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 1, label: "a", appName: "App",
            targetWorkspaceName: "pin", targetsNewWorkspace: false, isTabGroup: false, windowCount: 1)
        for panel in [left, right] {
            XCTAssertEqual(workspaceSidebarPanelDropPreview(join, panelScopeId: panel, ownerId: nil, sharesPinnedTabs: true),
                join.sourceOnly, "A join names no list, so no panel lights it")
        }
    }

    /// Through the panels' own models: an equal preview moving from one panel to the other moves
    /// its highlight, and the same preview again publishes nothing.
    func testThePanelsFollowTheOwnerAndPublishOnlyChanges() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        setUpWorkspacesForTests()
        let wasEnabled = TrayMenuModel.shared.isEnabled
        defer { TrayMenuModel.shared.isEnabled = wasEnabled }
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        config.workspaceSidebar.sharePinnedTabs = true
        let leftMonitor = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Left",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true)
        let rightMonitor = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Right",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        setMonitorsForTests([leftMonitor, rightMonitor])
        WorkspaceSidebarPanel.refreshAll()
        defer {
            setMonitorsForTests(nil)
            config = defaultConfig
            WorkspaceSidebarPanel.refreshAll()
        }
        let leftPanel = try XCTUnwrap(WorkspaceSidebarPanel.panel(for: left))
        let rightPanel = try XCTUnwrap(WorkspaceSidebarPanel.panel(for: right))
        let preview = pinPreview(list: left)

        setWorkspaceSidebarDropPreviewIfChanged(preview, owner: .panel(monitorScopeId: left))
        XCTAssertEqual(leftPanel.viewModel.workspaceSidebarDropPreview, preview)
        XCTAssertEqual(rightPanel.viewModel.workspaceSidebarDropPreview, preview.sourceOnly)

        var publications = 0
        let subscriptions = [leftPanel, rightPanel].map {
            $0.viewModel.$workspaceSidebarDropPreview.dropFirst().sink { _ in publications += 1 }
        }
        defer { withExtendedLifetime(subscriptions) {} }
        for _ in 0 ..< 5 { setWorkspaceSidebarDropPreviewIfChanged(preview, owner: .panel(monitorScopeId: left)) }
        XCTAssertEqual(publications, 0, "The same preview on the same panel publishes nothing")

        setWorkspaceSidebarDropPreviewIfChanged(preview, owner: .panel(monitorScopeId: right))
        XCTAssertEqual(leftPanel.viewModel.workspaceSidebarDropPreview, preview.sourceOnly)
        XCTAssertEqual(rightPanel.viewModel.workspaceSidebarDropPreview, preview, "The owner changed, the preview didn't")
        XCTAssertEqual(publications, 2, "One per panel")

        setWorkspaceSidebarDropPreviewIfChanged(nil)
        XCTAssertNil(leftPanel.viewModel.workspaceSidebarDropPreview)
        XCTAssertNil(rightPanel.viewModel.workspaceSidebarDropPreview)
    }

    private func pinPreview(list: String) -> WorkspaceSidebarDropPreviewViewModel {
        var preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 1, label: "a", appName: "App",
            targetWorkspaceName: nil, targetsNewWorkspace: false, targetProjectId: workspaceProjectDefaultId,
            targetMonitorScopeId: list, isTabGroup: false, windowCount: 1)
        preview.targetsPinned = true
        preview.targetPinnedGap = .init(workspaceName: "pin", isAfter: true)
        return preview
    }
}
