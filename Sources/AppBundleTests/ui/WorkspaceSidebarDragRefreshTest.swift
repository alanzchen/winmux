import AppKit
@testable import AppBundle
import XCTest

/// Every global drag event used to refresh every sidebar panel: sync its model, set its level,
/// order it front, update click-through and recheck hover. Another app's drag changes none of
/// that but click-through, which still follows the pointer at every event.
@MainActor
final class WorkspaceSidebarDragRefreshTest: XCTestCase {
    func testAWindowWinMuxHandlesRefreshesAtEveryEventAndAnotherAppsDragOnce() {
        var gate = WorkspaceSidebarDragRefreshGate()
        // Selecting text in another app: the first event only.
        XCTAssertEqual((0 ..< 4).map { _ in gate.shouldRefresh(manipulatesWindow: false) }, [true, false, false, false])
        // WinMux takes the window: every event, then the first after it.
        XCTAssertEqual([true, true, false, false].map { gate.shouldRefresh(manipulatesWindow: $0) }, [true, true, true, false])
        // A press whose release went unseen still starts over.
        gate.reset()
        XCTAssertTrue(gate.shouldRefresh(manipulatesWindow: false))
        XCTAssertFalse(gate.shouldRefresh(manipulatesWindow: false))
    }

    func testAnotherAppsDragRefreshesOncePerPressAndUpdatesInputAtEveryEvent() {
        let oldConfig = config
        defer { config = oldConfig }
        // No panel is framed or ordered on a display by the refreshes this makes.
        config.workspaceSidebar.enabled = false
        XCTAssertEqual(getCurrentMouseManipulationKind(), .none)
        noteLeftMousePressBoundaryForDragRefresh()
        defer { noteLeftMousePressBoundaryForDragRefresh() }
        let target = RecordingInputTarget()
        let points = (0 ..< 120).map { CGPoint(x: Double($0), y: 10) }
        let before = WorkspaceSidebarPanel.refreshAllPasses
        for point in points { refreshPendingWindowDragIntentFromGlobalMouseDrag(screenPoint: point, inputTargets: [target]) }
        XCTAssertEqual(WorkspaceSidebarPanel.refreshAllPasses - before, 1)
        XCTAssertEqual(target.points, Array(points.dropFirst()), "Each skipped event updates input at once, at its own point")
        // The next press, even with its predecessor's release unseen, refreshes as its drag starts.
        noteLeftMousePressBoundaryForDragRefresh()
        refreshPendingWindowDragIntentFromGlobalMouseDrag(screenPoint: .zero, inputTargets: [target])
        XCTAssertEqual(WorkspaceSidebarPanel.refreshAllPasses - before, 2)
        XCTAssertEqual(target.points.count, points.count - 1)
    }

    /// A drag crossing from a panel's visible surface into its transparent part, and back,
    /// within one hover interval: the panel passes or takes clicks at the event itself, before
    /// any timer or run-loop pass. The panel is ordered in entirely off every display.
    func testASkippedDragEventTakesOrPassesClicksAtOnceWhereThePointerIs() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let offscreen = CGRect(x: -20_000, y: -20_000, width: 560, height: 800)
        try XCTSkipIf(NSScreen.screens.contains { $0.frame.intersects(offscreen) }, "A display covers the offscreen frame")
        let oldConfig = config
        let panel = WorkspaceSidebarPanel.shared
        let oldFrame = panel.frame
        let trackingDepth = panel.menuTrackingDepth
        // Disabled, any refresh hides a panel rather than framing it on a display.
        config.workspaceSidebar.enabled = false
        panel.resetHiddenSidebarState()
        panel.menuTrackingDepth = 1 // Deferred hover rechecks change nothing.
        defer {
            panel.orderOut(nil)
            panel.resetHiddenSidebarState()
            panel.menuTrackingDepth = trackingDepth
            panel.setFrame(oldFrame, display: false)
            config = oldConfig
            noteLeftMousePressBoundaryForDragRefresh()
        }
        panel.setFrame(offscreen, display: false)
        panel.orderFront(nil)
        XCTAssertEqual(panel.frame, offscreen, "Ordered in without being moved onto a display")
        panel.visibleSurfaceFrame = CGRect(x: 0, y: 0, width: 280, height: 800)
        let surface = panel.visibleSurfaceFrameOnScreen
        let onSurface = CGPoint(x: surface.maxX - 4, y: surface.midY)
        let transparent = CGPoint(x: surface.maxX + 4, y: surface.midY)
        XCTAssertTrue(panel.frame.contains(transparent), "Inside the panel, outside what it draws")

        noteLeftMousePressBoundaryForDragRefresh()
        refreshPendingWindowDragIntentFromGlobalMouseDrag(screenPoint: transparent, inputTargets: [panel])
        for (point, ignores) in [(onSurface, false), (transparent, true), (onSurface, false), (transparent, true)] {
            let before = WorkspaceSidebarPanel.refreshAllPasses
            refreshPendingWindowDragIntentFromGlobalMouseDrag(screenPoint: point, inputTargets: [panel])
            XCTAssertEqual(WorkspaceSidebarPanel.refreshAllPasses, before, "Only the press's first event refreshes")
            XCTAssertEqual(panel.ignoresMouseEvents, ignores, point == onSurface ? "Over the surface" : "Over the transparent part")
        }
    }

    /// A refresh reapplies the panel's layer. Only a different level reaches the window server;
    /// yielding to System Settings still orders the panel beneath it.
    func testReapplyingAnUnchangedLayerWritesNoLevel() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let panel = NSPanelHud()
        panel.setFrame(CGRect(x: -10_000, y: -10_000, width: 200, height: 200), display: false)
        defer { resetSystemFrontStateForTests() }
        resetSystemFrontStateForTests()
        let writes = LevelWrites()
        let observation = panel.observe(\.level) { _, _ in writes.count += 1 }
        defer { observation.invalidate() }
        panel.applyWorkspaceSidebarLayer(stayOnTop: true)
        let firstWrites = writes.count
        for _ in 0 ..< 50 { panel.applyWorkspaceSidebarLayer(stayOnTop: true) }
        XCTAssertEqual(writes.count, firstWrites, "Unchanged level")
        panel.applyWorkspaceSidebarLayer(stayOnTop: false)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(writes.count, firstWrites + 1)
        panel.applyWinMuxLayer(.overlay)
        panel.applyWinMuxLayer(.overlay)
        XCTAssertEqual(panel.level, WinMuxPanelLayer.overlay.level)
        XCTAssertEqual(writes.count, firstWrites + 2)
    }
}

@MainActor
private final class RecordingInputTarget: WorkspaceSidebarDragInputTarget {
    private(set) var points: [CGPoint] = []

    func updateMousePassthrough(at point: CGPoint) {
        points.append(point)
    }
}

/// Counted on the main thread, where AppKit sets a window's level.
private final class LevelWrites: @unchecked Sendable {
    var count = 0
}
