import AppKit
import Common

/// Tabs mode: what becomes of a tab that isn't pinned once its last window has closed.
enum WorkspaceTabClosePolicy {
    /// How long a saved tab waits after its last window closed before it closes, and with it its
    /// name, label, group and saved places. Locking the screen blanks every window before WinMux
    /// learns it's locked (see closedWindowsCache), and the windows put back after that only find
    /// a tab by name. A tab that isn't saved has nothing to lose and closes at once, as before.
    static let delay: TimeInterval = 1
    /// Whether a tab whose app quit with its last window waits for the app to open again and bring
    /// its windows back, as saved tabs used to. Off: it closes like any other, and when the app opens
    /// again its windows open in new tabs, or in its empty pin.
    @MainActor static var waitsForAppRelaunch = false
}

/// Tabs mode: a tab that isn't pinned closes once its last window has closed, rather than staying
/// greyed, whether or not it's saved (renamed, grouped, made from a topic), and whether its app
/// keeps running or quit. A window moved to another tab didn't close. A workspace the config keeps
/// stays, and nothing changes while WinMux can't save the change.
@MainActor
func workspaceTabClosesWithLastWindow(_ tab: Workspace) -> Bool {
    tab.lastWindowClosedAt != nil && config.usesBrowserTabs && !tab.isArchived && !tab.isConfiguredPersistent &&
        workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite != true &&
        !serverArgs.isReadOnly && !savedWorkspaceStore.isReadOnly && workspaceSidebarOrganizationStore.readOnlyReason == nil &&
        !workspaceHasLifecycleWindows(tab)
}

/// Whether a saved tab closing with its last window waits a little longer: that may not have been
/// a close, or a window is still on its way to it. Only for the moment after the close; while
/// WinMux starts and restores windows; while capture is suspended, the lock screen is up or
/// displays settle; while a refresh still lists one of its windows or one is routed back to it;
/// while a window asked for it may still come; and with `WorkspaceTabClosePolicy.waitsForAppRelaunch`,
/// while its app is away or has only just opened again.
@MainActor
func workspaceTabCloseWaits(_ tab: Workspace, record: SavedWorkspaceRecord) -> Bool {
    let runtime = savedWorkspaceRuntime
    if isStartup || runtime.isStartupRestoreActive || runtime.isCaptureSuspended ||
        runtime.environment.frontmostAppBundleId() == lockScreenAppBundleId ||
        MonitorConfigurationObserver.shared.isSettling || runtime.workspacesAwaitingProject?.contains(tab.name) == true
    {
        return true
    }
    if let closedAt = tab.lastWindowClosedAt, runtime.now < closedAt.addingTimeInterval(WorkspaceTabClosePolicy.delay) {
        return true
    }
    if NewWindowIntentRegistry.shared.isWaitingForWindow(in: tab) { return true }
    let slots = record.layout.allSlots
    let windowIsBack = slots.contains { slot in
        guard let windowId = slot.lastWindowId, let pid = slot.lastPid else { return false }
        return runtime.aliveWindowPidsDuringRefresh[windowId] == pid || runtime.routingInFlightWindowIds.contains(windowId)
    }
    if windowIsBack { return true }
    guard WorkspaceTabClosePolicy.waitsForAppRelaunch else { return false }
    let facts = currentSavedWorkspaceCaptureFacts(titleByWindowId: [:])
    return slots.contains { savedSlotWaitsForItsAppToRelaunch($0, facts: facts) }
}

/// A window closed: `parent` is where it was. If it was its tab's last window, the tab closes with
/// it, unless the tab is pinned or the config keeps it: decided now, so a pin unpinned later stays
/// as it was. Not while capture is suspended or the lock screen is up: windows vanish then
/// without being closed.
@MainActor
func noteWindowClosed(_ window: Window, from parent: NonLeafTreeNodeObject) {
    guard config.usesBrowserTabs else { return }
    let runtime = savedWorkspaceRuntime
    let tab = parent.nodeWorkspace ?? minimizedWindowOwner(window, parent)
    guard let tab, !workspaceHasLifecycleWindows(tab), !tab.isConfiguredPersistent,
          workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite != true,
          !runtime.isCaptureSuspended, runtime.environment.frontmostAppBundleId() != lockScreenAppBundleId
    else { return }
    tab.hasHadWindows = true
    tab.lastWindowClosedAt = runtime.now
    if savedWorkspaceStore.contains(workspaceName: tab.name) { scheduleWorkspaceTabCloseCheck(closedAt: runtime.now) }
}

/// The tab a minimized window belonged to: minimized windows live outside every workspace.
@MainActor
private func minimizedWindowOwner(_ window: Window, _ parent: NonLeafTreeNodeObject) -> Workspace? {
    guard parent is MacosMinimizedWindowsContainer, case .macos(_, let name?) = window.layoutReason else { return nil }
    return Workspace.existing(byName: name)
}

/// Whether the windows that vanished from one refresh closed, so their tabs close with them. When
/// windows of several apps that are still running vanish at once, the screen is locking, which
/// blanks every window: their tabs stay. An app that quit took its own windows.
@MainActor
func vanishedWindowsCloseTheirTabs(_ windows: [Window], appIsRunning: (Window) -> Bool) -> Bool {
    Set(windows.filter(appIsRunning).map(\.app.pid)).count < 2
}

/// The screen locks, the Mac sleeps or logs out, or the session switches: a tab still waiting to
/// close may have lost its windows to that rather than to the user, so it stays as it was.
@MainActor
func keepTabsWaitingToClose() {
    for workspace in Workspace.all where workspace.lastWindowClosedAt != nil && !workspaceHasLifecycleWindows(workspace) {
        workspace.lastWindowClosedAt = nil
    }
}

/// Refreshes once a tab closed a moment ago may close: after `WorkspaceTabClosePolicy.delay`, or
/// once the startup restore is over. A refresh lists windows again first, so one that came back
/// keeps its tab.
@MainActor
private func scheduleWorkspaceTabCloseCheck(closedAt: Date) {
    guard !isUnitTest else { return }
    let runtime = savedWorkspaceRuntime
    var deadline = closedAt.addingTimeInterval(WorkspaceTabClosePolicy.delay)
    if let readyAt = runtime.runtimeReadyAt {
        deadline = max(deadline, readyAt.addingTimeInterval(SavedWorkspaceTiming.restoreWindow))
    }
    let delay = max(deadline.timeIntervalSince(runtime.now), 0) + 0.1
    _ = Task { @MainActor in
        try? await Task.sleep(for: .seconds(delay))
        scheduleRefreshSession(.globalObserver("workspaceTabClose"))
    }
}
