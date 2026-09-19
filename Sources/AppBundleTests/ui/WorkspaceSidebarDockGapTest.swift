@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WorkspaceSidebarDockGapTest: XCTestCase {
    func testNativePanelGapPassesThroughClickHitTesting() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let panel = WorkspaceSidebarPanel.shared
        let previousFrame = panel.frame
        let previousSurface = panel.visibleSurfaceFrame
        let previousIcons = panel.dockIconFrames
        let wasVisible = panel.isVisible
        defer {
            if !wasVisible { panel.orderOut(nil) }
            panel.setFrame(previousFrame, display: false)
            panel.visibleSurfaceFrame = previousSurface
            panel.dockIconFrames = previousIcons
        }
        panel.setFrame(CGRect(x: 100, y: 100, width: 480, height: 800), display: false)
        panel.visibleSurfaceFrame = CGRect(x: 24, y: 100, width: 64, height: 300)
        panel.dockIconFrames = []
        panel.orderFront(nil)
        XCTAssertTrue(panel.isVisible)
        let surface = panel.visibleSurfaceFrameOnScreen
        let gapPoint = CGPoint(x: surface.minX - 12, y: surface.midY)
        XCTAssertTrue(panel.frame.contains(gapPoint), "The gap is inside the native window")
        XCTAssertFalse(panel.isScreenPointInsideVisibleRegion(gapPoint), "The gap must pass clicks through")
        XCTAssertTrue(panel.isScreenPointInsideVisibleRegion(CGPoint(x: surface.midX, y: surface.midY)))
    }

    func testPanelStaysOnDisplayEdgeWhileCompactGapReservesSpace() throws {
        var sidebar = WorkspaceSidebarConfig(mode: .dock)
        for gap in [0, 2, 24] {
            sidebar.dockLeftGap = gap
            for size in [24, 31, 48] {
                sidebar.dockIconSize = size
                let railWidth = CGFloat(size) * 4 / 3
                for screenX: CGFloat in [-1920, 0, 2560] {
                    let screen = CGRect(x: screenX, y: -100, width: 1920, height: 1080)
                    let layout = try XCTUnwrap(workspaceSidebarPanelLayout(screenFrame: screen, sidebarConfig: sidebar))
                    XCTAssertEqual(layout.frame.minX, screenX, "The native panel must accommodate flush expansion")
                    XCTAssertEqual(layout.frame.minY, screen.minY)
                    XCTAssertEqual(layout.collapsedWidth, railWidth, accuracy: 0.001)
                    XCTAssertEqual(layout.expandedWidth, 240)
                    XCTAssertEqual(layout.frame.width, 480)
                    XCTAssertEqual(workspaceSidebarReservedWidth(sidebar), railWidth + CGFloat(gap), accuracy: 0.001)
                }
            }
        }
        sidebar.alwaysExpanded = true
        XCTAssertEqual(sidebar.effectiveLeftGap, 0)
        XCTAssertEqual(workspaceSidebarReservedWidth(sidebar), 240)
        sidebar.mode = .sidebar
        XCTAssertEqual(sidebar.effectiveLeftGap, 0)
        XCTAssertEqual(sidebar.dockLeftGap, 24, "Changing modes must retain the user's Dock gap")
        XCTAssertEqual(workspaceSidebarReservedWidth(sidebar), 240)
    }

    func testAutoHideReservesNoSpaceAndStillRevealsFromPhysicalEdge() {
        let sidebar = WorkspaceSidebarConfig(autoHide: true, mode: .dock, dockLeftGap: 24)
        XCTAssertEqual(workspaceSidebarReservedWidth(sidebar), 0)
        let surface = CGRect(x: -1920 + 24, y: 200, width: 0, height: 300)
        let region = workspaceSidebarHoverRegion(surface: surface, displayMinX: -1920, sidebarConfig: sidebar, exitTolerance: 20)
        XCTAssertEqual(region.minX, -1920)
        XCTAssertTrue(region.contains(CGPoint(x: -1920, y: 250)))
        XCTAssertFalse(region.contains(CGPoint(x: -1921, y: 250)))
        var visible = sidebar
        visible.autoHide = false
        let visibleRegion = workspaceSidebarHoverRegion(surface: surface, displayMinX: -1920, sidebarConfig: visible, exitTolerance: 20)
        XCTAssertEqual(visibleRegion.minX, surface.minX, "The gap beside an always-visible Dock is not a hover target")
    }

    func testAutoHideHoverRegionNeverCrossesTheDisplayEdgeDuringExpansion() {
        let sidebar = WorkspaceSidebarConfig(autoHide: true, mode: .dock, dockLeftGap: 24)
        for screenX: CGFloat in [-1920, 0, 2560] {
            for progress: CGFloat in [0, 0.25, 0.5, 1] {
                let surface = workspaceSidebarSurfaceFrame(availableSize: CGSize(width: 480, height: 800),
                    visibleWidth: 64 + 176 * progress, compactHeight: 300, expansionProgress: progress,
                    fitsDockContent: true, compactLeftGap: 24).offsetBy(dx: screenX, dy: 0)
                let region = workspaceSidebarHoverRegion(surface: surface, displayMinX: screenX,
                    sidebarConfig: sidebar, exitTolerance: 20)
                XCTAssertEqual(region.minX, screenX)
                XCTAssertTrue(region.contains(CGPoint(x: screenX, y: surface.midY)))
                XCTAssertFalse(region.contains(CGPoint(x: screenX - 1, y: surface.midY)))
            }
        }
    }

    func testLiveGapChangesReachTheViewWithoutChangingSavedPreferenceOnExpansion() {
        let previous = config
        defer { config = previous }
        let model = TrayMenuModel()
        config.workspaceSidebar.mode = .dock
        config.workspaceSidebar.alwaysExpanded = false
        for gap in [0, 2, 24] {
            config.workspaceSidebar.dockLeftGap = gap
            model.refreshWorkspaceSidebarAppearance()
            XCTAssertEqual(model.workspaceSidebarAppearance.compactLeftGap, CGFloat(gap))
        }
        for (mode, expanded, expectedGap) in [(WorkspaceSidebarMode.dock, true, 0), (.sidebar, false, 0), (.dock, false, 24)] {
            config.workspaceSidebar.mode = mode
            config.workspaceSidebar.alwaysExpanded = expanded
            model.refreshWorkspaceSidebarAppearance()
            XCTAssertEqual(model.workspaceSidebarAppearance.compactLeftGap, CGFloat(expectedGap))
            XCTAssertEqual(config.workspaceSidebar.dockLeftGap, 24)
        }
    }

    func testConfigDefaultsValidationAndSettingsRoundTrip() {
        XCTAssertEqual(WorkspaceSidebarConfig().dockLeftGap, 2)
        for gap in [0, 2, 24] {
            let text = updateSettingsScalarConfig(in: "[workspace-sidebar]\nmode = 'dock'\nwidth = 280\n",
                                                 section: "workspace-sidebar", key: "dock-left-gap", renderedValue: "\(gap)")
            let (parsed, errors) = parseConfig(text)
            XCTAssertTrue(errors.isEmpty)
            XCTAssertEqual(parsed.workspaceSidebar.dockLeftGap, gap)
            XCTAssertEqual(parsed.workspaceSidebar.effectiveLeftGap, gap)
            XCTAssertEqual(parsed.workspaceSidebar.width, 280)
        }
        for invalid in ["-1", "25", "2.5", "'2'"] {
            let (_, errors) = parseConfig("[workspace-sidebar]\ndock-left-gap = \(invalid)\n")
            XCTAssertEqual(errors.count, 1)
            XCTAssertTrue(errors[0].description.contains("workspace-sidebar.dock-left-gap"))
        }
    }
}
