import AppKit
import Common

@MainActor
func switchWorkspaceProject(_ projectId: WorkspaceProjectId, on monitor: Monitor) -> Workspace? {
    materializePersistedWorkspaceProjects()
    guard winMuxWorkspaceState.projectsById[projectId] != nil else {
        debugWorkspaceSidebarProjectLog("switchProjectAbort unknownProject=\(projectId.rawValue)")
        return nil
    }
    let viewportId = MonitorViewportId(monitor)
    // A pin in All Projects on screen stays there: only the display's project changes, so the
    // sidebar shows that project's pins and tabs below it. Its last tab isn't brought back.
    if let shown = winMuxWorkspaceState.visibleWorkspace(for: monitor), workspaceIsPinnedInAllProjects(shown) {
        winMuxWorkspaceState.setContextProject(projectId, on: viewportId)
        debugWorkspaceSidebarProjectLog(
            "switchProject project=\(projectId.rawValue) viewport=\(viewportId.description) keptPinInAllProjects=\(shown.name)"
        )
        return shown
    }
    // The tab last chosen in that project here: one of its own, or a pin in All Projects chosen in it.
    let rememberedWorkspace = winMuxWorkspaceState.monitorViewportsById[viewportId]?
        .lastActiveWorkspaceByProject[projectId]
        .flatMap { winMuxWorkspaceState.workspaceById[$0] }
        .flatMap { workspaceIsListed($0, inProject: projectId) ? $0 : nil }
        .flatMap { workspaceIsProjectFallbackCandidate($0) && workspaceIsAvailableForMonitor($0, monitor: monitor) ? $0 : nil }
    let workspace = rememberedWorkspace
        ?? availablePreferredWorkspace(projectId: projectId, monitor: monitor)
        ?? createBlankWorkspace(projectId: projectId, monitor: monitor)
    let didSetActive = monitor.setActiveWorkspace(workspace, contextProjectId: projectId)
    debugWorkspaceSidebarProjectLog(
        "switchProject project=\(projectId.rawValue) viewport=\(viewportId.description) remembered=\(rememberedWorkspace?.name ?? "nil") chosen=\(workspace.name) chosenProject=\(workspace.projectId.rawValue) didSetActive=\(didSetActive)"
    )
    return didSetActive ? workspace : nil
}

@MainActor
func preferredWorkspace(projectId: WorkspaceProjectId, monitor: Monitor) -> Workspace? {
    projectWorkspaces(projectId: projectId)
        .filter { !$0.isArchived && !workspaceIsPinnedInAllProjects($0) }
        .filter(workspaceIsProjectFallbackCandidate)
        .filter { isValidAssignment(workspace: $0, screen: monitor.rect.topLeftCorner) }
        .first
}

@MainActor
func createBlankWorkspace(projectId: WorkspaceProjectId, monitor: Monitor) -> Workspace {
    let workspace = Workspace.get(byName: nextAutomaticWorkspaceName(projectId: projectId, monitor: monitor))
    workspace.markAsTransientBlank()
    workspace.assignProject(projectId)
    workspace.seedMonitorIfNeeded(monitor)
    return workspace
}

@MainActor
func getOrCreateAdjacentBlankWorkspace(projectId: WorkspaceProjectId, monitor: Monitor) -> Workspace {
    let scope = WorkspaceScope(projectId: projectId)
    if let workspaceId = retainedEmptyWorkspaceId(in: scope),
       let workspace = winMuxWorkspaceState.workspaceById[workspaceId],
       isValidAssignment(workspace: workspace, screen: monitor.rect.topLeftCorner)
    {
        return workspace
    }
    return createBlankWorkspace(projectId: projectId, monitor: monitor)
}

@MainActor
func deleteWorkspace(_ workspace: Workspace) throws {
    // The project its display is in, read while it's still pinned: a pin in All Projects leaves its
    // place to a tab of that one.
    let fallbackProjectId = workspaceContextProjectId(of: workspace)
    if workspaceSidebarOrganizationStore.state.workspaces[workspace.name] != nil ||
        workspaceSidebarOrganizationStore.collection(containing: workspace.name) != nil {
        try workspaceSidebarOrganizationStore.removeWorkspace(workspace.name)
    }
    let fallback = workspaceFallbackForDeletion(
        excluding: workspace,
        projectId: fallbackProjectId,
        monitor: workspace.workspaceMonitor,
    )
    moveWorkspaceContents(from: workspace, to: fallback)
    if workspace.isVisible {
        check(
            workspace.workspaceMonitor.setActiveWorkspace(fallback),
            "Can't activate fallback workspace '\(fallback.name)' while deleting workspace '\(workspace.name)'",
        )
    }
    if focus.workspace == workspace {
        _ = setFocus(to: fallback.toLiveFocus())
    }
    removeWorkspaceFromRegistry(workspace, reason: .deleted)
    checkWorkspaceHierarchyInvariants()
}

@MainActor
func workspaceFallbackForDeletion(
    excluding workspace: Workspace,
    projectId: WorkspaceProjectId,
    monitor: Monitor,
) -> Workspace {
    closestWorkspaceForDeletion(
        excluding: workspace,
        projectId: projectId,
        monitor: monitor,
    )
        ?? createBlankWorkspace(projectId: projectId, monitor: monitor)
}

@MainActor
func closestWorkspaceForDeletion(
    excluding workspace: Workspace,
    projectId: WorkspaceProjectId,
    monitor: Monitor,
) -> Workspace? {
    let scopedCandidates = userFacingWorkspaces(
        orderedWorkspaces(in: projectId),
        focusedWorkspace: focus.workspace,
    )
        .filter { isValidAssignment(workspace: $0, screen: monitor.rect.topLeftCorner) && savedHomeAllows($0, on: monitor) }
    let automaticCandidates = scopedCandidates.filter(\.usesAutomaticDisplayName)
    let candidates = workspace.usesAutomaticDisplayName && automaticCandidates.contains(workspace)
        ? automaticCandidates
        : scopedCandidates

    guard let deletedIndex = candidates.firstIndex(where: { $0 === workspace }) else {
        return candidates.first { $0 !== workspace }
    }
    if let next = candidates.getOrNil(atIndex: deletedIndex + 1) {
        return next
    }
    if deletedIndex > 0 {
        return candidates[deletedIndex - 1]
    }
    return nil
}

@MainActor
func moveWorkspaceContents(from source: Workspace, to target: Workspace) {
    guard source != target else { return }
    for child in source.children {
        switch child.nodeCases {
            case .window(let window):
                window.bind(to: target, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .tilingContainer(let container):
                container.bind(to: target.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .macosFullscreenWindowsContainer(let container):
                for window in container.children.filterIsInstance(of: Window.self) {
                    window.bind(to: target.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                }
            case .macosHiddenAppsWindowsContainer(let container):
                for window in container.children.filterIsInstance(of: Window.self) {
                    window.bind(to: target.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                }
            case .workspace, .macosMinimizedWindowsContainer, .macosPopupWindowsContainer:
                break
        }
    }
    for window in workspaceOwnedMinimizedWindows(source) {
        switch window.layoutReason {
            case .macos(let prevParentKind, _):
                window.layoutReason = .macos(prevParentKind: prevParentKind, prevWorkspaceName: target.name)
            case .standard:
                break
        }
    }
}

enum WorkspaceRemovalReason {
    /// Removed automatically because it emptied.
    case pruned
    /// The user deleted the workspace or its project.
    case deleted
}

@MainActor
func removeWorkspaceFromRegistry(_ workspace: Workspace, reason: WorkspaceRemovalReason) {
    switch reason {
        case .deleted:
            if let removed = savedWorkspaceStore.remove(named: workspace.name) {
                clearSavedWorkspaceRuntimeState(removed)
                savedWorkspaceStore.flushNow()
            }
        case .pruned:
            // Explicitly kept or still-restoring identities retain their reserved names.
            if workspace.isSaved && (workspace.isKeptWhenEmpty || workspace.isAwaitingSavedWorkspaceRestoration) {
                _ = winMuxWorkspaceState.removeWorkspace(workspace)
                return
            }
            // Don't release an automatically saved name while its group still references
            // it on disk: a later window could otherwise inherit stale organization.
            if workspace.isSaved {
                let runtime = savedWorkspaceRuntime
                if let retryAfter = runtime.organizationPruneRetryAfter[workspace.name], runtime.now < retryAfter { return }
                do { try workspaceSidebarOrganizationStore.removeWorkspace(workspace.name) }
                catch {
                    runtime.organizationPruneRetryAfter[workspace.name] = runtime.now.addingTimeInterval(30)
                    return
                }
            }
            if let removed = savedWorkspaceStore.remove(named: workspace.name) {
                clearSavedWorkspaceRuntimeState(removed)
                savedWorkspaceStore.flushNow()
            }
    }
    try? workspaceSidebarOrganizationStore.removeWorkspace(workspace.name)
    clearWorkspaceSidebarLabelIfNeeded(workspace.name)
    _ = winMuxWorkspaceState.removeWorkspace(workspace)
}

@MainActor
func pruneEmptyWorkspaces() {
    captureAutomaticWorkspaceIdentitiesBeforePruning()
    let retainedEmptyWorkspaceIds = retainedEmptyWorkspaceIdsByScope()
    let focusedWorkspaceBeforePrune = focus.workspace
    let workspacesToRemove = Workspace.all.filter {
        !workspaceShouldSurviveReconciliation($0, retainedEmptyWorkspaceIds: retainedEmptyWorkspaceIds)
    }
    var focusedReplacement: Workspace?

    for workspace in workspacesToRemove {
        let replacement = replacementWorkspaceForPrunedWorkspace(
            workspace,
            retainedEmptyWorkspaceIds: retainedEmptyWorkspaceIds,
        )
        if workspace.isVisible, let replacement {
            check(
                workspace.workspaceMonitor.setActiveWorkspace(replacement),
                "Can't replace pruned empty workspace '\(workspace.name)' with '\(replacement.name)'",
            )
        }
        if workspace == focusedWorkspaceBeforePrune {
            focusedReplacement = focusReplacementForPrunedWorkspace(workspace) ?? replacement
        }
        removeWorkspaceFromRegistry(workspace, reason: .pruned)
    }

    if let focusedReplacement, focus.workspace != focusedReplacement {
        _ = setFocus(to: focusedReplacement.toLiveFocus())
    }
}

@MainActor
func focusReplacementForPrunedWorkspace(_ workspace: Workspace) -> Workspace? {
    let visibleWorkspaces = Workspace.all.filter { $0.isVisible && $0 != workspace }
    if let mainVisible = visibleWorkspaces.first(where: { $0 === mainMonitor.activeWorkspace }) {
        return mainVisible
    }
    return visibleWorkspaces.first { $0.projectId == workspace.projectId } ?? visibleWorkspaces.first
}

@MainActor
func workspaceShouldSurviveReconciliation(
    _ workspace: Workspace,
    retainedEmptyWorkspaceIds: [WorkspaceScope: WorkspaceId],
) -> Bool {
    guard !workspace.isArchived else { return false }
    return workspace.isVisible ||
        workspace.retainsEmptyAfterProjectMove ||
        workspaceHasLifecycleWindows(workspace) ||
        workspace.isKeptWhenEmpty ||
        workspace.isAwaitingSavedWorkspaceRestoration ||
        projectWorkspaces(projectId: workspace.projectId).filter { !$0.isArchived }.count == 1 ||
        retainedEmptyWorkspaceIds[WorkspaceScope(projectId: workspace.projectId)] == workspace.id
}

@MainActor
func replacementWorkspaceForPrunedWorkspace(
    _ workspace: Workspace,
    retainedEmptyWorkspaceIds: [WorkspaceScope: WorkspaceId],
) -> Workspace? {
    let scope = WorkspaceScope(projectId: workspace.projectId)
    if let retainedWorkspaceId = retainedEmptyWorkspaceIds[scope],
       retainedWorkspaceId != workspace.id,
       let retainedWorkspace = winMuxWorkspaceState.workspaceById[retainedWorkspaceId],
       workspaceIsAvailableForMonitor(retainedWorkspace, monitor: workspace.workspaceMonitor)
    {
        return retainedWorkspace
    }
    if let candidate = orderedWorkspaces(in: scope).first(where: {
        $0.id != workspace.id &&
            workspaceShouldSurviveReconciliation($0, retainedEmptyWorkspaceIds: retainedEmptyWorkspaceIds) &&
            (workspaceHasSidebarVisibleWindows($0) || $0.isKeptWhenEmpty) &&
            workspaceIsAvailableForMonitor($0, monitor: workspace.workspaceMonitor)
    }) {
        return candidate
    }
    if workspace.isVisible {
        return createBlankWorkspace(projectId: workspace.projectId, monitor: workspace.workspaceMonitor)
    }
    return nil
}

@MainActor
func ensureVisibleActiveProjectWorkspaces() {
    for monitor in monitors where winMuxWorkspaceState.visibleWorkspace(for: monitor) == nil {
        let viewportId = MonitorViewportId(monitor)
        let projectId = fallbackProjectIdForMissingActiveWorkspace(on: viewportId)
        let workspace = availablePreferredWorkspace(projectId: projectId, monitor: monitor)
            ?? createBlankWorkspace(projectId: projectId, monitor: monitor)
        check(monitor.setActiveWorkspace(workspace))
    }
}

@MainActor
private func fallbackProjectIdForMissingActiveWorkspace(on viewportId: MonitorViewportId) -> WorkspaceProjectId {
    guard let viewport = winMuxWorkspaceState.monitorViewportsById[viewportId] else {
        return workspaceProjectDefaultId
    }
    if let previous = viewport.previousWorkspaceId.flatMap({ winMuxWorkspaceState.workspaceById[$0] }) {
        // A pin in All Projects isn't from the project the display was in.
        guard workspaceIsPinnedInAllProjects(previous), let contextProjectId = viewport.contextProjectId,
              winMuxWorkspaceState.projectsById[contextProjectId] != nil else { return previous.projectId }
        return contextProjectId
    }
    if let rememberedProjectId = viewport.lastActiveWorkspaceByProject
        .sorted(by: { $0.key < $1.key })
        .first(where: { entry in winMuxWorkspaceState.workspaceById[entry.value] != nil })?
        .key
    {
        return rememberedProjectId
    }
    return workspaceProjectDefaultId
}

@MainActor
func availablePreferredWorkspace(projectId: WorkspaceProjectId, monitor: Monitor) -> Workspace? {
    // A pin in All Projects isn't where a project opens, though going back to a project where it
    // was showing shows it again.
    orderedWorkspacesForPresentation()
        .filter { $0.projectId == projectId && !workspaceIsPinnedInAllProjects($0) }
        .filter { !$0.isArchived }
        .filter(workspaceIsProjectFallbackCandidate)
        .filter { isValidAssignment(workspace: $0, screen: monitor.rect.topLeftCorner) }
        .first { workspaceIsAvailableForMonitor($0, monitor: monitor) }
}

/// A reserved automatic identity is waiting for its app, not an empty project landing page.
@MainActor
private func workspaceIsProjectFallbackCandidate(_ workspace: Workspace) -> Bool {
    !workspace.isSaved || workspace.isKeptWhenEmpty || workspaceHasLifecycleWindows(workspace) ||
        workspace.retainsEmptyAfterProjectMove
}

@MainActor
func workspaceIsAvailableForMonitor(_ workspace: Workspace, monitor: Monitor) -> Bool {
    isValidAssignment(workspace: workspace, screen: monitor.rect.topLeftCorner) &&
        (!workspace.isVisible || workspace.workspaceMonitor.rect.topLeftCorner == monitor.rect.topLeftCorner) &&
        savedHomeAllows(workspace, on: monitor)
}

@MainActor
func repairInvalidVisibleWorkspaceAssignments() {
    let invalidVisibleWorkspaces = winMuxWorkspaceState.monitorViewportsById.compactMap { viewportId, viewport -> Workspace? in
        guard let workspaceId = viewport.activeWorkspaceId,
              let workspace = winMuxWorkspaceState.workspaceById[workspaceId],
              !isValidAssignment(workspace: workspace, screen: viewportId.topLeftCorner)
        else {
            return nil
        }
        return workspace
    }

    for workspace in invalidVisibleWorkspaces {
        if let forceAssignedMonitor = workspace.forceAssignedMonitor {
            _ = activateWorkspaceOnMonitorPreservingSourceViewport(workspace, targetMonitor: forceAssignedMonitor)
        }
    }

    for (viewportId, viewport) in winMuxWorkspaceState.monitorViewportsById {
        guard let workspaceId = viewport.activeWorkspaceId,
              let workspace = winMuxWorkspaceState.workspaceById[workspaceId],
              !isValidAssignment(workspace: workspace, screen: viewportId.topLeftCorner)
        else {
            continue
        }
        var viewport = viewport
        viewport.activeWorkspaceId = nil
        if viewport.previousWorkspaceId == workspaceId {
            viewport.previousWorkspaceId = nil
        }
        winMuxWorkspaceState.monitorViewportsById[viewportId] = viewport
    }
}
