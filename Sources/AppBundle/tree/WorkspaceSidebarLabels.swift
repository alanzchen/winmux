import Common

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

/// Whether `workspaceName` has a non-empty label in `[workspace-sidebar.workspace-labels]`
/// (from `winmux.toml` or set by renaming in the sidebar/UI).
@MainActor
func workspaceNameHasConfiguredLabel(_ workspaceName: String) -> Bool {
    config.workspaceSidebar.workspaceLabels[workspaceName]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty == false
}

/// Canonical numbers always name positions. A nonnumeric configured binding
/// can name the exact display label instead (for example `workspace Notes` for tab "2").
/// Merely having the stock `workspace 2` binding never makes the backing name "2" an override.
@MainActor
func configuredLabelWorkspaceName(named target: String, from current: Workspace) -> String? {
    if parsePositiveWorkspaceDisplayIndex(target) != nil { return nil }
    if workspaceNameHasConfiguredLabel(target) { return target }
    // Display labels are aliases; an existing literal workspace name keeps its meaning.
    if Workspace.existing(byName: target) != nil { return nil }
    let commands = config.modes.values.flatMap { mode in
        mode.bindings.values.flatMap(\.commands) + mode.tapBindings.values.flatMap(\.commands) +
            mode.sequenceBindings.values.flatMap(\.commands)
    }
    let isBound = commands.contains { command in
        if let command = command as? WorkspaceCommand { return command.args.target.val.workspaceNameOrNil()?.raw == target }
        if let command = command as? MoveNodeToWorkspaceCommand { return command.args.target.val.workspaceNameOrNil()?.raw == target }
        return false
    }
    guard isBound else { return nil }
    let project = workspaceContextProjectId(of: current)
    let matches = config.workspaceSidebar.workspaceLabels.filter { _, label in
        label.trimmingCharacters(in: .whitespacesAndNewlines) == target
    }.keys
    guard !matches.isEmpty else { return nil }
    let local = matches.filter { name in
        Workspace.existing(byName: name).map { !$0.isArchived && $0.projectId == project } == true
    }
    if local.count == 1 { return local.first }
    // A known but unavailable/ambiguous label must not fall through and create another name.
    return matches.count == 1 ? matches.first : target
}

/// Only an absent name can be assigned to the caller's project. Existing foreign or archived
/// workspaces are unavailable; callers must not turn that rejection into an unscoped fallback.
@MainActor
func resolveConfiguredLabelWorkspaceTarget(
    named workspaceName: String,
    from current: Workspace,
    monitor: Monitor,
) -> Workspace? {
    guard workspaceNameHasConfiguredLabel(workspaceName) else { return nil }
    let project = workspaceContextProjectId(of: current)
    if let existing = Workspace.existing(byName: workspaceName) {
        return !existing.isArchived && existing.projectId == project ? existing : nil
    }
    let workspace = Workspace.get(byName: workspaceName)
    workspace.assignProject(project)
    workspace.seedMonitorIfNeeded(monitor)
    return workspace
}

@MainActor
func clearWorkspaceSidebarLabelIfNeeded(_ workspaceName: String) {
    // D-S3-1: the live config may be an incomplete reading of the file; its labels stay, in memory and on disk.
    guard !configWriteBackSuspended else { return }
    guard config.workspaceSidebar.workspaceLabels.removeValue(forKey: workspaceName) != nil else { return }
    if !isUnitTest {
        try? persistWorkspaceSidebarLabel(workspaceName: workspaceName, label: nil)
    }
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
        if let index = automaticWorkspaceDisplayIndex(workspace)
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
