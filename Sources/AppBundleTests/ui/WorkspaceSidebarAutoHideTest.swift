import AppKit
@testable import AppBundle
import QuartzCore
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarAutoHideTest: XCTestCase {
    func testSlideClearsAllThreeEdgesIncludingGapAndMagnifiedIcons() {
        let viewport = CGRect(x: 0, y: 0, width: 480, height: 800)
        for position in [WorkspaceDockPosition.left, .right, .bottom] {
            let content: CGRect = switch position {
                case .left: CGRect(x: 24, y: 100, width: 120, height: 600)
                case .right: CGRect(x: 336, y: 100, width: 120, height: 600)
                case .bottom: CGRect(x: 40, y: 24, width: 400, height: 120)
            }
            let offset = workspaceSidebarSlideOffset(content: content, bounds: viewport, position: position)
            let hidden = content.offsetBy(dx: offset.x, dy: offset.y)
            XCTAssertEqual(hidden.size, content.size, "Sliding must never squeeze the icons")
            XCTAssertTrue(hidden.intersection(viewport).isEmpty)
            switch position {
                case .left: XCTAssertEqual(hidden.maxX, viewport.minX)
                case .right: XCTAssertEqual(hidden.minX, viewport.maxX)
                case .bottom: XCTAssertEqual(hidden.maxY, viewport.minY)
            }
        }
    }

    func testQuickReversalCancelsHideCompletion() async throws {
        let transition = WorkspaceSidebarSlideTransition(layer: CALayer())
        var completions: [String] = []
        transition.setHidden(true, offset: CGPoint(x: -80, y: 0), animated: true) { completions.append("hide") }
        try await Task.sleep(for: .milliseconds(40))
        transition.setHidden(false, offset: .zero, animated: true) { completions.append("show") }
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(completions, ["show"], "The old hide must not remove a newly revealed panel")
        XCTAssertFalse(transition.isHidden)
        XCTAssertFalse(transition.layer.isHidden)
        XCTAssertFalse(transition.isAnimating)
        XCTAssertTrue(CATransform3DIsIdentity(transition.layer.transform))
    }

    func testNativeLayerHasIntermediatePositionsAndReversesFromPresentedPosition() async throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 200, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clip = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        let rail = NSView(frame: clip.bounds)
        rail.wantsLayer = true
        clip.addSubview(rail)
        window.contentView = clip
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let layer = try XCTUnwrap(rail.layer)
        let transition = WorkspaceSidebarSlideTransition(layer: layer)
        for offset in [CGPoint(x: -100, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: -100)] {
            transition.reset()
            CATransaction.flush()
            transition.setHidden(true, offset: offset, animated: true)
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(80))
            let transform = try XCTUnwrap(layer.presentation()).transform
            let distance = abs(transform.m41) + abs(transform.m42)
            XCTAssertGreaterThan(distance, 0)
            XCTAssertLessThan(distance, 100)
            XCTAssertEqual(transform.m11, 1)
            XCTAssertEqual(transform.m22, 1)
            transition.setHidden(false, offset: .zero, animated: true)
            let animation = try XCTUnwrap(layer.animation(forKey: WorkspaceSidebarSlideTransition.animationKey) as? CABasicAnimation)
            let start = try XCTUnwrap(animation.fromValue as? NSValue).caTransform3DValue
            XCTAssertEqual(start.m41, transform.m41, accuracy: 2)
            XCTAssertEqual(start.m42, transform.m42, accuracy: 2)
            XCTAssertEqual(window.frame.origin, CGPoint(x: -10_000, y: -10_000))
        }
        // Reset and reveal in the same turn, before Core Animation can synchronize
        // its presentation tree. The new endpoint must win over that stale tree.
        transition.reset(hidden: true, offset: CGPoint(x: -96, y: 0))
        transition.setHidden(false, offset: .zero, animated: true)
        let reveal = try XCTUnwrap(layer.animation(forKey: WorkspaceSidebarSlideTransition.animationKey) as? CABasicAnimation)
        XCTAssertEqual(try XCTUnwrap(reveal.fromValue as? NSValue).caTransform3DValue.m41, -96)
        transition.reset()
    }

    func testHiddenDockRetainsItsEdgeRevealRegionWithoutAnInvisibleExpandedTarget() async throws {
        try await withPanel { panel in
            config.workspaceSidebar.mode = .dock
            for position in [WorkspaceDockPosition.left, .right, .bottom] {
                panel.resetHiddenSidebarState()
                config.workspaceSidebar.dockPosition = position
                config.workspaceSidebar.autoHide = false
                panel.refresh(on: mainMonitor)
                panel.visibleSurfaceFrame = workspaceSidebarSurfaceFrame(availableSize: panel.hostingView.bounds.size,
                    visibleWidth: 240, compactHeight: 300, expansionProgress: 0,
                    fitsDockContent: true, compactLeftGap: 2, position: position)
                let surface = panel.visibleSurfaceFrameOnScreen
                config.workspaceSidebar.autoHide = true
                panel.hideSidebar(.pointerExit, animated: false)
                let edge: CGPoint = switch position {
                    case .left: CGPoint(x: panel.frame.minX + 0.5, y: surface.midY)
                    case .right: CGPoint(x: panel.frame.maxX - 0.5, y: surface.midY)
                    case .bottom: CGPoint(x: surface.midX, y: panel.frame.minY + 0.5)
                }
                XCTAssertTrue(panel.isScreenPointInsideHoverRegion(edge), "Hidden \(position) Dock must reopen from its edge")
                let distant: CGPoint = switch position {
                    case .left: CGPoint(x: edge.x + 200, y: edge.y)
                    case .right: CGPoint(x: edge.x - 200, y: edge.y)
                    case .bottom: CGPoint(x: edge.x, y: edge.y + 200)
                }
                XCTAssertFalse(panel.isScreenPointInsideHoverRegion(distant), "An outgoing wide panel must not own distant hover")
            }
        }
    }

    func testColdHiddenDockHasAnEdgeTargetAndShortRevealDistanceInEveryPlacement() async throws {
        try await withPanel { panel in
            config.workspaceSidebar.mode = .dock
            config.workspaceSidebar.autoHide = true
            for position in [WorkspaceDockPosition.left, .right, .bottom] {
                panel.resetHiddenSidebarState()
                config.workspaceSidebar.dockPosition = position
                panel.refresh(on: mainMonitor)
                panel.visibleSurfaceFrame = nil // No SwiftUI preference has arrived.
                panel.dockIconFrames = []
                let distance = (panel.fittedDockRestingWidth ?? workspaceSidebarHoverActivationWidth(config.workspaceSidebar))
                    + CGFloat(config.workspaceSidebar.effectiveLeftGap)
                let offset = panel.slideOffset
                XCTAssertEqual(abs(offset.x) + abs(offset.y), distance, accuracy: 0.01,
                    "An empty cache must not add the whole panel width or height to the slide")
                panel.visibleSurfaceFrame = workspaceSidebarSurfaceFrame(availableSize: panel.hostingView.bounds.size,
                    visibleWidth: 240, compactHeight: 300, expansionProgress: 1,
                    fitsDockContent: true, compactLeftGap: 2, position: position)
                let warmOffset = panel.slideOffset
                XCTAssertEqual(abs(warmOffset.x) + abs(warmOffset.y), distance, accuracy: 0.01,
                    "A retained expanded surface must not lengthen a compact reveal")
                let edge: CGPoint = switch position {
                    case .left: CGPoint(x: panel.frame.minX + 0.5, y: panel.frame.midY)
                    case .right: CGPoint(x: panel.frame.maxX - 0.5, y: panel.frame.midY)
                    case .bottom: CGPoint(x: panel.frame.midX, y: panel.frame.minY + 0.5)
                }
                XCTAssertTrue(panel.isScreenPointInsideHoverRegion(edge))
            }
        }
    }

    func testCommandCanReverseOutgoingHideAndCompactRevealAcceptsInputImmediately() async throws {
        try await withPanel { panel in
            config.workspaceSidebar.autoHide = true
            panel.viewModel.workspaceSidebarVisibleWidth = CGFloat(config.workspaceSidebar.width)
            panel.viewModel.isWorkspaceSidebarExpanded = true
            XCTAssertTrue(panel.sidebarCommandWouldClose)
            closeWorkspaceSidebarFromCommand(panel)
            XCTAssertFalse(panel.sidebarCommandWouldClose, "The next toggle must reopen an outgoing rail")
            panel.revealSidebar(width: workspaceSidebarHoverActivationWidth(config.workspaceSidebar))
            XCTAssertTrue(panel.sidebarAcceptsPointer, "A fast drop or click must not fall through a revealing rail")
            XCTAssertFalse(panel.viewModel.isWorkspaceSidebarExpanded)
            try await Task.sleep(for: .milliseconds(260))
            XCTAssertGreaterThan(panel.viewModel.workspaceSidebarVisibleWidth, 0)
        }
    }

    func testUnpinningUnderPointerDoesNotStartAnOutAndBackSlide() async throws {
        try await withPanel { panel in
            config.workspaceSidebar.alwaysExpanded = true
            config.workspaceSidebar.autoHide = true
            panel.refresh(on: mainMonitor)
            panel.visibleSurfaceFrame = CGRect(x: 0, y: 0, width: 240, height: panel.hostingView.bounds.height)
            let surface = panel.visibleSurfaceFrameOnScreen
            config.workspaceSidebar.alwaysExpanded = false
            panel.refresh(on: mainMonitor, mouseLocation: CGPoint(x: surface.midX, y: surface.midY))
            XCTAssertNil(panel.autoHideReason)
            XCTAssertFalse(panel.slideTransition.isAnimating)
            XCTAssertGreaterThan(panel.viewModel.workspaceSidebarVisibleWidth, 0)
        }
    }

    func testSystemSuppressionDuringPointerHideOrdersOutAtCompletion() async throws {
        try await withPanel { panel in
            panel.hideSidebar(.pointerExit)
            panel.hideSidebar(.systemChrome)
            try await Task.sleep(for: .milliseconds(260))
            XCTAssertFalse(panel.isVisible)
            XCTAssertTrue(panel.slidingView.layer!.isHidden)
        }
    }

    func testSystemSuppressionSurvivesReentrantSearchCancellation() async throws {
        try await withPanel { panel in
            for autoHide in [false, true] {
                panel.resetHiddenSidebarState()
                config.workspaceSidebar.autoHide = autoHide
                panel.refresh(on: mainMonitor)
                panel.revealSidebar(width: CGFloat(config.workspaceSidebar.width))
                panel.viewModel.isWorkspaceSidebarExpanded = true
                panel.inlineTextEditingActive = true
                panel.inlineTextEditingCancel = { closeWorkspaceSidebarFromCommand(panel) }
                WorkspaceSidebarPanel.inputSession.acquire(panel)
                panel.hideSidebar(.systemChrome)
                XCTAssertEqual(panel.autoHideReason, .systemChrome)
                XCTAssertFalse(panel.inlineTextEditingActive)
                XCTAssertNil(WorkspaceSidebarPanel.inputSession.owner)
                try await Task.sleep(for: .milliseconds(260))
                XCTAssertFalse(panel.isVisible)
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 0)
            }
        }
    }

    func testDisableCancelsAnimationStartedBySearchCancellation() async throws {
        try await withPanel { panel in
            config.workspaceSidebar.autoHide = true
            panel.viewModel.isWorkspaceSidebarExpanded = true
            panel.inlineTextEditingActive = true
            panel.inlineTextEditingCancel = { closeWorkspaceSidebarFromCommand(panel) }
            panel.resetHiddenSidebarState()
            XCTAssertFalse(panel.slideTransition.isAnimating)
            XCTAssertNil(panel.autoHideReason)
            XCTAssertFalse(panel.isVisible)
            try await Task.sleep(for: .milliseconds(260))
            XCTAssertFalse(panel.isVisible)
        }
    }

    func testRepeatedHideDoesNotExtendAnimationAndUsesLatestCompletion() async throws {
        let transition = WorkspaceSidebarSlideTransition(layer: CALayer())
        var completions: [String] = []
        transition.setHidden(true, offset: CGPoint(x: 80, y: 0), animated: true) { completions.append("pointer") }
        try await Task.sleep(for: .milliseconds(120))
        transition.setHidden(true, offset: CGPoint(x: 80, y: 0), animated: true) { completions.append("system") }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(completions, ["system"])
        XCTAssertTrue(transition.layer.isHidden)
        XCTAssertFalse(transition.isAnimating)
    }

    func testReducedMotionAndDisableCancelAnimationImmediately() async throws {
        let transition = WorkspaceSidebarSlideTransition(layer: CALayer())
        var completions: [String] = []
        transition.setHidden(true, offset: CGPoint(x: 0, y: -100), animated: true) { completions.append("old") }
        transition.setHidden(true, offset: CGPoint(x: 0, y: -100), animated: false) { completions.append("reduced") }
        XCTAssertEqual(completions, ["reduced"])
        XCTAssertFalse(transition.isAnimating)
        XCTAssertNil(transition.layer.animation(forKey: WorkspaceSidebarSlideTransition.animationKey))
        transition.reset()
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(completions, ["reduced"])
        XCTAssertTrue(CATransform3DIsIdentity(transition.layer.transform))
        XCTAssertFalse(transition.layer.isHidden)
    }

    func testPointerHideKeepsNativeFrameAndLayoutUntilCompletionThenReveals() async throws {
        try await withPanel { panel in
            let width = panel.viewModel.workspaceSidebarVisibleWidth
            let frame = panel.frame
            config.workspaceSidebar.autoHide = true
            panel.hideSidebar(.pointerExit)
            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(panel.ignoresMouseEvents)
            XCTAssertFalse(panel.sidebarAcceptsPointer)
            XCTAssertEqual(panel.frame, frame)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertTrue(panel.slideTransition.isAnimating)
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, width)
                panel.refresh(on: mainMonitor)
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, width,
                    "A window-manager refresh must not clear the outgoing rail")
            }
            try await Task.sleep(for: .milliseconds(260))
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 0)
            XCTAssertTrue(panel.isVisible, "The stationary panel still detects edge hover")
            panel.animateVisibleSidebarWidth(width, animation: .linear)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, width)
            try await Task.sleep(for: .milliseconds(260))
            XCTAssertTrue(panel.sidebarAcceptsPointer)
            XCTAssertEqual(panel.frame, frame)
            XCTAssertTrue(CATransform3DIsIdentity(panel.slidingView.layer!.transform))
        }
    }

    func testDisableDuringSlideCannotHideReenabledPanelLater() async throws {
        try await withPanel { panel in
            panel.hideSidebar(.systemChrome)
            config.workspaceSidebar.enabled = false
            panel.refresh(on: mainMonitor)
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(panel.slideTransition.isAnimating)
            config.workspaceSidebar.enabled = true
            panel.refresh(on: mainMonitor)
            try await Task.sleep(for: .milliseconds(260))
            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(panel.sidebarAcceptsPointer)
            XCTAssertGreaterThan(panel.viewModel.workspaceSidebarVisibleWidth, 0)
        }
    }

    func testRefreshKeepsBothProjectPanesExpandedAtEveryDockPosition() async throws {
        try await withPanel { panel in
            config.workspaceSidebar.mode = .dock
            config.workspaceSidebar.width = 240
            for autoHide in [false, true] {
                config.workspaceSidebar.autoHide = autoHide
                for position in WorkspaceDockPosition.allCases {
                    config.workspaceSidebar.dockPosition = position
                    panel.refresh(on: mainMonitor)
                    panel.viewModel.isWorkspaceSidebarExpanded = true
                    panel.animateVisibleSidebarWidth(480, animation: .linear)
                    for _ in 0..<3 {
                        panel.refresh(on: mainMonitor)
                        XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 480,
                            "Routine refresh must keep room for both projects at \(position)")
                    }
                }
            }
        }
    }

    func testExpandedWidthSettingResizesSingleAndSplitProjectViews() async throws {
        try await withPanel { panel in
            for pinned in [false, true] {
                for columns: CGFloat in [1, 2] {
                    config.workspaceSidebar.alwaysExpanded = pinned
                    config.workspaceSidebar.width = 240
                    panel.refresh(on: mainMonitor)
                    panel.viewModel.isWorkspaceSidebarExpanded = true
                    panel.animateVisibleSidebarWidth(240 * columns, animation: .linear)
                    for width in [280, 200] {
                        config.workspaceSidebar.width = width
                        panel.refresh(on: mainMonitor)
                        XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, CGFloat(width) * columns,
                            "Changing width must preserve the number of project panes")
                    }
                }
            }
        }
    }

    func testPinnedSplitProjectViewKeepsItsWidthOnPointerExit() async throws {
        try await withPanel { panel in
            config.workspaceSidebar.alwaysExpanded = true
            config.workspaceSidebar.width = 240
            panel.refresh(on: mainMonitor)
            panel.animateVisibleSidebarWidth(480, animation: .linear)
            panel.handleHoverExit(collapsedWidth: 240)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 480)
            panel.refresh(on: mainMonitor)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 480)
        }
    }

    func testPinningAnOpenSplitProjectViewKeepsBothPanes() async throws {
        try await withPanel { panel in
            config.workspaceSidebar.width = 240
            panel.refresh(on: mainMonitor)
            panel.viewModel.isWorkspaceSidebarExpanded = true
            panel.animateVisibleSidebarWidth(480, animation: .linear)
            config.workspaceSidebar.alwaysExpanded = true
            panel.refresh(on: mainMonitor)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 480)
        }
    }

    func testInlineEditingAndPinnedCommandCloseKeepBothProjectPanes() async throws {
        try await withPanel { panel in
            config.workspaceSidebar.width = 240
            panel.refresh(on: mainMonitor)
            panel.viewModel.isWorkspaceSidebarExpanded = true
            panel.animateVisibleSidebarWidth(480, animation: .linear)
            panel.prepareForInlineTextEditing()
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 480,
                "Starting search or a rename must not squeeze two projects into one pane")
            config.workspaceSidebar.alwaysExpanded = true
            panel.refresh(on: mainMonitor)
            closeWorkspaceSidebarFromCommand(panel)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 480,
                "Closing search in pinned mode must leave both project panes open")
            config.workspaceSidebar.alwaysExpanded = false
            panel.refresh(on: mainMonitor)
            panel.viewModel.isWorkspaceSidebarExpanded = true
            panel.animateVisibleSidebarWidth(480, animation: .linear)
            closeWorkspaceSidebarFromCommand(panel)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, workspaceSidebarRestingWidth(config.workspaceSidebar))
        }
    }

    private func withPanel(_ body: @MainActor (WorkspaceSidebarPanel) async throws -> Void) async throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let oldConfig = config
        let wasEnabled = TrayMenuModel.shared.isEnabled
        let panel = WorkspaceSidebarPanel.shared
        panel.resetHiddenSidebarState()
        panel.lastConfiguredExpandedWidth = nil
        panel.persistentExpansionWidth = nil
        panel.viewModel.isWorkspaceSidebarExpanded = false
        let trackingDepth = panel.menuTrackingDepth
        // Native global pointer location must not drive these controlled transitions.
        panel.menuTrackingDepth = 1
        defer {
            panel.resetHiddenSidebarState()
            panel.lastConfiguredExpandedWidth = nil
            panel.persistentExpansionWidth = nil
            panel.viewModel.isWorkspaceSidebarExpanded = false
            panel.menuTrackingDepth = trackingDepth
            TrayMenuModel.shared.isEnabled = wasEnabled
            config = oldConfig
        }
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.autoHide = false
        config.workspaceSidebar.alwaysExpanded = false
        TrayMenuModel.shared.isEnabled = true
        panel.refresh(on: mainMonitor)
        try await body(panel)
    }
}
