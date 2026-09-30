import AppKit

// Tabs mode with share-pinned-tabs: a project's pins are one collection, shown in one order on
// every display. Pinning a tab there, or rearranging the pins, changes only the pins: it never
// takes the tab to another display. Every other drop keeps its display, as on its own: a tab's
// window (to join or split it), a group, the list between tabs, and New Tab still bring the tab to
// the display whose list shows them. Without shared pins, pins belong to their display's list and
// a drop on them brings the tab there too, as between tabs.
//
// The rule is read when a drop is shown, and the drop made with the rule it was shown with.

/// Whether pin tiles are display-neutral: the pins every display shows are shared.
@MainActor
func workspaceSidebarPinGridIsShared() -> Bool {
    config.usesBrowserTabs && config.workspaceSidebar.sharePinnedTabs
}

/// Where a drop on the pin tiles of the list for `monitorScopeId` takes `tab`. Shared pins take
/// it nowhere, though a display that's gone still takes nothing.
@MainActor
func workspaceSidebarPinDropDisplay(for tab: Workspace, monitorScopeId: String?,
                                    pinGridIsShared: Bool) -> WorkspaceSidebarDropDisplay {
    let display = workspaceSidebarDropDisplay(for: tab, monitorScopeId: monitorScopeId)
    guard pinGridIsShared else { return display }
    if case .gone = display { return .gone }
    return .stays
}

/// The display a drop on pin tiles brings `tab` to, if any.
@MainActor
func workspaceSidebarPinDropDisplayChange(for tab: Workspace, monitorScopeId: String?, pinGridIsShared: Bool) -> Monitor? {
    if case .moves(let monitor) = workspaceSidebarPinDropDisplay(for: tab, monitorScopeId: monitorScopeId,
        pinGridIsShared: pinGridIsShared) { monitor } else { nil }
}

/// Whether `tab` may be dropped on those pin tiles. A tab held to its display can still be pinned
/// or rearranged among shared pins, since it doesn't move.
@MainActor
func workspaceSidebarPinDropCanReachDisplay(_ tab: Workspace, monitorScopeId: String?, pinGridIsShared: Bool) -> Bool {
    switch workspaceSidebarPinDropDisplay(for: tab, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared) {
        case .stays: true
        case .moves(let monitor): workspaceTabCanMove(tab, to: monitor)
        case .gone: false
    }
}

/// Throws before anything changes if `tab` can't be dropped on those pin tiles.
@MainActor
func checkWorkspaceSidebarPinDropDisplay(_ tab: Workspace, monitorScopeId: String?, pinGridIsShared: Bool) throws {
    guard pinGridIsShared else { return try checkWorkspaceSidebarDropDisplay(tab, monitorScopeId: monitorScopeId) }
    if case .gone = workspaceSidebarDropDisplay(for: tab, monitorScopeId: monitorScopeId) {
        throw WorkspaceMutationError.displayUnavailable
    }
}

/// Runs `edit`, the pin change, where a drop on those pin tiles puts `tab`: on the list's display
/// without shared pins, as `withWorkspaceTabOnDropDisplay` does, and where it is with them.
@MainActor
func withWorkspaceTabOnPinDropDisplay(_ tab: Workspace, monitorScopeId: String?, pinGridIsShared: Bool,
                                      focusing window: Window?, _ edit: () throws -> Void) throws {
    guard pinGridIsShared else {
        return try withWorkspaceTabOnDropDisplay(tab, monitorScopeId: monitorScopeId, focusing: window, edit)
    }
    try checkWorkspaceSidebarPinDropDisplay(tab, monitorScopeId: monitorScopeId, pinGridIsShared: true)
    try edit()
}

extension WorkspaceSidebarDropTargetKind {
    /// The pin tiles, as opposed to a tab, a group, the list or New Tab.
    var isPinTiles: Bool {
        if case .pinnedTabs = self { true } else { false }
    }
}
