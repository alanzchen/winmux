import AppKit

// Tabs mode: every list belongs to one display, and a tab dropped on a list goes to its display,
// whether it lands between tabs, among the pins, or in a group. Without this, a tab pinned or
// grouped from another display stayed on its own one, while the list it was dropped on showed
// the drop and then nothing.

/// Where a drop on a display's list takes a tab.
enum WorkspaceSidebarDropDisplay {
    /// The list names no single display, or the tab is on it already.
    case stays
    case moves(to: Monitor)
    /// The list's display is no longer connected. Nothing may be dropped there.
    case gone
}

/// Where a drop on the list for `monitorScopeId` takes `tab`. A list that names no display, such
/// as "all displays", leaves the tab where it is; a display that's gone takes nothing.
@MainActor
func workspaceSidebarDropDisplay(for tab: Workspace, monitorScopeId: String?) -> WorkspaceSidebarDropDisplay {
    guard let monitorScopeId, monitorScopeId != workspaceSidebarDefaultScopeId else { return .stays }
    if let monitor = workspaceSidebarMonitor(forScopeId: monitorScopeId) {
        return tab.workspaceMonitor.rect == monitor.rect ? .stays : .moves(to: monitor)
    }
    // A display's scope that no longer resolves: it was unplugged or rearranged.
    return workspaceSidebarMonitorScopePoint(monitorScopeId) != nil ? .gone : .stays
}

/// The display a drop on the list for `monitorScopeId` brings `tab` to, if it isn't there already.
@MainActor
func workspaceSidebarDropDisplayChange(for tab: Workspace, monitorScopeId: String?) -> Monitor? {
    if case .moves(let monitor) = workspaceSidebarDropDisplay(for: tab, monitorScopeId: monitorScopeId) { monitor } else { nil }
}

/// Whether `tab` can go to the display of the list for `monitorScopeId`. A tab held to another
/// display can't, nor can any tab go to a display that's gone, so that list offers it no drop.
@MainActor
func workspaceSidebarDropCanReachDisplay(_ tab: Workspace, monitorScopeId: String?) -> Bool {
    switch workspaceSidebarDropDisplay(for: tab, monitorScopeId: monitorScopeId) {
        case .stays: true
        case .moves(let monitor): workspaceTabCanMove(tab, to: monitor)
        case .gone: false
    }
}

/// Throws before anything changes if `tab` can't go to the list's display.
@MainActor
func checkWorkspaceSidebarDropDisplay(_ tab: Workspace, monitorScopeId: String?) throws {
    switch workspaceSidebarDropDisplay(for: tab, monitorScopeId: monitorScopeId) {
        case .stays: return
        case .gone: throw WorkspaceMutationError.displayUnavailable
        case .moves(let monitor):
            guard workspaceTabCanMove(tab, to: monitor) else { throw WorkspaceMutationError.tabAssignedToAnotherDisplay }
    }
}

/// Runs `edit`, the pin or group change, after bringing `tab` to the display of the list it was
/// dropped on. If either fails, the move is undone along with the edit.
@MainActor
func withWorkspaceTabOnDropDisplay(_ tab: Workspace, monitorScopeId: String?, focusing window: Window?,
                                   _ edit: () throws -> Void) throws {
    try checkWorkspaceSidebarDropDisplay(tab, monitorScopeId: monitorScopeId)
    guard let monitor = workspaceSidebarDropDisplayChange(for: tab, monitorScopeId: monitorScopeId) else { return try edit() }
    let before = WorkspaceSidebarTabUndoSnapshot()
    syncClosedWindowsCacheToCurrentWorld()
    suppressPostDragAxObserverEvents(for: tab.allLeafWindowsRecursive.map(\.windowId))
    do {
        try moveWorkspaceTabToDisplay(tab, monitor, focusing: window)
        try edit()
    } catch {
        before.restore(replacing: WorkspaceSidebarTabUndoSnapshot())
        throw error
    }
}
