import AppKit
import SwiftUI

extension WorkspaceSidebarView {
    /// Tabs owns a browser-like column, including its resting presentation. The other
    /// modes continue using their compact workspace rail and existing project controls.
    func tabsSidebarContent(expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration) -> some View {
        let expanded = expansionProgress >= workspaceSidebarRowsRevealProgress
        let project = snapshot.projects.first { $0.id == snapshot.activeProjectId }
        let visible = workspaceSidebarVisibleWorkspacesByProject(workspaces: snapshot.workspaces,
            selectedScopeId: snapshot.selectedMonitorScopeId, focusedMonitorScopeId: snapshot.focusedMonitorScopeId,
            browsedProjectId: nil)
        let filtered = workspaceSidebarFilteredWorkspacesByProject(visible, projects: snapshot.projects, query: searchText,
            collections: snapshot.configuration.tabCollections)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if expanded {
                    Menu {
                        ForEach(snapshot.projects) { item in
                            Button(item.displayName) { actions.send(.selectProject(item.id)) }
                        }
                        Divider()
                        Button("Edit Project…") { WorkspaceSidebarIdentityMenu.show(.project(snapshot.activeProjectId), selectName: true) }
                        Button("New Project") { actions.send(.createProject) }
                    } label: {
                        HStack(spacing: 7) {
                            if let emoji = project?.emoji { Text(emoji) }
                            Text(project?.displayName ?? "Work").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .sidebarIdentityMenu(.project(snapshot.activeProjectId))
                    Spacer(minLength: 0)
                }
                Button { actions.send(.toggleTabsSidebar) } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 15)).frame(width: 28, height: 30)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse sidebar" : "Keep sidebar open")
                .accessibilityLabel(expanded ? "Collapse sidebar" : "Keep sidebar open")
            }
            .padding(.horizontal, expanded ? 14 : 8)
            .padding(.top, 14).padding(.bottom, 12)

            if expanded {
                if snapshot.monitorScopes.count > 1 {
                    Menu {
                        ForEach(snapshot.monitorScopes) { scope in
                            Button(scope.displayName) { actions.send(.selectMonitorScope(scope.id)) }
                        }
                    } label: {
                        Label(snapshot.monitorScopes.first { $0.id == snapshot.selectedMonitorScopeId }?.displayName ?? "This Display",
                            systemImage: "display")
                    }
                    .menuStyle(.borderlessButton).padding(.horizontal, 16).padding(.bottom, 10)
                }
                if searchText.isEmpty, !isSearchEditing {
                    tabsFavorites(visible[snapshot.activeProjectId] ?? [])
                    Button { beginSidebarSearchIfNeeded() } label: {
                        Label("Search tabs", systemImage: "magnifyingglass")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(9).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 4)
                } else {
                    sidebarSearchSection(layout: layout, expansionProgress: 1, leadingInset: 12, trailingInset: 12)
                }
                projectPagerContent(layout: layout, expansionProgress: 1, leadingInset: 10, trailingInset: 10,
                    topPadding: 0, visibleWorkspacesByProject: filtered,
                    swipeDirection: workspaceSidebarProjectSwipeDirection(horizontalTranslation: projectSwipeTranslation,
                        verticalTranslation: 0, minimumDistance: 1))
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                HStack {
                    Button { ShortcutSettingsModel.shared.requestDockSettings() } label: { Image(systemName: "gearshape") }
                        .help("Sidebar Settings").accessibilityLabel("Sidebar Settings")
                    Spacer()
                    Text("\((visible[snapshot.activeProjectId] ?? []).count) tabs").font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(visible[snapshot.activeProjectId] ?? []) { workspace in
                            Button { selectTabWorkspace(workspace) } label: {
                                if let emoji = workspace.appearance.emoji { Text(emoji).font(.system(size: 19)) }
                                else if let first = workspace.items.first, case .window(let window) = first.kind {
                                    WorkspaceSidebarTabIcon(bundleId: window.appBundleId, bundlePath: window.appBundlePath, size: 20)
                                } else { Image(systemName: "macwindow") }
                            }
                            .buttonStyle(.plain).frame(width: 34, height: 34)
                            .background(workspace.isVisible ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .help(workspace.displayName).accessibilityLabel(workspace.displayName)
                            .sidebarIdentityMenu(.workspace(workspace.name))
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { sidebarSurface(in: sidebarShape(layout: layout)) }
        .clipShape(sidebarShape(layout: layout))
    }

    private func tabsFavorites(_ workspaces: [WorkspaceSidebarWorkspaceViewModel]) -> some View {
        let favorites = workspaces.filter { $0.appearance.isFavorite }
        return ScrollView {
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(favorites) { workspace in
                Button { selectTabWorkspace(workspace) } label: {
                    VStack(spacing: 4) {
                        if let emoji = workspace.appearance.emoji { Text(emoji).font(.system(size: 23)) }
                        else if let first = workspace.items.first, case .window(let window) = first.kind {
                            WorkspaceSidebarTabIcon(bundleId: window.appBundleId, bundlePath: window.appBundlePath, size: 24)
                        } else { Image(systemName: "macwindow").font(.system(size: 22)) }
                    }
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background((workspace.appearance.colorHex.flatMap(workspaceSidebarColor) ?? Color.primary)
                        .opacity(workspace.isVisible ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
                }.buttonStyle(.plain).help(workspace.displayName).accessibilityLabel(workspace.displayName)
                    .sidebarIdentityMenu(.workspace(workspace.name))
            }
          }
        }
        .frame(height: CGFloat(min(3, (favorites.count + 2) / 3) * 62 - (favorites.isEmpty ? 0 : 8)))
        .padding(.horizontal, 10).padding(.bottom, favorites.isEmpty ? 0 : 8)
        .overlay {
            if let workspace = favorites.first(where: { $0.name == activeInUseOverrideWorkspaceName }) {
                WorkspaceSidebarInUseOverrideOverlay(
                    text: workspace.monitorName.map { "In use on \($0)" } ?? "In use on another display",
                    onOverride: {
                        activeInUseOverrideWorkspaceName = nil
                        actions.send(.overrideWorkspaceInUse(workspace.name))
                    }, onCancel: { activeInUseOverrideWorkspaceName = nil })
            }
        }
    }

    private func selectTabWorkspace(_ workspace: WorkspaceSidebarWorkspaceViewModel) {
        let (activation, _) = tabActivation(workspace, isPinned: false, pageAllowsActivation: true)
        activation.select(.selectWorkspace(workspace.name), send: actions.send)
    }

    func tabCollection(_ group: WorkspaceTabCollection, workspaces: [WorkspaceSidebarWorkspaceViewModel],
                       projectId: WorkspaceProjectId, pageAllowsActivation: Bool, isSearching: Bool,
                       overrideMinHeight: CGFloat, monitorScopeId: String) -> some View {
        let color = group.colorHex.flatMap(workspaceSidebarColor) ?? Color.secondary
        let rows = group.isCollapsed && !isSearching ? workspaces.filter(\.isVisible) : workspaces
        let isDropTarget = snapshot.dropPreview?.targetCollectionId == group.id
        return VStack(alignment: .leading, spacing: 3) {
            Button { actions.send(.toggleTabCollection(group.id)) } label: {
                HStack(spacing: 8) {
                    Image(systemName: group.isCollapsed && !isSearching ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    if let emoji = group.emoji { Text(emoji) }
                    Text(group.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(workspaces.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                }.foregroundStyle(color).padding(.horizontal, 9).frame(height: 35).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(group.isCollapsed ? "Expand" : "Collapse") group \(group.name)")
                .sidebarIdentityMenu(.collection(group.id))
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: WorkspaceSidebarDropTargetPreferenceKey.self,
                            value: [.init(kind: .tabCollection(group.id), frame: geometry.frame(in: .named("workspaceSidebarContent")))])
                    }
                }
            ForEach(rows) { workspace in
                tabEntry(workspace, isPinned: false, projectId: projectId, pageAllowsActivation: pageAllowsActivation,
                    isSearching: isSearching, overrideMinHeight: overrideMinHeight, monitorScopeId: monitorScopeId,
                    collectionId: group.id)
                    .id(workspaceSidebarTabFolderRowId(workspace.name))
            }
            if rows.isEmpty, !group.isCollapsed {
                Text(isDropTarget ? "Add tab to group" : "Drag tabs here")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
            }
        }
        .padding(5)
        .background(color.opacity(isDropTarget ? 0.23 : 0.11), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(isDropTarget ? 0.7 : 0.16), lineWidth: 1))
        .padding(.vertical, 4)
    }
}
