@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class WorkspacePresentationTest: XCTestCase {
    private var previousApp: (any AbstractApp)?
    private var wasEnabled = false

    override func setUp() async throws {
        previousApp = appForTests
        wasEnabled = TrayMenuModel.shared.isEnabled
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        TrayMenuModel.shared.isEnabled = true
    }

    override func tearDown() async throws {
        appForTests = previousApp
        TrayMenuModel.shared.isEnabled = wasEnabled
        config = defaultConfig
    }

    func testIncomingFramesCompleteBeforeTheOutgoingWindowIsHidden() async throws {
        let trace = PresentationTrace()
        let oldApp = PresentationApp(pid: 101, trace: trace)
        let incomingApp = PresentationApp(pid: 102, trace: trace, delaysFrames: true)
        defer { incomingApp.completeFrames() }
        let old = PresentationWindow(id: 1, workspace: focus.workspace, app: oldApp)
        let target = Workspace.get(byName: "incoming")
        _ = PresentationWindow(id: 2, workspace: target, app: incomingApp, hidden: true)
        _ = PresentationWindow(id: 3, workspace: target, app: incomingApp, hidden: true)
        XCTAssertTrue(target.focusWorkspace())
        let reachedTransition = expectation(description: "Incoming wait or premature outgoing hide")
        var signaled = false
        trace.onEvent = { event in
            if !signaled && (event == "wait:102" || event == "hide:1") {
                signaled = true
                reachedTransition.fulfill()
            }
        }

        let layout = Task { try await layoutWorkspaces() }
        await fulfillment(of: [reachedTransition], timeout: 2)
        XCTAssertFalse(old.isHiddenInCorner, "Keep the current window onscreen while the other app is still moving")
        XCTAssertFalse(trace.events.contains("frame:2"))
        incomingApp.completeFrames()
        try await layout.value

        XCTAssertEqual(incomingApp.waitCount, 1, "Two split windows in one app share a single queue barrier")
        let hide = try XCTUnwrap(trace.events.firstIndex(of: "hide:1"))
        for event in ["frame:2", "frame:3"] {
            XCTAssertLessThan(try XCTUnwrap(trace.events.firstIndex(of: event)), hide)
        }
        try await layoutWorkspaces()
        XCTAssertEqual(incomingApp.waitCount, 1, "Ordinary refreshes do not add a frame barrier once the old window is parked")
    }

    func testAnOverlappingRefreshStillWaitsForTheIncomingFrames() async throws {
        let trace = PresentationTrace()
        let oldApp = PresentationApp(pid: 101, trace: trace)
        let incomingApp = PresentationApp(pid: 102, trace: trace, delaysFrames: true)
        defer { incomingApp.completeFrames() }
        let old = PresentationWindow(id: 1, workspace: focus.workspace, app: oldApp)
        let target = Workspace.get(byName: "incoming")
        let incoming = PresentationWindow(id: 2, workspace: target, app: incomingApp, hidden: true)
        XCTAssertTrue(target.focusWorkspace())
        let firstWaiting = expectation(description: "First incoming frame queue")
        let secondWaiting = expectation(description: "Overlapping incoming frame queue")
        var waitCount = 0
        incomingApp.onWait = {
            waitCount += 1
            (waitCount == 1 ? firstWaiting : secondWaiting).fulfill()
        }
        let first = Task { try await layoutWorkspaces() }
        await fulfillment(of: [firstWaiting], timeout: 2)
        XCTAssertFalse(incoming.isHiddenInCorner, "Logical unhide happens before the app has applied its frame")
        let second = Task { try await layoutWorkspaces() }
        await fulfillment(of: [secondWaiting], timeout: 2)
        XCTAssertFalse(old.isHiddenInCorner)
        incomingApp.completeFrames()
        try await first.value
        try await second.value
        XCTAssertTrue(old.isHiddenInCorner)
        XCTAssertEqual(trace.events.filter { $0 == "hide:1" }.count, 1, "Only the latest layout may hide the outgoing window")
    }

    func testASplitAcrossAppsWaitsForEveryIncomingApp() async throws {
        let trace = PresentationTrace()
        let oldApp = PresentationApp(pid: 101, trace: trace)
        let leftApp = PresentationApp(pid: 102, trace: trace, delaysFrames: true)
        let rightApp = PresentationApp(pid: 103, trace: trace, delaysFrames: true)
        defer { leftApp.completeFrames(); rightApp.completeFrames() }
        let old = PresentationWindow(id: 1, workspace: focus.workspace, app: oldApp)
        let target = Workspace.get(byName: "split")
        _ = PresentationWindow(id: 2, workspace: target, app: leftApp, hidden: true)
        _ = PresentationWindow(id: 3, workspace: target, app: rightApp, hidden: true)
        XCTAssertTrue(target.focusWorkspace())
        let waiting = expectation(description: "Both incoming app queues")
        waiting.expectedFulfillmentCount = 2
        leftApp.onWait = { waiting.fulfill() }
        rightApp.onWait = { waiting.fulfill() }
        let layout = Task { try await layoutWorkspaces() }
        await fulfillment(of: [waiting], timeout: 2)

        leftApp.completeFrames()
        XCTAssertFalse(old.isHiddenInCorner)
        XCTAssertFalse(trace.events.contains("frame:3"))
        rightApp.completeFrames()
        try await layout.value
        let hide = try XCTUnwrap(trace.events.firstIndex(of: "hide:1"))
        for event in ["frame:2", "frame:3"] {
            XCTAssertLessThan(try XCTUnwrap(trace.events.firstIndex(of: event)), hide)
        }
    }

    func testCancellingARevealKeepsTheOutgoingWindowVisible() async throws {
        let trace = PresentationTrace()
        let oldApp = PresentationApp(pid: 101, trace: trace)
        let incomingApp = PresentationApp(pid: 102, trace: trace, delaysFrames: true)
        defer { incomingApp.completeFrames() }
        let old = PresentationWindow(id: 1, workspace: focus.workspace, app: oldApp)
        let target = Workspace.get(byName: "incoming")
        _ = PresentationWindow(id: 2, workspace: target, app: incomingApp, hidden: true)
        XCTAssertTrue(target.focusWorkspace())
        let waiting = expectation(description: "Incoming frame queue")
        incomingApp.onWait = { waiting.fulfill() }
        let layout = Task { try await layoutWorkspaces() }
        await fulfillment(of: [waiting], timeout: 2)

        layout.cancel()
        incomingApp.completeFrames()
        do {
            try await layout.value
            XCTFail("A cancelled transition must stop before hiding windows")
        } catch is CancellationError {}
        XCTAssertFalse(old.isHiddenInCorner)
    }

    func testAnUnchangedDisplayDoesNotDelayTheTabSwitch() async throws {
        let main = SavedWorkspaceTestMonitor(id: 1, name: "Main", x: 0, isMain: true, uuid: nil)
        let secondary = SavedWorkspaceTestMonitor(id: 2, name: "Secondary", x: 1920, uuid: nil)
        setMonitorsForTests([main, secondary])
        defer { setMonitorsForTests(nil) }
        Workspace.reconcileWorkspaceState()
        let trace = PresentationTrace()
        let oldApp = PresentationApp(pid: 101, trace: trace)
        let incomingApp = PresentationApp(pid: 102, trace: trace)
        let unrelatedApp = PresentationApp(pid: 103, trace: trace, delaysFrames: true)
        defer { unrelatedApp.completeFrames() }
        let old = PresentationWindow(id: 1, workspace: main.activeWorkspace, app: oldApp)
        let unrelatedWorkspace = secondary.activeWorkspace
        let unrelated = PresentationWindow(id: 3, workspace: unrelatedWorkspace, app: unrelatedApp)
        let target = Workspace.get(byName: "incoming")
        _ = PresentationWindow(id: 2, workspace: target, app: incomingApp, hidden: true)
        XCTAssertTrue(main.setActiveWorkspace(target))
        XCTAssertTrue(target.focusWorkspace())
        let finished = expectation(description: "Switch finishes without the unrelated app")
        let layout = Task {
            defer { finished.fulfill() }
            try await layoutWorkspaces()
        }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(unrelatedApp.waitCount, 0)
        unrelatedApp.completeFrames()
        try await layout.value
        XCTAssertEqual(incomingApp.waitCount, 1)
        XCTAssertTrue(old.isHiddenInCorner)
        XCTAssertFalse(unrelated.isHiddenInCorner)
        XCTAssertTrue(secondary.activeWorkspace === unrelatedWorkspace)
    }

    func testAnUnparkableWindowDoesNotRepeatCompletedFrameWaits() async throws {
        let trace = PresentationTrace()
        let oldApp = PresentationApp(pid: 101, trace: trace)
        let incomingApp = PresentationApp(pid: 102, trace: trace)
        let old = PresentationWindow(id: 1, workspace: focus.workspace, app: oldApp)
        old.canHide = false // Models an outgoing app whose AX frame read fails.
        let target = Workspace.get(byName: "incoming")
        let incoming = PresentationWindow(id: 2, workspace: target, app: incomingApp, hidden: true)
        XCTAssertTrue(target.focusWorkspace())
        try await $refreshSessionEvent.withValue(.ax(kAXFocusedWindowChangedNotification as String)) {
            try await layoutWorkspaces()
            XCTAssertFalse(old.isHiddenInCorner)
            XCTAssertEqual(incomingApp.waitCount, 1)
            try await layoutWorkspaces()
            XCTAssertEqual(incomingApp.waitCount, 1, "No new frames means no additional AX queue drain")
            incoming.lastAppliedLayoutPhysicalRect = nil
            try await layoutWorkspaces()
            XCTAssertEqual(incomingApp.waitCount, 2, "A newly queued frame must still be awaited")
        }
    }

    func testACompletedFrameMarkerDoesNotAcknowledgeLaterWrites() async throws {
        let barrier = AppFrameWriteBarrier()
        barrier.recordWrite()
        let waiting = expectation(description: "First frame marker")
        var continuation: CheckedContinuation<Void, Never>?
        let first = Task {
            try await barrier.waitForPendingWrites {
                await withCheckedContinuation {
                    continuation = $0
                    waiting.fulfill()
                }
            }
        }
        await fulfillment(of: [waiting], timeout: 2)
        barrier.recordWrite()
        continuation?.resume()
        try await first.value
        var drainedLaterWrites = false
        try await barrier.waitForPendingWrites { drainedLaterWrites = true }
        XCTAssertTrue(drainedLaterWrites, "Writes submitted after a marker need their own completion")
    }

    func testACancelledFrameWaitStillRequiresCompletion() async throws {
        let barrier = AppFrameWriteBarrier()
        barrier.recordWrite()
        do {
            try await barrier.waitForPendingWrites { throw CancellationError() }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        var retried = false
        try await barrier.waitForPendingWrites { retried = true }
        XCTAssertTrue(retried)
    }

    func testReturningToTheOriginalTabWhileAnotherIsRevealing() async throws {
        let trace = PresentationTrace()
        let oldApp = PresentationApp(pid: 101, trace: trace)
        let slowApp = PresentationApp(pid: 102, trace: trace, delaysFrames: true)
        defer { slowApp.completeFrames() }
        let old = PresentationWindow(id: 1, workspace: focus.workspace, app: oldApp)
        oldApp.focusedWindow = old
        appForTests = oldApp
        XCTAssertTrue(old.focusWindow())
        let slow = PresentationWindow(id: 2, workspace: Workspace.get(byName: "slow"), app: slowApp, hidden: true)
        let waiting = expectation(description: "Other tab is revealing")
        slowApp.onWait = { waiting.fulfill() }
        let firstSwitch = Task {
            try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) { _ = slow.focusWindow() }
        }
        await fulfillment(of: [waiting], timeout: 2)
        try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) { _ = old.focusWindow() }
        XCTAssertFalse(old.isHiddenInCorner)
        XCTAssertTrue(slow.isHiddenInCorner)
        slowApp.completeFrames()
        try await firstSwitch.value
        XCTAssertTrue(focus.windowOrNil === old)
        XCTAssertFalse(trace.events.contains("hide:1"))
        XCTAssertFalse(trace.events.contains("focus:2"))
        XCTAssertLessThan(try XCTUnwrap(trace.events.firstIndex(of: "frame:2")), try XCTUnwrap(trace.events.firstIndex(of: "hide:2")))
    }

    func testANewerTabChoiceWinsWhileThePreviousAppIsStillRevealing() async throws {
        let trace = PresentationTrace()
        let oldApp = PresentationApp(pid: 101, trace: trace)
        let slowApp = PresentationApp(pid: 102, trace: trace, delaysFrames: true)
        let latestApp = PresentationApp(pid: 103, trace: trace, delaysFrames: true)
        defer { slowApp.completeFrames(); latestApp.completeFrames() }
        let old = PresentationWindow(id: 1, workspace: focus.workspace, app: oldApp)
        oldApp.focusedWindow = old
        appForTests = oldApp
        XCTAssertTrue(old.focusWindow())
        let slow = PresentationWindow(id: 2, workspace: Workspace.get(byName: "slow"), app: slowApp, hidden: true)
        let latest = PresentationWindow(id: 3, workspace: Workspace.get(byName: "latest"), app: latestApp, hidden: true)
        let slowWaiting = expectation(description: "First tab frame queue")
        let latestWaiting = expectation(description: "Latest tab frame queue")
        slowApp.onWait = { slowWaiting.fulfill() }
        latestApp.onWait = { latestWaiting.fulfill() }
        let firstSwitch = Task {
            try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) { _ = slow.focusWindow() }
        }
        await fulfillment(of: [slowWaiting], timeout: 2)
        let latestSwitch = Task {
            try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) { _ = latest.focusWindow() }
        }
        await fulfillment(of: [latestWaiting], timeout: 2)

        slowApp.completeFrames()
        try await firstSwitch.value
        XCTAssertFalse(old.isHiddenInCorner, "An obsolete layout must not hide windows before the latest tab is ready")
        XCTAssertFalse(trace.events.contains("focus:2"), "The previous click must not steal native focus back")
        latestApp.completeFrames()
        try await latestSwitch.value
        XCTAssertTrue(focus.windowOrNil === latest)
        XCTAssertEqual(trace.events.last, "focus:3")
        XCTAssertTrue(old.isHiddenInCorner)
    }
}

private final class PresentationTrace {
    var events: [String] = []
    var onEvent: ((String) -> Void)?
    func record(_ event: String) { events.append(event); onEvent?(event) }
}

private final class PresentationApp: AbstractApp {
    let pid: Int32
    var rawAppBundleId: String? { "test.presentation.\(pid)" }
    var name: String? { rawAppBundleId }
    var execPath: String? { nil }
    var bundlePath: String? { nil }
    var focusedWindow: Window?
    var onWait: (() -> Void)?
    private(set) var waitCount = 0
    private let trace: PresentationTrace
    private var delaysFrames: Bool
    private var pending: [() -> Void] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let frameWriteBarrier = AppFrameWriteBarrier()

    init(pid: Int32, trace: PresentationTrace, delaysFrames: Bool = false) {
        self.pid = pid
        self.trace = trace
        self.delaysFrames = delaysFrames
    }

    @MainActor func getFocusedWindow() async throws -> Window? { focusedWindow }
    func enqueue(_ frame: @escaping () -> Void) {
        frameWriteBarrier.recordWrite()
        if delaysFrames { pending.append(frame) } else { frame() }
    }
    @MainActor func waitForPendingFrameWrites() async throws {
        try await frameWriteBarrier.waitForPendingWrites {
            waitCount += 1
            trace.record("wait:\(pid)")
            onWait?()
            if delaysFrames { await withCheckedContinuation { waiters.append($0) } }
        }
    }
    func completeFrames() {
        delaysFrames = false
        let writes = pending
        pending = []
        writes.forEach { $0() }
        let resumed = waiters
        waiters = []
        resumed.forEach { $0.resume() }
    }
}

private final class PresentationWindow: Window {
    private let owner: PresentationApp
    private let trace: PresentationTrace
    private var hidden: Bool
    private var rect: Rect
    var canHide = true

    @MainActor init(id: UInt32, workspace: Workspace, app: PresentationApp, hidden: Bool = false) {
        owner = app
        trace = app.traceForWindow
        self.hidden = hidden
        rect = Rect(topLeftX: hidden ? -10_000 : 0, topLeftY: 0, width: 800, height: 600)
        super.init(id: id, app, lastFloatingSize: nil, parent: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        recordAuthoritativeActualRect(rect)
    }

    @MainActor override var title: String { get async { "Window \(windowId)" } }
    override var isHiddenInCorner: Bool { hidden }
    @MainActor override func getAxRect() async throws -> Rect? { rect }
    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        owner.enqueue { [self] in
            rect = Rect(topLeftX: topLeft?.x ?? rect.minX, topLeftY: topLeft?.y ?? rect.minY,
                width: size?.width ?? rect.width, height: size?.height ?? rect.height)
            trace.record("frame:\(windowId)")
        }
    }
    @MainActor func unhideFromCorner() { hidden = false }
    @MainActor func hideInCorner(_ corner: OptimalHideCorner, reassert: Bool, ifStillValid: () -> Bool) async throws {
        guard ifStillValid(), canHide else { return }
        if hidden && !reassert { return }
        hidden = true
        owner.enqueue { [self] in trace.record("hide:\(windowId)") }
    }
    @MainActor override func nativeFocus() {
        owner.focusedWindow = self
        appForTests = owner
        trace.record("focus:\(windowId)")
    }
}

extension PresentationWindow: WorkspaceWindowVisibility {}

private extension PresentationApp {
    var traceForWindow: PresentationTrace { trace }
}
