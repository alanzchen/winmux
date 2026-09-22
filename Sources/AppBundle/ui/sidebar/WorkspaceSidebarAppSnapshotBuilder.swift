@MainActor
func workspaceSidebarWindowsForAppSummary(_ workspace: Workspace) -> [Window] {
    // Tab-group rows contain only representative windows. Walk every tiled leaf so an
    // app in a nested group is still included, then append independent floating windows.
    (workspace.rootTilingContainer.allLeafWindowsRecursive + workspace.floatingWindows
        + workspaceOwnedMinimizedWindows(workspace)
        + workspace.macOsNativeHiddenAppsWindowsContainer.allLeafWindowsRecursive
        + workspace.macOsNativeFullscreenWindowsContainer.allLeafWindowsRecursive)
        .filter(\.isBound)
}

@MainActor
func buildWorkspaceSidebarAppSummaries(for workspace: Workspace) -> [WorkspaceSidebarAppViewModel] {
    let windows = workspaceSidebarWindowsForAppSummary(workspace)
    let grouped = Dictionary(grouping: windows, by: workspaceSidebarAppIdentity)
    return uniqueWorkspaceSidebarApps(grouped.values.compactMap { matching in
        guard let window = matching.first else { return nil }
        return WorkspaceSidebarAppViewModel(
            name: window.app.name ?? window.app.rawAppBundleId ?? "Unknown App",
            bundleId: window.app.rawAppBundleId,
            bundlePath: window.app.bundlePath,
            contextTitle: matching.count == 1 ? cachedWindowTitle(for: window) : nil
        )
    })
}

@MainActor
func workspaceSidebarAppIdentity(_ window: Window) -> String {
    WorkspaceSidebarAppViewModel(name: window.app.name ?? window.app.rawAppBundleId ?? "Unknown App",
        bundleId: window.app.rawAppBundleId, bundlePath: window.app.bundlePath).id
}
