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
        if !workspaceSidebarHasRow(workspace, focusedWorkspace: currentFocus.workspace) { continue }
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

/// Whether the sidebar has a row for `workspace`. Automatic identities are kept for app
/// restoration, and a saved tab closing with its last window for its grace, without showing them
/// empty. Explicitly kept tabs and the active empty tab stay. In Tabs mode the list shows only the
/// rows of tabs `workspaceTabIsShown` (`isLeftEmpty` marks the others).
@MainActor
func workspaceSidebarHasRow(_ workspace: Workspace, focusedWorkspace: Workspace) -> Bool {
    if config.usesBrowserTabs, workspaceTabIsShown(workspace) { return true }
    guard let record = savedWorkspaceStore.record(named: workspace.name),
          record.keepWhenEmpty == false || workspaceTabClosesWithLastWindow(workspace)
    else { return true }
    return isUserFacingWorkspace(workspace, focusedWorkspace: focusedWorkspace)
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
    let isPinned = workspaceSidebarOrganizationStore.state.workspaces[workspace.name]?.isFavorite == true
    var lentWindow: WorkspaceSidebarWindowViewModel?
    if isPinned, let lent = workspaceSidebarLentWindow(of: workspace) {
        lentWindow = await makeWorkspaceSidebarWindowViewModel(for: lent, workspaceName: lent.nodeWorkspace?.name ?? workspace.name,
            currentFocus: currentFocus)
    }
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
        isLeftEmpty: config.usesBrowserTabs && !workspaceTabIsShown(workspace),
        knownDisplay: availableMonitors.count > 1 && config.workspaceSidebar.sharesPinnedTabs && isPinned
            ? workspaceSidebarTabKnownDisplay(workspace, among: availableMonitors) : nil,
        // Kept whether or not pins are shared: turning sharing on shows the pins before their
        // tabs are listed again, and a click must still tell a held one.
        heldMonitorScopeId: availableMonitors.count > 1 && isPinned ? workspaceSidebarTabHeldMonitorScopeId(workspace) : nil,
        lentWindow: lentWindow,
        recallsWindows: isPinned && workspaceSidebarPinRecallsWindows(workspace),
    )
}

/// The connected display `workspace` is on screen on, is held to, is saved on, or was last placed
/// on, in the order its listing uses them. Nil when it's none of these, or that display is gone:
/// then it's only listed on the focused or main display, which says nothing about where it is.
/// A saved home that's gone isn't replaced by the display now at its old coordinates.
@MainActor
func workspaceSidebarTabKnownDisplay(_ workspace: Workspace, among monitors: [Monitor]) -> WorkspaceSidebarTabDisplay? {
    let hasSavedHome = savedWorkspaceStore.record(named: workspace.name)?.display != nil
    let placed = workspace.visibleMonitor ?? workspace.forceAssignedMonitor ?? savedHomeMonitor(of: workspace)
        ?? (hasSavedHome ? nil : workspace.preferredMonitorPoint.flatMap { point in monitors.first { $0.rect.topLeftCorner == point } })
    guard let placed, let monitor = monitors.first(where: { $0.rect.topLeftCorner == placed.rect.topLeftCorner }) else { return nil }
    return .init(monitorScopeId: workspaceSidebarMonitorScopeId(for: monitor),
        displayName: workspaceSidebarMonitorDisplayName(monitor, among: monitors))
}

/// The display `workspace` is held to, as `workspaceTabCanMove` decides: its force assignment,
/// else a saved Keep on display whose display is connected.
@MainActor
func workspaceSidebarTabHeldMonitorScopeId(_ workspace: Workspace) -> String? {
    let held = workspace.forceAssignedMonitor
        ?? (savedWorkspaceStore.record(named: workspace.name)?.isPinnedToDisplay == true ? savedHomeMonitor(of: workspace) : nil)
    return held.map { workspaceSidebarMonitorScopeId(for: $0) }
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
