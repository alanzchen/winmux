import AppKit
import Common

/// Tabs mode: what becomes of a tab that isn't pinned once its last window has closed.
enum WorkspaceTabClosePolicy {
    /// Whether such a tab keeps its saved places for its app to open again and bring its windows
    /// back, when the app quit with them, as saved tabs used to. Off: they get the grace any closed
    /// window's place gets (`SavedWorkspaceTiming.closedWindowGrace`), then the tab's identity goes,
    /// and when the app opens again its windows open in new tabs, or in its empty pin.
    @MainActor static var waitsForAppRelaunch = false
}

/// Tabs mode: a tab that isn't pinned closes once its last window has closed, rather than staying
/// greyed, whether or not it's saved (renamed, grouped, made from a topic), and whether its app
/// keeps running or quit. It leaves the screen and the list at once. A saved one's name, label,
/// group and saved places stay reserved, out of sight, until its saved places run out their grace,
/// so a window back by then returns to it. A window moved to another tab didn't close. A workspace
/// the config keeps stays; nothing changes while WinMux starts and restores windows, or can't save
/// the change.
@MainActor
func workspaceTabClosesWithLastWindow(_ tab: Workspace) -> Bool {
    tab.lastWindowClosed && config.usesBrowserTabs && !tab.isArchived && !tab.isConfiguredPersistent &&
        workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite != true &&
        !isStartup && !savedWorkspaceRuntime.isStartupRestoreActive &&
        !serverArgs.isReadOnly && !savedWorkspaceStore.isReadOnly && workspaceSidebarOrganizationStore.readOnlyReason == nil &&
        !workspaceHasLifecycleWindows(tab)
}

/// Whether a saved tab closing with its last window keeps its identity a while longer, besides its
/// saved places' grace: a window asked for it may still come, or a window of one of its apps is
/// still choosing a saved place, as a relaunched app's new windows do while their titles arrive.
@MainActor
func workspaceTabCloseIsHeld(_ tab: Workspace, record: SavedWorkspaceRecord) -> Bool {
    if NewWindowIntentRegistry.shared.isWaitingForWindow(in: tab) { return true }
    let runtime = savedWorkspaceRuntime
    let bundleIds = Set(record.layout.allSlots.map(\.bundleId))
    return Set(runtime.windowsAwaitingTitle.keys).union(runtime.routingInFlightWindowIds).contains { windowId in
        Window.get(byId: windowId)?.app.rawAppBundleId.map(bundleIds.contains) == true
    }
}

/// A window closed: `parent` is where it was. If it was its tab's last window, the tab closes with
/// it, unless the tab is pinned or the config keeps it: decided now, so a pin unpinned later stays
/// as it was.
@MainActor
func noteWindowClosed(_ window: Window, from parent: NonLeafTreeNodeObject) {
    guard config.usesBrowserTabs else { return }
    let tab = parent.nodeWorkspace ?? minimizedWindowOwner(window, parent)
    guard let tab, !workspaceHasLifecycleWindows(tab), !tab.isConfiguredPersistent,
          workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite != true
    else { return }
    tab.hasHadWindows = true
    tab.lastWindowClosed = true
}

/// The tab a minimized window belonged to: minimized windows live outside every workspace.
@MainActor
private func minimizedWindowOwner(_ window: Window, _ parent: NonLeafTreeNodeObject) -> Workspace? {
    guard parent is MacosMinimizedWindowsContainer, case .macos(_, let name?) = window.layoutReason else { return nil }
    return Workspace.existing(byName: name)
}
