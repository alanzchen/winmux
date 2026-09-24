import AppKit
import Common

extension Monitor {
    @MainActor
    var activeWorkspace: Workspace {
        if let existing = winMuxWorkspaceState.visibleWorkspace(for: self) {
            return existing
        }
        rearrangeWorkspacesOnMonitors()
        return self.activeWorkspace
    }

    @MainActor
    func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        rect.topLeftCorner.setActiveWorkspace(workspace)
    }
}

@MainActor
func activateWorkspaceOnMonitorPreservingSourceViewport(_ workspace: Workspace, targetMonitor: Monitor) -> Bool {
    let sourceMonitor = workspace.isVisible ? workspace.workspaceMonitor : nil
    let sourceProjectId = workspace.projectId
    if let sourceMonitor,
       sourceMonitor.rect.topLeftCorner != targetMonitor.rect.topLeftCorner
    {
        let fallbackWorkspace = getOrCreateMonitorViewportFallbackWorkspace(
            projectId: sourceProjectId,
            for: sourceMonitor,
            excluding: workspace,
        )
        check(
            sourceMonitor.setActiveWorkspace(fallbackWorkspace),
            "Generated incompatible fallback workspace (\(fallbackWorkspace)) for the monitor (\(sourceMonitor))",
        )
    }
    guard targetMonitor.setActiveWorkspace(workspace) else { return false }
    return true
}

@MainActor
func overrideWorkspaceOnMonitorBySwappingActiveViewports(_ workspace: Workspace, targetMonitor: Monitor) -> Bool {
    guard isValidAssignment(workspace: workspace, screen: targetMonitor.rect.topLeftCorner),
          !savedPinBlocks(workspace, on: targetMonitor)
    else {
        return false
    }
    guard workspace.isVisible else {
        guard targetMonitor.setActiveWorkspace(workspace) else { return false }
        noteSavedWorkspacePlacedByUser(workspace, on: targetMonitor)
        return true
    }

    let sourceMonitor = workspace.workspaceMonitor
    guard sourceMonitor.rect.topLeftCorner != targetMonitor.rect.topLeftCorner else {
        return true
    }

    let sourceReplacement = nearestWorkspaceForOverrideSourceMonitor(
        excluding: workspace,
        sourceMonitor: sourceMonitor,
        targetMonitor: targetMonitor,
    )
    if let sourceReplacement {
        _ = winMuxWorkspaceState.setActiveWorkspace(sourceReplacement, on: MonitorViewportId(sourceMonitor))
    } else {
        let fallback = createBlankWorkspace(projectId: workspace.projectId, monitor: sourceMonitor)
        _ = winMuxWorkspaceState.setActiveWorkspace(fallback, on: MonitorViewportId(sourceMonitor))
    }
    _ = winMuxWorkspaceState.setActiveWorkspace(workspace, on: MonitorViewportId(targetMonitor))
    checkWorkspaceHierarchyInvariants()
    noteSavedWorkspacePlacedByUser(workspace, on: targetMonitor)
    return true
}

@MainActor
func nearestWorkspaceForOverrideSourceMonitor(
    excluding workspace: Workspace,
    sourceMonitor: Monitor,
    targetMonitor: Monitor,
) -> Workspace? {
    let candidates = orderedWorkspacesForPresentation()
        .filter { candidate in
            candidate.projectId == workspace.projectId &&
                candidate != workspace &&
                !candidate.isArchived &&
                isValidAssignment(workspace: candidate, screen: sourceMonitor.rect.topLeftCorner) &&
                savedHomeAllows(candidate, on: sourceMonitor) &&
                (!candidate.isVisible || candidate.workspaceMonitor.rect.topLeftCorner == targetMonitor.rect.topLeftCorner)
        }
    guard let workspaceIndex = orderedWorkspacesForPresentation().firstIndex(of: workspace) else {
        return candidates.first
    }
    return candidates.min {
        abs((orderedWorkspacesForPresentation().firstIndex(of: $0) ?? Int.max) - workspaceIndex) <
            abs((orderedWorkspacesForPresentation().firstIndex(of: $1) ?? Int.max) - workspaceIndex)
    }
}

@MainActor
func gcMonitors() {
    rearrangeWorkspacesOnMonitors()
}

extension CGPoint {
    @MainActor
    func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        if !isValidAssignment(workspace: workspace, screen: self) {
            return false
        }
        let viewportId = MonitorViewportId(topLeftCorner: self)
        guard !winMuxWorkspaceState.isWorkspaceActive(workspace.id, outside: viewportId) else {
            return false
        }
        _ = winMuxWorkspaceState.setActiveWorkspace(workspace, on: viewportId)
        checkWorkspaceHierarchyInvariants()
        return true
    }
}

@MainActor
func checkWorkspaceHierarchyInvariants(requireActiveMonitorViewports: Bool = false) {
    for workspace in Workspace.all {
        check(winMuxWorkspaceState.projectsById[workspace.projectId] != nil, "Workspace '\(workspace.name)' references missing project '\(workspace.projectId)'")
    }

    for (viewportId, viewport) in winMuxWorkspaceState.monitorViewportsById {
        if let activeWorkspaceId = viewport.activeWorkspaceId {
            check(winMuxWorkspaceState.workspaceById[activeWorkspaceId] != nil, "Display viewport '\(viewportId)' references missing workspace '\(activeWorkspaceId)'")
            check(!winMuxWorkspaceState.isWorkspaceActive(activeWorkspaceId, outside: viewportId), "Workspace '\(activeWorkspaceId)' is active on more than one display viewport")
            if let workspace = winMuxWorkspaceState.workspaceById[activeWorkspaceId] {
                check(isValidAssignment(workspace: workspace, screen: viewportId.topLeftCorner), "Display viewport '\(viewportId)' has incompatible active workspace '\(workspace.name)'")
            }
        }
    }

    guard requireActiveMonitorViewports else { return }
    for monitor in monitors {
        let viewportId = MonitorViewportId(monitor)
        guard let viewport = winMuxWorkspaceState.monitorViewportsById[viewportId],
              let activeWorkspaceId = viewport.activeWorkspaceId,
              let workspace = winMuxWorkspaceState.workspaceById[activeWorkspaceId]
        else {
            check(false, "Current monitor viewport '\(viewportId)' has no active workspace after reconciliation")
            continue
        }
        check(isValidAssignment(workspace: workspace, screen: viewportId.topLeftCorner), "Current monitor viewport '\(viewportId)' has incompatible active workspace '\(workspace.name)'")
    }
}

@MainActor
func rearrangeWorkspacesOnMonitors() {
    let oldViewportsById = winMuxWorkspaceState.monitorViewportsById
    let currentMonitors = monitors
    let currentMonitorIds = Set(currentMonitors.map(MonitorViewportId.init))
    let activeViewportIds = Set(oldViewportsById.compactMap { viewportId, viewport -> MonitorViewportId? in
        guard let workspaceId = viewport.activeWorkspaceId,
              let workspace = winMuxWorkspaceState.workspaceById[workspaceId],
              isValidAssignment(workspace: workspace, screen: viewportId.topLeftCorner)
        else { return nil }
        return viewportId
    })
    // Displays that trade places keep the same set of points, so the points alone can't tell
    // that anything changed.
    if activeViewportIds == currentMonitorIds && viewportDisplayKeysAgree(oldViewportsById, currentMonitors) {
        fillMissingViewportDisplayKeys(currentMonitors)
        return
    }

    var oldVisibleMonitors: Set<MonitorViewportId> = oldViewportsById.compactMap { viewportId, viewport in
        guard let activeWorkspaceId = viewport.activeWorkspaceId,
              winMuxWorkspaceState.workspaceById[activeWorkspaceId] != nil
        else { return nil }
        return viewportId
    }.toSet()

    let newMonitors = currentMonitors.map(MonitorViewportId.init)
    var newMonitorToOldMonitorMapping: [MonitorViewportId: MonitorViewportId] = [:]
    // Pass 1: the same physical display.
    for monitor in currentMonitors {
        guard let key = monitor.displayIdentity?.key else { continue }
        let newMonitor = MonitorViewportId(monitor)
        let candidates = oldVisibleMonitors.filter { oldViewportsById[$0]?.displayKey == key }
        if let oldMonitor = candidates.minBy({ ($0.topLeftCorner - newMonitor.topLeftCorner).vectorLength }) {
            check(oldVisibleMonitors.remove(oldMonitor) != nil)
            newMonitorToOldMonitorMapping[newMonitor] = oldMonitor
        }
    }
    // A display that comes back shows its saved workspace. Identity beats position, so
    // saved homes skip the point-based passes.
    let savedHomes = savedWorkspaceHomeViewportIds(in: currentMonitors)
    let unmappedSavedHomes = currentMonitors.filter { monitor in
        let viewportId = MonitorViewportId(monitor)
        return newMonitorToOldMonitorMapping[viewportId] == nil && savedHomes.contains(viewportId)
    }
    // Passes 2 and 3: the same point, then the nearest point.
    for newMonitor in newMonitors where newMonitorToOldMonitorMapping[newMonitor] == nil && !savedHomes.contains(newMonitor) {
        if oldVisibleMonitors.contains(newMonitor), oldViewportDisplayKeyMatches(oldViewportsById[newMonitor], newMonitor, currentMonitors) {
            check(oldVisibleMonitors.remove(newMonitor) != nil)
            newMonitorToOldMonitorMapping[newMonitor] = newMonitor
        }
    }
    // An unmapped saved home may still fall back to its own old viewport below.
    let oldViewportsOfUnmappedSavedHomes = unmappedSavedHomes.map(MonitorViewportId.init).toSet()
    for newMonitor in newMonitors where newMonitorToOldMonitorMapping[newMonitor] == nil && !savedHomes.contains(newMonitor) {
        if let oldMonitor = oldVisibleMonitors.subtracting(oldViewportsOfUnmappedSavedHomes)
            .minBy({ ($0.topLeftCorner - newMonitor.topLeftCorner).vectorLength })
        {
            check(oldVisibleMonitors.remove(oldMonitor) != nil)
            newMonitorToOldMonitorMapping[newMonitor] = oldMonitor
        }
    }
    // Pass 4: saved workspaces for the returning homes, given everything that stays visible.
    let restoreTargets = savedWorkspaceRestoreTargets(
        unmappedMonitors: unmappedSavedHomes,
        oldViewportsById: oldViewportsById,
        mappedOldViewportIds: newMonitorToOldMonitorMapping.values.toSet(),
    )
    // A saved home with nothing to restore keeps what was on screen there, like any display.
    for newMonitor in unmappedSavedHomes.map(MonitorViewportId.init) where restoreTargets.byViewport[newMonitor] == nil {
        if oldVisibleMonitors.contains(newMonitor), oldViewportDisplayKeyMatches(oldViewportsById[newMonitor], newMonitor, currentMonitors) {
            check(oldVisibleMonitors.remove(newMonitor) != nil)
            newMonitorToOldMonitorMapping[newMonitor] = newMonitor
        } else if let oldMonitor = oldVisibleMonitors.minBy({ ($0.topLeftCorner - newMonitor.topLeftCorner).vectorLength }) {
            check(oldVisibleMonitors.remove(oldMonitor) != nil)
            newMonitorToOldMonitorMapping[newMonitor] = oldMonitor
        }
    }
    let reservedTargetIds = restoreTargets.byViewport.values.map(\.id).toSet()
    // Workspaces that stay on their mapped display; mid-rebuild, isVisible can't tell.
    let keptVisibleIds = newMonitorToOldMonitorMapping.values
        .compactMap { oldViewportsById[$0]?.activeWorkspaceId }
        .toSet()
        .subtracting(restoreTargets.stolen)
        .subtracting(reservedTargetIds)

    winMuxWorkspaceState.monitorViewportsById = [:]

    var assignedWorkspaceIds: Set<WorkspaceId> = []
    for monitor in currentMonitors {
        let newMonitor = MonitorViewportId(monitor)
        let newScreen = newMonitor.topLeftCorner
        let mappedOldMonitor = newMonitorToOldMonitorMapping[newMonitor]
        let preservedViewport = mappedOldMonitor.flatMap { oldViewportsById[$0] } ?? oldViewportsById[newMonitor]
        let displayKey = monitor.displayIdentity?.key ?? mappedOldMonitor.flatMap { oldViewportsById[$0]?.displayKey }
        if let preservedViewport {
            winMuxWorkspaceState.monitorViewportsById[newMonitor] = MonitorViewport(
                id: newMonitor,
                activeWorkspaceId: nil,
                previousWorkspaceId: preservedViewport.previousWorkspaceId,
                lastActiveWorkspaceByProject: preservedViewport.lastActiveWorkspaceByProject,
                displayKey: displayKey,
            )
        } else if displayKey != nil {
            winMuxWorkspaceState.monitorViewportsById[newMonitor] = MonitorViewport(id: newMonitor, displayKey: displayKey)
        }
        if let target = restoreTargets.byViewport[newMonitor],
           !assignedWorkspaceIds.contains(target.id),
           newScreen.setActiveWorkspace(target)
        {
            assignedWorkspaceIds.insert(target.id)
            continue
        }
        let existingVisibleWorkspace = mappedOldMonitor
            .flatMap { oldViewportsById[$0]?.activeWorkspaceId }
            .flatMap { winMuxWorkspaceState.workspaceById[$0] }
        if let existingVisibleWorkspace,
           !restoreTargets.stolen.contains(existingVisibleWorkspace.id),
           !reservedTargetIds.contains(existingVisibleWorkspace.id),
           !assignedWorkspaceIds.contains(existingVisibleWorkspace.id),
           newScreen.setActiveWorkspace(existingVisibleWorkspace)
        {
            assignedWorkspaceIds.insert(existingVisibleWorkspace.id)
            continue
        }
        let excludedFromRestore = assignedWorkspaceIds
            .union(restoreTargets.stolen)
            .union(reservedTargetIds)
            .union(keptVisibleIds)
        if let savedWorkspace = savedWorkspaceToRestore(on: monitor, excluding: excludedFromRestore),
           newScreen.setActiveWorkspace(savedWorkspace)
        {
            assignedWorkspaceIds.insert(savedWorkspace.id)
            continue
        }
        let projectId = existingVisibleWorkspace?.projectId ?? workspaceProjectDefaultId
        let workspace = getOrCreateFallbackWorkspace(
            projectId: projectId,
            monitor: newScreen.monitorApproximation,
            excluding: existingVisibleWorkspace,
        )
        check(newScreen.setActiveWorkspace(workspace),
              "Generated incompatible fallback workspace (\(workspace)) for the display viewport (\(newScreen)")
        assignedWorkspaceIds.insert(workspace.id)
    }
}

/// Whether every connected display is still at the viewport it was last seen at. Viewports
/// without a key yet (fake monitors, first run) agree with anything.
@MainActor
private func viewportDisplayKeysAgree(_ viewports: [MonitorViewportId: MonitorViewport], _ monitors: [Monitor]) -> Bool {
    monitors.allSatisfy { monitor in
        guard let key = monitor.displayIdentity?.key,
              let viewportKey = viewports[MonitorViewportId(monitor)]?.displayKey
        else { return true }
        return key == viewportKey
    }
}

@MainActor
private func oldViewportDisplayKeyMatches(_ viewport: MonitorViewport?, _ newMonitor: MonitorViewportId, _ monitors: [Monitor]) -> Bool {
    guard let viewportKey = viewport?.displayKey,
          let monitorKey = monitors.first(where: { MonitorViewportId($0) == newMonitor })?.displayIdentity?.key
    else { return true }
    return viewportKey == monitorKey
}

@MainActor
private func fillMissingViewportDisplayKeys(_ monitors: [Monitor]) {
    for monitor in monitors {
        guard let key = monitor.displayIdentity?.key else { continue }
        let viewportId = MonitorViewportId(monitor)
        guard var viewport = winMuxWorkspaceState.monitorViewportsById[viewportId], viewport.displayKey == nil else { continue }
        viewport.displayKey = key
        winMuxWorkspaceState.monitorViewportsById[viewportId] = viewport
    }
}

@MainActor
func isValidAssignment(workspace: Workspace, screen: CGPoint) -> Bool {
    isValidAssignment(workspaceName: workspace.name, screen: screen)
}

@MainActor
func isValidAssignment(workspaceName: String, screen: CGPoint) -> Bool {
    if let forceAssigned = resolvedForceAssignedMonitor(forWorkspaceName: workspaceName), forceAssigned.rect.topLeftCorner != screen {
        return false
    } else {
        return true
    }
}
