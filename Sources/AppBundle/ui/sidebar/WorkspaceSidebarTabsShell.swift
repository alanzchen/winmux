import AppKit
import SwiftUI

extension WorkspaceSidebarView {
    /// Tabs owns a browser-like column, including its resting presentation. The other
    /// modes continue using their compact workspace rail and existing project controls.
    func tabsSidebarContent(expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration) -> some View {
        let expanded = expansionProgress >= workspaceSidebarRowsRevealProgress
        let pagerInset = layout.compactHorizontalInset +
            (workspaceSidebarContentLeadingInset - layout.compactHorizontalInset) * expansionProgress
        let project = snapshot.projects.first { $0.id == snapshot.activeProjectId }
        let visible = workspaceSidebarVisibleWorkspacesByProject(workspaces: snapshot.workspaces,
            selectedScopeId: snapshot.selectedMonitorScopeId, focusedMonitorScopeId: snapshot.focusedMonitorScopeId,
            browsedProjectId: nil).mapValues { workspaceSidebarOrderedTabs($0, collections: snapshot.configuration.tabCollections) }
        let filtered = workspaceSidebarFilteredWorkspacesByProject(visible, projects: snapshot.projects, query: searchText,
            collections: snapshot.configuration.tabCollections)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if expanded {
                    HStack(spacing: 7) {
                        if let emoji = project?.emoji { Text(emoji) }
                        Text(project?.displayName ?? "Work").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    }
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
                if isSearchEditing || !searchText.isEmpty {
                    tabsSearchResults.frame(maxHeight: .infinity, alignment: .topLeading)
                } else {
                    projectPagerContent(layout: layout, expansionProgress: 1, leadingInset: 10, trailingInset: 10,
                        topPadding: 0, visibleWorkspacesByProject: filtered,
                        swipeDirection: workspaceSidebarProjectSwipeDirection(horizontalTranslation: projectSwipeTranslation,
                            verticalTranslation: 0, minimumDistance: 1))
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(Array((visible[snapshot.activeProjectId] ?? []).enumerated()), id: \.element.id) { index, workspace in
                            let tabs = visible[snapshot.activeProjectId] ?? []
                            if index > 0, tabs[index - 1].appearance.isFavorite, !workspace.appearance.isFavorite {
                                Divider().padding(.horizontal, 8).padding(.vertical, 3)
                            }
                            WorkspaceSidebarPinnedTab(workspace: workspace, badgeModel: dockBadgeModel, compact: true,
                                targetMonitorScopeId: snapshot.targetMonitorScopeId) { windowId in
                                selectTabWorkspace(workspace, windowId: windowId)
                            }
                            .frame(width: 34, height: 34)
                            .overlay(alignment: .leading) {
                                if let group = snapshot.configuration.tabCollections.first(where: { $0.workspaceNames.contains(workspace.name) }) {
                                    Capsule().fill(group.colorHex.flatMap(workspaceSidebarColor) ?? .secondary)
                                        .frame(width: 3, height: 23).offset(x: -4).allowsHitTesting(false)
                                }
                            }
                            .help(workspace.displayName)
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
            if expanded { WorkspaceSidebarTabUndoButton(actions: actions) }
            projectPagerSection(layout: layout, expansionProgress: expansionProgress,
                leadingInset: pagerInset, trailingInset: pagerInset,
                swipeDirection: workspaceSidebarProjectSwipeDirection(horizontalTranslation: projectSwipeTranslation,
                    verticalTranslation: 0, minimumDistance: 1), switchProgress: 0, edgeProgress: 0)
            if expanded {
                HStack {
                    Button { ShortcutSettingsModel.shared.requestDockSettings() } label: { Image(systemName: "gearshape") }
                        .help("Sidebar Settings").accessibilityLabel("Sidebar Settings")
                    Spacer()
                    Text("\((visible[snapshot.activeProjectId] ?? []).count) tabs").font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).padding(14)
            } else {
                Color.clear.frame(height: 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { sidebarSurface(in: sidebarShape(layout: layout)) }
        .clipShape(sidebarShape(layout: layout))
        .environment(\.workspaceSidebarBadgeOwners, workspaceSidebarBadgeOwners(
            isSearchEditing || !searchText.isEmpty
                ? tabsSearchProjectOrder.filter { !searchText.isEmpty || $0.id == snapshot.activeProjectId }
                    .flatMap { filtered[$0.id] ?? [] }
                : visible[snapshot.activeProjectId] ?? []))
    }

    private func tabsFavorites(_ workspaces: [WorkspaceSidebarWorkspaceViewModel]) -> some View {
        let favorites = workspaces.filter { $0.appearance.isFavorite }
        let grid = WorkspaceSidebarPinnedGridLayout(workspaces: favorites, width: snapshot.visibleWidth - 20)
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: grid.columns), spacing: 8) {
                ForEach(favorites) { workspace in
                    WorkspaceSidebarPinnedTab(workspace: workspace, badgeModel: dockBadgeModel,
                        targetMonitorScopeId: snapshot.targetMonitorScopeId) { windowId in
                        selectTabWorkspace(workspace, windowId: windowId)
                    }
                }
            }
            .animation(reduceDockMotion ? nil : .easeInOut(duration: 0.18),
                value: favorites.map(WorkspaceSidebarPinnedTabIdentity.init))
        }
        .frame(height: grid.height)
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

    private func selectTabWorkspace(_ workspace: WorkspaceSidebarWorkspaceViewModel, windowId: UInt32?) {
        let (activation, _) = tabActivation(workspace, isPinned: false, pageAllowsActivation: true)
        activation.select(windowId.map(WorkspaceSidebarAction.selectWindow) ?? .selectWorkspace(workspace.name), send: actions.send)
    }

    func tabCollection(_ group: WorkspaceTabCollection, workspaces: [WorkspaceSidebarWorkspaceViewModel],
                       projectId: WorkspaceProjectId, pageAllowsActivation: Bool, isSearching: Bool,
                       overrideMinHeight: CGFloat, monitorScopeId: String) -> some View {
        let color = group.colorHex.flatMap(workspaceSidebarColor) ?? Color.secondary
        let disclosure = WorkspaceSidebarTabCollectionDisclosure(group: group,
            containsActiveTab: snapshot.workspaces.contains {
                group.workspaceNames.contains($0.name) && $0.isVisible &&
                    (workspaceSidebarMonitorScopeIsSentinel(snapshot.targetMonitorScopeId) || $0.monitorScopeId == snapshot.targetMonitorScopeId)
            },
            isSearching: isSearching)
        let rows = disclosure.isCollapsed ? [] : workspaces
        let isDropTarget = snapshot.dropPreview?.targetCollectionId == group.id
        return VStack(alignment: .leading, spacing: 3) {
            Button { if disclosure.canToggle { actions.send(.toggleTabCollection(group.id)) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: disclosure.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    if let emoji = group.emoji { Text(emoji) }
                    if disclosure.isCollapsed {
                        ForEach(Array(workspaces.flatMap(workspaceSidebarPinnedTabWindows).prefix(3))) { window in
                            WorkspaceSidebarTabIcon(bundleId: window.appBundleId, bundlePath: window.appBundlePath, size: 13)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(group.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if disclosure.isCollapsed { WorkspaceSidebarGroupActivity(workspaces: workspaces, model: dockBadgeModel) }
                    Text("\(workspaces.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                }.foregroundStyle(color).padding(.horizontal, 9).frame(height: 35).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(disclosure.canToggle
                    ? "\(disclosure.isCollapsed ? "Expand" : "Collapse") group \(group.name)" : "Group \(group.name)")
                .accessibilityValue(disclosure.isCollapsed ? "Collapsed" : "Expanded")
                .accessibilityHint(disclosure.canToggle ? "" : (isSearching ? "Expanded for search" : "Contains the active tab"))
                .sidebarIdentityMenu(.collection(group.id, isSearching: isSearching,
                    monitorScopeId: snapshot.targetMonitorScopeId, createMonitorScopeId: monitorScopeId))
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
            if rows.isEmpty, !disclosure.isCollapsed {
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
