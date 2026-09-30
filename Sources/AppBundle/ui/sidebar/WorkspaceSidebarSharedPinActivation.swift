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
    return workspace.heldMonitorScopeId.map { $0 == representedMonitorScopeId } ?? true
}

/// The display a click in the panel for `targetMonitorScopeId` brings `tab` to: a shared pin on
/// another display, which may go there. Nil when the click activates it where it is.
@MainActor
func workspaceSidebarSharedPinClickDestination(_ tab: Workspace, targetMonitorScopeId: String?) -> Monitor? {
    guard let monitor = workspaceSidebarSharedPinClickMonitor(tab, targetMonitorScopeId: targetMonitorScopeId),
          tab.workspaceMonitor.rect != monitor.rect else { return nil }
    return monitor
}

/// The clicked panel's display, for a shared pin that may be shown there, wherever it is now.
@MainActor
private func workspaceSidebarSharedPinClickMonitor(_ tab: Workspace, targetMonitorScopeId: String?) -> Monitor? {
    guard config.usesBrowserTabs, config.workspaceSidebar.sharesPinnedTabs,
          workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite == true,
          let targetMonitorScopeId, let monitor = workspaceSidebarMonitor(forScopeId: targetMonitorScopeId),
          workspaceTabCanMove(tab, to: monitor)
    else { return nil }
    return monitor
}

/// Brings `tab` to `monitor` and focuses it there, or `window` in it. The display it leaves shows
/// another tab. If it can't be shown there, everything goes back as it was. `move` is for tests.
@MainActor
func showSharedPinnedTab(_ tab: Workspace, on monitor: Monitor, focusing window: Window?,
                         move: @MainActor (Workspace, Monitor, Window?) throws -> Void = moveWorkspaceTabToDisplay) throws {
    let before = WorkspaceSidebarTabUndoSnapshot()
    do {
        try move(tab, monitor, window)
    } catch {
        before.restore(replacing: WorkspaceSidebarTabUndoSnapshot())
        throw error
    }
}

/// The shared pin a click on `name`, or on the window `windowId`, in the panel for
/// `targetMonitorScopeId` goes to: every one that may be shown on that display, wherever it is
/// when the click comes, since it may move before the click's session runs. Nil for a pin held
/// to another display, and without shared pins: the click activates it as any tab.
@MainActor
func workspaceSidebarSharedPinClicked(_ name: String? = nil, windowId: UInt32? = nil,
                                      targetMonitorScopeId: String?) -> Workspace? {
    // A window that closed just now is found in the sidebar's last list, as any click finds it.
    let tab = name.flatMap { Workspace.existing(byName: $0) } ?? windowId.flatMap {
        Window.get(byId: $0)?.nodeWorkspace ?? workspaceSidebarFallbackWorkspaceName(for: $0).flatMap(Workspace.existing(byName:))
    }
    guard let tab, workspaceSidebarSharedPinClickMonitor(tab, targetMonitorScopeId: targetMonitorScopeId) != nil
    else { return nil }
    return tab
}

/// A click on the shared pin `tab`, or on its window `windowId`, in the panel for
/// `targetMonitorScopeId`. The session decides where the pin is: on another display, it comes to
/// this one; here, it's focused as any tab. `proceeds`, checked when the session runs, before
/// anything moves, can call it off. `afterShown` runs after the layout, once it's here.
@MainActor
@discardableResult
func showSharedPinnedTabFromSidebar(_ tab: Workspace, windowId: UInt32? = nil, targetMonitorScopeId: String?,
                                    proceeds: (@MainActor () -> Bool)? = nil,
                                    afterShown: (@MainActor (Workspace) -> Void)? = nil) -> Task<Void, Never>? {
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    if windowId == nil, workspaceSidebarSharedPinClickDestination(tab, targetMonitorScopeId: targetMonitorScopeId) == nil {
        optimisticallyMarkWorkspaceFocusedInSidebar(tab.name)
    }
    let name = tab.name
    var shown: Workspace?
    return runWorkspaceSidebarSession(afterLayout: {
        guard let shown, winMuxWorkspaceState.workspaceById[shown.id] === shown else { return }
        afterShown?(shown)
    }) {
        // The session runs after other events: the tab may have closed, moved, or given its name
        // away, and the display it was clicked on may have gone, which leaves everything as it is.
        guard Workspace.existing(byName: name) === tab, let targetMonitorScopeId,
              workspaceSidebarMonitor(forScopeId: targetMonitorScopeId) != nil, proceeds?() ?? true else { return }
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

/// A saved shared pin whose windows are gone opens its apps once it's here, if they're still
/// gone. Replaceable for tests.
@MainActor
var openSharedPinnedTabApps: @MainActor (Workspace) -> Void = { shown in
    if !workspaceHasLifecycleWindows(shown) { openSavedTabApps(shown) }
}

/// Each browser tab chosen from the sidebar, in order. Choosing one of a pin on another display
/// waits for the pin to come; if another is chosen meanwhile, the first isn't chosen after it.
@MainActor
private var workspaceSidebarBrowserTabChoices = 0

@MainActor
func noteWorkspaceSidebarBrowserTabChoice() -> Int {
    workspaceSidebarBrowserTabChoices &+= 1
    return workspaceSidebarBrowserTabChoices
}

@MainActor
func workspaceSidebarBrowserTabChoiceIsLatest(_ choice: Int) -> Bool {
    choice == workspaceSidebarBrowserTabChoices
}

/// Whether choosing `target` may go ahead, as choosing it checks: browser tabs shown, WinMux on and
/// writable, and its window still the one the browser listed it in.
@MainActor
func workspaceSidebarBrowserTabCanBeChosen(_ target: BrowserTabTarget) -> Bool {
    config.workspaceSidebar.usesTabsList && config.workspaceSidebar.browserTabs && TrayMenuModel.shared.isEnabled
        && !serverArgs.isReadOnly && Window.get(byId: target.windowId)?.app.pid == target.pid
}
