import AppKit

/// The native corner-parking operations used when presenting a workspace.
@MainActor
protocol WorkspaceWindowVisibility: AnyObject {
    func unhideFromCorner()
    func hideInCorner(_ corner: OptimalHideCorner, force: Bool, ifStillValid: () -> Bool) async throws
}

extension MacWindow: WorkspaceWindowVisibility {}
