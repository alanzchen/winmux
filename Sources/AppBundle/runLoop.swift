import Common
import Foundation

/// Owns admission to one app's AX run loop. Shutdown cancels queued operations even when the
/// run loop never executes their blocks, so checked continuations cannot be left suspended.
final class AxAppWorker: @unchecked Sendable {
    private struct Action {
        let job: RunLoopJob
        let run: @Sendable () -> ()
        let cancel: @Sendable () -> ()
    }

    private let runLoop: CFRunLoop
    private let lock = NSLock()
    private var accepting = true
    private var pending: [UniqueToken: Action] = [:]
    private var running: [UniqueToken: RunLoopJob] = [:]

    /// Construct on the AX worker thread, before publishing the app on the main actor.
    init() { runLoop = CFRunLoopGetCurrent() }

    @discardableResult
    func runInLoopAsync(
        job: RunLoopJob = RunLoopJob(),
        autoCheckCancelled: Bool = true,
        _ body: @Sendable @escaping (RunLoopJob) -> (),
    ) -> RunLoopJob {
        submit(job: job, autoCheckCancelled: autoCheckCancelled, body, onShutdown: {})
        return job
    }

    func runInLoop<T>(_ body: @Sendable @escaping (RunLoopJob) throws -> T) async throws -> T {
        try checkCancellation()
        let job = RunLoopJob()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                submit(job: job, autoCheckCancelled: false, { job in
                    do {
                        try job.checkCancellation()
                        cont.resume(returning: try body(job))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }, onShutdown: { cont.resume(throwing: CancellationError()) })
            }
        } onCancel: {
            job.cancel()
        }
    }

    private func submit(
        job: RunLoopJob,
        autoCheckCancelled: Bool,
        _ body: @Sendable @escaping (RunLoopJob) -> (),
        onShutdown: @Sendable @escaping () -> (),
    ) {
        let id = UniqueToken()
        let event = refreshSessionEvent
        let action = Action(job: job, run: {
            if autoCheckCancelled && job.isCancelled { return }
            $refreshSessionEvent.withValue(event) { body(job) }
        }, cancel: onShutdown)
        let admitted = lock.withLock {
            guard accepting else { return false }
            pending[id] = action
            return true
        }
        guard admitted else {
            job.cancel()
            onShutdown()
            return
        }
        // The block captures only the identity. Shutdown releases the queued body and cancels
        // its continuation; a block that CF executes afterward finds no work and is harmless.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }
            let action = lock.withLock {
                guard let action = pending.removeValue(forKey: id) else { return nil as Action? }
                running[id] = action.job
                return action
            }
            guard let action else { return }
            defer { _ = lock.withLock { running.removeValue(forKey: id) } }
            action.run()
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Stops admission immediately, then requests loop termination. A running operation can
    /// finish or observe cancellation before CFRunLoopRun returns and wrappers are destroyed.
    func shutdown() {
        guard closeAdmission() else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Also close admission if the run loop exits for another reason.
    func finish() { _ = closeAdmission() }

    @discardableResult
    private func closeAdmission() -> Bool {
        let work = lock.withLock { () -> ([Action], [RunLoopJob])? in
            guard accepting else { return nil }
            accepting = false
            let work = (Array(pending.values), Array(running.values))
            pending = [:]
            return work
        }
        guard let (pending, running) = work else { return false }
        for job in running { job.cancel() }
        for action in pending {
            action.job.cancel()
            action.cancel()
        }
        return true
    }
}

final class RunLoopJob: Sendable, WinMuxAny {
    // Alternative 1. In macOS 15, it's possible to use `Atomic<Bool>` from `Synchronization` module
    // Alternative 2. https://github.com/apple/swift-atomics/tree/main but I don't want to add one more dependency just for
    //                AtomicBool
    nonisolated(unsafe) private var _isCancelled: Int32 = 0
    var isCancelled: Bool { _isCancelled == 1 }
    func cancel() {
        while !isCancelled {
            OSAtomicCompareAndSwapInt(0, 1, &_isCancelled)
        }
    }

    static let cancelled: RunLoopJob = RunLoopJob().also { $0.cancel() }

    func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}
