import AppKit
import Common

/// Whether the new window's app is the one the user is working in. Tests replace it.
@MainActor var newWindowAppIsFrontmost: @MainActor (Window) -> Bool = { window in
    window.app.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
}

/// What a window a refresh listed but hasn't registered yet is, as its registration will classify
/// it; nil when its app isn't known. Tests replace it.
@MainActor var registeringWindowType: @MainActor (_ windowId: UInt32, _ pid: Int32) async throws -> AxUiElementWindowType? = { windowId, pid in
    guard let app = MacApp.allAppsMap[pid] else { return nil }
    return try await app.getAxUiElementWindowType(windowId, getWindowLevel(for: windowId))
}

/// With `open-new-windows-in-new-workspace`, a window the user opens gets its own empty
/// workspace in the same project and display; in Tabs mode, a new tab right after the one it
/// opened from. Runs after `on-window-detected`, so a rule that already moved the window to
/// another workspace wins. Tabs also separate existing, unrestored windows on startup.
@MainActor
func shouldMoveNewWindowToNewWorkspace(_ window: Window, detectedIn initialWorkspace: Workspace?, isNewRegularWindow: Bool) -> Bool {
    guard config.opensNewWindowsInNewWorkspace, isNewRegularWindow, !isStartup || config.usesBrowserTabs,
          let initialWorkspace, window.nodeWorkspace === initialWorkspace,
          // An app being restored into saved workspaces waits for its window's title, then
          // places it in a saved slot. Moving it meanwhile would only make it jump twice.
          savedWorkspaceRuntime.windowsAwaitingTitle[window.windowId] == nil
    else { return false }
    // A window that opens into an empty workspace already has one to itself.
    return initialWorkspace.allLeafWindowsRecursive.contains { $0 !== window }
}

/// Tabs mode: a pin with no window is its app's home. A window that would get a new tab goes into
/// the first such pin of its app the window's display lists instead, while WinMux knows no other
/// window of that app: then no window of it is in use anywhere, so this one isn't an unrelated
/// window the pin would take. Its saved place may have expired while the app hid the window, or
/// the app opens a new one.
///
/// A refresh registers windows one by one. Other windows of the app it listed but hasn't
/// registered yet are classified first, as their registration will: popups don't count, while
/// windows, dialogs and any AX can't tell about do. The window then goes to the pin only if
/// nothing has placed it meanwhile and the pin is still free. Returns whether it went there.
@MainActor
func moveNewWindowToEmptyPinIfNeeded(_ window: Window, detectedIn initialWorkspace: Workspace?, isNewRegularWindow: Bool) async -> Bool {
    guard emptyPinHome(for: window, detectedIn: initialWorkspace, isNewRegularWindow: isNewRegularWindow) != nil else { return false }
    let registering = windowsBeingRegistered(with: window)
    for (windowId, pid) in registering {
        guard (try? await registeringWindowType(windowId, pid)) == .popup else { return false }
    }
    // Asking took a while: the window, its tab, the pin and the app's windows may have changed.
    guard windowsBeingRegistered(with: window).allSatisfy({ other in registering.contains { $0.windowId == other.windowId } }),
          let (pin, monitor) = emptyPinHome(for: window, detectedIn: initialWorkspace, isNewRegularWindow: isNewRegularWindow)
    else { return false }
    // A shared pin with no window isn't on any display yet: it comes to this one, as a click
    // brings it, so the window stays on the display it opened on.
    if pin.workspaceMonitor.rect.topLeftCorner != monitor.rect.topLeftCorner {
        pin.preferredMonitorPoint = monitor.rect.topLeftCorner
        noteSavedWorkspacePlacedByUser(pin, on: monitor)
    }
    // Focus as for a new tab: it follows a window from the app in use.
    _ = moveWindowToWorkspace(window, pin, CmdIo(stdin: .emptyStdin),
        focusFollowsWindow: !isStartup && newWindowAppIsFrontmost(window), failIfNoop: true)
    return window.nodeWorkspace === pin
}

/// The empty pin that would take the window now, and the display it opened on: none once a claim,
/// a title wait, a rule or the user has placed it, or once WinMux has registered another window
/// of its app.
@MainActor
private func emptyPinHome(for window: Window, detectedIn initialWorkspace: Workspace?,
                          isNewRegularWindow: Bool) -> (pin: Workspace, monitor: Monitor)? {
    guard config.usesBrowserTabs, !serverArgs.isReadOnly, !savedWorkspaceStore.isReadOnly,
          shouldMoveNewWindowToNewWorkspace(window, detectedIn: initialWorkspace, isNewRegularWindow: isNewRegularWindow),
          NewWindowIntentRegistry.shared.pendingClaim(windowId: window.windowId) == nil,
          let initialWorkspace, let bundleId = window.app.rawAppBundleId,
          bundleId != winMuxAppId, bundleId != lockScreenAppBundleId,
          !appHasOtherRegisteredWindow(window, bundleId: bundleId)
    else { return nil }
    let monitor = window.nodeMonitor ?? initialWorkspace.workspaceMonitor
    return firstEmptyPin(bundleId: bundleId, projectId: workspaceContextProjectId(of: initialWorkspace), monitor: monitor)
        .map { ($0, monitor) }
}

/// The first pin listed on `monitor`'s display for `projectId` with no window at all, whose apps
/// include `bundleId`: its saved apps, or its saved places' apps. Pins in All Projects come first,
/// then the project's own, each in their tiles' order. A pin on screen, or another display's
/// unless shared pins bring it here, is never one.
@MainActor
private func firstEmptyPin(bundleId: String, projectId: WorkspaceProjectId, monitor: Monitor) -> Workspace? {
    (workspacePinnedTabsInAllProjects() + workspacePinnedTabs(in: projectId)).first { pin in
        guard !pin.isArchived, !pin.isVisible, !workspaceHasLifecycleWindows(pin),
              let record = savedWorkspaceStore.record(named: pin.name),
              (record.launchApps ?? []).contains(where: { $0.bundleId == bundleId }) ||
              record.layout.allSlots.contains(where: { $0.bundleId == bundleId })
        else { return false }
        if pin.workspaceMonitor.rect.topLeftCorner == monitor.rect.topLeftCorner { return true }
        return config.workspaceSidebar.sharesPinnedTabs && !MonitorConfigurationObserver.shared.isSettling && workspaceTabCanMove(pin, to: monitor)
    }
}

/// Whether WinMux has registered another window of the app, in any of its processes: in a
/// workspace, minimized, hidden or full screen, as a pin reopen counts them.
@MainActor
private func appHasOtherRegisteredWindow(_ window: Window, bundleId: String) -> Bool {
    registeredSavedWorkspaceWindows().contains {
        $0 !== window && $0.app.rawAppBundleId == bundleId && $0.isBound && !($0.parent is MacosPopupWindowsContainer)
    }
}

/// The other windows of the app, in any of its processes, that the refreshes under way listed
/// and haven't registered yet, by id.
@MainActor
private func windowsBeingRegistered(with window: Window) -> [(windowId: UInt32, pid: Int32)] {
    let runtime = savedWorkspaceRuntime
    let bundleId = window.app.rawAppBundleId
    return runtime.aliveWindowPidsDuringRefresh.filter { windowId, pid in
        windowId != window.windowId && Window.get(byId: windowId) == nil &&
            (pid == window.app.pid || bundleId != nil && runtime.bundleIdsByPidDuringRefresh[pid] == bundleId)
    }.map { (windowId: $0.key, pid: $0.value) }.sorted { $0.windowId < $1.windowId }
}

@MainActor
func moveNewWindowToNewWorkspaceIfNeeded(_ window: Window, detectedIn initialWorkspace: Workspace?, isNewRegularWindow: Bool) {
    guard shouldMoveNewWindowToNewWorkspace(window, detectedIn: initialWorkspace, isNewRegularWindow: isNewRegularWindow),
          let initialWorkspace else { return }
    let monitor = window.nodeMonitor ?? initialWorkspace.workspaceMonitor
    let target = config.usesBrowserTabs
        ? createWorkspaceForNewWindow(openedFrom: initialWorkspace, monitor: monitor)
        : getOrCreateAdjacentBlankWorkspace(projectId: initialWorkspace.projectId, monitor: monitor)
    guard target !== initialWorkspace else { return }
    // Only a window opened from the same app in the active tab inherits organization.
    // Restoration and window-detected rules have already had the first chance to route it.
    var inheritedGroupId: String?
    if config.usesBrowserTabs, !isStartup, !savedWorkspaceRuntime.isStartupRestoreActive,
       workspaceSidebarOrganizationStore.readOnlyReason == nil, !savedWorkspaceStore.isReadOnly,
       newWindowAppIsFrontmost(window), let opener = focus.windowOrNil,
       opener !== window, opener.nodeWorkspace === initialWorkspace, opener.app.pid == window.app.pid,
       let group = workspaceSidebarOrganizationStore.collection(containing: initialWorkspace.name) {
        inheritedGroupId = group.id
    }
    // Follow a window from the app in use, so it never lands out of sight. A window that
    // a background app opens waits in its new workspace without taking focus. Startup
    // enumeration must not activate every existing window from the frontmost app.
    _ = moveWindowToWorkspace(window, target, CmdIo(stdin: .emptyStdin),
        focusFollowsWindow: !isStartup && newWindowAppIsFrontmost(window), failIfNoop: true)
    if window.nodeWorkspace === target, let inheritedGroupId {
        do { try assignWorkspaceToSidebarCollection(target, collectionId: inheritedGroupId, keepWhenEmpty: false) }
        catch { showWorkspaceSidebarError(error.localizedDescription) }
    }
}
