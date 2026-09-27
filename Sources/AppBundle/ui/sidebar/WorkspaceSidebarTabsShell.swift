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
            collections: snapshot.configuration.tabCollections, browserTabs: browserTabs)
        let collapsedGroups = Set(snapshot.configuration.tabCollections.filter {
            expanded && !isSearchEditing && searchText.isEmpty && tabCollectionDisclosure($0).isCollapsed
        }.map(\.id))
        let isSearchActive = isSearchEditing || !searchText.isEmpty
        // While the sidebar opens or closes, the list fades in once there's room for it and
        // the rail fades out before it goes, instead of either popping at the threshold.
        let reveal = min(max((expansionProgress - workspaceSidebarRowsRevealProgress) / 0.3, 0), 1)
        let railOpacity = min(max(1 - expansionProgress / workspaceSidebarRowsRevealProgress, 0), 1)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if expanded {
                    // The project's emoji and name sit on the tabs' icon and title columns.
                    HStack(spacing: 9) {
                        if let emoji = project?.emoji {
                            Text(emoji).font(.system(size: 15)).frame(width: workspaceSidebarTabIconSize)
                        }
                        Text(project?.displayName ?? "Work").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    }
                    .opacity(reveal)
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
            // Expanded, the toggle centers on the column of the rows' counts and close buttons.
            .padding(.leading, expanded ? workspaceSidebarTabsListInset + workspaceSidebarTabLeadingPadding : 8)
            .padding(.trailing, expanded ? workspaceSidebarTabsListInset + workspaceSidebarTabTrailingSlotWidth / 2 - 14 : 8)
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
                    .menuStyle(.borderlessButton)
                    .padding(.leading, workspaceSidebarTabsListInset + workspaceSidebarTabLeadingPadding)
                    .padding(.trailing, 16).padding(.bottom, 10)
                    .opacity(reveal)
                }
                if !isSearchActive {
                    tabsFavorites(visible[snapshot.activeProjectId] ?? [])
                        .opacity(reveal)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                WorkspaceSidebarTabsSearchRow(text: searchText, isEditing: isSearchEditing,
                    onBegin: { beginSidebarSearchIfNeeded() },
                    onClear: {
                        finishSidebarSearch(clearText: true)
                        beginSidebarSearchIfNeeded()
                    })
                    .padding(.horizontal, workspaceSidebarTabsListInset).padding(.bottom, 4)
                    .opacity(reveal)
                ZStack(alignment: .topLeading) {
                    if isSearchActive {
                        tabsSearchResults.transition(.opacity)
                    } else {
                        projectPagerContent(layout: layout, expansionProgress: 1, leadingInset: workspaceSidebarTabsListInset,
                            trailingInset: workspaceSidebarTabsListInset,
                            topPadding: 0, visibleWorkspacesByProject: filtered,
                            swipeDirection: workspaceSidebarProjectSwipeDirection(horizontalTranslation: projectSwipeTranslation,
                                verticalTranslation: 0, minimumDistance: 1))
                            .transition(.opacity)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .opacity(reveal)
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
                .opacity(railOpacity)
            }
            if expanded { WorkspaceSidebarTabUndoButton(actions: actions, reducesMotion: reduceDockMotion).opacity(reveal) }
            projectPagerSection(layout: layout, expansionProgress: expansionProgress,
                leadingInset: pagerInset, trailingInset: pagerInset,
                swipeDirection: workspaceSidebarProjectSwipeDirection(horizontalTranslation: projectSwipeTranslation,
                    verticalTranslation: 0, minimumDistance: 1), switchProgress: 0, edgeProgress: 0)
            if expanded {
                HStack {
                    Button { ShortcutSettingsModel.shared.requestDockSettings() } label: {
                        Image(systemName: "gearshape").frame(width: workspaceSidebarTabIconSize)
                    }
                    .help("Sidebar Settings").accessibilityLabel("Sidebar Settings")
                    Spacer()
                    Text("\((visible[snapshot.activeProjectId] ?? []).count) tabs").font(.system(size: 11)).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                .padding(.leading, workspaceSidebarTabsListInset + workspaceSidebarTabLeadingPadding)
                .padding(.trailing, 14).padding(.vertical, 14)
                .opacity(reveal)
            } else {
                Color.clear.frame(height: 6)
            }
        }
        .animation(reduceDockMotion ? nil : WorkspaceSidebarTabMotion.disclosure, value: isSearchActive)
        .environment(\.workspaceSidebarReducesMotion, reduceDockMotion)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { sidebarSurface(in: sidebarShape(layout: layout)) }
        .clipShape(sidebarShape(layout: layout))
        .environment(\.workspaceSidebarBadgeOwners, workspaceSidebarBadgeOwners(
            isSearchEditing || !searchText.isEmpty
                ? tabsSearchProjectOrder.filter { !searchText.isEmpty || $0.id == snapshot.activeProjectId }
                    .flatMap { filtered[$0.id] ?? [] }
                : visible[snapshot.activeProjectId] ?? [],
            collections: snapshot.configuration.tabCollections, collapsedCollectionIds: collapsedGroups))
    }

    private func tabsFavorites(_ workspaces: [WorkspaceSidebarWorkspaceViewModel]) -> some View {
        let favorites = workspaces.filter { $0.appearance.isFavorite }
        let grid = WorkspaceSidebarPinnedGridLayout(workspaces: favorites, width: snapshot.visibleWidth - 20)
        return ScrollView {
            WorkspaceSidebarPinnedGrid(columns: grid.columns) {
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

    func tabCollectionDisclosure(_ group: WorkspaceTabCollection, isSearching: Bool = false) -> WorkspaceSidebarTabCollectionDisclosure {
        WorkspaceSidebarTabCollectionDisclosure(group: group,
            containsActiveTab: snapshot.workspaces.contains {
                group.workspaceNames.contains($0.name) && $0.isVisible &&
                    (workspaceSidebarMonitorScopeIsSentinel(snapshot.targetMonitorScopeId) || $0.monitorScopeId == snapshot.targetMonitorScopeId)
            }, isSearching: isSearching)
    }

    func tabCollection(_ group: WorkspaceTabCollection, workspaces: [WorkspaceSidebarWorkspaceViewModel],
                       projectId: WorkspaceProjectId, pageAllowsActivation: Bool, isSearching: Bool,
                       overrideMinHeight: CGFloat, monitorScopeId: String) -> some View {
        let color = group.colorHex.flatMap(workspaceSidebarColor)
        let disclosure = tabCollectionDisclosure(group, isSearching: isSearching)
        let isDropTarget = snapshot.dropPreview?.targetCollectionId == group.id
        return WorkspaceSidebarTabGroupCard(tint: color, isExpanded: !disclosure.isCollapsed, isDropTarget: isDropTarget) {
            WorkspaceSidebarTabCollectionHeader(group: group, workspaces: workspaces, tint: color, disclosure: disclosure,
                badgeModel: dockBadgeModel) {
                if disclosure.canToggle { actions.send(.toggleTabCollection(group.id)) }
            }
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
        } content: {
            ForEach(workspaces) { workspace in
                tabEntry(workspace, isPinned: false, projectId: projectId, pageAllowsActivation: pageAllowsActivation,
                    isSearching: isSearching, overrideMinHeight: overrideMinHeight, monitorScopeId: monitorScopeId,
                    collectionId: group.id)
                    .id(workspaceSidebarTabFolderRowId(workspace.name))
                    .transition(.workspaceSidebarTabReveal)
            }
            if workspaces.isEmpty {
                WorkspaceSidebarTabsGroupPlaceholder(isDropTarget: isDropTarget)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A group's header, which opens and closes it.
struct WorkspaceSidebarTabCollectionHeader: View {
    let group: WorkspaceTabCollection
    let workspaces: [WorkspaceSidebarWorkspaceViewModel]
    let tint: Color?
    let disclosure: WorkspaceSidebarTabCollectionDisclosure
    @ObservedObject var badgeModel: WorkspaceSidebarDockBadgeModel
    let toggle: () -> Void
    @State private var isHovered = false
    @Environment(\.workspaceSidebarTabIndent) private var indent

    var body: some View {
        Button(action: toggle) {
            WorkspaceSidebarTabGroupHeaderLabel(isExpanded: !disclosure.isCollapsed, tint: tint, count: workspaces.count,
                canToggle: disclosure.canToggle, isHighlighted: isHovered && disclosure.canToggle) {
                if let emoji = group.emoji {
                    Text(emoji).font(.system(size: 13))
                } else {
                    // The group's color, where its tabs show their app icons.
                    Circle().fill(tint ?? Color.secondary).frame(width: 8, height: 8)
                }
            } title: {
                WorkspaceSidebarTabGroupTitle(text: group.name, tint: tint)
            } accessory: {
                // A closed group previews what it holds after its name, keeping names aligned.
                if disclosure.isCollapsed {
                    HStack(spacing: 3) {
                        ForEach(Array(workspaces.flatMap(workspaceSidebarPinnedTabWindows).prefix(3))) { window in
                            WorkspaceSidebarTabIcon(bundleId: window.appBundleId, bundlePath: window.appBundlePath, size: 13)
                                .accessibilityHidden(true)
                        }
                    }
                    .transition(.opacity)
                    WorkspaceSidebarGroupActivity(workspaces: workspaces, model: badgeModel)
                }
            }
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: indent.rowCornerRadius, style: .continuous)
                .fill((tint ?? Color.primary).opacity(isHovered && disclosure.canToggle ? 0.1 : 0))
        }
        .onHover { hovering in withAnimation(WorkspaceSidebarTabMotion.hover) { isHovered = hovering } }
    }
}

/// An empty group's hint, on its rows' title column.
struct WorkspaceSidebarTabsGroupPlaceholder: View {
    let isDropTarget: Bool
    @Environment(\.workspaceSidebarTabIndent) private var indent

    var body: some View {
        Text(isDropTarget ? "Add tab to group" : "Drag tabs here")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.leading, indent.leadingPadding)
            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, alignment: .leading)
            .animation(WorkspaceSidebarTabMotion.feedback, value: isDropTarget)
    }
}

/// The distance from the sidebar's edge to the tabs list, shared by everything aligned with it.
let workspaceSidebarTabsListInset: CGFloat = 10

/// Search tabs, resting or typing: one row on the tabs' columns, so starting a search changes
/// its look but moves nothing.
struct WorkspaceSidebarTabsSearchRow: View {
    let text: String
    let isEditing: Bool
    let onBegin: () -> Void
    let onClear: () -> Void
    @State private var isHovered = false

    private var isActive: Bool { isEditing || !text.isEmpty }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
        Button(action: onBegin) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(isActive ? 0.7 : 0.45))
                    .frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
                Text(text.isEmpty ? "Search tabs" : text)
                    .font(.system(size: 13, weight: text.isEmpty ? .regular : .medium))
                    .foregroundStyle(Color.primary.opacity(text.isEmpty ? (isEditing ? 0.35 : 0.45) : 0.9))
                    .lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: workspaceSidebarTabTrailingSlotWidth, height: 1)
            }
            .padding(.leading, workspaceSidebarTabLeadingPadding)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if isActive {
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: workspaceSidebarTabTrailingSlotWidth)
                .help("Clear search")
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }
        }
        .background {
            shape.fill(Color.primary.opacity(isActive ? 0.08 : (isHovered ? 0.05 : 0)))
                .overlay { shape.strokeBorder(Color.accentColor.opacity(isEditing ? 0.55 : 0), lineWidth: 1) }
        }
        .animation(WorkspaceSidebarTabMotion.feedback, value: isActive)
        .animation(WorkspaceSidebarTabMotion.feedback, value: isEditing)
        .onHover { hovering in withAnimation(WorkspaceSidebarTabMotion.hover) { isHovered = hovering } }
        .accessibilityLabel(text.isEmpty ? "Search tabs" : "Search tabs: \(text)")
    }
}
