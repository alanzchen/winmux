@MainActor
func workspaceSidebarWindowsForAppSummary(_ workspace: Workspace) -> [Window] {
    WorkspaceTabSnapshot(workspace).lifecycleMembers.map(\.window)
}

@MainActor
func buildWorkspaceSidebarAppSummaries(for workspace: Workspace) -> [WorkspaceSidebarAppViewModel] {
    buildWorkspaceSidebarAppSummaries(WorkspaceTabSnapshot(workspace))
}

@MainActor
func buildWorkspaceSidebarAppSummaries(_ content: WorkspaceTabSnapshot) -> [WorkspaceSidebarAppViewModel] {
    let windows = content.lifecycleMembers.map(\.window)
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
