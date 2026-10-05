import AppKit
import Common

extension Workspace {
    /// Saved identities reserve their name and can restore windows after a restart.
    @MainActor
    var isSaved: Bool { savedWorkspaceStore.contains(workspaceName: name) }

    /// A saved tab stays when its windows go, unless it closes with its last window: see
    /// `workspaceTabClosesWithLastWindow`.
    @MainActor
    var isKeptWhenEmpty: Bool {
        isConfiguredPersistent || !workspaceTabClosesWithLastWindow(self) &&
            savedWorkspaceStore.record(named: name).map { $0.keepWhenEmpty != false } == true
    }

    /// Let startup/title routing finish before deciding that an automatically grouped tab
    /// is empty. In read-only mode its persisted identity must remain reserved. A tab closing
    /// with its last window is kept, out of sight, the same way.
    @MainActor
    var isAwaitingSavedWorkspaceRestoration: Bool {
        guard let record = savedWorkspaceStore.record(named: name) else { return false }
        let closesWithLastWindow = workspaceTabClosesWithLastWindow(self)
        return isStartup || savedWorkspaceRuntime.isStartupRestoreActive ||
            !savedWorkspaceRuntime.windowsAwaitingTitle.isEmpty || savedWorkspaceStore.isReadOnly ||
            workspaceSidebarOrganizationStore.readOnlyReason != nil || savedWorkspaceRuntime.isCaptureSuspended ||
            savedWorkspaceRuntime.workspacesAwaitingProject?.contains(name) == true ||
            ((record.keepWhenEmpty == false || closesWithLastWindow) && !record.layout.allSlots.isEmpty) ||
            closesWithLastWindow && workspaceTabCloseIsHeld(self, record: record)
    }
}

/// Use the existing Cmd-W/Cmd-Q restoration policy before pruning automatic identities.
/// Capture drops windows moved to another tab immediately, waits briefly for a closed
/// window, and preserves slots for an app that quit or is still restoring. Empty automatic
/// tabs waiting for restoration are not user-facing unless currently on screen.
@MainActor
func captureAutomaticWorkspaceIdentitiesBeforePruning() {
    let runtime = savedWorkspaceRuntime
    guard !isStartup, !runtime.isStartupRestoreActive, !runtime.isCaptureSuspended,
          !savedWorkspaceStore.isReadOnly, !MonitorConfigurationObserver.shared.isSettling,
          runtime.environment.frontmostAppBundleId() != lockScreenAppBundleId else { return }
    let empty = Workspace.all.filter { workspace in
        guard let record = savedWorkspaceStore.record(named: workspace.name) else { return false }
        return !workspaceHasLifecycleWindows(workspace) && (record.keepWhenEmpty == false || workspaceTabClosesWithLastWindow(workspace)) &&
            runtime.workspacesAwaitingProject?.contains(workspace.name) != true
    }
    guard !empty.isEmpty else { return }
    let facts = currentSavedWorkspaceCaptureFacts(titleByWindowId: [:])
    for workspace in empty { captureSavedWorkspace(named: workspace.name, facts: facts) }
}

/// A split member can be assigned a group before it is bound into its new tab. Record the
/// window immediately after binding so an immediate quit/relaunch can restore that tab.
@MainActor
func captureNewAutomaticWorkspaceIdentity(_ workspace: Workspace) {
    guard savedWorkspaceStore.record(named: workspace.name)?.keepWhenEmpty == false,
          !savedWorkspaceStore.isReadOnly else { return }
    let layout = snapshotSavedWorkspaceLayoutNow(workspace)
    if savedWorkspaceStore.update(named: workspace.name, { $0.layout = layout }) {
        savedWorkspaceStore.flushNow()
    }
}

/// Registers every saved workspace name before anything can hand it out as an automatic name.
/// Also runs at the start of every reconcile as a self-heal.
@MainActor
func materializeSavedWorkspaceNames() {
    guard !savedWorkspaceStore.isEmpty else { return }
    for record in savedWorkspaceStore.records where winMuxWorkspaceState.workspace(named: record.workspaceName) == nil {
        let workspace = Workspace.get(byName: record.workspaceName)
        workspace.restoreNamingStyle(record.namingStyle)
        workspace.lifecycle = .durable
        guard record.projectId != workspaceProjectDefaultId else { continue }
        if winMuxWorkspaceState.projectsById[record.projectId] != nil {
            workspace.assignProject(record.projectId)
        } else {
            savedWorkspaceRuntime.workspacesAwaitingProject?.insert(record.workspaceName)
        }
    }
}

@MainActor
func noteSavedWorkspaceConfigLoaded() {
    savedWorkspaceRuntime.isConfigLoaded = true
}

/// Moves saved workspaces into their saved projects. Projects only exist once the TOML config
/// is loaded, so this runs from materializePersistedWorkspaceProjects. The first pass places
/// every saved workspace in saved order, which also restores the order inside each project.
/// A workspace whose project isn't registered waits in Default and keeps its saved project:
/// a config that fails to load, or another --config-path, must not move it for good. Each
/// workspace is placed once, so later passes never undo the user's own moves.
@MainActor
func assignSavedWorkspacesToProjectsIfNeeded() {
    let runtime = savedWorkspaceRuntime
    guard runtime.isConfigLoaded, !savedWorkspaceStore.isEmpty else { return }
    let isFirstPass = runtime.workspacesAwaitingProject == nil
    let awaiting = runtime.workspacesAwaitingProject ?? []
    guard isFirstPass || !awaiting.isEmpty else { return }
    var stillAwaiting: Set<String> = []
    for record in savedWorkspaceStore.records where isFirstPass || awaiting.contains(record.workspaceName) {
        guard let workspace = Workspace.existing(byName: record.workspaceName) else { continue }
        if record.projectId == workspaceProjectDefaultId || winMuxWorkspaceState.projectsById[record.projectId] != nil {
            if isFirstPass || workspace.projectId != record.projectId {
                winMuxWorkspaceState.assignWorkspace(workspace, to: record.projectId)
            }
        } else {
            workspace.assignProject(workspaceProjectDefaultId)
            stillAwaiting.insert(record.workspaceName)
        }
    }
    runtime.workspacesAwaitingProject = stillAwaiting
}

/// Whether a checkpoint may copy the workspace's project into its record. A workspace waiting
/// in Default for its saved project keeps that project.
@MainActor
func savedWorkspaceProjectSyncAllowed(_ workspace: Workspace, record: SavedWorkspaceRecord) -> Bool {
    !(workspace.projectId == workspaceProjectDefaultId &&
        record.projectId != workspaceProjectDefaultId &&
        winMuxWorkspaceState.projectsById[record.projectId] == nil)
}

/// Drops the session state of a record that was forgotten or deleted.
@MainActor
func clearSavedWorkspaceRuntimeState(_ record: SavedWorkspaceRecord) {
    let runtime = savedWorkspaceRuntime
    for slot in record.layout.allSlots {
        runtime.vanishedSlots.removeValue(forKey: slot.id)
    }
    runtime.visibleOnHomeAtLastCheckpoint.remove(record.workspaceName)
    runtime.workspacesAwaitingProject?.remove(record.workspaceName)
    runtime.organizationPruneRetryAfter.removeValue(forKey: record.workspaceName)
}

@MainActor
func savedWorkspaceDisplayName(_ workspaceName: String) -> String? {
    savedWorkspaceStore.record(named: workspaceName)?.displayName?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .takeIf { !$0.isEmpty }
}

/// - Parameter flush: false when the caller changes the record further and flushes itself.
@MainActor
@discardableResult
func ensureSavedWorkspaceRecord(_ workspace: Workspace, flush: Bool = true, keepWhenEmpty: Bool = true) throws -> (record: SavedWorkspaceRecord, created: Bool) {
    if var existing = savedWorkspaceStore.record(named: workspace.name) {
        // A later explicit Save/Pin/Customize opts an inherited tab into being kept.
        if keepWhenEmpty, existing.keepWhenEmpty == false {
            if let reason = savedWorkspaceStore.readOnlyReason {
                throw WorkspaceMutationError.savedWorkspacesReadOnly(reason)
            }
            existing.keepWhenEmpty = nil
            savedWorkspaceStore.update(named: workspace.name) { $0.keepWhenEmpty = nil }
            if flush { savedWorkspaceStore.flushNow() }
            else { savedWorkspaceStore.scheduleWrite() }
        }
        return (existing, false)
    }
    if let reason = savedWorkspaceStore.readOnlyReason {
        throw WorkspaceMutationError.savedWorkspacesReadOnly(reason)
    }
    workspace.lifecycle = .durable
    let monitor = workspace.visibleMonitor ?? workspace.workspaceMonitor
    let label = config.workspaceSidebar.workspaceLabels[workspace.name]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .takeIf { !$0.isEmpty }
    var record = SavedWorkspaceRecord(
        workspaceName: workspace.name,
        displayName: label,
        projectId: workspace.projectId,
        namingStyle: workspace.namingStyle,
        display: SavedDisplayAffinity(monitor: monitor),
        keepWhenEmpty: keepWhenEmpty ? nil : false,
        lastVisibleSequence: workspace.isVisible ? savedWorkspaceStore.takeVisibilitySequence() : nil,
        layout: snapshotSavedWorkspaceLayoutNow(workspace),
    )
    if case let apps = savedLaunchApps(record.layout.allSlots), !apps.isEmpty { record.launchApps = apps }
    check(savedWorkspaceStore.insert(record))
    if workspace.isVisible {
        savedWorkspaceRuntime.visibleOnHomeAtLastCheckpoint.insert(workspace.name)
    }
    savedWorkspaceStore.reorder(workspaceNamesInOrder: orderedWorkspacesForPresentation().map(\.name))
    if flush {
        savedWorkspaceStore.flushNow()
    }
    return (record, true)
}

/// Stops saving the workspace. It keeps its windows and name for now, then behaves like any
/// other workspace: it is removed when it empties.
@MainActor
@discardableResult
func forgetSavedWorkspace(_ workspace: Workspace) throws -> Bool {
    guard savedWorkspaceStore.contains(workspaceName: workspace.name) else { return false }
    if let reason = savedWorkspaceStore.readOnlyReason {
        throw WorkspaceMutationError.savedWorkspacesReadOnly(reason)
    }
    if workspaceSidebarOrganizationStore.state.workspaces[workspace.name] != nil ||
        workspaceSidebarOrganizationStore.collection(containing: workspace.name) != nil {
        try workspaceSidebarOrganizationStore.removeWorkspace(workspace.name)
    }
    if let removed = savedWorkspaceStore.remove(named: workspace.name) {
        clearSavedWorkspaceRuntimeState(removed)
    }
    savedWorkspaceStore.flushNow()
    return true
}

/// Pins the workspace to the display it is on (saving it first), or unpins it. Unpinning keeps
/// the display as its soft home.
@MainActor
@discardableResult
func setSavedWorkspacePinned(_ workspace: Workspace, _ pinned: Bool) throws -> Bool {
    // Pinning again changes nothing: while the pinned display is disconnected, the workspace's
    // current display must not become its home.
    if savedWorkspaceStore.record(named: workspace.name)?.isPinnedToDisplay == pinned {
        return false
    }
    if !pinned, !workspace.isSaved {
        return false
    }
    if let reason = savedWorkspaceStore.readOnlyReason {
        throw WorkspaceMutationError.savedWorkspacesReadOnly(reason)
    }
    let monitor = workspace.visibleMonitor ?? workspace.workspaceMonitor
    let affinity = SavedDisplayAffinity(monitor: monitor)
    // Checked before saving, so a pin that can't happen leaves the workspace unchanged. The
    // workspace is pinned to the display it is on, never silently to an older home.
    if pinned, affinity == nil {
        throw WorkspaceMutationError.displayHasNoIdentity(monitor.name)
    }
    let created = try ensureSavedWorkspaceRecord(workspace, flush: false).created
    let changed = savedWorkspaceStore.update(named: workspace.name) { record in
        record.isPinnedToDisplay = pinned
        if pinned, let affinity {
            record.display = affinity
        }
    }
    if changed || created {
        savedWorkspaceStore.flushNow()
    }
    return changed
}

/// Saves the workspace, naming it first when a name is given.
@MainActor
func saveWorkspaceForSidebar(workspaceName: String, displayName: String?) throws {
    guard let workspace = Workspace.existing(byName: workspaceName) else {
        throw WorkspaceMutationError.workspaceNotFound(workspaceName)
    }
    if let displayName,
       displayName.trimmingCharacters(in: .whitespacesAndNewlines) != workspaceDisplayName(workspaceName)
    {
        try renameWorkspaceForSidebar(workspaceName: workspaceName, displayName: displayName, forceSave: true)
    } else {
        try ensureSavedWorkspaceRecord(workspace)
    }
}

@MainActor
func forgetSavedWorkspaceForSidebar(workspaceName: String) throws {
    guard let workspace = Workspace.existing(byName: workspaceName) else {
        throw WorkspaceMutationError.workspaceNotFound(workspaceName)
    }
    try forgetSavedWorkspace(workspace)
}

@MainActor
func setSavedWorkspacePinnedForSidebar(workspaceName: String, pinned: Bool) throws {
    guard let workspace = Workspace.existing(byName: workspaceName) else {
        throw WorkspaceMutationError.workspaceNotFound(workspaceName)
    }
    try setSavedWorkspacePinned(workspace, pinned)
}

/// On the first launch with saved workspaces, workspaces the user already named are saved as
/// if they had just been renamed. Only workspaces with windows qualify, so a stale label on an
/// empty workspace isn't adopted.
@MainActor
func adoptLabeledWorkspacesIfNeeded() {
    let runtime = savedWorkspaceRuntime
    guard !runtime.didRunLabelAdoption else { return }
    runtime.didRunLabelAdoption = true
    guard savedWorkspaceStore.fileWasAbsentAtLoad,
          savedWorkspaceStore.adoptsLabels,
          !savedWorkspaceStore.isReadOnly,
          config.workspaceSidebar.saveNamedWorkspaces
    else { return }
    var adopted = false
    for workspace in orderedWorkspacesForPresentation() {
        guard !workspace.isSaved,
              !isSidebarDraftWorkspaceName(workspace.name),
              config.workspaceSidebar.workspaceLabels[workspace.name]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              workspaceHasLifecycleWindows(workspace)
        else { continue }
        adopted = (try? ensureSavedWorkspaceRecord(workspace, flush: false))?.created == true || adopted
    }
    if adopted {
        savedWorkspaceStore.flushNow()
    }
}
