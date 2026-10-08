import Foundation

func workspaceSidebarFilteredWorkspacesByProject(
    _ workspacesByProject: [WorkspaceProjectId: [WorkspaceSidebarWorkspaceViewModel]],
    projects: [WorkspaceSidebarProjectViewModel],
    query: String,
    collections: [WorkspaceTabCollection] = [],
    browserTabs: [UInt32: BrowserWindowTabs] = [:],
) -> [WorkspaceProjectId: [WorkspaceSidebarWorkspaceViewModel]] {
    let terms = workspaceSidebarSearchTerms(query)
    guard !terms.isEmpty else { return workspacesByProject }
    let projectNamesById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.displayName) })
    let collectionNames = collections.reduce(into: [String: String]()) { names, group in
        for member in group.workspaceNames { names[member] = group.name }
    }

    return workspacesByProject.mapValues { workspaces in
        workspaces.compactMap { workspace in
            workspaceSidebarFilteredWorkspace(
                workspace,
                projectName: [projectNamesById[workspace.projectId], collectionNames[workspace.name]].compactMap { $0 }.joined(separator: " "),
                terms: terms,
                browserTabs: browserTabs,
            )
        }
    }
}

private func workspaceSidebarFilteredWorkspace(
    _ workspace: WorkspaceSidebarWorkspaceViewModel,
    projectName: String?,
    terms: [String],
    browserTabs: [UInt32: BrowserWindowTabs],
) -> WorkspaceSidebarWorkspaceViewModel? {
    let matchingItems = workspace.items.compactMap { item in
        workspaceSidebarSearchResultItem(item, workspace: workspace, projectName: projectName, terms: terms, browserTabs: browserTabs)
    }
    if !matchingItems.isEmpty {
        return WorkspaceSidebarWorkspaceViewModel(
            name: workspace.name,
            projectId: workspace.projectId,
            displayName: workspace.displayName,
            sidebarLabel: workspace.sidebarLabel,
            isGeneratedName: workspace.isGeneratedName,
            monitorScopeId: workspace.monitorScopeId,
            monitorName: workspace.monitorName,
            isFocused: workspace.isFocused,
            isVisible: workspace.isVisible,
            items: matchingItems,
            apps: workspace.apps,
            savedState: workspace.savedState,
            appearance: workspace.appearance,
            preservesFolderPresentation: workspaceSidebarTabPresentation(workspace) == .folder,
            lentWindow: workspace.lentWindow,
            recallsWindows: workspace.recallsWindows,
        )
    }
    if workspaceSidebarWorkspaceMatchesSearch(workspace, projectName: projectName, terms: terms) {
        return workspace
    }
    return nil
}

private func workspaceSidebarSearchTerms(_ query: String) -> [String] {
    query
        .split(whereSeparator: { $0.isWhitespace })
        .map { String($0).localizedLowercase }
        .filter { !$0.isEmpty }
}

private func workspaceSidebarSearchResultItem(
    _ item: WorkspaceSidebarItemViewModel,
    workspace: WorkspaceSidebarWorkspaceViewModel,
    projectName: String?,
    terms: [String],
    browserTabs: [UInt32: BrowserWindowTabs],
) -> WorkspaceSidebarItemViewModel? {
    switch item.kind {
        case .window(let window):
            if !workspaceSidebarMatchingBrowserTabs(browserTabs[window.windowId], window: window, workspace: workspace,
                query: terms.joined(separator: " "), context: projectName ?? "").isEmpty { return item }
            if workspaceSidebarSearchTextMatches(
                [
                    window.title,
                    window.appName,
                    window.appBundleId,
                    workspaceSidebarSearchableBundleName(window.appBundlePath),
                    workspace.displayName,
                    workspace.name,
                    projectName,
                ],
                terms: terms,
            ) {
                return item
            }
            return nil
        case .tabGroup(let group):
            // Tabs mode lists every window of the stack, so search every window it can show.
            let searchable = group.allWindows.isEmpty ? group.tabs : group.allWindows
            let matchingTabs = searchable.filter { tab in
                workspaceSidebarSearchTextMatches(
                    [tab.title, tab.appName, tab.appBundleId, workspaceSidebarSearchableBundleName(tab.appBundlePath),
                     workspace.displayName, workspace.name, projectName],
                    terms: terms,
                )
            }
            if !matchingTabs.isEmpty {
                return WorkspaceSidebarItemViewModel(kind: .tabGroup(WorkspaceSidebarTabGroupViewModel(
                    representativeWindowId: group.representativeWindowId,
                    workspaceName: group.workspaceName,
                    title: group.title,
                    windowCount: group.windowCount,
                    isFocused: group.isFocused,
                    tabs: group.tabs,
                    searchVisibleTabs: matchingTabs,
                    allWindows: group.allWindows,
                )))
            }
            guard workspaceSidebarSearchTextMatches(
                [
                    group.title,
                    workspace.displayName,
                    workspace.name,
                    projectName,
                ],
                terms: terms,
            ) else {
                return nil
            }
            return WorkspaceSidebarItemViewModel(kind: .tabGroup(WorkspaceSidebarTabGroupViewModel(
                representativeWindowId: group.representativeWindowId,
                workspaceName: group.workspaceName,
                title: group.title,
                windowCount: group.windowCount,
                isFocused: group.isFocused,
                tabs: group.tabs,
                // A stack found by its title: the Sidebar shows its header alone, while Tabs
                // mode lists windows and shows all of them.
                searchVisibleTabs: group.allWindows,
                allWindows: group.allWindows,
            )))
    }
}

private func workspaceSidebarWorkspaceMatchesSearch(
    _ workspace: WorkspaceSidebarWorkspaceViewModel,
    projectName: String?,
    terms: [String],
) -> Bool {
    workspaceSidebarSearchTextMatches(
        [
            workspace.displayName,
            workspace.sidebarLabel,
            workspace.name,
            workspace.monitorName,
            projectName,
        ],
        terms: terms,
    )
}

/// Matches an app by its bundle's file name. Its folders, such as `/System/Applications`,
/// would otherwise match short queries for every app.
func workspaceSidebarSearchableBundleName(_ bundlePath: String?) -> String? {
    guard let bundlePath, !bundlePath.isEmpty else { return nil }
    return ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
}

private func workspaceSidebarSearchTextMatches(_ values: [String?], terms: [String]) -> Bool {
    let searchableText = values
        .compactMap { $0?.localizedLowercase }
        .joined(separator: " ")
    return terms.allSatisfy { searchableText.contains($0) }
}
