@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WorkspaceSidebarDockGapTest: XCTestCase {
    func testGapMovesWholePanelOnEveryDisplayWithoutChangingRailWidth() throws {
        var sidebar = WorkspaceSidebarConfig(mode: .dock)
        for gap in [0, 2, 24] {
            sidebar.dockLeftGap = gap
            for size in [24, 31, 48] {
                sidebar.dockIconSize = size
                let railWidth = CGFloat(size) * 4 / 3
                for screenX: CGFloat in [-1920, 0, 2560] {
                    let screen = CGRect(x: screenX, y: -100, width: 1920, height: 1080)
                    let layout = try XCTUnwrap(workspaceSidebarPanelLayout(screenFrame: screen, sidebarConfig: sidebar))
                    XCTAssertEqual(layout.frame.minX, screenX + CGFloat(gap))
                    XCTAssertEqual(layout.frame.minY, screen.minY)
                    XCTAssertEqual(layout.collapsedWidth, railWidth, accuracy: 0.001)
                    XCTAssertEqual(layout.expandedWidth, 240)
                    XCTAssertEqual(layout.frame.width, 480)
                    XCTAssertEqual(workspaceSidebarReservedWidth(sidebar), railWidth + CGFloat(gap), accuracy: 0.001)
                }
            }
        }
        sidebar.alwaysExpanded = true
        XCTAssertEqual(workspaceSidebarReservedWidth(sidebar), 264)
        sidebar.mode = .sidebar
        XCTAssertEqual(sidebar.effectiveLeftGap, 0)
        XCTAssertEqual(sidebar.dockLeftGap, 24, "Changing modes must retain the user's Dock gap")
        XCTAssertEqual(workspaceSidebarReservedWidth(sidebar), 240)
    }

    func testAutoHideReservesNoSpaceAndStillRevealsFromPhysicalEdge() {
        let sidebar = WorkspaceSidebarConfig(autoHide: true, mode: .dock, dockLeftGap: 24)
        XCTAssertEqual(workspaceSidebarReservedWidth(sidebar), 0)
        let surface = CGRect(x: -1920 + 24, y: 200, width: 0, height: 300)
        let region = workspaceSidebarHoverRegion(surface: surface, sidebarConfig: sidebar, exitTolerance: 20)
        XCTAssertEqual(region.minX, -1920)
        XCTAssertTrue(region.contains(CGPoint(x: -1920, y: 250)))
        XCTAssertFalse(region.contains(CGPoint(x: -1921, y: 250)))
        var visible = sidebar
        visible.autoHide = false
        let visibleRegion = workspaceSidebarHoverRegion(surface: surface, sidebarConfig: visible, exitTolerance: 20)
        XCTAssertEqual(visibleRegion.minX, surface.minX, "The gap beside an always-visible Dock is not a hover target")
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
