import AppKit
import Common

/// Whether the new window's app is the one the user is working in. Tests replace it.
@MainActor var newWindowAppIsFrontmost: @MainActor (Window) -> Bool = { window in
    window.app.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
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
