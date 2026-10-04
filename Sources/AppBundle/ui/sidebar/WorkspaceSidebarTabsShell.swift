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
        // Pins first; with shared pins, the project's from every display.
        let visible = snapshot.tabsListedWorkspacesByProject
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
            .overlay {
                // With nothing pinned in All Projects, dragging a tab offers that over the header, above
                // where those pins go, so nothing below moves under the pointer.
                if expanded, !isSearchActive {
                    WorkspaceSidebarTabsPinDropZone(projectId: snapshot.activeProjectId, monitorScopeId: tabsListScopeId,
                        hasPins: (visible[snapshot.activeProjectId] ?? []).contains(where: \.appearance.isPinnedInAllProjects),
                        isDropTarget: workspaceSidebarPinDropZoneIsTarget(snapshot.dropPreview, section: .allProjects,
                            projectId: snapshot.activeProjectId, list: tabsListScopeId),
                        section: .allProjects)
                        .padding(.horizontal, workspaceSidebarTabsListInset).padding(.vertical, 8)
                        .opacity(reveal)
                }
            }

            if expanded {
                if showsTabsDisplayMenu {
                    let menuScopes = workspaceSidebarMonitorScopeMenu(snapshot.monitorScopes,
                        targetScopeId: snapshot.targetMonitorScopeId)
                    let selectedScope = menuScopes.first { $0.id == snapshot.selectedMonitorScopeId }
                    let firstOtherDisplayId = menuScopes.first {
                        workspaceSidebarMonitorScopePoint($0.id) != nil && $0.id != snapshot.targetMonitorScopeId
                    }?.id
                    Menu {
                        ForEach(menuScopes) { scope in
                            if scope.id == firstOtherDisplayId { Divider() }
                            Button(scope.displayName) { actions.send(.selectMonitorScope(scope.id)) }
                        }
                    } label: {
                        Label(selectedScope?.displayName ?? "This Display", systemImage: selectedScope?.systemImageName ?? "display")
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
                    .overlay {
                        // With none of the project's own pins, dragging a tab offers pinning over the search
                        // row, so the list doesn't move under the pointer. Below pins in All Projects, it
                        // names the project.
                        let shown = visible[snapshot.activeProjectId] ?? []
                        let pinsEverywhere = shown.contains(where: \.appearance.isPinnedInAllProjects)
                        WorkspaceSidebarTabsPinDropZone(projectId: snapshot.activeProjectId, monitorScopeId: tabsListScopeId,
                            hasPins: shown.contains { $0.appearance.isFavorite && !$0.appearance.isPinnedInAllProjects },
                            isDropTarget: workspaceSidebarPinDropZoneIsTarget(snapshot.dropPreview, section: .project,
                                projectId: snapshot.activeProjectId, list: tabsListScopeId),
                            label: pinsEverywhere ? "Pin to “\(project?.displayName ?? "This Project")”" : "Drop to Pin")
                    }
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
                            } else if index > 0, tabs[index - 1].appearance.isPinnedInAllProjects, !workspace.appearance.isPinnedInAllProjects {
                                // Pins in All Projects, then the project's own.
                                Divider().opacity(0.6).padding(.horizontal, 12).padding(.vertical, 2)
                            }
                            WorkspaceSidebarPinnedTab(workspace: workspace, badgeModel: dockBadgeModel, compact: true,
                                targetMonitorScopeId: snapshot.targetMonitorScopeId,
                                onOpenSavedApps: { selectTabWorkspace(workspace, action: .openSavedTab(workspace.name)) },
                                sharedPinLocation: snapshot.sharedPinLocation(of: workspace)) { windowId in
                                selectTabWorkspace(workspace, windowId: windowId)
                            }
                            .frame(width: 34, height: 34)
                            .overlay(alignment: .leading) {
                                if let group = snapshot.configuration.tabCollections.first(where: { $0.workspaceNames.contains(workspace.name) }) {
                                    Capsule().fill(group.colorHex.flatMap(workspaceSidebarColor) ?? .secondary)
                                        .frame(width: 3, height: 23).offset(x: -4).allowsHitTesting(false)
                                }
                            }
                            .help(snapshot.sharedPinLocation(of: workspace).map { "\(workspace.displayName)\n\($0.help())" }
                                ?? workspace.displayName)
                        }
                    }.frame(maxWidth: .infinity)
                }
                .opacity(railOpacity)
            }
            if expanded { WorkspaceSidebarTabUndoButton(actions: actions, reducesMotion: reduceDockMotion).opacity(reveal) }
            if expanded, snapshot.configuration.musicPlayerAtBottom {
                WorkspaceSidebarBottomMusicPlayer(onSelect: { selectMusicFromBottomPlayer() }, model: musicPlayerModel)
                    .opacity(reveal)
            }
            projectPagerSection(layout: layout, expansionProgress: expansionProgress,
                leadingInset: pagerInset, trailingInset: pagerInset,
                swipeDirection: workspaceSidebarProjectSwipeDirection(horizontalTranslation: projectSwipeTranslation,
                    verticalTranslation: 0, minimumDistance: 1), switchProgress: 0, edgeProgress: 0)
            if expanded {
                HStack {
                    Button { ShortcutSettingsModel.shared.requestPanelSettings() } label: {
                        Image(systemName: "gearshape").frame(width: workspaceSidebarTabIconSize)
                    }
                    .help("Tabs Settings").accessibilityLabel("Tabs Settings")
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
        .environment(\.workspaceSidebarBrowserWindows, WorkspaceSidebarBrowserWindows(browserTabs,
            windows: snapshot.workspaces.flatMap(workspaceSidebarPinnedTabWindows)))
    }

    /// The display whose tabs the list shows, where a tab dropped on it goes: this panel's own,
    /// or the one chosen in its display menu.
    var tabsListScopeId: String {
        workspaceSidebarWorkspaceCreateScope(selectedScopeId: snapshot.selectedMonitorScopeId,
            targetMonitorScopeId: snapshot.targetMonitorScopeId, focusedScopeId: snapshot.focusedMonitorScopeId)
    }

    /// Pins in All Projects above the project's own, with a divider between them when both have some.
    /// Each section wraps on its own; an empty one takes no room.
    private func tabsFavorites(_ workspaces: [WorkspaceSidebarWorkspaceViewModel]) -> some View {
        let favorites = workspaces.filter { $0.appearance.isFavorite }
        let everywhere = favorites.filter(\.appearance.isPinnedInAllProjects)
        let own = favorites.filter { !$0.appearance.isPinnedInAllProjects }
        let width = snapshot.visibleWidth - 20
        return VStack(alignment: .leading, spacing: 0) {
            tabsFavoriteGrid(everywhere, grid: .init(workspaces: everywhere, sizedLike: favorites, width: width),
                section: .allProjects)
            if !everywhere.isEmpty, !own.isEmpty {
                Divider().opacity(0.6).padding(.horizontal, 16).padding(.bottom, 8).accessibilityHidden(true)
            }
            tabsFavoriteGrid(own, grid: .init(workspaces: own, sizedLike: favorites, width: width), section: .project)
        }
    }

    /// A tab dropped beside a tile goes there among the pins, and the insertion line shows where;
    /// after a pause over a tile's middle, a window joins that pin's split instead. Dropped among the other
    /// section's pins, a pin moves there, which the section's caption says while it's over them.
    private func tabsFavoriteGrid(_ favorites: [WorkspaceSidebarWorkspaceViewModel],
                                  grid: WorkspaceSidebarPinnedGridLayout, section: WorkspaceSidebarPinSection) -> some View {
        let projectName = snapshot.projects.first { $0.id == snapshot.activeProjectId }?.displayName ?? "This Project"
        // The scroll view reaches past the tiles so it doesn't clip the insertion line beside the outer ones.
        let lineRoom = workspaceSidebarPinnedGridSpacing
        return GeometryReader { viewport in
            ScrollView {
                WorkspaceSidebarPinnedGrid(columns: grid.columns) {
                    ForEach(favorites) { workspace in
                        WorkspaceSidebarPinnedTab(workspace: workspace, badgeModel: dockBadgeModel,
                            targetMonitorScopeId: snapshot.targetMonitorScopeId, actions: actions,
                            insertionEdge: workspaceSidebarPinnedInsertionEdge(snapshot.dropPreview,
                                workspaceName: workspace.name, projectId: snapshot.activeProjectId,
                                monitorScopeId: tabsListScopeId),
                            isDropTarget: snapshot.dropPreview?.targetWorkspaceName == workspace.name
                                || snapshot.dropPreview?.receivingPinnedTabName == workspace.name,
                            // A pin that takes a tab in lights up whole; the half shown is on the tab.
                            dropPlacement: snapshot.dropPreview?.targetWorkspaceName == workspace.name
                                ? snapshot.dropPreview?.targetPlacement : nil,
                            dropLabelSlot: snapshot.dropPreview?.targetLabelSlot,
                            onOpenSavedApps: { selectTabWorkspace(workspace, action: .openSavedTab(workspace.name)) },
                            sharedPinLocation: snapshot.sharedPinLocation(of: workspace)) { windowId in
                            selectTabWorkspace(workspace, windowId: windowId)
                        }
                    }
                }
                .animation(reduceDockMotion ? nil : .easeInOut(duration: 0.18),
                    value: favorites.map(WorkspaceSidebarPinnedTabIdentity.init))
                .background {
                    GeometryReader { content in
                        Color.clear.preference(key: WorkspaceSidebarDropTargetPreferenceKey.self,
                            value: favorites.isEmpty ? [] : workspaceSidebarPinnedDropTargets(names: favorites.map(\.name),
                                projectId: snapshot.activeProjectId, monitorScopeId: tabsListScopeId,
                                frame: content.frame(in: .named("workspaceSidebarContent")), columns: grid.columns,
                                section: section))
                    }
                }
                .padding(.horizontal, lineRoom)
            }
            // Tiles scrolled out of view take no drops.
            .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) { targets in
                targets = workspaceSidebarClippedDropTargets(targets,
                    to: viewport.frame(in: .named("workspaceSidebarContent")).insetBy(dx: 0, dy: -4))
            }
        }
        .padding(.horizontal, -lineRoom)
        .frame(height: grid.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section == .allProjects ? "Pinned in All Projects" : "Pinned in \(projectName)")
        .overlay(alignment: .topTrailing) {
            if !favorites.isEmpty, workspaceSidebarPinScopeChangeTargets(snapshot.dropPreview, section: section,
                projectId: snapshot.activeProjectId, list: tabsListScopeId) {
                WorkspaceSidebarPinScopeCaption(section: section, projectName: projectName)
                    .offset(y: -9)
            }
        }
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

    private func selectMusicFromBottomPlayer() {
        guard !isWorkspaceSidebarDragInProgress() else { return }
        if let action = workspaceSidebarBottomMusicPlayerAction(snapshot.workspaces,
            targetMonitorScopeId: snapshot.targetMonitorScopeId)
        {
            actions.send(action)
        } else {
            musicPlayerModel.openMusic()
        }
    }

    private func selectTabWorkspace(_ workspace: WorkspaceSidebarWorkspaceViewModel, windowId: UInt32? = nil,
                                    action: WorkspaceSidebarAction? = nil) {
        let (activation, _) = tabActivation(workspace, isPinned: false, pageAllowsActivation: true)
        activation.select(action ?? windowId.map(WorkspaceSidebarAction.selectWindow) ?? .selectWorkspace(workspace.name),
            send: actions.send)
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
            && workspaceSidebarDropPreview(snapshot.dropPreview, targetsList: monitorScopeId)
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
                        value: [.init(kind: .tabCollection(group.id, monitorScopeId: monitorScopeId),
                            frame: geometry.frame(in: .named("workspaceSidebarContent")))])
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
                // A closed group previews what it holds after its name, keeping names aligned. A narrow
                // sidebar leaves the preview out rather than squeezing the name away.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 9) {
                        WorkspaceSidebarTabGroupTitle(text: group.name, tint: tint)
                            .frame(idealWidth: workspaceSidebarTabGroupPreviewMinimumTitleWidth, maxWidth: .infinity,
                                alignment: .leading)
                        if disclosure.isCollapsed {
                            HStack(spacing: 3) {
                                ForEach(Array(workspaces.flatMap(workspaceSidebarPinnedTabWindows).prefix(3))) { window in
                                    WorkspaceSidebarWindowIcon(window: window, size: 13)
                                        .accessibilityHidden(true)
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    WorkspaceSidebarTabGroupTitle(text: group.name, tint: tint)
                }
            } accessory: {
                if disclosure.isCollapsed {
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

/// A closed group's preview shows only while its name keeps at least this much room.
let workspaceSidebarTabGroupPreviewMinimumTitleWidth: CGFloat = 48

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
                    // A long query keeps its end in view; a narrow sidebar shortens the prompt's end.
                    .lineLimit(1).truncationMode(text.isEmpty ? .tail : .head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Room for the clear button, which only an active search shows.
                if isActive { Color.clear.frame(width: workspaceSidebarTabTrailingSlotWidth, height: 1) }
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

/// The pinned tiles' drop target: a tab dropped anywhere on them is pinned, among `section`'s pins.
struct WorkspaceSidebarTabsPinDropTarget: View {
    let projectId: WorkspaceProjectId
    let monitorScopeId: String
    var section: WorkspaceSidebarPinSection = .project

    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: WorkspaceSidebarDropTargetPreferenceKey.self,
                value: [WorkspaceSidebarDropTargetFrame(kind: .pinnedTabs(projectId: projectId, monitorScopeId: monitorScopeId,
                    section: section), frame: geometry.frame(in: .named("workspaceSidebarContent")).insetBy(dx: -4, dy: -4))])
        }
    }
}

/// Whether the drop shown is on `section`'s place to pin, in the list of `list`'s display showing `projectId`.
func workspaceSidebarPinDropZoneIsTarget(_ preview: WorkspaceSidebarDropPreviewViewModel?, section: WorkspaceSidebarPinSection,
                                         projectId: WorkspaceProjectId, list: String) -> Bool {
    guard let preview, preview.targetsPinned, preview.targetProjectId == projectId else { return false }
    return (preview.targetPinSection ?? .project) == section && workspaceSidebarDropPreview(preview, targetsList: list)
}

/// Whether the drop shown moves a pin to `section`'s pins, or pins a tab in All Projects there.
func workspaceSidebarPinScopeChangeTargets(_ preview: WorkspaceSidebarDropPreviewViewModel?, section: WorkspaceSidebarPinSection,
                                           projectId: WorkspaceProjectId, list: String) -> Bool {
    preview?.changesPinScope == true && workspaceSidebarPinDropZoneIsTarget(preview, section: section, projectId: projectId, list: list)
}

/// Over a pin section a drop would move a pin to: which pins it would be among.
struct WorkspaceSidebarPinScopeCaption: View {
    let section: WorkspaceSidebarPinSection
    let projectName: String

    var body: some View {
        Label(section == .allProjects ? "All Projects" : projectName, systemImage: section == .allProjects ? "globe" : "pin")
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(Color.white)
            .background(Capsule().fill(Color.accentColor))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// With no pins in its section, a place to drop a tab to pin it there, shown only while a tab is dragged.
struct WorkspaceSidebarTabsPinDropZone: View {
    let projectId: WorkspaceProjectId
    let monitorScopeId: String
    let hasPins: Bool
    let isDropTarget: Bool
    var section: WorkspaceSidebarPinSection = .project
    var label: String? = nil
    @ObservedObject private var drag = WorkspaceSidebarTabDragState.shared
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
        ZStack {
            if drag.isDragging && !hasPins {
                Label(label ?? (section == .allProjects ? "Pin to All Projects" : "Drop to Pin"),
                    systemImage: section == .allProjects ? "globe" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isDropTarget ? Color.accentColor : Color.primary.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        shape.fill(.regularMaterial)
                            .overlay { shape.fill(Color.accentColor.opacity(isDropTarget ? 0.16 : 0.05)) }
                    }
                    .overlay {
                        shape.strokeBorder(isDropTarget ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 1, dash: isDropTarget ? [] : [4, 3]))
                    }
                    .background { WorkspaceSidebarTabsPinDropTarget(projectId: projectId, monitorScopeId: monitorScopeId, section: section) }
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .animation(reducesMotion ? nil : WorkspaceSidebarTabMotion.feedback, value: drag.isDragging)
        .animation(WorkspaceSidebarTabMotion.feedback, value: isDropTarget)
    }
}
