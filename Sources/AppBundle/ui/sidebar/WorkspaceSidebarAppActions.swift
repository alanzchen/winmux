@MainActor
func workspaceSidebarAppWindow(in workspace: Workspace, appId: String) -> Window? {
    let candidates = workspaceSidebarWindowsForAppSummary(workspace).filter { window in
        window.participatesInWorkspaceFocus &&
            window.lastKnownNativeMinimized != true &&
            window.lastKnownNativeFullscreen != true &&
            WorkspaceSidebarAppViewModel(
                name: window.app.name ?? window.app.rawAppBundleId ?? "Unknown App",
                bundleId: window.app.rawAppBundleId,
                bundlePath: window.app.bundlePath,
            ).id == appId
    }
    if let current = focus.windowOrNil, candidates.contains(where: { $0 === current }) {
        return current
    }
    let candidateIds = Set(candidates.map(\.windowId))
    func mostRecentCandidate(in node: TreeNode) -> Window? {
        if let window = node as? Window, candidateIds.contains(window.windowId) {
            return window
        }
        for child in node.childrenByMostRecentUse {
            if let candidate = mostRecentCandidate(in: child) { return candidate }
        }
        return nil
    }
    return mostRecentCandidate(in: workspace)
}

/// Resolve again when the action runs: app summaries can outlive a closed or moved window.
/// Complete monitor assignment and logical focus together before scheduling native focus.
@MainActor
func selectWorkspaceSidebarAppWindow(
    workspaceName: String,
    appId: String,
    targetMonitorScopeId: String? = nil,
    overrideWorkspaceInUse: Bool = false,
) -> Window? {
    guard let workspace = Workspace.existing(byName: workspaceName),
          let window = workspaceSidebarAppWindow(in: workspace, appId: appId),
          let liveFocus = window.toLiveFocusOrNil()
    else { return nil }

    // A panel removed during the click must not redirect the action to a different display.
    if let targetMonitorScopeId, workspaceSidebarMonitor(forScopeId: targetMonitorScopeId) == nil {
        return nil
    }
    if overrideWorkspaceInUse {
        guard let targetMonitorScopeId,
              let targetMonitor = workspaceSidebarMonitor(forScopeId: targetMonitorScopeId),
              overrideWorkspaceOnMonitorBySwappingActiveViewports(workspace, targetMonitor: targetMonitor)
        else { return nil }
    }
    guard focusWorkspaceFromSidebar(workspace, targetMonitorScopeId: targetMonitorScopeId),
          setFocus(to: liveFocus)
    else { return nil }
    return window
}

@MainActor
func focusAppFromSidebar(
    workspaceName: String,
    appId: String,
    targetMonitorScopeId: String? = nil,
    overrideWorkspaceInUse: Bool = false,
) {
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    var selectedWindow: Window?
    runWorkspaceSidebarSession(afterLayout: {
        guard let selectedWindow else { return }
        // Light sessions synchronize ordinary native focus after layout. Queue the explicit
        // raise last so that synchronization cannot cancel it with an activation-only job.
        raiseWorkspaceSidebarAppWindow(selectedWindow, expectedWorkspaceName: workspaceName)
    }) {
        selectedWindow = selectWorkspaceSidebarAppWindow(
            workspaceName: workspaceName,
            appId: appId,
            targetMonitorScopeId: targetMonitorScopeId,
            overrideWorkspaceInUse: overrideWorkspaceInUse,
        )
    }
}

@MainActor
func raiseWorkspaceSidebarAppWindow(_ window: Window, expectedWorkspaceName: String? = nil) {
    guard window.isBound,
          Window.get(byId: window.windowId) === window,
          focus.windowOrNil === window,
          window.participatesInWorkspaceFocus,
          window.lastKnownNativeMinimized != true,
          window.lastKnownNativeFullscreen != true,
          let workspace = window.nodeWorkspace,
          workspace.isVisible,
          expectedWorkspaceName == nil || workspace.name == expectedWorkspaceName
    else { return }
    if let macWindow = window as? MacWindow {
        // An explicit icon click must raise even when native and logical focus already match.
        macWindow.macApp.nativeFocus(macWindow.windowId, forceRaise: true)
    } else {
        window.nativeFocus()
    }
}
