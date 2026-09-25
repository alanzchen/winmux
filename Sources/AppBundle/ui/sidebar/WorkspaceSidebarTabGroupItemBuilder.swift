@MainActor
func makeWorkspaceSidebarTabGroupViewModel(
    for container: TilingContainer,
    workspaceName: String,
    currentFocus: LiveFocus,
) async -> WorkspaceSidebarTabGroupViewModel? {
    let representativeWindow = container.tabActiveWindow ?? container.mostRecentWindowRecursive ?? container.anyLeafWindowRecursive
    guard let representativeWindow else { return nil }
    let tabs = await buildWorkspaceSidebarTabItems(
        for: container,
        workspaceName: workspaceName,
        currentFocus: currentFocus,
    )
    guard !tabs.isEmpty else { return nil }
    return WorkspaceSidebarTabGroupViewModel(
        representativeWindowId: representativeWindow.windowId,
        workspaceName: workspaceName,
        title: sidebarDisplayLabel(for: representativeWindow),
        windowCount: container.allLeafWindowsRecursive.count,
        isFocused: representativeWindow.moveNode == currentFocus.windowOrNil?.moveNode,
        tabs: tabs,
        allWindows: config.workspaceSidebar.usesTabsList
            ? await buildWorkspaceSidebarTabGroupWindows(for: container, reusing: tabs,
                workspaceName: workspaceName, currentFocus: currentFocus)
            : [],
    )
}

/// All bound windows of the stack in tree order. Windows already built as tabs are reused.
@MainActor
func buildWorkspaceSidebarTabGroupWindows(
    for container: TilingContainer,
    reusing tabs: [WorkspaceSidebarWindowViewModel],
    workspaceName: String,
    currentFocus: LiveFocus,
) async -> [WorkspaceSidebarWindowViewModel] {
    let built = Dictionary(tabs.map { ($0.windowId, $0) }, uniquingKeysWith: { first, _ in first })
    var windows: [WorkspaceSidebarWindowViewModel] = []
    for window in container.allLeafWindowsRecursive where window.isBound {
        if let existing = built[window.windowId] {
            windows.append(existing)
        } else {
            windows.append(await makeWorkspaceSidebarWindowViewModel(
                for: window, workspaceName: workspaceName, currentFocus: currentFocus))
        }
    }
    return windows
}

@MainActor
private func buildWorkspaceSidebarTabItems(
    for container: TilingContainer,
    workspaceName: String,
    currentFocus: LiveFocus,
) async -> [WorkspaceSidebarWindowViewModel] {
    var tabs: [WorkspaceSidebarWindowViewModel] = []
    for child in container.children {
        guard let representative = child.tabRepresentativeWindow ?? child.mostRecentWindowRecursive ?? child.anyLeafWindowRecursive,
              representative.isBound
        else { continue }
        tabs.append(await makeWorkspaceSidebarWindowViewModel(
            for: representative,
            workspaceName: workspaceName,
            currentFocus: currentFocus,
        ))
    }
    return tabs
}
