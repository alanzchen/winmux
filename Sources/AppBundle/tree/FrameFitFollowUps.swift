import AppKit

/// One follow-up per window: a layout's frame write that left the window unsettled looks again once its settle interval is
/// up (`WindowFrameFit.followUpAt`). A later layout may not come to do it: right after a drag the window's own kAXMoved
/// and kAXResized are suppressed, and a layout may reuse the frames it wrote. A newer write for the window replaces it.
@MainActor
final class FrameFitFollowUps {
    static let shared = FrameFitFollowUps()

    private struct Pending {
        let at: TimeInterval
        let token: UInt64
        let cell: Rect
        let target: FrameFitTarget
        let task: Task<Void, Never>?
    }

    private var pending: [UInt32: Pending] = [:]
    private var tokens: UInt64 = 0
    /// Tests drive the clock: follow-ups run as it's advanced past them, not on a timer.
    private var manualTime: TimeInterval?

    private init() {}

    /// The monotonic clock frame writes are timed on.
    func now() -> TimeInterval { manualTime ?? ProcessInfo.processInfo.systemUptime }

    /// At `time`, `windowId`'s write into `cell` with `target` again, if layout still has the window there
    /// (`Window.continueLayoutFrame`).
    func schedule(_ windowId: UInt32, at time: TimeInterval, cell: Rect, target: FrameFitTarget) {
        cancel(windowId)
        tokens &+= 1
        let token = tokens
        let task: Task<Void, Never>? = manualTime != nil ? nil : Task { @MainActor in
            // A millisecond past it, so the look isn't still inside the interval on a clock read a little early.
            try? await Task.sleep(for: .seconds(max(0, time - ProcessInfo.processInfo.systemUptime) + 0.001))
            FrameFitFollowUps.shared.run(windowId, token: token)
        }
        pending[windowId] = Pending(at: time, token: token, cell: cell, target: target, task: task)
    }

    func cancel(_ windowId: UInt32) {
        pending.removeValue(forKey: windowId)?.task?.cancel()
    }

    func isPending(_ windowId: UInt32) -> Bool { pending[windowId] != nil }

    private func run(_ windowId: UInt32, token: UInt64) {
        guard let due = pending[windowId], due.token == token else { return }
        pending[windowId] = nil
        Window.get(byId: windowId)?.continueLayoutFrame(due.cell, target: due.target)
    }

    func startManualClockForTests(at time: TimeInterval) {
        stopManualClockForTests()
        manualTime = time
    }

    func stopManualClockForTests() {
        for due in pending.values { due.task?.cancel() }
        pending = [:]
        manualTime = nil
    }

    /// Moves the test clock on by `delay`, running each follow-up due by then at its time, those they schedule included.
    func advanceManualClockForTests(by delay: TimeInterval) {
        guard let start = manualTime else { return }
        let end = start + delay
        for _ in 0 ..< 1000 {
            guard let (windowId, due) = pending.filter({ $0.value.at <= end }).min(by: { $0.value.at < $1.value.at }) else { break }
            manualTime = max(manualTime ?? due.at, due.at)
            run(windowId, token: due.token)
        }
        manualTime = end
    }
}
