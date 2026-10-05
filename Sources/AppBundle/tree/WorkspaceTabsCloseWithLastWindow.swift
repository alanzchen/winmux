import AppKit
import Common

/// Tabs mode: what becomes of a tab that isn't pinned once its last window has closed.
enum WorkspaceTabClosePolicy {
    /// How long after a saved tab's last window went a refresh may confirm that it closed, and close
    /// the tab, and with it its name, label, group and saved places. Locking the screen blanks every
    /// window before WinMux learns it's locked (see closedWindowsCache), and the windows put back
    /// after that only find a tab by name. A tab that isn't saved has nothing to lose and closes at
    /// once, as before.
    static let delay: TimeInterval = 1
    /// Used instead when regular windows of several running apps went in one refresh, as they do
    /// when the screen locks: the lock has longer to show.
    static let ambiguousDelay: TimeInterval = 5
    /// Whether a tab whose app quit with its last window waits for the app to open again and bring
    /// its windows back, as saved tabs used to. Off: it closes like any other, and when the app opens
    /// again its windows open in new tabs, or in its empty pin.
    @MainActor static var waitsForAppRelaunch = false
}

/// A tab's last window went: which, when, and how long before a refresh may confirm it closed.
struct WorkspaceLastWindowClose {
    let at: Date
    /// None for an app that quit; see `workspaceTabCloseDelay`.
    let delay: TimeInterval
    let windowId: UInt32
    let pid: Int32

    var confirmableAt: Date { at.addingTimeInterval(delay) }
}

/// Tabs mode: a tab that isn't pinned closes once its last window has closed, rather than staying
/// greyed, whether or not it's saved (renamed, grouped, made from a topic), and whether its app
/// keeps running or quit. A window moved to another tab didn't close, nor did one WinMux finds
/// again. A workspace the config keeps stays, and nothing changes while WinMux can't save the change.
@MainActor
func workspaceTabClosesWithLastWindow(_ tab: Workspace) -> Bool {
    guard let close = tab.lastWindowClose, config.usesBrowserTabs, !tab.isArchived, !tab.isConfiguredPersistent,
          workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite != true,
          !serverArgs.isReadOnly, !savedWorkspaceStore.isReadOnly, workspaceSidebarOrganizationStore.readOnlyReason == nil,
          !workspaceHasLifecycleWindows(tab)
    else { return false }
    return Window.get(byId: close.windowId)?.app.pid != close.pid
}

/// Whether a saved tab closing with its last window still waits: until the reconcile right after
/// a refresh that listed every window again, starting once the close could be confirmed, found
/// the window still gone; and while something may still bring a window to it.
@MainActor
func workspaceTabCloseWaits(_ tab: Workspace, record: SavedWorkspaceRecord) -> Bool {
    guard let close = tab.lastWindowClose, let listing = completedWindowListing,
          listing.startedAt >= workspaceTabCloseConfirmableAt(close)
    else { return true }
    return workspaceTabCloseIsHeld(tab, record: record)
}

/// Once a refresh may confirm the close: a moment after it, or after the lock screen or a capture
/// suspension was last seen, when windows may not be back yet.
@MainActor
private func workspaceTabCloseConfirmableAt(_ close: WorkspaceLastWindowClose) -> Date {
    let lockedUntil = savedWorkspaceRuntime.lastSeenLockedAt?.addingTimeInterval(WorkspaceTabClosePolicy.delay) ?? .distantPast
    return max(close.confirmableAt, lockedUntil)
}

/// While WinMux starts and restores windows; while capture is suspended, the lock screen is up or
/// displays settle; while a refresh still lists one of its windows or one is routed back to it;
/// while a window asked for it may still come, or one of its apps' windows is choosing a saved
/// place; and with `WorkspaceTabClosePolicy.waitsForAppRelaunch`, while its app is away or has only
/// just opened again.
@MainActor
private func workspaceTabCloseIsHeld(_ tab: Workspace, record: SavedWorkspaceRecord) -> Bool {
    let runtime = savedWorkspaceRuntime
    if isStartup || runtime.isStartupRestoreActive || isLockedForWindowListing() ||
        MonitorConfigurationObserver.shared.isSettling || runtime.workspacesAwaitingProject?.contains(tab.name) == true ||
        NewWindowIntentRegistry.shared.isWaitingForWindow(in: tab)
    {
        return true
    }
    let slots = record.layout.allSlots
    let windowIsBack = slots.contains { slot in
        guard let windowId = slot.lastWindowId, let pid = slot.lastPid else { return false }
        return runtime.aliveWindowPidsDuringRefresh[windowId] == pid || runtime.routingInFlightWindowIds.contains(windowId)
    }
    if windowIsBack { return true }
    // A relaunched app's new windows may still take its saved places, once their titles are known.
    let bundleIds = Set(slots.map(\.bundleId))
    let isChoosingAPlace = runtime.windowsAwaitingTitle.keys.contains { bundleIds.contains(Window.get(byId: $0)?.app.rawAppBundleId ?? "") } ||
        runtime.routingInFlightWindowIds.contains { bundleIds.contains(Window.get(byId: $0)?.app.rawAppBundleId ?? "") }
    if isChoosingAPlace { return true }
    guard WorkspaceTabClosePolicy.waitsForAppRelaunch else { return false }
    let facts = currentSavedWorkspaceCaptureFacts(titleByWindowId: [:])
    return slots.contains { savedSlotWaitsForItsAppToRelaunch($0, facts: facts) }
}

/// A window closed: `parent` is where it was. If it was its tab's last window, the tab closes with
/// it, unless the tab is pinned or the config keeps it: decided now, so a pin unpinned later stays
/// as it was. A refresh may confirm the close `closeDelay` later.
@MainActor
func noteWindowClosed(_ window: Window, from parent: NonLeafTreeNodeObject, closeDelay: TimeInterval) {
    guard config.usesBrowserTabs else { return }
    let tab = parent.nodeWorkspace ?? minimizedWindowOwner(window, parent)
    guard let tab, !workspaceHasLifecycleWindows(tab), !tab.isConfiguredPersistent,
          workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite != true
    else { return }
    tab.hasHadWindows = true
    tab.lastWindowClose = WorkspaceLastWindowClose(at: savedWorkspaceRuntime.now, delay: closeDelay,
        windowId: window.windowId, pid: window.app.pid)
}

/// The tab a minimized window belonged to: minimized windows live outside every workspace.
@MainActor
private func minimizedWindowOwner(_ window: Window, _ parent: NonLeafTreeNodeObject) -> Workspace? {
    guard parent is MacosMinimizedWindowsContainer, case .macos(_, let name?) = window.layoutReason else { return nil }
    return Workspace.existing(byName: name)
}

/// How long after windows vanished from one refresh another may confirm that each closed. An app
/// that quit took its windows: at once. Regular windows of several running apps going together
/// is how the screen locking looks: `ambiguousDelay`. Otherwise `delay`.
@MainActor
func workspaceTabCloseDelay(forVanished windows: [Window], appIsRunning: @escaping (Window) -> Bool) -> (Window) -> TimeInterval {
    let runningPids = Set(windows.filter { appIsRunning($0) && !($0.parent is MacosPopupWindowsContainer) }.map(\.app.pid))
    let delay = runningPids.count < 2 ? WorkspaceTabClosePolicy.delay : WorkspaceTabClosePolicy.ambiguousDelay
    return { appIsRunning($0) ? delay : 0 }
}

// MARK: - Listing windows

/// A refresh's listing of every window, from when it started.
struct WindowListing {
    let startedAt: Date
    let wasUnlocked: Bool
}

/// The listing the reconcile under way follows, completed without the screen locked or capture
/// suspended. Only that reconcile may close a saved tab.
@TaskLocal var completedWindowListing: WindowListing? = nil

@MainActor
private func isLockedForWindowListing() -> Bool {
    savedWorkspaceRuntime.isCaptureSuspended || savedWorkspaceRuntime.environment.frontmostAppBundleId() == lockScreenAppBundleId
}

/// A refresh starts listing every window.
@MainActor
func beginWindowListing() -> WindowListing {
    let runtime = savedWorkspaceRuntime
    let isLocked = isLockedForWindowListing()
    // Locked now, or unlocked since the last listing: windows may not be back yet.
    if isLocked || runtime.wasLockedAtLastWindowListing { runtime.lastSeenLockedAt = runtime.now }
    runtime.wasLockedAtLastWindowListing = isLocked
    return WindowListing(startedAt: runtime.now, wasUnlocked: !isLocked)
}

/// The refresh has listed and registered every window: reconciles, closing saved tabs whose
/// windows it didn't find again.
@MainActor
func reconcileAfterWindowListing(_ listing: WindowListing) {
    let runtime = savedWorkspaceRuntime
    runtime.lastWindowListingStartedAt = listing.startedAt
    var completed: WindowListing? = listing
    if !listing.wasUnlocked || isLockedForWindowListing() {
        runtime.lastSeenLockedAt = runtime.now
        runtime.wasLockedAtLastWindowListing = true
        completed = nil
    }
    $completedWindowListing.withValue(completed) { Workspace.reconcileWorkspaceState() }
}

@MainActor private var workspaceTabCloseCheck: (at: Date, task: Task<Void, Never>)?

/// Refreshes once a saved tab waiting to close may be confirmed, unless a listing since has had its
/// chance. Not while the screen is locked or capture suspended: the unlock brings refreshes.
@MainActor
func scheduleWorkspaceTabCloseChecks() {
    guard !isUnitTest, !isLockedForWindowListing() else { return }
    let runtime = savedWorkspaceRuntime
    let restoreEnd = runtime.runtimeReadyAt?.addingTimeInterval(SavedWorkspaceTiming.restoreWindow) ?? .distantPast
    let lastListing = runtime.lastWindowListingStartedAt ?? .distantPast
    let deadline = Workspace.all.compactMap { tab -> Date? in
        guard let close = tab.lastWindowClose, tab.isSaved, workspaceTabClosesWithLastWindow(tab) else { return nil }
        let at = max(workspaceTabCloseConfirmableAt(close), restoreEnd)
        return at > lastListing ? at : nil
    }.min()
    guard let deadline else { return }
    if let pending = workspaceTabCloseCheck, pending.at <= deadline { return }
    workspaceTabCloseCheck?.task.cancel()
    let delay = max(deadline.timeIntervalSince(runtime.now), 0) + 0.1
    workspaceTabCloseCheck = (deadline, Task { @MainActor in
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        workspaceTabCloseCheck = nil
        scheduleRefreshSession(.globalObserver("workspaceTabClose"))
    })
}
