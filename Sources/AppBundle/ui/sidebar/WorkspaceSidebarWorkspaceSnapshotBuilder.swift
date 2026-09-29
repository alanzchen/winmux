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
        // Keep automatic identities reserved for app restoration without showing empty
        // tabs after their windows close. Explicitly kept tabs and the active empty tab stay.
        if savedWorkspaceStore.record(named: workspace.name)?.keepWhenEmpty == false,
           !isUserFacingWorkspace(workspace, focusedWorkspace: currentFocus.workspace) { continue }
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
        appearance: workspaceSidebarOrganizationStore.state.workspaces[workspace.name] ?? .init(),
        isLeftEmpty: workspaceTabWasLeftEmpty(workspace),
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
        missingAppNames: missingSavedWorkspaceApps(workspaceNames: [workspace.name], runningApps: runningApps).map { app in
            savedWorkspaceAppDisplayName(bundleId: app.bundleId, appName: app.appName, bundlePath: app.bundlePath)
        },
        keepWhenEmpty: record.keepWhenEmpty != false,
        apps: workspaceSidebarSavedApps(for: workspace),
    )
}

/// The apps a saved tab opens in: those of its saved windows, one per window, then any others its
/// windows had last, whose slots have expired.
@MainActor
func workspaceSidebarSavedApps(for workspace: Workspace) -> [WorkspaceSidebarSavedApp] {
    guard let record = savedWorkspaceStore.record(named: workspace.name) else { return [] }
    let slots = record.layout.allSlots.filter { $0.bundleId != winMuxAppId && $0.bundleId != lockScreenAppBundleId }
    let waiting = Set(slots.map(\.bundleId))
    let apps = slots.map { ($0.bundleId, $0.bundlePath, $0.appName) } +
        (record.launchApps ?? []).filter { !waiting.contains($0.bundleId) }.map { ($0.bundleId, $0.bundlePath, $0.appName) }
    return apps.map { bundleId, bundlePath, appName in
        WorkspaceSidebarSavedApp(bundleId: bundleId, bundlePath: bundlePath,
            name: savedWorkspaceAppDisplayName(bundleId: bundleId, appName: appName, bundlePath: bundlePath))
    }
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
