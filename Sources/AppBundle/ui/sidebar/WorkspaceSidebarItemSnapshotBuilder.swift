@MainActor
func buildWorkspaceSidebarItems(
    for workspace: Workspace,
    currentFocus: LiveFocus,
) async -> [WorkspaceSidebarItemViewModel] {
    var items = await buildWorkspaceSidebarItems(
        from: workspace.rootTilingContainer,
        workspaceName: workspace.name,
        currentFocus: currentFocus,
    )
    for floatingWindow in workspace.floatingWindows where floatingWindow.isBound {
        items.append(.init(kind: .window(await makeWorkspaceSidebarWindowViewModel(
            for: floatingWindow,
            workspaceName: workspace.name,
            currentFocus: currentFocus,
        ))))
    }
    return items
}

/// Tabs mode: a tab's rows, and apart from them the auxiliary windows listed under one of its
/// windows. In a pin, one whose parent is still open anywhere is apart too, so a pin that lent its
/// window still shows that window, not the draft, with the draft only counted. A tab holding a stack
/// lists every window as before.
@MainActor
func workspaceSidebarSeparatingAssociatedWindows(
    _ items: [WorkspaceSidebarItemViewModel],
    in workspace: Workspace,
    isPinned: Bool = false,
) -> (items: [WorkspaceSidebarItemViewModel], associated: [WorkspaceSidebarAssociatedWindowViewModel]) {
    guard config.usesBrowserTabs,
          !items.contains(where: { if case .tabGroup = $0.kind { true } else { false } })
    else { return (items, []) }
    let registry = AuxiliaryWindowRegistry.shared
    var links: [UInt32: (parent: UInt32, role: AuxiliaryWindowRole, needsListedParent: Bool)] = [:]
    for window in workspace.floatingWindows {
        guard let role = registry.role(of: window) else { continue }
        if let parent = auxiliaryWindowParent(of: window) {
            links[window.windowId] = (parent.windowId, role, true)
        } else if isPinned, isAuxiliaryWindowOfOpenParent(window), let parentId = registry.parentWindowId(of: window) {
            links[window.windowId] = (parentId, role, false)
        }
    }
    guard !links.isEmpty else { return (items, []) }
    let listed = Set(items.compactMap { item -> UInt32? in
        guard case .window(let window) = item.kind, links[window.windowId] == nil else { return nil }
        return window.windowId
    })
    var main: [WorkspaceSidebarItemViewModel] = []
    var associated: [WorkspaceSidebarAssociatedWindowViewModel] = []
    for item in items {
        if case .window(let window) = item.kind, let link = links[window.windowId], !link.needsListedParent || listed.contains(link.parent) {
            associated.append(.init(window: window, parentWindowId: link.parent, role: link.role))
        } else {
            main.append(item)
        }
    }
    return (main, associated)
}
