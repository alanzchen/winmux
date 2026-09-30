import AppKit

/// One custom sidebar drag, a row, card, Dock icon or pinned tile, from its first update to its
/// release or cancellation. Late callbacks of a gesture that was cancelled or released are refused,
/// while the next real drag starts a new session.
struct WorkspaceSidebarDragSession: Equatable {
    enum State: Equatable {
        case active, cancelled, finished
    }

    let generation: UInt64
    /// The left mouse-down the drag began under.
    let mouseDownSerial: UInt64
    var state: State
    /// The mouse button has gone up since the session ended, so the next update is a new drag.
    var releaseObserved = false
}

@MainActor
final class WorkspaceSidebarDragSessions {
    static let shared = WorkspaceSidebarDragSessions()

    private(set) var current: WorkspaceSidebarDragSession?
    private(set) var mouseDownSerial: UInt64 = 0
    private var nextGeneration: UInt64 = 1

    init() {}

    var active: WorkspaceSidebarDragSession? { current?.state == .active ? current : nil }

    func noteLeftMouseDown() { mouseDownSerial &+= 1 }

    /// The button went up: whatever ended the last session, the next update starts a new one.
    func noteLeftMouseUp() {
        if current?.state != .active { current?.releaseObserved = true }
    }

    /// An update of a custom drag: continues the active session, or starts one. After a cancel,
    /// updates of the same press are refused until the button is released or pressed again.
    func acceptUpdate() -> Bool {
        if let current {
            switch current.state {
                case .active: return true
                case .cancelled, .finished:
                    guard current.releaseObserved || mouseDownSerial != current.mouseDownSerial else { return false }
            }
        }
        current = WorkspaceSidebarDragSession(generation: nextGeneration, mouseDownSerial: mouseDownSerial, state: .active)
        nextGeneration &+= 1
        return true
    }

    /// The release, once: the active session ends as finished and is returned. A second finish of
    /// the same release, or one after a cancel, gets nil and must commit nothing.
    func consumeRelease() -> WorkspaceSidebarDragSession? {
        guard var session = active else { return nil }
        session.state = .finished
        session.releaseObserved = true
        current = session
        return session
    }

    /// Ends the active session without a drop. Returns whether one was active.
    @discardableResult
    func cancel() -> Bool {
        guard active != nil else { return false }
        current?.state = .cancelled
        current?.releaseObserved = !isLeftMouseButtonDown
        return true
    }

    /// Tests hold no mouse button, so a cancel always counts as released. The gesture in use
    /// cancels with the button down.
    func markCancelledWhilePressedForTests() {
        guard current?.state == .cancelled else { return }
        current?.releaseObserved = false
    }

    func resetForTests() {
        current = nil
        mouseDownSerial = 0
    }
}

/// Ends the custom sidebar drag in progress without a drop: Escape, or anything else that makes
/// the drop meaningless. Nothing moves; its feedback and the temporary UI go away, and the rest of
/// the gesture is refused. Returns whether a drag was in progress.
@MainActor
@discardableResult
func cancelWorkspaceSidebarDragSession() -> Bool {
    guard WorkspaceSidebarDragSessions.shared.cancel() else { return false }
    WorkspaceSidebarDropDestinationController.shared.end()
    cancelActiveSidebarPinnedTabDrag()
    clearActiveWorkspaceSidebarDrag()
    clearPendingWindowDragIntent()
    if getCurrentMouseDragStartedInSidebar() {
        cancelManipulatedWithMouseState()
        scheduleRefreshSession(.resetManipulatedWithMouse, optimisticallyPreLayoutWorkspaces: true)
    }
    clearWorkspaceSidebarDropPreview()
    WindowDragCursorProxyPanel.shared.hide()
    return true
}

/// Escape during a custom sidebar drag cancels it. Every key path asks this first, before inline
/// editing or sequence bindings see the key; returns whether the key was taken.
@MainActor
func workspaceSidebarHandleEscapeDuringDrag(keyCode: Int64) -> Bool {
    guard keyCode == 53 else { return false }
    return cancelWorkspaceSidebarDragSession()
}

/// A release a sidebar drop consumed, by its mouse-down, so the desktop-click handling of the same
/// mouse-up doesn't move focus back to the display under the pointer.
@MainActor
private var workspaceSidebarConsumedReleaseSerial: UInt64?

@MainActor
func noteWorkspaceSidebarConsumedRelease() {
    workspaceSidebarConsumedReleaseSerial = WorkspaceSidebarDragSessions.shared.mouseDownSerial
}

/// Whether the current mouse-up was a sidebar drop. Asking forgets it.
@MainActor
func takeWorkspaceSidebarConsumedRelease() -> Bool {
    defer { workspaceSidebarConsumedReleaseSerial = nil }
    return workspaceSidebarConsumedReleaseSerial == WorkspaceSidebarDragSessions.shared.mouseDownSerial
}

@MainActor
func isWorkspaceSidebarDragSessionActive() -> Bool {
    WorkspaceSidebarDragSessions.shared.active != nil
}
