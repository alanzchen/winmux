import AppKit
import Common

/// Whether the new window's app is the one the user is working in. Tests replace it.
@MainActor var newWindowAppIsFrontmost: @MainActor (Window) -> Bool = { window in
    window.app.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
}

/// With `open-new-windows-in-new-workspace`, a window the user opens gets its own empty
/// workspace in the same project and display; in Tabs mode, a new tab right after the one it
/// opened from. Runs after `on-window-detected`, so a rule that already moved the window to
/// another workspace wins.
@MainActor
func shouldMoveNewWindowToNewWorkspace(_ window: Window, detectedIn initialWorkspace: Workspace?, isNewRegularWindow: Bool) -> Bool {
    guard config.opensNewWindowsInNewWorkspace, isNewRegularWindow, !isStartup,
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
    // Follow a window from the app in use, so it never lands out of sight. A window that
    // a background app opens waits in its new workspace without taking focus.
    _ = moveWindowToWorkspace(window, target, CmdIo(stdin: .emptyStdin),
        focusFollowsWindow: newWindowAppIsFrontmost(window), failIfNoop: true)
}
