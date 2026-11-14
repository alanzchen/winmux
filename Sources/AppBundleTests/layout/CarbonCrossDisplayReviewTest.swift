@testable import AppBundle
import AppKit
import Common
import XCTest

/// Replicates `MacWindow` + `MacApp.setFrameJobs` + `AxAppWorker` (`MacWindow.swift:168-178`,
/// `MacApp.swift:482-504`, `runLoop.swift:59-62`): one `setFrameJobs[windowId]` slot per window where each
/// submission cancels any un-started job in that slot, and cancelled jobs return before running `body(job)`.
private final class QueuedAxWorkerWindow: Window, @unchecked Sendable {
    let native: SimulatedAppWindow
    private var fit = WindowFrameFit()
    private var activeSetFrameJob: RunLoopJob?
    private var workerQueue: [(job: RunLoopJob, body: @MainActor (RunLoopJob) -> Void)] = []
    let cornerParking = CornerParkingState()

    @MainActor init(id: UInt32, parent: NonLeafTreeNodeObject, native: SimulatedAppWindow) {
        self.native = native
        super.init(id: id, TestApp.shared, lastFloatingSize: native.frame.size, parent: parent, adaptiveWeight: 1,
            index: INDEX_BIND_LAST)
        recordAuthoritativeActualRect(native.frame)
    }

    @MainActor override var title: String { get async { "Queued \(windowId)" } }
    override var isHiddenInCorner: Bool { cornerParking.isHiddenInCorner }

    @MainActor override func getAxRect() async throws -> Rect? {
        let token = nativeStateObservationToken()
        recordObservedActualRect(native.frame, token: token)
        return native.frame
    }

    @MainActor override func getAxSize() async throws -> CGSize? { native.frame.size }

    override func writeAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        enqueueSetFrame(topLeft, size, within: nil, target: nil, continuing: false, done: nil)
    }

    @MainActor override func writeLayoutFrame(_ cell: Rect, within bounds: Rect, target: FrameFitTarget, continuing: Bool) {
        let token = nativeStateObservationToken()
        enqueueSetFrame(cell.topLeftCorner, cell.size, within: bounds, target: target, continuing: continuing) {
            [weak self] frame, followUpAt in
            self?.didWriteLayoutFrame(frame, in: cell, target: target, token: token, followUpAt: followUpAt)
        }
    }

    private func enqueueSetFrame(
        _ topLeft: CGPoint?,
        _ size: CGSize?,
        within bounds: Rect?,
        target: FrameFitTarget?,
        continuing: Bool,
        done: (@MainActor (Rect?, TimeInterval?) -> Void)?
    ) {
        // Exact `MacApp.setAxFrame` (`MacApp.swift:493-503`):
        activeSetFrameJob?.cancel()
        let job = RunLoopJob()
        activeSetFrameJob = job
        workerQueue.append((job: job, body: { [weak self] job in
            guard let self else { return }
            // Exact `AxAppWorker.submit(autoCheckCancelled: true)` (`runLoop.swift:60`):
            if job.isCancelled { return }
            let frame = (try? setFrame(
                self.native, topLeft, size, fit: &self.fit, within: bounds, target: target,
                continuing: continuing, now: FrameFitFollowUps.shared.now(), job
            )) ?? nil
            let followUpAt = self.fit.followUpAt
            if let done, frame != nil || followUpAt != nil {
                done(frame, followUpAt)
            }
        }))
    }

    @MainActor func drainWorker() {
        while !workerQueue.isEmpty {
            let next = workerQueue.removeFirst()
            next.body(next.job)
        }
    }
}

extension QueuedAxWorkerWindow: WorkspaceWindowVisibility {
    func hideInCorner(_ corner: OptimalHideCorner, reassert: Bool, ifStillValid: () -> Bool) async throws {
        try await parkInCorner(corner, cornerParking, reassert: reassert, onePixelOffset: true, ifStillValid: ifStillValid)
    }

    func unhideFromCorner() { restoreFromCorner(cornerParking) }
}

/// Window whose `getAxRect()` / `getAxSize()` hooks let tests simulate an AX read returning `nil` once or a
/// pending follow-up firing while `parkInCorner` is suspended awaiting AX.
private final class HookedParkTestWindow: Window {
    let native: SimulatedAppWindow
    private var fit = WindowFrameFit()
    let cornerParking = CornerParkingState()
    var failNextGetAxRect = false
    var onGetAxSize: (() -> Void)?

    @MainActor init(id: UInt32, parent: NonLeafTreeNodeObject, native: SimulatedAppWindow) {
        self.native = native
        super.init(id: id, TestApp.shared, lastFloatingSize: native.frame.size, parent: parent, adaptiveWeight: 1,
            index: INDEX_BIND_LAST)
        recordAuthoritativeActualRect(native.frame)
    }

    @MainActor override var title: String { get async { "Hooked \(windowId)" } }
    override var isHiddenInCorner: Bool { cornerParking.isHiddenInCorner }

    @MainActor override func getAxRect() async throws -> Rect? {
        if failNextGetAxRect {
            failNextGetAxRect = false
            return nil
        }
        let token = nativeStateObservationToken()
        recordObservedActualRect(native.frame, token: token)
        return native.frame
    }

    @MainActor override func getAxSize() async throws -> CGSize? {
        let size = native.frame.size
        onGetAxSize?()
        return size
    }

    override func writeAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        _ = try? setFrame(native, topLeft, size, fit: &fit, RunLoopJob())
    }

    @MainActor override func writeLayoutFrame(_ cell: Rect, within bounds: Rect, target: FrameFitTarget, continuing: Bool) {
        let token = nativeStateObservationToken()
        let frame = (try? setFrame(native, cell.topLeftCorner, cell.size, fit: &fit, within: bounds, target: target,
            continuing: continuing, now: FrameFitFollowUps.shared.now(), RunLoopJob())) ?? nil
        didWriteLayoutFrame(frame, in: cell, target: target, token: token, followUpAt: fit.followUpAt)
    }
}

extension HookedParkTestWindow: WorkspaceWindowVisibility {
    func hideInCorner(_ corner: OptimalHideCorner, reassert: Bool, ifStillValid: () -> Bool) async throws {
        try await parkInCorner(corner, cornerParking, reassert: reassert, onePixelOffset: true, ifStillValid: ifStillValid)
    }

    func unhideFromCorner() { restoreFromCorner(cornerParking) }
}

/// Independent Carbon review reproduction and adversarial verification tests against commit 3341f36f.
@MainActor
final class CarbonCrossDisplayReviewTest: XCTestCase {
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

    private func twoDisplaysBottomLeftHideOnPrimary() -> (Monitor, Monitor) {
        // Primary 2560x1440 at (0, 0) with Built-in 1512x982 bottom-aligned on its right at (2560, 458):
        // brc1 of primary (2562, 1296) lies inside Built-in, so optimalHideCorner(for: primary) == .bottomLeftCorner.
        let primary = SavedWorkspaceTestMonitor(
            id: 1, name: "External", x: 0, y: 0, width: 2560, height: 1440, isMain: true, uuid: "EXTERNAL"
        )
        let builtIn = SavedWorkspaceTestMonitor(
            id: 2, name: "Built-in", x: 2560, y: 458, width: 1512, height: 982, uuid: "BUILTIN", isBuiltin: true
        )
        setMonitorsForTests([primary, builtIn])
        MonitorConfigurationObserver.shared.noteDisplayChangeForTests()
        Workspace.reconcileWorkspaceState()
        return (primary, builtIn)
    }

    // MARK: - Defect 1: Queued non-layout `setAxFrame` cancelled & overwritten by pending `continueLayoutFrame`

    /// Defect 1a: When a non-layout move-only write (`setAxFrame(parkedOrigin, nil)`, e.g.
    /// `WindowMouseInteractionOpacityController.moveWindowsOutOfView` at `WindowMouseInteractionOpacity.swift:83`)
    /// is queued on the app's AX worker while a 60 ms follow-up from an earlier `setAxLayoutFrame` is pending,
    /// `continueLayoutFrame` (`Window.swift:194-202`) fires on `@MainActor`, cancels the queued `setAxFrame` job in
    /// `MacApp.setFrameJobs` (`MacApp.swift:493`) before `fit.suspend()` ever runs, and moves/resizes the window
    /// back into its visible layout cell.
    func testDefect1a_QueuedMoveOnlySetAxFrameIsNotCancelledAndOverwrittenByPendingFollowUp() async throws {
        let (primary, builtIn) = twoDisplaysBottomLeftHideOnPrimary()
        let workspace = primary.activeWorkspace
        XCTAssertTrue(workspace.focusWorkspace())

        let app = SimulatedAppWindow(Rect(topLeftX: 2600, topLeftY: 500, width: 1200, height: 800))
        app.displays = [primary.rect, builtIn.rect]
        app.screenLagsMoves = true
        let window = QueuedAxWorkerWindow(id: 101, parent: workspace.rootTilingContainer, native: app)

        // Layout 1 on primary: clamped on Attempt 1 because screenLagsMoves == true; schedules follow-up at +60 ms.
        try await workspace.layoutWorkspace()
        window.drainWorker()
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertNotEqual(app.frame, cell, "Clamped on first cross-display attempt, follow-up armed")

        // Before +60 ms: sibling drag hides `window` off-screen via `setAxFrame(hiddenOrigin, nil)`.
        // That job sits in `setFrameJobs[windowId]` while the AX worker thread is busy with the dragged sibling.
        app.catchUp()
        let hiddenOrigin = CGPoint(x: 2559, y: 1439)
        window.setAxFrame(hiddenOrigin, nil)

        // At +60 ms (before AX worker drains `setAxFrame`), the scheduled follow-up fires on `@MainActor`,
        // then the AX worker drains.
        advanceFrameFitTestClock(by: 0.07)
        window.drainWorker()

        XCTAssertEqual(
            app.frame.topLeftCorner,
            hiddenOrigin,
            "A follow-up from an older layout write must not cancel a newer move-only setAxFrame and pull an off-screen window back into its cell"
        )
    }

    /// Defect 1b: Same race for an explicit-size non-layout `setAxFrame(origin, size)` (e.g.
    /// `WindowTabStripFocusActions.swift:25`, `WindowMouseInteractionOpacity.swift:49,75`, `WindowDragTabStackApply.swift:56`).
    func testDefect1b_QueuedExplicitSizeSetAxFrameIsNotCancelledAndOverwrittenByPendingFollowUp() async throws {
        let (primary, builtIn) = twoDisplaysBottomLeftHideOnPrimary()
        let workspace = primary.activeWorkspace
        XCTAssertTrue(workspace.focusWorkspace())

        let app = SimulatedAppWindow(Rect(topLeftX: 2600, topLeftY: 500, width: 1200, height: 800))
        app.displays = [primary.rect, builtIn.rect]
        app.screenLagsMoves = true
        let window = QueuedAxWorkerWindow(id: 102, parent: workspace.rootTilingContainer, native: app)

        try await workspace.layoutWorkspace()
        window.drainWorker()
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertNotEqual(app.frame, cell)

        app.catchUp()
        let explicitRect = Rect(topLeftX: 120, topLeftY: 140, width: 900, height: 700)
        window.setAxFrame(explicitRect.topLeftCorner, explicitRect.size)

        advanceFrameFitTestClock(by: 0.07)
        window.drainWorker()

        XCTAssertEqual(
            app.frame,
            explicitRect,
            "A follow-up from an older layout write must not cancel a newer explicit setAxFrame and overwrite it with the layout cell"
        )
    }

    // MARK: - Defect 2: Intra-workspace hiding (`hideAllWindowsExcept` / `hideTabbedWindows`) leaves follow-up armed

    /// Defect 2a: Window 1 is laid out on a visible workspace and arms a 60 ms follow-up. Sibling Window 2 enters
    /// WinMux fullscreen (`hideAllWindowsExcept`, `layoutRecursive.swift:48, 377-379`), setting
    /// `w1.lastAppliedLayoutPhysicalRect = nil` and calling `parkInCorner`. If `w1.getAxRect()` transiently returns
    /// `nil` once (`CornerParking.swift:130`), `w1` is no longer in `cell`, yet `frameFitLayout` and `FrameFitFollowUps`
    /// remain armed; when the 60 ms timer fires, `continueLayoutFrame` writes the covered background window back into
    /// its visible cell on top of the workspace.
    func testDefect2a_CoveredWindowAfterTransientParkReadFailureIsNotWrittenBackIntoCellByFollowUp() async throws {
        let (primary, builtIn) = twoDisplaysBottomLeftHideOnPrimary()
        let workspace = primary.activeWorkspace
        XCTAssertTrue(workspace.focusWorkspace())

        let app1 = SimulatedAppWindow(Rect(topLeftX: 2600, topLeftY: 500, width: 1200, height: 800))
        app1.displays = [primary.rect, builtIn.rect]
        app1.screenLagsMoves = true
        let app2 = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 800, height: 600))
        app2.displays = [primary.rect, builtIn.rect]

        let w1 = HookedParkTestWindow(id: 201, parent: workspace.rootTilingContainer, native: app1)
        let w2 = HookedParkTestWindow(id: 202, parent: workspace.rootTilingContainer, native: app2)

        try await workspace.layoutWorkspace()
        let oldW1Cell = try XCTUnwrap(w1.lastAppliedLayoutPhysicalRect)
        XCTAssertNotEqual(app1.frame, oldW1Cell, "w1 clamped on Attempt 1; follow-up armed")

        // w2 enters WinMux fullscreen while w1's park read transiently returns nil once.
        app1.catchUp()
        w1.failNextGetAxRect = true
        w2.isFullscreen = true
        XCTAssertTrue(w2.focusWindow())
        try await workspace.layoutWorkspace()
        XCTAssertNil(w1.lastAppliedLayoutPhysicalRect, "Layout removed w1 from its tiled cell because w2 is fullscreen")

        let writesBeforeFollowUp = app1.sizeWrites
        advanceFrameFitTestClock(by: 0.07)

        XCTAssertEqual(
            app1.sizeWrites,
            writesBeforeFollowUp,
            "Follow-up must not resize/place a window that layout has already hidden behind a fullscreen sibling"
        )
        XCTAssertNotEqual(
            app1.frame,
            oldW1Cell,
            "Covered window w1 must not be written back into its former tiled cell while w2 is fullscreen"
        )
    }

    /// Defect 2b: Same intra-workspace hide on a `.bottomLeftCorner` display (`optimalHideCorner == .bottomLeftCorner`)
    /// with NO failed AX reads: while `parkInCorner` is suspended at `getAxSize()` (`CornerParking.swift:151`) having
    /// read `w1`'s pre-follow-up clamped width (`1512`), the pending 60 ms follow-up fires on `@MainActor`, expanding
    /// `w1` to `2560`/`2544` wide, and `parkInCorner` then parks `w1` at `x = 1 - 1512 = -1511`, leaving over 1,000 px
    /// of the hidden window horizontally inside the monitor's X span!
    func testDefect2b_FollowUpDuringBottomLeftParkSuspensionDoesNotLeaveHiddenTabOversizedAtStaleOffset() async throws {
        config.windowTabs.enabled = true
        let (primary, builtIn) = twoDisplaysBottomLeftHideOnPrimary()
        XCTAssertEqual(optimalHideCorner(for: primary), .bottomLeftCorner)

        let workspace = primary.activeWorkspace
        XCTAssertTrue(workspace.focusWorkspace())
        let tabGroup = TilingContainer(parent: workspace.rootTilingContainer, adaptiveWeight: 1, .h, .tabGroup, index: INDEX_BIND_LAST)

        let app1 = SimulatedAppWindow(Rect(topLeftX: 2600, topLeftY: 500, width: 1200, height: 800))
        app1.displays = [primary.rect, builtIn.rect]
        app1.screenLagsMoves = true
        let app2 = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 900, height: 700))
        app2.displays = [primary.rect, builtIn.rect]

        let w1 = HookedParkTestWindow(id: 203, parent: tabGroup, native: app1)
        let w2 = HookedParkTestWindow(id: 204, parent: tabGroup, native: app2)
        XCTAssertTrue(w1.focusWindow())

        // Layout 1: w1 is active tab on primary; clamped to Built-in's width (1512), follow-up scheduled at +60 ms.
        try await workspace.layoutWorkspace()
        let tabCell = try XCTUnwrap(w1.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(app1.frame.width, builtIn.rect.width)
        XCTAssertLessThan(app1.frame.width, tabCell.width)

        // Switch active tab to w2; during w1's parkInCorner(.bottomLeftCorner) getAxSize() suspension, +60 ms elapses.
        app1.catchUp()
        w1.onGetAxSize = { [weak w1] in
            w1?.onGetAxSize = nil
            advanceFrameFitTestClock(by: 0.07)
        }
        XCTAssertTrue(w2.focusWindow())
        try await workspace.layoutWorkspace()

        // A bottom-left park places `maxX` at `primary.visibleRect.minX + 1` (1 px on screen).
        XCTAssertLessThanOrEqual(
            app1.frame.maxX,
            primary.visibleRect.minX + 2,
            "Inactive parked tab must have at most ~1 px inside primary's X range, not \(app1.frame.maxX) px protruding across the display"
        )
    }

    // MARK: - Adversarial Bound & Lifecycle Checks (Expected PASS on 3341f36f)

    /// Verifies that after `.learned` + 1 recovery write (or `.settled` + 1 recovery write), `hasSettled` stays `true`
    /// and `recoveryWriteSpent` stays `true`, so no 5th size write can ever occur in the same context.
    func testAdversarialRecoveryWriteNeverRearmsFurtherWritesInSameContext() throws {
        let display = Rect(topLeftX: 0, topLeftY: 0, width: 1440, height: 900)
        let cell = Rect(topLeftX: 0, topLeftY: 25, width: 1200, height: 800)
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 640, height: 480), aspect: 4.0 / 3.0)
        var fit = WindowFrameFit()
        var now: TimeInterval = 1000

        // 2 writes to learn 4:3 (1067x800).
        for _ in 0 ..< 4 {
            now += 0.1
            try layFrame(app, cell: cell, bounds: display, display: display, monitor: 1, epoch: 0, now: now, fit: &fit)
        }
        XCTAssertEqual(app.sizeWrites, 2)
        XCTAssertNotNil(learnedSize(fit))

        // App drops constraint and resizes itself repeatedly: only 1 recovery write is ever allowed in this context.
        for step in 1 ... 10 {
            app.aspect = 16.0 / 9.0
            app.resizeOnItsOwn(to: CGSize(width: 500 + CGFloat(step * 10), height: 400))
            now += 0.1
            try layFrame(app, cell: cell, bounds: display, display: display, monitor: 1, epoch: 0, now: now, fit: &fit)
            if let due = followUpTime(fit) {
                now = max(now, due)
                try layFrame(app, cell: cell, bounds: display, display: display, monitor: 1, epoch: 0, now: now,
                    continuing: true, fit: &fit)
            }
        }
        XCTAssertEqual(app.sizeWrites, 3, "2 acquisition writes + 1 recovery write = 3 total, never re-armed")
        XCTAssertLessThanOrEqual(app.sizeWrites, WindowFrameFit.acquisitionWrites + 1)
    }

    /// Verifies that closing (`unbindFromParent`) a window while a follow-up is scheduled does not crash or write.
    func testWindowUnboundBeforeFollowUpDueDoesNotWriteOrCrash() async throws {
        let (primary, builtIn) = twoDisplaysBottomLeftHideOnPrimary()
        let workspace = primary.activeWorkspace
        XCTAssertTrue(workspace.focusWorkspace())

        let app = SimulatedAppWindow(Rect(topLeftX: 2600, topLeftY: 500, width: 1200, height: 800))
        app.displays = [primary.rect, builtIn.rect]
        app.screenLagsMoves = true
        let window = FrameFitTestWindow(id: 301, parent: workspace.rootTilingContainer, native: app)

        try await workspace.layoutWorkspace()
        let writesAfterFirstLayout = app.sizeWrites
        window.unbindFromParent()
        app.catchUp()
        advanceFrameFitTestClock(by: 0.2)

        XCTAssertEqual(app.sizeWrites, writesAfterFirstLayout, "Closed/unbound window must not receive follow-up writes")
    }
}
