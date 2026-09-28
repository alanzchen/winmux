import CoreGraphics

let workspaceSidebarDefaultScopeId = "default"
let workspaceSidebarFocusedScopeId = "focused"
private let workspaceSidebarMonitorScopePrefix = "monitor:"

extension TrayMenuModel {
    var workspaceSidebarAutomaticMonitorScopeId: String {
        workspaceSidebarAutomaticScopeId(workspaceSidebarAppearance, targetScopeId: workspaceSidebarTargetMonitorScopeId)
    }

    @MainActor func refreshWorkspaceSidebarMonitorScope() {
        // A cleared model is not an authoritative disconnect. Keep manual choices
        // while disabled or waiting for discovery; a populated catalog includes Default.
        guard !workspaceSidebarMonitorScopes.isEmpty else { return }
        if let choiceFilter = workspaceSidebarMonitorScopeChoiceFilter,
           choiceFilter != workspaceSidebarAppearance.displayFilter ||
           !workspaceSidebarMonitorScopes.contains(where: { $0.id == workspaceSidebarSelectedMonitorScopeId })
        {
            // Changing the setting, or disconnecting the chosen display, returns to the default.
            workspaceSidebarMonitorScopeChoiceFilter = nil
        }
        let preferredScopeId = workspaceSidebarMonitorScopeChoiceFilter != nil
            ? workspaceSidebarSelectedMonitorScopeId
            : workspaceSidebarAutomaticMonitorScopeId
        let resolvedScopeId = workspaceSidebarMonitorScopes.contains { $0.id == preferredScopeId }
            ? preferredScopeId : workspaceSidebarDefaultScopeId
        setIfChanged(\.workspaceSidebarSelectedMonitorScopeId, resolvedScopeId)
    }
}

/// What a panel lists until its display menu is used: its own display, or every display.
func workspaceSidebarAutomaticScopeId(_ configuration: WorkspaceSidebarConfiguration, targetScopeId: String) -> String {
    configuration.defaultsToOwnDisplay ? targetScopeId : workspaceSidebarDefaultScopeId
}

/// Whether every connected display has a panel of its own. When one doesn't, each panel
/// lists every display by default so that display's workspaces stay reachable.
@MainActor
func workspaceSidebarPanelsCoverEveryDisplay() -> Bool {
    let panelCorners = Set(workspaceSidebarResolvedPanelMonitors().map(\.rect.topLeftCorner))
    return sortedMonitors.allSatisfy { panelCorners.contains($0.rect.topLeftCorner) }
}

func workspaceSidebarMonitorScopeIsSentinel(_ scopeId: String) -> Bool {
    scopeId == workspaceSidebarDefaultScopeId ||
        scopeId == workspaceSidebarFocusedScopeId
}

func workspaceSidebarMonitorScopeId(for monitor: Monitor) -> String {
    workspaceSidebarMonitorScopeId(for: monitor.rect.topLeftCorner)
}

func workspaceSidebarMonitorScopeId(for point: CGPoint) -> String {
    "\(workspaceSidebarMonitorScopePrefix)\(point.x),\(point.y)"
}

func workspaceSidebarMonitorScopePoint(_ scopeId: String) -> CGPoint? {
    guard scopeId.hasPrefix(workspaceSidebarMonitorScopePrefix) else { return nil }
    let rawPoint = scopeId.dropFirst(workspaceSidebarMonitorScopePrefix.count)
    let parts = rawPoint.split(separator: ",", maxSplits: 1).compactMap { Double($0) }
    guard parts.count == 2 else { return nil }
    return CGPoint(x: parts[0], y: parts[1])
}

@MainActor
func workspaceSidebarMonitor(forScopeId scopeId: String) -> Monitor? {
    if scopeId == workspaceSidebarFocusedScopeId {
        return focus.workspace.workspaceMonitor
    }
    guard let point = workspaceSidebarMonitorScopePoint(scopeId) else { return nil }
    return sortedMonitors.first { $0.rect.topLeftCorner == point }
}

func workspaceSidebarWorkspaceMatchesScope(
    workspaceMonitorScopeId: String,
    selectedScopeId: String,
    focusedMonitorScopeId: String,
) -> Bool {
    switch selectedScopeId {
        case workspaceSidebarDefaultScopeId:
            true
        case workspaceSidebarFocusedScopeId:
            workspaceMonitorScopeId == focusedMonitorScopeId
        default:
            workspaceMonitorScopeId == selectedScopeId
    }
}

func workspaceSidebarWorkspaceMatchesScope(
    _ workspace: WorkspaceSidebarWorkspaceViewModel,
    selectedScopeId: String,
    focusedMonitorScopeId: String,
) -> Bool {
    if selectedScopeId == workspaceSidebarDefaultScopeId {
        return true
    }
    if selectedScopeId == workspaceSidebarFocusedScopeId {
        return workspace.isFocused
    }
    return workspaceSidebarWorkspaceMatchesScope(
        workspaceMonitorScopeId: workspace.monitorScopeId,
        selectedScopeId: selectedScopeId,
        focusedMonitorScopeId: focusedMonitorScopeId,
    )
}
