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
}

@MainActor
final class WorkspaceSidebarDragSessions {
    static let shared = WorkspaceSidebarDragSessions()

    private(set) var current: WorkspaceSidebarDragSession?
    private(set) var mouseDownSerial: UInt64 = 0
    private var nextGeneration: UInt64 = 1

    init() {}

    var active: WorkspaceSidebarDragSession? { current?.state == .active ? current : nil }

    /// Every left mouse-down, the gesture's own included: local monitors see a press before
    /// SwiftUI does.
    func noteLeftMouseDown() { mouseDownSerial &+= 1 }

    /// A drag of this press has ended, released or cancelled. Its late callbacks belong to it.
    var hasEndedThisPress: Bool {
        guard let current else { return false }
        return current.state != .active && current.mouseDownSerial == mouseDownSerial
    }

    /// An update of a custom drag: continues the active session, or starts one. Once a drag ends,
    /// by release or cancel, every later update of the same press is refused, even after the
    /// button went up; only a new press starts a new drag.
    func acceptUpdate() -> Bool {
        if current?.state == .active { return true }
        guard !hasEndedThisPress else { return false }
        current = WorkspaceSidebarDragSession(generation: nextGeneration, mouseDownSerial: mouseDownSerial, state: .active)
        nextGeneration &+= 1
        return true
    }

    /// The release, once: the active session ends as finished and is returned. A second finish of
    /// the same release, or one after a cancel, gets nil and must commit nothing.
    func consumeRelease() -> WorkspaceSidebarDragSession? {
        guard var session = active else { return nil }
        session.state = .finished
        current = session
        return session
    }

    /// Ends the active session without a drop. Returns whether one was active.
    @discardableResult
    func cancel() -> Bool {
        guard active != nil else { return false }
        current?.state = .cancelled
        return true
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
