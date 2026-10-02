import AppKit

/// The native corner-parking operations used when presenting a workspace.
@MainActor
protocol WorkspaceWindowVisibility: AnyObject {
    func unhideFromCorner()
    /// `reassert`: the window may have moved without any event reaching WinMux (wake, a settled
    /// display change), so look at it again even if WinMux believes it parked.
    func hideInCorner(_ corner: OptimalHideCorner, reassert: Bool, ifStillValid: () -> Bool) async throws
}

extension MacWindow: WorkspaceWindowVisibility {}
