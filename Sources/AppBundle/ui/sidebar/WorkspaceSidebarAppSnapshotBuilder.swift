@MainActor
func workspaceSidebarWindowsForAppSummary(_ workspace: Workspace) -> [Window] {
    // Tab-group rows contain only representative windows. Walk every tiled leaf so an
    // app in a nested group is still included, then append independent floating windows.
    (workspace.rootTilingContainer.allLeafWindowsRecursive + workspace.floatingWindows)
        .filter(\.isBound)
}

@MainActor
func buildWorkspaceSidebarAppSummaries(for workspace: Workspace) -> [WorkspaceSidebarAppViewModel] {
    uniqueWorkspaceSidebarApps(workspaceSidebarWindowsForAppSummary(workspace).map { window in
        WorkspaceSidebarAppViewModel(
            name: window.app.name ?? window.app.rawAppBundleId ?? "Unknown App",
            bundleId: window.app.rawAppBundleId,
            bundlePath: window.app.bundlePath,
        )
    })
}
