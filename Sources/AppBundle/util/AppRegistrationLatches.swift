import Foundation

/// All callers waiting on one app share its current registration attempt. Failure clears the
/// attempt too: existing waiters return nil, and a later refresh can make one fresh attempt.
@MainActor
final class AppRegistrationLatches {
    private var latches: [pid_t: AwaitableOneTimeBroadcastLatch] = [:]

    subscript(pid: pid_t) -> AwaitableOneTimeBroadcastLatch? { latches[pid] }

    func begin(_ pid: pid_t) -> AwaitableOneTimeBroadcastLatch {
        precondition(latches[pid] == nil)
        let latch = AwaitableOneTimeBroadcastLatch()
        latches[pid] = latch
        return latch
    }

    func complete(_ pid: pid_t) async {
        // The map must be clear before signalToAll's actor hop can resume any waiter.
        guard let latch = latches.removeValue(forKey: pid) else { return }
        await latch.signalToAll()
    }
}
