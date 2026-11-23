@testable import AppBundle
import XCTest

/// Owns one held AX phase, including every overlapping refresh read and teardown.
/// A refresh may enter the same hook, but only this restore can satisfy the entry handshake.
@MainActor
final class FrozenRestoreTestSuspension {
    @MainActor
    private final class ReadObservation {
        let ready = AwaitableOneTimeBroadcastLatch()
        var entered = false
    }

    enum FixtureError: Error { case readAlreadyHeld, restoreFinishedBeforeNativeRead }

    @TaskLocal private static var observedRestore: ReadObservation?

    let restore: Task<Bool, any Error>
    private let held: TestWindow
    private let released: AwaitableOneTimeBroadcastLatch
    private var didRelease = false

    private init(restore: Task<Bool, any Error>, held: TestWindow, released: AwaitableOneTimeBroadcastLatch) {
        self.restore = restore
        self.held = held
        self.released = released
    }

    static func start(_ other: Window, held: TestWindow, in test: XCTestCase,
                      failing: (any Error)? = nil) async throws -> FrozenRestoreTestSuspension {
        guard held.nativeStateGate == nil else { throw FixtureError.readAlreadyHeld }
        let observation = ReadObservation()
        let released = AwaitableOneTimeBroadcastLatch()
        let restoresBefore = activeFrozenRestoreCount
        held.nativeStateGate = {
            if observedRestore === observation {
                observation.entered = true
                await observation.ready.signalToAll()
            }
            try await released.await()
            if let failing { throw failing }
            try Task.checkCancellation()
        }
        let binding = bindingDataForNewRegularWindow(focus.workspace, window: nil)
        other.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        let restore = Task { @MainActor in
            let result: Result<Bool, any Error>
            do {
                result = .success(try await $observedRestore.withValue(observation) {
                    try await restoreOrDetectNewWindow(other, isRegularWindow: true)
                })
            } catch { result = .failure(error) }
            // A restore that exits before the expected read must fail setup, not strand it.
            await observation.ready.signalToAll()
            return try result.get()
        }
        let suspension = FrozenRestoreTestSuspension(restore: restore, held: held, released: released)
        test.addTeardownBlock { @MainActor in await suspension.finish() }
        // No scheduler-turn budget: the actual restore has reached its native read.
        try await observation.ready.await()
        guard observation.entered else {
            let result = await restore.result
            await suspension.finish()
            _ = try result.get()
            throw FixtureError.restoreFinishedBeforeNativeRead
        }
        XCTAssertEqual(activeFrozenRestoreCount, restoresBefore + 1)
        return suspension
    }

    func release() async {
        if !didRelease {
            didRelease = true
            held.nativeStateGate = nil
        }
        // One owner wakes all readers, including a captured hook entering after release.
        await released.signalToAll()
    }

    func finish() async {
        restore.cancel()
        await release()
        // Drain before the test's global state is reset, also on an earlier assertion/throw.
        _ = await restore.result
    }
}
