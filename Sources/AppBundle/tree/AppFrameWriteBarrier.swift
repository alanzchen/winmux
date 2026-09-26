/// Tracks frame submissions independently of logical window visibility. A window whose
/// AX frame cannot be read may remain logically unhidden after every parking attempt.
/// That must not make subsequent layouts drain an unrelated focus/read job on this app.
final class AppFrameWriteBarrier {
    private var queuedGeneration: UInt64 = 0
    @MainActor private var completedGeneration: UInt64 = 0

    func recordWrite() { queuedGeneration += 1 }

    @MainActor
    func waitForPendingWrites(_ drain: () async throws -> Void) async throws {
        let generation = queuedGeneration
        guard generation > completedGeneration else { return }
        try await drain()
        // A newer write may have been submitted while this marker was queued. Only
        // acknowledge the writes preceding this marker, even if waits finish out of order.
        completedGeneration = max(completedGeneration, generation)
    }
}
