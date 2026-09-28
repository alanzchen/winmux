import AppKit

@MainActor
func workspaceSidebarResolvedPanelMonitor() -> Monitor {
    if isMouseWindowDragInProgress() {
        return mouseLocation.monitorApproximation
    }
    return config.workspaceSidebar.resolvedMonitor(sortedMonitors: sortedMonitors) ?? mainMonitor
}

@MainActor
func workspaceSidebarResolvedPanelMonitors() -> [Monitor] {
    let resolved = config.workspaceSidebar.resolvedMonitors(sortedMonitors: sortedMonitors)
    return resolved.isEmpty ? [mainMonitor] : resolved
}

@MainActor
func buildWorkspaceSidebarMonitorScopes(
    sortedMonitors: [Monitor],
    focusedMonitorScopeId: String,
) -> [WorkspaceSidebarMonitorScopeViewModel] {
    var scopes = [
        WorkspaceSidebarMonitorScopeViewModel(
            id: workspaceSidebarDefaultScopeId,
            displayName: "All Displays",
            subtitle: nil,
            systemImageName: "display.2",
            isFocusedMonitor: false,
        ),
    ]
    if config.workspaceSidebar.enableFocus {
        scopes.append(WorkspaceSidebarMonitorScopeViewModel(
            id: workspaceSidebarFocusedScopeId,
            displayName: "Focused",
            subtitle: nil,
            systemImageName: "scope",
            isFocusedMonitor: false,
        ))
    }
    return scopes + sortedMonitors.map { monitor in
        let scopeId = workspaceSidebarMonitorScopeId(for: monitor)
        return WorkspaceSidebarMonitorScopeViewModel(
            id: scopeId,
            displayName: workspaceSidebarMonitorDisplayName(monitor, among: sortedMonitors),
            subtitle: monitor.isMain ? "Main display" : nil,
            systemImageName: "display",
            isFocusedMonitor: scopeId == focusedMonitorScopeId,
        )
    }
}

/// The display menu's name for a display. Identical displays are numbered from left to right.
/// Each display's own sidebar width is saved under it.
func workspaceSidebarMonitorDisplayName(_ monitor: Monitor, among monitors: [Monitor]) -> String {
    let names = monitors.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let index = monitors.firstIndex(where: { $0.rect.topLeftCorner == monitor.rect.topLeftCorner }) else {
        return workspaceSidebarMonitorDisplayName(monitor, fallbackIndex: 1)
    }
    let sameName = names.indices.filter { names[$0] == names[index] }
    return workspaceSidebarMonitorDisplayName(monitor, fallbackIndex: index + 1,
        duplicateNumber: sameName.count > 1 ? sameName.firstIndex(of: index).map { $0 + 1 } : nil)
}

/// A display's own name, including the main display's. Identical displays are numbered.
func workspaceSidebarMonitorDisplayName(_ monitor: Monitor, fallbackIndex: Int, duplicateNumber: Int? = nil) -> String {
    let name = monitor.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return "Display \(fallbackIndex)" }
    return duplicateNumber.map { "\(name) \($0)" } ?? name
}

/// The display menu as one panel shows it: the panel's own display first, as This Display,
/// then All Displays, Focused, and the other displays by name.
func workspaceSidebarMonitorScopeMenu(
    _ scopes: [WorkspaceSidebarMonitorScopeViewModel],
    targetScopeId: String,
) -> [WorkspaceSidebarMonitorScopeViewModel] {
    guard workspaceSidebarMonitorScopePoint(targetScopeId) != nil,
          let own = scopes.first(where: { $0.id == targetScopeId })
    else { return scopes }
    let thisDisplay = WorkspaceSidebarMonitorScopeViewModel(id: own.id, displayName: "This Display",
        subtitle: own.displayName, systemImageName: own.systemImageName, isFocusedMonitor: own.isFocusedMonitor)
    return [thisDisplay] + scopes.filter { $0.id != own.id }
}
