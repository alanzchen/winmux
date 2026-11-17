import AppKit

/// The native corner-parking operations used when presenting a workspace.
@MainActor
protocol WorkspaceWindowVisibility: AnyObject {
    func unhideFromCorner()
    /// `reassert`: the window may have moved without any event reaching WinMux (wake, a settled
    /// display change), so look at it again even if WinMux believes it parked.
    func hideInCorner(_ corner: OptimalHideCorner, reassert: Bool, ifStillValid: () -> Bool) async throws
    /// What hiding the window has come to: confirmed, pending or blocked. Nil while it isn't hidden, or for a
    /// window that doesn't keep parking state.
    var cornerParkOutcome: CornerParkOutcome? { get }
}

extension WorkspaceWindowVisibility {
    var cornerParkOutcome: CornerParkOutcome? { nil }
}

extension MacWindow: WorkspaceWindowVisibility {}
