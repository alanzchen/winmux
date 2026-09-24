import Common
import Foundation

@MainActor
func buildWorkspaceSidebarWorkspaceViewModels(
    currentFocus: LiveFocus,
    workspaceLabels: [String: String],
    availableMonitors: [Monitor],
) async -> [WorkspaceSidebarWorkspaceViewModel] {
    var workspaces: [WorkspaceSidebarWorkspaceViewModel] = []
    // Read running apps once per build, and only when something is saved.
    let runningApps = savedWorkspaceStore.isEmpty ? nil : savedWorkspaceRuntime.environment.runningApps()
    for workspace in orderedWorkspacesForPresentation() {
        workspaces.append(await makeWorkspaceSidebarWorkspaceViewModel(
            workspace,
            currentFocus: currentFocus,
            workspaceLabels: workspaceLabels,
            availableMonitors: availableMonitors,
            runningApps: runningApps,
        ))
    }
    return workspaceSidebarIdentityLabels(workspaces, mode: config.workspaceSidebar.dockIdentityLabels)
}

@MainActor
private func makeWorkspaceSidebarWorkspaceViewModel(
    _ workspace: Workspace,
    currentFocus: LiveFocus,
    workspaceLabels: [String: String],
    availableMonitors: [Monitor],
    runningApps: [String: [SavedRunningApp]]?,
) async -> WorkspaceSidebarWorkspaceViewModel {
    let workspaceMonitor = workspace.workspaceMonitor
    return WorkspaceSidebarWorkspaceViewModel(
        name: workspace.name,
        projectId: workspace.projectId,
        displayName: workspaceDisplayName(workspace.name),
        sidebarLabel: workspaceLabels[workspace.name] ?? "",
        isGeneratedName: isSidebarDraftWorkspaceName(workspace.name) || workspace.usesAutomaticDisplayName,
        monitorScopeId: workspaceSidebarMonitorScopeId(for: workspaceMonitor),
        monitorName: availableMonitors.count > 1 ? workspaceMonitor.name : nil,
        isFocused: currentFocus.workspace == workspace,
        isVisible: workspace.isVisible,
        items: await buildWorkspaceSidebarItems(for: workspace, currentFocus: currentFocus),
        apps: buildWorkspaceSidebarAppSummaries(for: workspace),
        savedState: runningApps.flatMap { workspaceSidebarSavedState(for: workspace, runningApps: $0) },
    )
}

@MainActor
func workspaceSidebarSavedState(for workspace: Workspace, runningApps: [String: [SavedRunningApp]]) -> WorkspaceSidebarSavedState? {
    guard let record = savedWorkspaceStore.record(named: workspace.name) else { return nil }
    return WorkspaceSidebarSavedState(
        isPinnedToDisplay: record.isPinnedToDisplay,
        homeDisplayName: record.display?.name.takeIf { !$0.isEmpty },
        isHomeConnected: savedHomeMonitor(of: workspace) != nil,
        isForceAssignedByConfig: resolvedForceAssignedMonitor(forWorkspaceName: workspace.name) != nil,
        // WinMux doesn't open apps with --read-only, so it offers none.
        missingAppNames: serverArgs.isReadOnly ? [] : missingSavedWorkspaceApps(workspaceNames: [workspace.name], runningApps: runningApps).map { app in
            savedWorkspaceAppDisplayName(bundleId: app.bundleId, appName: app.appName, bundlePath: app.bundlePath)
        },
    )
}

func visibleWorkspaceNamesForSidebar(
    workspaces: [WorkspaceSidebarWorkspaceViewModel],
    selectedMonitorScopeId: String,
    focusedMonitorScopeId: String,
) -> Set<String> {
    Set(workspaces.filter {
        workspaceSidebarWorkspaceMatchesScope(
            $0,
            selectedScopeId: selectedMonitorScopeId,
            focusedMonitorScopeId: focusedMonitorScopeId,
        )
    }.map(\.name))
}
