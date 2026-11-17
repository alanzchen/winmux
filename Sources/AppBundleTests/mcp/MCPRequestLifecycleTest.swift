@testable import AppBundle
import Foundation
import XCTest

/// A request has one ending: completed, timed out or cancelled. Not on the main actor, as the MCP connection that
/// runs these isn't: the deadline's timer and the work run on their own threads.
final class MCPRequestLifecycleTest: XCTestCase {
    private var savedDeadline: (@Sendable (Duration) async throws -> Void)!

    override func setUp() {
        savedDeadline = mcpRequestDeadline
    }

    override func tearDown() {
        mcpRequestDeadline = savedDeadline
    }

    // Astra's audit B3: the timer ignored the error from its cancelled sleep and claimed a timeout. Once the work
    // had cancelled it, a timer that got there first turned a success into a timeout.
    func testACancelledTimerEndsNothingAndSuccessAfterItWins() async {
        let request = MCPRequestLifecycle<Int>()
        let deadline = MCPTestDeadline()
        let timer = Task { await request.timeOut(after: .seconds(60), { try await deadline.sleep($0) }) }
        await deadline.waiting.wait()
        timer.cancel()
        await timer.value
        XCTAssertTrue(request.end(.completed(42)), "Cancelling the timer must not have ended the request")
        let outcome = await request.outcome()
        XCTAssertEqual(outcome.completedValue, 42, "\(outcome)")
    }

    func testATimerWhoseDeadlinePassesTimesTheRequestOut() async {
        let request = MCPRequestLifecycle<Int>()
        await request.timeOut(after: .seconds(60), { _ in })
        XCTAssertFalse(request.end(.completed(1)), "Success after a timeout doesn't change what was answered")
        guard case .timedOut = await request.outcome() else { return XCTFail() }
    }

    func testWorkThatAnswersWhileTheTimerWaitsCompletesAndThenCancelsTheTimer() async {
        let deadline = MCPTestDeadline()
        mcpRequestDeadline = { try await deadline.sleep($0) }
        let outcome = await mcpFirst(orAfter: .seconds(60)) {
            await deadline.waiting.wait()
            return 42
        }
        XCTAssertEqual(outcome.completedValue, 42, "\(outcome)")
        let cancelled = await deadline.cancelled.wait(timeout: 5)
        XCTAssertTrue(cancelled, "The timer is cancelled once the request has completed")
    }

    func testWorkThatAnswersAtOnceCompletes() async {
        for value in 0 ..< 5 {
            let deadline = MCPTestDeadline()
            mcpRequestDeadline = { try await deadline.sleep($0) }
            let outcome = await mcpFirst(orAfter: .seconds(60)) { value }
            XCTAssertEqual(outcome.completedValue, value, "\(outcome)")
        }
    }

    func testADeadlineThatPassesFirstTimesOutAndTheWorkStillFinishes() async {
        mcpRequestDeadline = { _ in }
        let gate = MCPTestGate()
        let finished = MCPTestGate()
        let outcome = await mcpFirst(orAfter: .seconds(60)) {
            await gate.wait()
            finished.open()
            return 1
        }
        guard case .timedOut = outcome else { return XCTFail("\(outcome)") }
        gate.open()
        await finished.wait()
    }

    func testCancellingTheCallerCancelsTheRequestAndNotItsWork() async {
        let gate = MCPTestGate()
        let started = MCPTestGate()
        let finished = MCPTestGate()
        let caller = Task {
            await mcpFirst(orAfter: .seconds(3600)) {
                started.open()
                await gate.wait()
                finished.open()
                return 1
            }
        }
        await started.wait()
        caller.cancel()
        let outcome = await caller.value
        guard case .cancelled = outcome else { return XCTFail("\(outcome)") }
        gate.open()
        await finished.wait()
    }

    func testTheFirstEndingIsTheOnlyOne() async {
        let request = MCPRequestLifecycle<Int>()
        XCTAssertTrue(request.end(.completed(7)))
        XCTAssertFalse(request.end(.timedOut))
        XCTAssertFalse(request.end(.cancelled))
        XCTAssertFalse(request.end(.completed(8)))
        let outcome = await request.outcome()
        XCTAssertEqual(outcome.completedValue, 7)
    }
}

/// A deadline that never passes by itself; it ends only when cancelled.
final class MCPTestDeadline: @unchecked Sendable {
    private let waitingSignal = DispatchSemaphore(value: 0)
    /// Opens once a timer is waiting on this deadline.
    let waiting = MCPTestGate()
    /// Opens once this deadline has been cancelled.
    let cancelled = MCPTestGate()

    /// Blocks the calling thread until a timer is waiting on this deadline.
    func blockUntilWaiting(timeout: TimeInterval = 5) -> Bool {
        waitingSignal.wait(timeout: .now() + timeout) == .success
    }

    func sleep(_: Duration) async throws {
        let run = MCPTestDeadlineRun()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard run.install(continuation) else { return continuation.resume(throwing: CancellationError()) }
                waiting.open()
                waitingSignal.signal()
            }
        } onCancel: {
            run.cancel()?.resume(throwing: CancellationError())
            cancelled.open()
        }
    }
}

private final class MCPTestDeadlineRun: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Error>?
    private var cancelled = false

    /// False when already cancelled.
    func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.withLock {
            if cancelled { return false }
            waiter = continuation
            return true
        }
    }

    func cancel() -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            cancelled = true
            defer { waiter = nil }
            return waiter
        }
    }
}

/// Opens once; waiting on an open gate returns at once.
final class MCPTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { self.waiters = [] }
            return self.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Whether it opened within `timeout` seconds.
    func wait(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ isOpen }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return lock.withLock { isOpen }
    }
}
