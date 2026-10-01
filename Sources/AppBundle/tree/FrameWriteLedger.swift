import Foundation

/// Counts the geometry writes WinMux makes to each of an app's windows, as they run on the app's
/// AX thread: when each begins and when it ends. A write queued long before it runs, one still
/// running, and a move and a move back between two looks all show, however late, or whether,
/// the window's own notifications arrive. Writes that find the frame already in place don't count.
final class FrameWriteLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var begun: [UInt32: UInt64] = [:]
    private var ended: [UInt32: UInt64] = [:]

    func begin(_ windowId: UInt32) {
        lock.withLock {
            // Bounded: forget windows with nothing running, which only makes them look moved once.
            if begun.count >= 1024 {
                begun = begun.filter { ended[$0.key] != $0.value }
                ended = ended.filter { begun[$0.key] != nil }
            }
            begun[windowId, default: 0] &+= 1
        }
    }

    func end(_ windowId: UInt32) {
        lock.withLock { ended[windowId, default: 0] &+= 1 }
    }

    /// How many write steps have begun or ended for the window, and whether one is running now.
    func state(_ windowId: UInt32) -> (steps: UInt64, writing: Bool) {
        lock.withLock {
            let begun = begun[windowId] ?? 0
            let ended = ended[windowId] ?? 0
            return (begun &+ ended, begun != ended)
        }
    }

    /// Runs `write`, counted.
    func record<T>(_ windowId: UInt32, _ write: () throws -> T) rethrows -> T {
        begin(windowId)
        defer { end(windowId) }
        return try write()
    }
}
