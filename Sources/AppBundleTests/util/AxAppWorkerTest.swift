@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class AxAppWorkerTest: XCTestCase {
    func testShutdownCancelsQueuedAndNewOperationsWithoutRunningTheirBodies() async {
        let start = DispatchSemaphore(value: 0)
        let stopped = expectation(description: "worker exited")
        let (worker, _) = await startWorker(start: start, stopped: stopped)
        let queued = worker.runInLoopAsync { _ in XCTFail("Queued work ran after shutdown") }
        let completed = expectation(description: "async callers cancelled")
        completed.expectedFulfillmentCount = 9
        for _ in 0 ..< 8 {
            Task { @MainActor in
                do {
                    _ = try await worker.runInLoop { _ in XCTFail("Queued operation ran"); return 42 }
                    XCTFail("Queued operation should cancel")
                } catch is CancellationError { } catch { XCTFail("\(error)") }
                completed.fulfill()
            }
        }
        await Task.yield()
        worker.shutdown()
        worker.shutdown() // Shutdown is idempotent.
        XCTAssertTrue(queued.isCancelled)
        Task { @MainActor in
            do {
                _ = try await worker.runInLoop { _ in XCTFail("New operation was admitted"); return 42 }
                XCTFail("New operation should cancel")
            } catch is CancellationError { } catch { XCTFail("\(error)") }
            completed.fulfill()
        }
        start.signal()
        await fulfillment(of: [completed, stopped], timeout: 5)
    }

    func testRunningOperationRetainsWrappersUntilTheLoopActuallyExits() async {
        let stopped = expectation(description: "worker exited and destroyed wrapper")
        let (worker, value) = await startWorker(stopped: stopped)
        let entered = expectation(description: "operation started")
        let release = DispatchSemaphore(value: 0)
        let completed = expectation(description: "running operation cancelled cooperatively")
        Task { @MainActor in
            do {
                _ = try await worker.runInLoop { job in
                    entered.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                    // Shutdown has already requested CFRunLoopStop. Destroying the wrapper in
                    // that request would fail this read with "Value is already destroyed".
                    XCTAssertEqual(value.threadGuarded, 42)
                    try job.checkCancellation()
                    return 42
                }
                XCTFail("Running job should observe shutdown cancellation")
            } catch is CancellationError { } catch { XCTFail("\(error)") }
            completed.fulfill()
        }
        await fulfillment(of: [entered], timeout: 5)
        worker.shutdown()
        release.signal()
        await fulfillment(of: [completed, stopped], timeout: 5)
    }

    private func startWorker(
        start: DispatchSemaphore? = nil,
        stopped: XCTestExpectation,
    ) async -> (AxAppWorker, ThreadGuardedValue<Int>) {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: 42, idForDebug: "AX worker test")) {
                    let worker = AxAppWorker()
                    let value = ThreadGuardedValue(42)
                    // Production AX subscriptions supply the run-loop source. A timer keeps
                    // this test's worker alive without reading any real app's Accessibility tree.
                    let keepAlive = Timer(timeInterval: 60, repeats: true) { _ in }
                    RunLoop.current.add(keepAlive, forMode: .default)
                    continuation.resume(returning: (worker, value))
                    if let start { _ = start.wait(timeout: .now() + 5) }
                    CFRunLoopRun()
                    worker.finish()
                    value.destroy()
                    keepAlive.invalidate()
                    stopped.fulfill()
                }
            }
            thread.start()
        }
    }
}
