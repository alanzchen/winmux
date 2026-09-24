import Common

@MainActor
func nextSidebarDraftWorkspaceName() -> String {
    clearOrphanedWorkspaceSidebarLabels()
    let nextIndex = lowestUnusedPositiveIndex(Set(winMuxWorkspaceState.workspaceIdByName.keys.compactMap(sidebarDraftWorkspaceIndex)))
    return "\(sidebarDraftWorkspacePrefix)\(nextIndex)"
}

@MainActor
func nextSidebarCreatedWorkspaceName(projectId: WorkspaceProjectId = workspaceProjectDefaultId, monitor: Monitor = mainMonitor) -> String {
    nextAutomaticWorkspaceName(projectId: projectId, monitor: monitor)
}

func isSidebarDraftWorkspaceName(_ name: String) -> Bool {
    name.hasPrefix(sidebarDraftWorkspacePrefix)
}

func sidebarDraftWorkspaceIndex(_ name: String) -> Int? {
    guard isSidebarDraftWorkspaceName(name) else { return nil }
    let suffix = name.replacingOccurrences(of: sidebarDraftWorkspacePrefix, with: "")
    return Int(suffix)
}

@MainActor
func clearWorkspaceSidebarLabelIfNeeded(_ workspaceName: String) {
    guard config.workspaceSidebar.workspaceLabels.removeValue(forKey: workspaceName) != nil else { return }
    if !isUnitTest {
        try? persistWorkspaceSidebarLabel(workspaceName: workspaceName, label: nil)
    }
}

@MainActor
func clearSidebarDraftWorkspaceLabelIfNeeded(_ workspaceName: String) {
    guard isSidebarDraftWorkspaceName(workspaceName) else { return }
    clearWorkspaceSidebarLabelIfNeeded(workspaceName)
}

/// True while WinMux starts: workspaces restored from window-state.json don't exist until the
/// startup refresh registers their windows, and clearing their labels before that would
/// delete them from the config.
@MainActor var isDeferringOrphanedWorkspaceLabelCleanup = false

@MainActor
func clearOrphanedWorkspaceSidebarLabels() {
    guard !isDeferringOrphanedWorkspaceLabelCleanup else { return }
    for workspaceName in config.workspaceSidebar.workspaceLabels.keys
    where winMuxWorkspaceState.workspace(named: workspaceName) == nil && !savedWorkspaceStore.contains(workspaceName: workspaceName)
    {
        clearWorkspaceSidebarLabelIfNeeded(workspaceName)
    }
}

@MainActor
func workspaceDefaultDisplayName(_ workspaceName: String) -> String {
    if let workspace = Workspace.existing(byName: workspaceName) {
        guard workspace.usesAutomaticDisplayName else { return workspaceName }
        if let index = automaticWorkspaceDisplayIndex(workspace, focusedWorkspace: focus.workspace)
            ?? automaticWorkspaceDisplayIndexFallback(workspaceName)
        {
            return "Workspace \(index)"
        }
        return workspaceName
    }
    if let index = sidebarDraftWorkspaceIndex(workspaceName) {
        return "Workspace \(index)"
    }
    return workspaceName
}

/// The TOML label, then the saved name, then the automatic name.
@MainActor
func workspaceDisplayName(_ workspaceName: String) -> String {
    if let configuredName = config.workspaceSidebar.workspaceLabels[workspaceName]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !configuredName.isEmpty
    {
        return configuredName
    }
    return savedWorkspaceDisplayName(workspaceName) ?? workspaceDefaultDisplayName(workspaceName)
}

/// TOML labels, with saved names filling in where a label is missing (a failed TOML write,
/// another config file, or an older WinMux that cleared it).
@MainActor
func effectiveWorkspaceSidebarLabels() -> [String: String] {
    var labels = config.workspaceSidebar.workspaceLabels
    guard !savedWorkspaceStore.isEmpty else { return labels }
    for record in savedWorkspaceStore.records {
        guard labels[record.workspaceName]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              let name = savedWorkspaceDisplayName(record.workspaceName)
        else { continue }
        labels[record.workspaceName] = name
    }
    return labels
}
