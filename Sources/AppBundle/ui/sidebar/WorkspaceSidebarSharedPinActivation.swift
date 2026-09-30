import AppKit

// Shared pins: a pinned tab clicked on a display comes to that display, from wherever it is,
// hidden or on screen on another one. It moves as a tab dropped on that display's list does, and
// that display is recorded as its own, so it stays listed there. A tab held to its display, by
// `workspace-to-monitor-force-assignment` or a saved tab kept on its display, isn't brought:
// clicking it does what clicking another display's tab always has.

/// Whether a click on this shared pin in a list representing `representedMonitorScopeId` brings
/// it there instead of asking first. One held to another display asks, as other displays' tabs
/// do. The click itself checks again before anything moves.
func workspaceSidebarSharedPinComesToClick(_ workspace: WorkspaceSidebarWorkspaceViewModel, representedMonitorScopeId: String,
                                           sharesPinnedTabs: Bool) -> Bool {
    guard sharesPinnedTabs, workspace.appearance.isFavorite else { return false }
    return workspace.knownDisplay?.heldMonitorScopeId.map { $0 == representedMonitorScopeId } ?? true
}

/// The display a click in the panel for `targetMonitorScopeId` brings `tab` to: a shared pin on
/// another display, which may go there. Nil when the click activates it as any tab.
@MainActor
func workspaceSidebarSharedPinClickDestination(_ tab: Workspace, targetMonitorScopeId: String?) -> Monitor? {
    guard config.usesBrowserTabs, config.workspaceSidebar.sharesPinnedTabs,
          workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite == true,
          let targetMonitorScopeId, let monitor = workspaceSidebarMonitor(forScopeId: targetMonitorScopeId),
          tab.workspaceMonitor.rect != monitor.rect, workspaceTabCanMove(tab, to: monitor)
    else { return nil }
    return monitor
}

/// Brings `tab` to `monitor` and focuses it there, or `window` in it. The display it leaves shows
/// another tab. If it can't be shown there, everything goes back as it was.
@MainActor
func showSharedPinnedTab(_ tab: Workspace, on monitor: Monitor, focusing window: Window?) throws {
    let before = WorkspaceSidebarTabUndoSnapshot()
    do {
        try moveWorkspaceTabToDisplay(tab, monitor, focusing: window)
    } catch {
        before.restore(replacing: WorkspaceSidebarTabUndoSnapshot())
        throw error
    }
}

/// The shared pin a click on `name`, or on the window `windowId`, in the panel for
/// `targetMonitorScopeId` brings there. Nil when the click activates it as any tab.
@MainActor
func workspaceSidebarSharedPinClicked(_ name: String? = nil, windowId: UInt32? = nil,
                                      targetMonitorScopeId: String?) -> Workspace? {
    let tab = name.flatMap { Workspace.existing(byName: $0) } ?? windowId.flatMap { Window.get(byId: $0)?.nodeWorkspace }
    guard let tab, workspaceSidebarSharedPinClickDestination(tab, targetMonitorScopeId: targetMonitorScopeId) != nil
    else { return nil }
    return tab
}

/// Brings the shared pin `tab` to the display of the panel it was clicked in, focusing it or the
/// clicked `windowId` there. A saved pin whose windows are gone opens its apps once it's there.
@MainActor
@discardableResult
func showSharedPinnedTabFromSidebar(_ tab: Workspace, windowId: UInt32? = nil, opensSavedApps: Bool = false,
                                    targetMonitorScopeId: String?) -> Task<Void, Never>? {
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    let name = tab.name
    var shown: Workspace?
    return runWorkspaceSidebarSession(afterLayout: {
        guard opensSavedApps, let shown, winMuxWorkspaceState.workspaceById[shown.id] === shown,
              !workspaceHasLifecycleWindows(shown) else { return }
        openSavedTabApps(shown)
    }) {
        // The session runs after other events: the tab may have closed, moved, or given its name
        // away, and the display it was clicked on may have gone, which leaves everything as it is.
        guard Workspace.existing(byName: name) === tab, let targetMonitorScopeId,
              workspaceSidebarMonitor(forScopeId: targetMonitorScopeId) != nil else { return }
        let window = windowId.flatMap { Window.get(byId: $0) }.flatMap { $0.nodeWorkspace === tab ? $0 : nil }
        if let monitor = workspaceSidebarSharedPinClickDestination(tab, targetMonitorScopeId: targetMonitorScopeId) {
            try showSharedPinnedTab(tab, on: monitor, focusing: window)
        } else if let window {
            guard focusWindowFromSidebar(window, targetMonitorScopeId: targetMonitorScopeId) else { return }
        } else {
            guard focusWorkspaceFromSidebar(tab, targetMonitorScopeId: targetMonitorScopeId) else { return }
        }
        shown = tab
    }
}
