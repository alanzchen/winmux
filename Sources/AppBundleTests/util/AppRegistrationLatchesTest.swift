@testable import AppBundle
import XCTest

@MainActor
final class AppRegistrationLatchesTest: XCTestCase {
    func testFailedAttemptWakesAllWaitersAfterClearingEntryAndAllowsLaterRetry() async throws {
        let attempts = AppRegistrationLatches()
        let first = attempts.begin(42)
        XCTAssertTrue(attempts[42] === first)
        let waiter1 = Task { @MainActor in
            try await first.await()
            XCTAssertNil(attempts[42])
        }
        let waiter2 = Task { @MainActor in
            try await first.await()
            XCTAssertNil(attempts[42])
        }
        // Complete without registering an app, as on an AX subscription failure.
        await attempts.complete(42)
        try await waiter1.value
        try await waiter2.value
        let retry = attempts.begin(42)
        XCTAssertFalse(retry === first)
        XCTAssertTrue(attempts[42] === retry)
        await attempts.complete(42)
        XCTAssertNil(attempts[42])
    }

    func testCancelledWaiterDoesNotCancelSharedRegistration() async throws {
        let attempts = AppRegistrationLatches()
        let latch = attempts.begin(42)
        let cancelled = Task { try await latch.await() }
        cancelled.cancel()
        let remaining = Task { try await latch.await() }
        await attempts.complete(42)
        do {
            try await cancelled.value
            XCTFail("Cancelled waiter must finish with cancellation")
        } catch is CancellationError { }
        try await remaining.value
        XCTAssertNil(attempts[42])
    }
}
