import Common

/// With `open-new-windows-in-new-workspace`, a window the user opens gets its own empty
/// workspace in the same project and display. Runs after `on-window-detected`, so a rule
/// that already placed the window wins.
@MainActor
func shouldMoveNewWindowToNewWorkspace(_ window: Window, detectedIn initialWorkspace: Workspace?, isNewRegularWindow: Bool) -> Bool {
    guard config.openNewWindowsInNewWorkspace, isNewRegularWindow, !isStartup,
          let initialWorkspace, window.nodeWorkspace === initialWorkspace,
          // Saved workspaces are still deciding where these windows belong.
          savedWorkspaceRuntime.windowsAwaitingTitle[window.windowId] == nil,
          !savedWorkspaceRuntime.routingInFlightWindowIds.contains(window.windowId)
    else { return false }
    // A window that opens into an empty workspace already has one to itself.
    return initialWorkspace.allLeafWindowsRecursive.contains { $0 !== window }
}

@MainActor
func moveNewWindowToNewWorkspaceIfNeeded(_ window: Window, detectedIn initialWorkspace: Workspace?, isNewRegularWindow: Bool) {
    guard shouldMoveNewWindowToNewWorkspace(window, detectedIn: initialWorkspace, isNewRegularWindow: isNewRegularWindow),
          let initialWorkspace else { return }
    let target = getOrCreateAdjacentBlankWorkspace(
        projectId: initialWorkspace.projectId,
        monitor: window.nodeMonitor ?? initialWorkspace.workspaceMonitor,
    )
    guard target !== initialWorkspace else { return }
    // Focus stays put here. When the app focuses its new window, as it usually does,
    // the refresh follows native focus to the new workspace.
    _ = moveWindowToWorkspace(window, target, CmdIo(stdin: .emptyStdin), focusFollowsWindow: false, failIfNoop: true)
}
