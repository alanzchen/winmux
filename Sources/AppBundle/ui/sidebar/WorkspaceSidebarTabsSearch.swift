import SwiftUI

extension WorkspaceSidebarView {
    var tabsSearchProjectOrder: [WorkspaceSidebarProjectViewModel] {
        let current = snapshot.projects.filter { $0.id == snapshot.activeProjectId }
        return current + snapshot.projects.filter { $0.id != snapshot.activeProjectId }
    }

    /// Rendering, arrow keys, and Enter consume exactly the same ordered matches.
    func tabsSearchWorkspacesByProject() -> [WorkspaceProjectId: [WorkspaceSidebarWorkspaceViewModel]] {
        workspaceSidebarFilteredWorkspacesByProject(snapshot.tabsListedWorkspacesByProject, projects: snapshot.projects,
            query: searchText, collections: snapshot.configuration.tabCollections, browserTabs: browserTabs)
    }

    var tabsSearchResults: some View {
        let matches = tabsSearchWorkspacesByProject()
        let projects = tabsSearchProjectOrder.filter {
            (searchText.isEmpty ? $0.id == snapshot.activeProjectId : true) && !(matches[$0.id] ?? []).isEmpty
        }
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if projects.isEmpty {
                            Text("No matching tabs").font(.system(size: 13)).foregroundStyle(.secondary)
                                .padding(.horizontal, workspaceSidebarTabLeadingPadding).padding(.vertical, 12)
                        }
                        ForEach(projects) { project in
                            Text(project.id == snapshot.activeProjectId ? project.displayName : "In \(project.displayName)")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, workspaceSidebarTabLeadingPadding).padding(.top, 8)
                            ForEach(matches[project.id] ?? []) { workspace in
                                tabEntry(workspace, isPinned: false, projectId: project.id,
                                    pageAllowsActivation: true, isSearching: true,
                                    overrideMinHeight: workspaceSidebarInUseOverrideMinHeight(sectionWidth: viewport.size.width - 20),
                                    monitorScopeId: snapshot.targetMonitorScopeId)
                                    .id(workspaceSidebarTabFolderRowId(workspace.name))
                            }
                        }
                    }.padding(.horizontal, workspaceSidebarTabsListInset).padding(.bottom, 10)
                }
                .onChange(of: selectedSearchTarget) { target in
                    let tabs = projects.flatMap { matches[$0.id] ?? [] }
                    workspaceSidebarScrollTabsList(to: workspaceSidebarTabScrollTarget(folders: tabs, searchSelection: target), with: proxy)
                }
            }
        }
    }
}
