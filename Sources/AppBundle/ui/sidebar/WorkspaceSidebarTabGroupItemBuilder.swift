@MainActor
func makeWorkspaceSidebarTabGroupViewModel(
    for container: WorkspaceTabLayoutContainer,
    windows: [UInt32: WorkspaceSidebarWindowViewModel],
    workspaceName: String,
    currentFocus: LiveFocus,
) -> WorkspaceSidebarTabGroupViewModel? {
    guard let representative = container.representative else { return nil }
    let tabs = container.tabRepresentatives.compactMap { windows[$0.windowId] }
    guard !tabs.isEmpty else { return nil }
    return WorkspaceSidebarTabGroupViewModel(
        representativeWindowId: representative.windowId, workspaceName: workspaceName,
        title: sidebarDisplayLabel(for: representative), windowCount: container.windows.count,
        isFocused: representative.moveNode == currentFocus.windowOrNil?.moveNode, tabs: tabs,
        allWindows: config.workspaceSidebar.usesTabsList ? container.windows.compactMap { windows[$0.windowId] } : [])
}

@MainActor
func makeWorkspaceSidebarTabGroupViewModel(
    for container: TilingContainer,
    workspaceName: String,
    currentFocus: LiveFocus,
) async -> WorkspaceSidebarTabGroupViewModel? {
    let content = WorkspaceTabSnapshot.layout(of: container)
    var windows: [UInt32: WorkspaceSidebarWindowViewModel] = [:]
    for window in content.sidebarWindows where windows[window.windowId] == nil {
        windows[window.windowId] = await makeWorkspaceSidebarWindowViewModel(for: window,
            workspaceName: workspaceName, currentFocus: currentFocus, state: .laidOut)
    }
    return makeWorkspaceSidebarTabGroupViewModel(for: content, windows: windows,
        workspaceName: workspaceName, currentFocus: currentFocus)
}
