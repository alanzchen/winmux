import AppKit
import Common

extension SavedDisplayAffinity {
    @MainActor
    init?(monitor: Monitor) {
        guard let identity = monitor.displayIdentity, identity.key != nil || identity.isBuiltin else { return nil }
        self.init(
            uuid: identity.uuid,
            vendor: identity.vendor == 0 ? nil : identity.vendor,
            model: identity.model == 0 ? nil : identity.model,
            serial: identity.serial == 0 ? nil : identity.serial,
            isBuiltin: identity.isBuiltin,
            name: monitor.name,
            lastTopLeft: monitor.rect.topLeftCorner,
        )
    }
}

/// Finds the connected display a saved affinity refers to: same UUID, then same
/// vendor/model/serial, then the built-in panel. Identical displays are told apart by the
/// point they were last seen at.
@MainActor
func resolveSavedDisplay(_ affinity: SavedDisplayAffinity?, in monitors: [Monitor]) -> Monitor? {
    guard let affinity else { return nil }
    func nearest(_ candidates: [Monitor]) -> Monitor? {
        candidates.minBy { ($0.rect.topLeftCorner - affinity.lastTopLeft).vectorLength }
    }
    if let uuid = affinity.uuid {
        let matches = monitors.filter { $0.displayIdentity?.uuid == uuid }
        if !matches.isEmpty { return nearest(matches) }
    }
    // Without a serial number, the same model says nothing about which panel it is.
    if let vendor = affinity.vendor, let model = affinity.model, let serial = affinity.serial {
        let matches = monitors.filter { monitor in
            guard let identity = monitor.displayIdentity else { return false }
            return identity.vendor == vendor && identity.model == model && identity.serial == serial
        }
        if !matches.isEmpty { return nearest(matches) }
    }
    if affinity.isBuiltin {
        return monitors.first { $0.displayIdentity?.isBuiltin == true }
    }
    return nil
}

/// The connected display a saved workspace belongs on, or nil when the workspace isn't saved,
/// has no home yet, or its home is disconnected.
@MainActor
func savedHomeMonitor(of workspace: Workspace) -> Monitor? {
    guard !savedWorkspaceStore.isEmpty,
          let affinity = savedWorkspaceStore.record(named: workspace.name)?.display
    else { return nil }
    return resolveSavedDisplay(affinity, in: monitors)
}

/// Whether automatic selection may show the workspace on the monitor. Saved workspaces are
/// only picked for their home display. Config force-assignment wins over the saved home.
@MainActor
func savedHomeAllows(_ workspace: Workspace, on monitor: Monitor) -> Bool {
    guard !savedWorkspaceStore.isEmpty,
          resolvedForceAssignedMonitor(forWorkspaceName: workspace.name) == nil,
          let home = savedHomeMonitor(of: workspace)
    else { return true }
    if home.rect.topLeftCorner == monitor.rect.topLeftCorner { return true }
    // Already shown there (for example while its home was disconnected): it may stay.
    return !savedPinBlocksIgnoringVisibility(workspace) &&
        workspace.visibleMonitor?.rect.topLeftCorner == monitor.rect.topLeftCorner
}

@MainActor
private func savedPinBlocksIgnoringVisibility(_ workspace: Workspace) -> Bool {
    savedWorkspaceStore.record(named: workspace.name)?.isPinnedToDisplay == true
}

/// Whether an explicit user action must not show a pinned workspace on the monitor.
@MainActor
func savedPinBlocks(_ workspace: Workspace, on monitor: Monitor) -> Bool {
    guard savedWorkspaceStore.record(named: workspace.name)?.isPinnedToDisplay == true,
          resolvedForceAssignedMonitor(forWorkspaceName: workspace.name) == nil,
          let home = savedHomeMonitor(of: workspace)
    else { return false }
    return home.rect.topLeftCorner != monitor.rect.topLeftCorner
}

/// Displays that are home to at least one saved workspace.
@MainActor
func savedWorkspaceHomeViewportIds(in monitors: [Monitor]) -> Set<MonitorViewportId> {
    guard !savedWorkspaceStore.isEmpty else { return [] }
    var result: Set<MonitorViewportId> = []
    for record in savedWorkspaceStore.records {
        guard let workspace = Workspace.existing(byName: record.workspaceName),
              !workspace.isArchived,
              resolvedForceAssignedMonitor(forWorkspaceName: workspace.name) == nil,
              let home = resolveSavedDisplay(record.display, in: monitors)
        else { continue }
        result.insert(MonitorViewportId(home))
    }
    return result
}

@MainActor
func savedPinnedDisplayName(_ workspace: Workspace) -> String? {
    guard let record = savedWorkspaceStore.record(named: workspace.name), record.isPinnedToDisplay else { return nil }
    return record.display?.name
}

@MainActor
func savedPinRefusalMessage(_ workspace: Workspace) -> String {
    let display = savedPinnedDisplayName(workspace) ?? "its display"
    return "Workspace '\(workspaceDisplayName(workspace.name))' (\(workspace.name)) is kept on display '\(display)'. " +
        "Run 'winmux save-workspace --workspace \(workspace.name) --unpin-display' to move it"
}

/// The user deliberately put a saved workspace on a display, so that display becomes its home.
/// Pinned workspaces keep their home. A move while the home display is disconnected is
/// temporary.
@MainActor
func noteSavedWorkspacePlacedByUser(_ workspace: Workspace, on monitor: Monitor) {
    guard let record = savedWorkspaceStore.record(named: workspace.name),
          !record.isPinnedToDisplay,
          !MonitorConfigurationObserver.shared.isSettling,
          let affinity = SavedDisplayAffinity(monitor: monitor)
    else { return }
    if record.display != nil, resolveSavedDisplay(record.display, in: monitors) == nil {
        return
    }
    guard savedWorkspaceStore.update(named: workspace.name, { $0.display = affinity }) else { return }
    savedWorkspaceStore.scheduleWrite()
}

struct SavedWorkspaceRestoreTargets {
    var byViewport: [MonitorViewportId: Workspace] = [:]
    /// Pinned workspaces taken from the display that was showing them.
    var stolen: Set<WorkspaceId> = []
}

/// Chooses which saved workspace each newly seen display shows: a pinned workspace first (even
/// when another display shows it), then the one most recently visible there.
@MainActor
func savedWorkspaceRestoreTargets(
    unmappedMonitors: [Monitor],
    oldViewportsById: [MonitorViewportId: MonitorViewport],
    mappedOldViewportIds: Set<MonitorViewportId>,
) -> SavedWorkspaceRestoreTargets {
    var result = SavedWorkspaceRestoreTargets()
    guard !savedWorkspaceStore.isEmpty, !unmappedMonitors.isEmpty else { return result }
    let currentMonitors = monitors
    let visibleInMappedViewport: Set<WorkspaceId> = mappedOldViewportIds.compactMap { oldViewportsById[$0]?.activeWorkspaceId }.toSet()
    var chosen: Set<WorkspaceId> = []
    for monitor in unmappedMonitors {
        let viewportId = MonitorViewportId(monitor)
        let candidates = savedWorkspaceStore.records.enumerated().compactMap { index, record -> (Workspace, SavedWorkspaceRecord, Int)? in
            guard let workspace = Workspace.existing(byName: record.workspaceName),
                  !workspace.isArchived,
                  !chosen.contains(workspace.id),
                  resolvedForceAssignedMonitor(forWorkspaceName: workspace.name) == nil,
                  let home = resolveSavedDisplay(record.display, in: currentMonitors),
                  home.rect.topLeftCorner == monitor.rect.topLeftCorner,
                  isValidAssignment(workspace: workspace, screen: monitor.rect.topLeftCorner)
            else { return nil }
            if visibleInMappedViewport.contains(workspace.id), !record.isPinnedToDisplay {
                return nil
            }
            return (workspace, record, index)
        }
        let best = candidates.min { lhs, rhs in
            let lhsStolen = lhs.1.isPinnedToDisplay && visibleInMappedViewport.contains(lhs.0.id)
            let rhsStolen = rhs.1.isPinnedToDisplay && visibleInMappedViewport.contains(rhs.0.id)
            if lhsStolen != rhsStolen { return lhsStolen }
            let lhsSequence = lhs.1.lastVisibleSequence ?? Int.min
            let rhsSequence = rhs.1.lastVisibleSequence ?? Int.min
            if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
            return lhs.2 < rhs.2
        }
        guard let (workspace, record, _) = best else { continue }
        chosen.insert(workspace.id)
        result.byViewport[viewportId] = workspace
        if record.isPinnedToDisplay, visibleInMappedViewport.contains(workspace.id) {
            result.stolen.insert(workspace.id)
        }
    }
    return result
}

/// A hidden saved workspace homed on the monitor, for when the display's own workspace can't
/// stay there.
/// Callers mid-rearrange pass every workspace that stays visible elsewhere in `excluding`:
/// visibility itself is being rebuilt then.
@MainActor
func savedWorkspaceToRestore(on monitor: Monitor, excluding: Set<WorkspaceId>) -> Workspace? {
    guard !savedWorkspaceStore.isEmpty else { return nil }
    let currentMonitors = monitors
    return savedWorkspaceStore.records
        .enumerated()
        .compactMap { index, record -> (Workspace, Int, Int)? in
            guard let workspace = Workspace.existing(byName: record.workspaceName),
                  !workspace.isArchived,
                  !excluding.contains(workspace.id),
                  resolvedForceAssignedMonitor(forWorkspaceName: workspace.name) == nil,
                  let home = resolveSavedDisplay(record.display, in: currentMonitors),
                  home.rect.topLeftCorner == monitor.rect.topLeftCorner,
                  isValidAssignment(workspace: workspace, screen: monitor.rect.topLeftCorner)
            else { return nil }
            return (workspace, record.lastVisibleSequence ?? Int.min, index)
        }
        .min { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.2 < rhs.2 }?
        .0
}
