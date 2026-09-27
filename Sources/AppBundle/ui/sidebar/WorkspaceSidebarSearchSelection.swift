enum WorkspaceSidebarSearchSelection: Hashable {
    case workspace(String)
    case window(UInt32)
    case browserTab(BrowserTabTarget)
}

func workspaceSidebarSearchSelections(
    workspaces: [WorkspaceSidebarWorkspaceViewModel],
    browserTabs: [UInt32: BrowserWindowTabs] = [:],
    query: String = "",
    projects: [WorkspaceSidebarProjectViewModel] = [],
    collections: [WorkspaceTabCollection] = [],
) -> [WorkspaceSidebarSearchSelection] {
    workspaces.flatMap { workspace in
        let presentation = workspaceSidebarTabPresentation(workspace)
        if case .split = presentation {
            return splitSelections(workspace, browserTabs: browserTabs, query: query, projects: projects, collections: collections)
        }
        if case .multiple = presentation {
            return splitSelections(workspace, browserTabs: browserTabs, query: query, projects: projects, collections: collections)
        }
        let itemSelections = workspace.items.flatMap { item -> [WorkspaceSidebarSearchSelection] in
            switch item.kind {
                case .window(let window):
                    let context = workspaceSidebarBrowserSearchContext(workspace, projects: projects, collections: collections)
                    let tabs = workspaceSidebarMatchingBrowserTabs(browserTabs[window.windowId], window: window,
                        workspace: workspace, query: query, context: context)
                    if !tabs.isEmpty {
                        let header: [WorkspaceSidebarSearchSelection] = workspaceSidebarBrowserHeaderMatchesSearch(window,
                            workspace: workspace, query: query, context: context) ? [.window(window.windowId)] : []
                        return header + tabs.map { .browserTab($0.target) }
                    }
                    return [.window(window.windowId)]
                case .tabGroup(let group):
                    // The same windows the stack renders, in the same order.
                    return workspaceSidebarTabGroupWindows(group).map { .window($0.windowId) }
            }
        }
        return itemSelections.isEmpty ? [.workspace(workspace.name)] : itemSelections
    }
}

private func splitSelections(_ workspace: WorkspaceSidebarWorkspaceViewModel,
    browserTabs: [UInt32: BrowserWindowTabs], query: String,
    projects: [WorkspaceSidebarProjectViewModel], collections: [WorkspaceTabCollection]) -> [WorkspaceSidebarSearchSelection] {
    let windows = workspaceSidebarPinnedTabWindows(workspace)
    let context = workspaceSidebarBrowserSearchContext(workspace, projects: projects, collections: collections)
    var headers: [WorkspaceSidebarSearchSelection] = []
    var children: [WorkspaceSidebarSearchSelection] = []
    for window in windows {
        let tabs = workspaceSidebarMatchingBrowserTabs(browserTabs[window.windowId], window: window, workspace: workspace,
            query: query, context: context)
        if tabs.isEmpty || workspaceSidebarBrowserHeaderMatchesSearch(window, workspace: workspace, query: query, context: context) {
            headers.append(.window(window.windowId))
        }
        children += tabs.map { .browserTab($0.target) }
    }
    return headers + children
}
