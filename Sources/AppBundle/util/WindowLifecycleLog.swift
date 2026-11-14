import AppKit

/// A window's recent comings and goings, for a debug snapshot: registered, gone, parked in a corner, back from
/// one, moved to another workspace, and which workspace each display shows. Ids, kinds and workspace names only.
struct WindowLifecycleEvent: Equatable, Sendable {
    enum Kind: String, Sendable {
        case registered, unregistered, parked, unparked, moved, workspaceShown
    }

    let at: Date
    let kind: Kind
    /// Nil for a display's event.
    let windowId: UInt32?
    let detail: [String: String]
}

/// The newest `capacity` events, oldest first. Recording one costs an append to a fixed buffer.
@MainActor
final class WindowLifecycleLog {
    static let shared = WindowLifecycleLog()
    static let capacity = 256

    private var ring = DockPerformanceRing<WindowLifecycleEvent>(capacity: capacity)
    /// Sees every event as it's recorded: a running debug recording keeps them all.
    var observer: (@MainActor (WindowLifecycleEvent) -> Void)?

    var events: [WindowLifecycleEvent] { ring.elements }
    /// How many older events made room for newer ones.
    var overwritten: Int { ring.overwritten }

    func record(_ kind: WindowLifecycleEvent.Kind, windowId: UInt32?, _ detail: [String: String] = [:]) {
        let event = WindowLifecycleEvent(at: Date(), kind: kind, windowId: windowId, detail: detail)
        ring.append(event)
        observer?(event)
    }

    func reset() {
        ring = DockPerformanceRing(capacity: Self.capacity)
    }
}

/// The last AX error each window's reads got, as the refresh that checks windows are alive saw it, and when. At
/// most `capacity` windows; the one with the oldest error goes first. Recorded on apps' AX threads.
final class AxWindowErrorLog: @unchecked Sendable {
    static let shared = AxWindowErrorLog()
    static let capacity = 512

    private let lock = NSLock()
    private var entries: [UInt32: (error: String, at: Date, sequence: UInt64)] = [:]
    private var sequence: UInt64 = 0

    var count: Int { lock.withLock { entries.count } }

    func record(windowId: UInt32, error: AXError) {
        let at = Date()
        lock.withLock {
            sequence &+= 1
            entries[windowId] = (error.repr, at, sequence)
            if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
    }

    /// A new window has the id: an error an earlier one got isn't its.
    func forget(windowId: UInt32) {
        _ = lock.withLock { entries.removeValue(forKey: windowId) }
    }

    func last(windowId: UInt32) -> (error: String, at: Date)? {
        lock.withLock { entries[windowId].map { ($0.error, $0.at) } }
    }

    func reset() {
        lock.withLock { entries = [:] }
    }
}
