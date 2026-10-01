import Foundation

/// Counts the geometry writes WinMux makes to each of an app's windows, as they run on the app's
/// AX thread: when each begins and when it ends. A write queued long before it runs, one still
/// running, and a move and a move back between two looks all show, however late, or whether,
/// the window's own notifications arrive. Writes that find the frame already in place don't count.
final class FrameWriteLedger: @unchecked Sendable {
    private let lock = NSLock()
    /// One serial for every window, so a window's version never repeats, even after it's forgotten.
    private var serial: UInt64 = 0
    private var latest: [UInt32: UInt64] = [:]
    private var running: [UInt32: Int] = [:]

    func begin(_ windowId: UInt32) {
        lock.withLock {
            // Bounded: forget windows with nothing running. A forgotten window's version starts
            // over at zero and its next write gets a new serial, so it looks moved, never still.
            if latest.count >= 1024 { latest = latest.filter { running[$0.key] != nil } }
            serial &+= 1
            latest[windowId] = serial
            running[windowId, default: 0] += 1
        }
    }

    func end(_ windowId: UInt32) {
        lock.withLock {
            serial &+= 1
            latest[windowId] = serial
            if let count = running[windowId], count > 1 { running[windowId] = count - 1 } else { running[windowId] = nil }
        }
    }

    /// Changes whenever a write to the window begins or ends; and whether one is running now.
    func state(_ windowId: UInt32) -> (version: UInt64, writing: Bool) {
        lock.withLock { (latest[windowId] ?? 0, running[windowId] != nil) }
    }

    /// Runs `write`, counted.
    func record<T>(_ windowId: UInt32, _ write: () throws -> T) rethrows -> T {
        begin(windowId)
        defer { end(windowId) }
        return try write()
    }
}
