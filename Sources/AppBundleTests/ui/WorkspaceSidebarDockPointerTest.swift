import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceSidebarDockPointerTest: XCTestCase {
    func testPanelDeliversEveryPacketAndGeometryRechecksAStationaryPointer() async throws {
        let oldConfig = config
        let wasEnabled = TrayMenuModel.shared.isEnabled
        defer {
            for panel in WorkspaceSidebarPanel.visiblePanels { panel.resetHiddenSidebarState() }
            config = oldConfig
            TrayMenuModel.shared.isEnabled = wasEnabled
        }
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.autoHide = false
        TrayMenuModel.shared.isEnabled = true
        WorkspaceSidebarPanel.refreshAll()
        let panel = try XCTUnwrap(WorkspaceSidebarPanel.visiblePanels.first)
        // This test exercises pointer delivery at the visible endpoint, independent
        // of an auto-hide reveal left in progress by another panel fixture.
        panel.resetHiddenSidebarState()
        panel.refresh()
        let previousInputView = panel.dockPointerView
        let previousTimestamp = panel.lastHoverMonitorTimestamp
        let view = WorkspaceSidebarDockDisplayLinkView(frame: CGRect(x: 0, y: 0, width: 150, height: 700))
        view.updateTrackingAreas()
        XCTAssertTrue(view.trackingAreas.isEmpty, "Unattached views cannot choose the panel input policy yet")
        view.currentScreenPoint = { CGPoint(x: -100_000, y: -100_000) }
        view.configurePointer(blockers: [], contains: { CGRect(x: 4, y: 50, width: 80, height: 600).contains($0) })
        panel.hostingView.addSubview(view)
        view.updateTrackingAreas()
        XCTAssertFalse(view.trackingAreas.contains { $0.options.contains(.mouseMoved) },
            "Panels already deliver local/global movement; do not install a duplicate tracking stream")
        defer {
            view.removeFromSuperview()
            panel.dockPointerView = previousInputView
            panel.lastHoverMonitorTimestamp = previousTimestamp
        }
        let trace = DockPerformanceTrace()
        view.performanceTrace = trace
        // Keep all packets inside one expansion-throttle interval.
        panel.lastHoverMonitorTimestamp = ProcessInfo.processInfo.systemUptime
        for y in 100..<300 {
            WorkspaceSidebarPanel.noteHoverPointerActivityForVisiblePanels(
                timestamp: panel.lastHoverMonitorTimestamp, screenPoint: screenPoint(CGPoint(x: 32, y: y), in: view))
        }
        XCTAssertEqual(view.motion.target?.y, 299)
        XCTAssertEqual(trace.snapshot(panel: 1, maximumFPS: 120, scale: 2).input?.changedNativeTargets, 200)
        XCTAssertEqual(trace.summary.frames, 0, "Input delivery must not force layout or display frames")
        let point = screenPoint(CGPoint(x: 32, y: 299), in: view)
        view.currentScreenPoint = { point }
        view.configurePointer(blockers: [], contains: { _ in false })
        view.recheckPointer()
        XCTAssertNil(view.motion.target)
        view.configurePointer(blockers: [], contains: { _ in true })
        panel.updateDockIconFrames([CGRect(x: 4, y: 100, width: 80, height: 400)])
        // The existing 30 Hz trailing geometry recheck may already be queued.
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(view.motion.target?.y, 299, "Geometry preferences must recover without a gate change or mouse event")

        let oldSurface = panel.visibleSurfaceFrame
        let oldPassthrough = panel.ignoresMouseEvents
        defer {
            panel.visibleSurfaceFrame = oldSurface
            panel.ignoresMouseEvents = oldPassthrough
        }
        await drainRechecks()
        let mouse = panel.hostingView.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let insideSurface = CGRect(x: mouse.x - 50, y: mouse.y - 50, width: 100, height: 100)
        panel.ignoresMouseEvents = false
        view.receiveNativePointer(screenPoint(CGPoint(x: 32, y: 301), in: view))
        XCTAssertTrue(view.isRunning)
        panel.updateSurfaceFrame(insideSurface)
        XCTAssertFalse(panel.hasPendingHoverRecheck, "Lens resizing around an active pointer needs no duplicate panel check")
        panel.updateSurfaceFrame(insideSurface.offsetBy(dx: 1000, dy: 0))
        XCTAssertTrue(panel.hasPendingHoverRecheck, "A shrinking shelf that leaves the pointer outside must still recheck")
        await drainRechecks()
        view.stop()
        panel.ignoresMouseEvents = false
        panel.updateSurfaceFrame(insideSurface)
        XCTAssertTrue(panel.hasPendingHoverRecheck, "Stationary geometry changes must still recover hover")
        await drainRechecks()
    }

    private func fixture(origin: CGPoint = CGPoint(x: 350, y: 250)) -> (NSWindow, WorkspaceSidebarDockDisplayLinkView) {
        let window = NSWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 150, height: 700)),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = WorkspaceSidebarDockDisplayLinkView(frame: CGRect(x: 0, y: 0, width: 150, height: 700))
        view.currentScreenPoint = { CGPoint(x: -100_000, y: -100_000) }
        view.configurePointer(blockers: [], contains: { CGRect(x: 4, y: 100, width: 80, height: 500).contains($0) })
        window.contentView = view
        window.orderFrontRegardless()
        return (window, view)
    }

    private func screenPoint(_ local: CGPoint, in view: NSView) -> CGPoint {
        view.window!.convertPoint(toScreen: view.convert(local, to: nil))
    }

    private func drainRechecks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testNativeMovementRecoversWithoutAnySwiftUIHoverOrBoundaryCrossing() {
        let (window, view) = fixture()
        defer { window.close() }
        var publications = 0
        view.onFrame = { _ in publications += 1 }
        window.ignoresMouseEvents = true
        for y in 100..<500 {
            view.receiveNativePointer(screenPoint(CGPoint(x: 32, y: y), in: view), eventTimestamp: Double(y) / 120)
        }
        XCTAssertEqual(publications, 0, "High-rate native movement must only replace the target")
        XCTAssertEqual(view.motion.target?.y, 499)
        XCTAssertTrue(view.isRunning, "Click-through must not prevent native input from waking the driver")
        view.advance(to: 1)
        view.stop() // Simulate interrupted delivery while the pointer stays inside.
        XCTAssertFalse(view.isRunning)
        view.receiveNativePointer(screenPoint(CGPoint(x: 32, y: 499), in: view))
        XCTAssertTrue(view.isRunning, "Even an identical packet must restart an unfinished animation")
        for frame in 1...120 { view.advance(to: 1 + Double(frame) / 120) }
        XCTAssertTrue(view.motion.isSettled)
        XCTAssertFalse(view.isRunning, "Settled hover must not keep a display clock awake")
        view.receiveNativePointer(screenPoint(CGPoint(x: 35, y: 499), in: view))
        XCTAssertFalse(view.isRunning)
    }

    func testEverySuppressionGuardClearsAndRechecksAStationaryPointer() async {
        let (window, view) = fixture()
        defer { window.close() }
        let point = screenPoint(CGPoint(x: 32, y: 200), in: view)
        view.currentScreenPoint = { point }
        let inside: (CGPoint) -> Bool = { CGRect(x: 4, y: 100, width: 80, height: 500).contains($0) }
        for blocker: WorkspaceSidebarDockPointerBlockers in [
            .disabled, .expanded, .reduceMotion, .menu, .editing, .drop, .swipe, .drag, .scroll,
        ] {
            view.configurePointer(blockers: blocker, contains: inside)
            await drainRechecks()
            XCTAssertNil(view.motion.target, "Suppression bit \(blocker.rawValue)")
            XCTAssertFalse(view.isRunning)
            view.configurePointer(blockers: [], contains: inside)
            await drainRechecks()
            XCTAssertEqual(view.motion.target?.y, 200, "Clearing the guard must re-evaluate without mouse movement")
            XCTAssertTrue(view.isRunning)
        }
    }

    func testOutsideAndTransparentPaddingDoNotActivateButProtrudingIconsDo() {
        let (window, view) = fixture()
        defer { window.close() }
        let surface = CGRect(x: 4, y: 100, width: 64, height: 500)
        let protrudingIcon = CGRect(x: 15, y: 200, width: 100, height: 100)
        view.configurePointer(blockers: [], contains: { surface.contains($0) || protrudingIcon.contains($0) })
        for point in [CGPoint(x: 0, y: 200), CGPoint(x: 100, y: 150), CGPoint(x: 32, y: 650)] {
            view.receiveNativePointer(screenPoint(point, in: view))
            XCTAssertNil(view.motion.target)
            XCTAssertFalse(view.isRunning)
        }
        view.receiveNativePointer(screenPoint(CGPoint(x: 100, y: 250), in: view))
        view.advance(to: 1)
        XCTAssertNotNil(view.motion.target)
        view.receiveNativePointer(screenPoint(CGPoint(x: 140, y: 250), in: view))
        XCTAssertNil(view.motion.target)
        XCTAssertNotNil(view.motion.frame.pointer, "Ordinary exit should shrink at the last valid position")
    }

    func testCoordinatesStayInTheirOwnWindowAndHiddenDetachedViewsStop() {
        let (first, a) = fixture(origin: CGPoint(x: 100, y: 200))
        let (second, b) = fixture(origin: CGPoint(x: 600, y: 250))
        defer { first.close(); second.close() }
        let point = screenPoint(CGPoint(x: 32, y: 200), in: a)
        a.receiveNativePointer(point)
        b.receiveNativePointer(point)
        XCTAssertEqual(a.motion.target, CGPoint(x: 32, y: 200))
        XCTAssertNil(b.motion.target)
        first.orderOut(nil)
        a.receiveNativePointer(point, source: .recheck)
        XCTAssertNil(a.motion.target)
        XCTAssertFalse(a.isRunning)
        first.contentView = nil
        XCTAssertFalse(a.isPointerAttached)
        XCTAssertNil(a.motion.target)
        second.contentView = a
        a.receiveNativePointer(screenPoint(CGPoint(x: 32, y: 300), in: a))
        XCTAssertEqual(a.motion.target?.y, 300)
        XCTAssertTrue(a.isRunning)
    }

    func testTemporaryResetRecoversAndDetachedDriverIsReleased() {
        weak var released: WorkspaceSidebarDockDisplayLinkView?
        autoreleasepool {
            let (window, view) = fixture()
            released = view
            let point = screenPoint(CGPoint(x: 32, y: 200), in: view)
            view.receiveNativePointer(point)
            view.advance(to: 1)
            view.reset()
            XCTAssertFalse(view.isRunning)
            XCTAssertNil(view.motion.target)
            view.receiveNativePointer(point)
            XCTAssertTrue(view.isRunning, "A paused driver must resume at the same stationary pointer")
            view.reset()
            window.contentView = nil
            window.close()
        }
        XCTAssertNil(released, "Detaching must invalidate the paused display link and release its target")
    }

    func testTeardownDoesNotPublishAndTrackingSurvivesRepeatedLayout() {
        let (window, view) = fixture()
        defer { window.close() }
        var publications = 0
        view.onFrame = { _ in publications += 1 }
        for _ in 0..<100 { view.updateTrackingAreas() }
        XCTAssertEqual(view.trackingAreas.count, 1)
        XCTAssertTrue(view.trackingAreas[0].options.contains(.activeAlways))
        view.receiveNativePointer(screenPoint(CGPoint(x: 32, y: 200), in: view))
        view.advance(to: 1)
        let before = publications
        let trace = DockPerformanceTrace()
        view.performanceTrace = trace
        window.contentView = nil
        XCTAssertEqual(publications, before, "AppKit detach must not mutate SwiftUI state during reconciliation")
        XCTAssertFalse(view.isRunning)
        XCTAssertNil(view.motion.target)
        let events = trace.snapshot(panel: 1, maximumFPS: 60, scale: 2).input?.transitions ?? []
        XCTAssertTrue(events.contains { $0.kind == .detached })
        XCTAssertFalse(events.contains { $0.kind == .attached }, "Removing a view is not an attachment")
    }
}
