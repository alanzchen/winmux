import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceSidebarResizeTest: XCTestCase {
    func testOnlyAlwaysExpandedSidePanelsCanBeResized() {
        var sidebar = WorkspaceSidebarConfig(mode: .sidebar)
        XCTAssertFalse(workspaceSidebarAllowsResize(sidebar), "A collapsible rail opens over windows")
        sidebar.alwaysExpanded = true
        XCTAssertTrue(workspaceSidebarAllowsResize(sidebar))

        var dock = WorkspaceSidebarConfig(mode: .dock)
        dock.alwaysExpanded = true
        for (position, allowed) in [(WorkspaceDockPosition.left, true), (.right, true), (.bottom, false)] {
            dock.dockPosition = position
            XCTAssertEqual(workspaceSidebarAllowsResize(dock), allowed, "\(position)")
        }
    }

    func testDraggedWidthFollowsTheInnerEdgeAndStaysWithinTheSettingRange() {
        let bounds = 120...480
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 240, pointerDeltaX: 37.4, position: .left, paneCount: 1, bounds: bounds), 277)
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 240, pointerDeltaX: 40, position: .right, paneCount: 1, bounds: bounds), 200,
            "A right-side panel widens as its inner edge moves left")
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 240, pointerDeltaX: 60, position: .left, paneCount: 2, bounds: bounds), 270,
            "Each of two browsed panes takes half the travel, keeping the edge under the pointer")
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 240, pointerDeltaX: -500, position: .left, paneCount: 1, bounds: bounds), 120)
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 240, pointerDeltaX: 900, position: .left, paneCount: 1, bounds: bounds), 480)
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 240, pointerDeltaX: .nan, position: .left, paneCount: 1, bounds: bounds), 240)
    }

    func testMinimumDraggedWidthStaysAboveCollapsedWidth() {
        var sidebar = WorkspaceSidebarConfig(mode: .sidebar)
        sidebar.alwaysExpanded = true
        XCTAssertEqual(workspaceSidebarResizeWidthBounds(sidebar), workspaceSidebarResizableWidthRange)
        sidebar.collapsedWidth = 120
        XCTAssertEqual(workspaceSidebarResizeWidthBounds(sidebar), 121...480,
            "always-expanded rejects a width equal to collapsed-width")
        let (_, errors) = parseConfig("""
            [workspace-sidebar]
            always-expanded = true
            collapsed-width = 120
            width = \(workspaceSidebarResizeWidthBounds(sidebar).lowerBound)
            """)
        XCTAssertEqual(errors.descriptions, [])
    }

    func testHandleSitsInsideThePanelAlongItsInnerEdge() {
        let surface = CGRect(x: 10, y: 20, width: 240, height: 700)
        XCTAssertEqual(workspaceSidebarResizeHandleFrame(surface: surface, position: .left),
            CGRect(x: 250 - workspaceSidebarResizeHandleWidth, y: 20, width: workspaceSidebarResizeHandleWidth, height: 700))
        XCTAssertEqual(workspaceSidebarResizeHandleFrame(surface: surface, position: .right),
            CGRect(x: 10, y: 20, width: workspaceSidebarResizeHandleWidth, height: 700))
        XCTAssertNil(workspaceSidebarResizeHandleFrame(surface: surface, position: .bottom))
        XCTAssertNil(workspaceSidebarResizeHandleFrame(surface: .zero, position: .left))
    }

    func testDraggingTheInnerEdgeResizesTheSidebarLive() async throws {
        try await withAlwaysExpandedPanel { panel in
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 240)
            XCTAssertFalse(panel.resizeHandleView.isHidden)
            XCTAssertEqual(panel.resizeHandleView.frame.width, workspaceSidebarResizeHandleWidth)

            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            XCTAssertFalse(panel.beginSidebarResize(atScreenX: 500), "One drag at a time")
            XCTAssertFalse(panel.ignoresMouseEvents, "The drag keeps the pointer while the edge catches up")
            panel.updateSidebarResize(toScreenX: 560)
            XCTAssertEqual(config.workspaceSidebar.width, 300)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 300)
            XCTAssertEqual(panel.viewModel.workspaceSidebarAppearance.expandedWidth, 300)
            XCTAssertEqual(mainMonitor.workspaceSidebarInset, 300, "Tiled windows make room for the new width")

            panel.updateSidebarResize(toScreenX: 0)
            XCTAssertEqual(config.workspaceSidebar.width, workspaceSidebarResizableWidthRange.lowerBound)
            panel.endSidebarResize()
            XCTAssertNil(panel.sidebarResize)
            panel.updateSidebarResize(toScreenX: 700)
            XCTAssertEqual(config.workspaceSidebar.width, workspaceSidebarResizableWidthRange.lowerBound,
                "Movement after the drag ends does not resize")
        }
    }

    func testTurningOffAlwaysExpandedEndsTheDragAndHidesTheHandle() async throws {
        try await withAlwaysExpandedPanel { panel in
            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            config.workspaceSidebar.alwaysExpanded = false
            panel.updateSidebarResize(toScreenX: 600)
            XCTAssertNil(panel.sidebarResize)
            XCTAssertEqual(config.workspaceSidebar.width, 240)
            panel.refresh(on: mainMonitor)
            XCTAssertTrue(panel.resizeHandleView.isHidden)
            XCTAssertFalse(panel.beginSidebarResize(atScreenX: 500))
        }
    }

    private func withAlwaysExpandedPanel(_ body: @MainActor (WorkspaceSidebarPanel) async throws -> Void) async throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let oldConfig = config
        let wasEnabled = TrayMenuModel.shared.isEnabled
        config.workspaceSidebar = WorkspaceSidebarConfig(mode: .sidebar)
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.alwaysExpanded = true
        config.workspaceSidebar.width = 240
        TrayMenuModel.shared.isEnabled = true
        // Live resizing refreshes every display's panel, so drive the one refreshAll owns.
        WorkspaceSidebarPanel.refreshAll()
        let panel = try XCTUnwrap(WorkspaceSidebarPanel.panel(for: workspaceSidebarMonitorScopeId(for: mainMonitor)))
        let trackingDepth = panel.menuTrackingDepth
        // Native global pointer location must not drive these controlled transitions.
        panel.menuTrackingDepth = 1
        defer {
            panel.endSidebarResize()
            panel.menuTrackingDepth = trackingDepth
            TrayMenuModel.shared.isEnabled = wasEnabled
            config = oldConfig
            WorkspaceSidebarPanel.refreshAll()
        }
        panel.visibleSurfaceFrame = CGRect(x: 0, y: 0, width: 240, height: panel.hostingView.bounds.height)
        panel.updateResizeHandle()
        try await body(panel)
    }
}
