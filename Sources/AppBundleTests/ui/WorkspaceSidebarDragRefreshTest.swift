import AppKit
@testable import AppBundle
import XCTest

/// Every global drag event used to refresh every sidebar panel: sync its model, set its level,
/// order it front and recheck hover. Another app's drag changes none of that.
@MainActor
final class WorkspaceSidebarDragRefreshTest: XCTestCase {
    func testAWindowWinMuxHandlesRefreshesAtEveryEventAndAnotherAppsDragOnce() {
        var gate = WorkspaceSidebarDragRefreshGate()
        // Selecting text in another app: the first event only.
        XCTAssertEqual((0 ..< 4).map { _ in gate.shouldRefresh(manipulatesWindow: false) }, [true, false, false, false])
        // WinMux takes the window: every event, then the first after it.
        XCTAssertEqual([true, true, false, false].map { gate.shouldRefresh(manipulatesWindow: $0) }, [true, true, true, false])
        gate.pressEnded()
        XCTAssertTrue(gate.shouldRefresh(manipulatesWindow: false), "The next press refreshes as its drag starts")
        XCTAssertFalse(gate.shouldRefresh(manipulatesWindow: false))
    }

    func testAnotherAppsDragRefreshesThePanelsOncePerPress() {
        XCTAssertEqual(getCurrentMouseManipulationKind(), .none)
        notePointerPressEndedForDragRefresh()
        defer { notePointerPressEndedForDragRefresh() }
        let before = WorkspaceSidebarPanel.refreshAllPasses
        for _ in 0 ..< 120 { refreshPendingWindowDragIntentFromGlobalMouseDrag() }
        XCTAssertEqual(WorkspaceSidebarPanel.refreshAllPasses - before, 1)
        notePointerPressEndedForDragRefresh()
        for _ in 0 ..< 120 { refreshPendingWindowDragIntentFromGlobalMouseDrag() }
        XCTAssertEqual(WorkspaceSidebarPanel.refreshAllPasses - before, 2)
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

/// Counted on the main thread, where AppKit sets a window's level.
private final class LevelWrites: @unchecked Sendable {
    var count = 0
}
