enum WorkspaceSidebarSearchSelection: Hashable {
    case workspace(String)
    case window(UInt32)
    case browserTab(BrowserTabTarget)
}

/// The panel keeps the key handler a search session began with, and a handler captured then
/// would read that moment's snapshot. The panel's handler forwards here instead, and each view
/// update replaces `handler` with one that reads the current snapshot.
@MainActor
final class WorkspaceSidebarSearchKeyRelay {
    var handler: (@MainActor (WorkspaceSidebarInlineTextKey) -> Void)?

    func send(_ key: WorkspaceSidebarInlineTextKey) { handler?(key) }
}

/// The search selection while it's still among the listed matches. A display filter or
/// workspace change can hide it, and Enter must not open a result that isn't listed.
func workspaceSidebarListedSearchTarget(
    _ target: WorkspaceSidebarSearchSelection?,
    in selections: [WorkspaceSidebarSearchSelection],
) -> WorkspaceSidebarSearchSelection? {
    target.flatMap { selections.contains($0) ? $0 : nil }
}

func workspaceSidebarSearchSelections(
    workspaces: [WorkspaceSidebarWorkspaceViewModel],
    browserTabs: [UInt32: BrowserWindowTabs] = [:],
    query: String = "",
    projects: [WorkspaceSidebarProjectViewModel] = [],
    collections: [WorkspaceTabCollection] = [],
) -> [WorkspaceSidebarSearchSelection] {
    workspaces.flatMap { workspace in
        // Windows listed under the tab's own come after them, in the order they're shown.
        workspaceSidebarTabSearchSelections(workspace, browserTabs: browserTabs, query: query, projects: projects,
            collections: collections) + workspaceSidebarListedAssociatedWindows(workspace).map { .window($0.window.windowId) }
    }
}

private func workspaceSidebarTabSearchSelections(
    _ workspace: WorkspaceSidebarWorkspaceViewModel,
    browserTabs: [UInt32: BrowserWindowTabs],
    query: String,
    projects: [WorkspaceSidebarProjectViewModel],
    collections: [WorkspaceTabCollection],
) -> [WorkspaceSidebarSearchSelection] {
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
    // A tab found only by a draft, such as a pin that lent its window: the arrow keys reach the draft alone.
    guard itemSelections.isEmpty else { return itemSelections }
    return workspace.associatedWindows.isEmpty ? [.workspace(workspace.name)] : []
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
