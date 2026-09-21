import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceSidebarDockHoverStabilityTest: XCTestCase {
    func testOpeningHoverAreaRejectsChangedDockLayout() {
        var settings = WorkspaceSidebarConfig()
        settings.mode = .dock
        settings.dockPosition = .bottom
        let frame = CGRect(x: 0, y: 0, width: 1024, height: 740)
        let region = CGRect(x: 200, y: 0, width: 600, height: 64)
        let point = CGPoint(x: 760, y: 30)
        let source = WorkspaceSidebarExpansionHoverSource(region: region, panelFrame: frame, sidebarConfig: settings)
        XCTAssertTrue(source.contains(point, panelFrame: frame, sidebarConfig: settings))
        for change: (inout WorkspaceSidebarConfig) -> Void in [
            { $0.width += 20 }, { $0.dockIconSize += 8 }, { $0.dockLeftGap += 10 },
            { $0.autoHide.toggle() }, { $0.dockPosition = .right }, { $0.mode = .sidebar },
            { $0.alwaysExpanded = true },
        ] {
            var changed = settings
            change(&changed)
            XCTAssertFalse(source.contains(point, panelFrame: frame, sidebarConfig: changed))
        }
    }

    func testExpansionKeepsTheStationaryTriggerInsideHoverWithoutCapturingInvisibleClicks() throws {
        try withPanel { panel in
            for autoHide in [false, true] {
                config.workspaceSidebar.autoHide = autoHide
                panel.resetHiddenSidebarState()
                panel.viewModel.isWorkspaceSidebarExpanded = false
                panel.viewModel.workspaceSidebarVisibleWidth = 64
                panel.orderFront(nil)
                panel.visibleSurfaceFrame = compactSurface
                let compact = panel.visibleSurfaceFrameOnScreen
                let trigger = CGPoint(x: compact.maxX - 12, y: compact.midY)
                panel.expandSidebar(to: 280)
                panel.updateSurfaceFrame(expandedSurface)
                let expanded = panel.visibleSurfaceFrameOnScreen
                XCTAssertFalse(expanded.contains(trigger), "The arrow can be outside the narrower expanded view")
                XCTAssertTrue(panel.isScreenPointInsideHoverRegion(trigger),
                    "The stationary opening point stays inside the hover region after the surface narrows")
                XCTAssertFalse(panel.isScreenPointInsideVisibleRegion(trigger),
                    "Keeping the popup open must not steal clicks in its former Dock area")
                XCTAssertTrue(panel.isScreenPointInsideHoverRegion(CGPoint(x: expanded.midX, y: expanded.maxY - 20)))
                XCTAssertFalse(panel.isScreenPointInsideHoverRegion(CGPoint(x: compact.maxX + 30, y: compact.midY)))
                XCTAssertFalse(panel.isScreenPointInsideHoverRegion(CGPoint(x: compact.maxX - 12, y: expanded.maxY - 20)),
                    "Do not turn the union into a large invisible bounding rectangle")
            }
        }
    }

    func testClosingHidingAndMovingThePanelDiscardTheOpeningHoverArea() throws {
        try withPanel { panel in
            panel.visibleSurfaceFrame = compactSurface
            let compact = panel.visibleSurfaceFrameOnScreen
            let trigger = CGPoint(x: compact.maxX - 12, y: compact.midY)
            panel.expandSidebar(to: 280)
            panel.updateSurfaceFrame(expandedSurface)
            XCTAssertTrue(panel.isScreenPointInsideHoverRegion(trigger))
            closeWorkspaceSidebarFromCommand(panel)
            // Retain the outgoing expanded geometry until the next layout arrives.
            XCTAssertFalse(panel.isScreenPointInsideHoverRegion(trigger))
            panel.expandSidebar(to: 280)
            XCTAssertFalse(panel.isScreenPointInsideHoverRegion(trigger), "A fresh expansion must not inherit an old trigger")

            closeWorkspaceSidebarFromCommand(panel)
            panel.visibleSurfaceFrame = compactSurface
            panel.expandSidebar(to: 280)
            panel.updateSurfaceFrame(expandedSurface)
            let originalFrame = panel.frame
            panel.setFrame(originalFrame.offsetBy(dx: 20, dy: 0), display: false)
            XCTAssertFalse(panel.isScreenPointInsideHoverRegion(trigger), "An old display position must not retain hover")
            panel.setFrame(originalFrame, display: false)
            panel.hideSidebar(.systemChrome, animated: false)
            panel.revealSidebar(width: 280)
            panel.visibleSurfaceFrame = expandedSurface
            panel.orderFront(nil)
            panel.expandSidebar(to: 280)
            XCTAssertFalse(panel.isScreenPointInsideHoverRegion(trigger), "Suppression must release the trigger area")
        }
    }

    func testAutoHideRetainsTheOpeningAreaOnlyUntilTheHideFinishes() throws {
        try withPanel { panel in
            config.workspaceSidebar.autoHide = true
            panel.orderFront(nil)
            panel.visibleSurfaceFrame = compactSurface
            let compact = panel.visibleSurfaceFrameOnScreen
            let trigger = CGPoint(x: compact.maxX - 12, y: compact.midY)
            panel.expandSidebar(to: 280)
            panel.updateSurfaceFrame(expandedSurface)
            panel.hideSidebar(.pointerExit)
            if panel.slideTransition.isAnimating {
                XCTAssertTrue(panel.isScreenPointInsideHoverRegion(trigger), "Re-entry can reverse an in-flight hide")
                XCTAssertFalse(panel.isScreenPointInsideVisibleRegion(trigger), "Hiding content must stay click-through")
                panel.revealSidebar(width: 280)
                XCTAssertTrue(panel.isScreenPointInsideHoverRegion(trigger), "Reversing the slide retains the opening area")
                panel.hideSidebar(.pointerExit, animated: false)
            }
            // Reduce Motion completes immediately and must release the region too.
            XCTAssertFalse(panel.isScreenPointInsideHoverRegion(trigger), "A completed hide must release the opening area")
            panel.revealSidebar(width: 280)
            panel.visibleSurfaceFrame = expandedSurface
            panel.expandSidebar(to: 280)
            XCTAssertFalse(panel.isScreenPointInsideHoverRegion(trigger), "A fresh reveal must not inherit the old area")
        }
    }

    private let compactSurface = CGRect(x: 212, y: 674, width: 600, height: 64)
    private let expandedSurface = CGRect(x: 372, y: 296, width: 280, height: 444)

    private func withPanel(_ body: (WorkspaceSidebarPanel) throws -> Void) throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let oldConfig = config
        let wasEnabled = TrayMenuModel.shared.isEnabled
        let panel = WorkspaceSidebarPanel.shared
        let oldFrame = panel.frame
        let trackingDepth = panel.menuTrackingDepth
        panel.resetHiddenSidebarState()
        panel.menuTrackingDepth = 1 // Ignore the real desktop pointer during controlled geometry checks.
        defer {
            panel.resetHiddenSidebarState()
            panel.viewModel.isWorkspaceSidebarExpanded = false
            panel.menuTrackingDepth = trackingDepth
            panel.setFrame(oldFrame, display: false)
            config = oldConfig
            TrayMenuModel.shared.isEnabled = wasEnabled
        }
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .dock
        config.workspaceSidebar.dockPosition = .bottom
        config.workspaceSidebar.dockIconSize = 48
        config.workspaceSidebar.autoHide = false
        config.workspaceSidebar.alwaysExpanded = false
        config.workspaceSidebar.width = 280
        TrayMenuModel.shared.isEnabled = true
        panel.refresh(on: mainMonitor)
        panel.setFrame(CGRect(x: 100, y: 100, width: 1024, height: 740), display: false)
        panel.viewModel.workspaceSidebarVisibleWidth = 64
        panel.viewModel.isWorkspaceSidebarExpanded = false
        try body(panel)
    }
}
