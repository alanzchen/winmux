@testable import AppBundle
import AppKit
import Common
import XCTest

/// AX reads can take longer than the settle interval before the first move/size write.
/// Advance a monotonic test clock during that read, without blocking or using live AX.
private final class SlowInitialRead: AxFrameAccess {
    let app: SimulatedAppWindow
    let initialDelay: TimeInterval
    var clock: TimeInterval = 1000
    private var firstRead = true
    init(_ app: SimulatedAppWindow, initialDelay: TimeInterval) {
        self.app = app
        self.initialDelay = initialDelay
    }
    var axSize: CGSize? {
        if firstRead { firstRead = false; clock += initialDelay }
        return app.axSize
    }
    var axTopLeft: CGPoint? { app.axTopLeft }
    func setAxTopLeft(_ point: CGPoint) { app.setAxTopLeft(point) }
    func setAxSize(_ size: CGSize) -> Bool { app.setAxSize(size) }
}

final class AstraFrameFitTimingReviewTest: XCTestCase {
    func testSlowPreWriteReadDoesNotConsumeThePostWriteSettleInterval() throws {
        try verifyCrossDisplayMove(initialDelay: 0.1)
    }

    func testInstantReadControlGetsTheSameOrdinaryWindowItsCell() throws {
        try verifyCrossDisplayMove(initialDelay: 0)
    }

    private func verifyCrossDisplayMove(initialDelay: TimeInterval) throws {
        let source = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)
        let destination = Rect(topLeftX: 800, topLeftY: 0, width: 1600, height: 1200)
        let cell = Rect(topLeftX: 808, topLeftY: 33, width: 1584, height: 1159)
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 500, height: 300))
        app.displays = [source, destination]
        app.screenLagsMoves = true
        let access = SlowInitialRead(app, initialDelay: initialDelay)
        var fit = WindowFrameFit()
        let target = FrameFitTarget(monitor: 2, epoch: 0)
        try setFrame(access, cell.topLeftCorner, cell.size, fit: &fit, within: destination,
            target: target, now: access.clock, RunLoopJob())
        let movedAt = access.clock
        let firstDeadline = try XCTUnwrap(fit.followUpAt)
        XCTAssertGreaterThanOrEqual(firstDeadline, movedAt + WindowFrameFit.settleInterval - 0.001,
            "The 100ms initial AX read happened before the move; the app has had no time to adopt its new display")

        // As the production scheduler does: a past deadline runs 1ms later. The app adopts
        // its new screen 20ms after the move, comfortably inside the intended 60ms wait.
        for _ in 0..<10 {
            guard let deadline = fit.followUpAt else { break }
            access.clock = max(access.clock, deadline) + 0.001
            if access.clock >= movedAt + 0.02 { app.catchUp() }
            try setFrame(access, cell.topLeftCorner, cell.size, fit: &fit, within: destination,
                target: target, continuing: true, now: access.clock, RunLoopJob())
        }
        XCTAssertEqual(app.frame, cell, "Do not learn the old display's clamp from two writes only 1ms apart")
        XCTAssertNil(fit.heldSize, "An ordinary resizable window has no constraint here")
    }
}

@MainActor
final class AstraFrameFitContinuationReviewTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setMonitorsForTests([FitTestMonitor()])
        startFrameFitTestClock()
    }
    override func tearDown() async throws {
        stopFrameFitTestClock()
        currentlyManipulatedWithMouseWindowId = nil
        setCurrentMouseManipulationKind(.none)
        setMonitorsForTests(nil)
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private func pendingWindow() async throws -> (Workspace, FrameFitTestWindow, SimulatedAppWindow) {
        let workspace = Workspace.get(byName: "astra-fit")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 640, height: 360), aspect: 16.0 / 9.0)
        let window = FrameFitTestWindow(id: 1001, parent: workspace.rootTilingContainer, native: app)
        try await workspace.layoutWorkspace()
        XCTAssertEqual(app.sizeWrites, 1)
        return (workspace, window, app)
    }

    func testOldEpochContinuationCannotWriteAfterScreenChange() async throws {
        let (_, _, app) = try await pendingWindow()
        let before = (app.sizeWrites, app.positionWrites)
        MonitorConfigurationObserver.shared.noteDisplayChangeForTests()
        advanceFrameFitTestClock(by: 1)
        XCTAssertEqual(app.sizeWrites, before.0)
        XCTAssertEqual(app.positionWrites, before.1)
    }

    func testHiddenWorkspaceContinuationDoesNotWrite() async throws {
        let (workspace, _, app) = try await pendingWindow()
        let before = (app.sizeWrites, app.positionWrites)
        XCTAssertTrue(Workspace.get(byName: "astra-other").focusWorkspace())
        XCTAssertFalse(workspace.isVisible)
        advanceFrameFitTestClock(by: 1)
        XCTAssertEqual(app.sizeWrites, before.0)
        XCTAssertEqual(app.positionWrites, before.1)
    }

    func testLeavingTilingCancelsContinuationAndRearmsOnce() async throws {
        let (workspace, window, app) = try await pendingWindow()
        let arming = window.frameFitArming
        window.bind(to: workspace, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertEqual(window.frameFitArming, arming + 1)
        window.bind(to: workspace, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertEqual(window.frameFitArming, arming + 1)
        let before = (app.sizeWrites, app.positionWrites)
        advanceFrameFitTestClock(by: 1)
        XCTAssertEqual(app.sizeWrites, before.0)
        XCTAssertEqual(app.positionWrites, before.1)
    }

    func testClosedWindowContinuationCannotTargetAnUnlaidOutReplacement() async throws {
        let (workspace, window, oldApp) = try await pendingWindow()
        window.removeClosedWindowFromTree()
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 500, height: 400))
        _ = FrameFitTestWindow(id: window.windowId, parent: workspace.rootTilingContainer, native: app)
        let before = (oldApp.sizeWrites, oldApp.positionWrites)
        advanceFrameFitTestClock(by: 1)
        XCTAssertEqual(oldApp.sizeWrites, before.0)
        XCTAssertEqual(oldApp.positionWrites, before.1)
        XCTAssertEqual(app.sizeWrites, 0)
        XCTAssertEqual(app.positionWrites, 0)
    }

    func testRepeatedScreenSignalsInvalidateOldContinuationWithoutWriting() async throws {
        let (_, _, app) = try await pendingWindow()
        for _ in 0..<100 { MonitorConfigurationObserver.shared.noteDisplayChangeForTests() }
        advanceFrameFitTestClock(by: 1)
        XCTAssertEqual(app.sizeWrites, 1)
    }
}
