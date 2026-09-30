import AppKit

// Tabs mode: every list belongs to one display, and a tab dropped on a list goes to its display,
// whether it lands between tabs, among the pins, or in a group. Without this, a tab pinned or
// grouped from another display stayed on its own one, while the list it was dropped on showed
// the drop and then nothing.

/// The display a drop on the list for `monitorScopeId` brings `tab` to: nil when the tab is
/// already there, or when the scope names no single display.
@MainActor
func workspaceSidebarDropDisplayChange(for tab: Workspace, monitorScopeId: String?) -> Monitor? {
    guard let monitor = monitorScopeId.flatMap(workspaceSidebarMonitor(forScopeId:)),
          tab.workspaceMonitor.rect != monitor.rect else { return nil }
    return monitor
}

/// Whether `tab` can go to the display of the list for `monitorScopeId`. A tab held to another
/// display can't, so that list offers it no drop.
@MainActor
func workspaceSidebarDropCanReachDisplay(_ tab: Workspace, monitorScopeId: String?) -> Bool {
    workspaceSidebarDropDisplayChange(for: tab, monitorScopeId: monitorScopeId).map { workspaceTabCanMove(tab, to: $0) } ?? true
}

/// Runs `edit`, the pin or group change, after bringing `tab` to the display of the list it was
/// dropped on. If either fails, the move is undone along with the edit.
@MainActor
func withWorkspaceTabOnDropDisplay(_ tab: Workspace, monitorScopeId: String?, focusing window: Window?,
                                   _ edit: () throws -> Void) throws {
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
