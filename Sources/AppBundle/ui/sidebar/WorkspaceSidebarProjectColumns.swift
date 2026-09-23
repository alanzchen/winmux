import SwiftUI

private let workspaceSidebarProjectColumnHeaderSpacing: CGFloat = 4
private let workspaceSidebarProjectColumnsBottomPadding: CGFloat = 10
private let workspaceSidebarProjectColumnMinimumListHeight: CGFloat = 40

extension WorkspaceSidebarView {
    /// The collapsible Dock stays in place. Expansion adds this rounded, floating view
    /// beside it, with one column of workspaces for every project.
    func floatingProjectColumns(layout: WorkspaceSidebarConfiguration, availableSize: CGSize,
                                progress: CGFloat) -> some View {
        let region = workspaceSidebarFloatingViewRegion(availableSize: availableSize,
            dockThickness: layout.compactRailWidth, dockGap: layout.compactLeftGap, position: layout.dockPosition)
        let towardDock: CGSize = switch layout.dockPosition {
            case .left: CGSize(width: -12, height: 0)
            case .right: CGSize(width: 12, height: 0)
            case .bottom: CGSize(width: 0, height: 12)
        }
        return projectColumnsCard(layout: layout, maxSize: region.size)
            .opacity(Double(progress))
            .background {
                GeometryReader { card in
                    Color.clear.preference(key: WorkspaceSidebarExpandedSurfaceFramePreferenceKey.self,
                        value: card.frame(in: .named("workspaceSidebarContent")))
                }
            }
            .allowsHitTesting(progress >= 1)
            .accessibilityHidden(progress < 1)
            .onPreferenceChange(WorkspaceSidebarExpandedSurfaceFramePreferenceKey.self) { actions.setExpandedSurfaceFrame($0) }
            .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { actions.setExpandedDropTargets($0) }
            // The panel keeps these targets apart from the Dock's own native targets. It ignores
            // them once collapse starts and clears them on hide; clearing on disappear could
            // erase a reopened view's frame when the outgoing view finishes fading later.
            .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) { $0 = [] }
            .frame(width: region.width, height: region.height,
                alignment: workspaceSidebarFloatingViewAlignment(layout.dockPosition))
            .position(x: region.midX, y: region.midY)
            // The panel width changes inside its expand/collapse animation transaction.
            .transition(.opacity.combined(with: .offset(towardDock)))
    }

    /// Projects shown as columns. While searching, only projects with matches remain.
    func projectColumnsContent() -> [(project: WorkspaceSidebarProjectViewModel, workspaces: [WorkspaceSidebarWorkspaceViewModel])] {
        let visible = workspaceSidebarVisibleWorkspacesByProject(
            workspaces: snapshot.workspaces,
            selectedScopeId: snapshot.selectedMonitorScopeId,
            focusedMonitorScopeId: snapshot.focusedMonitorScopeId,
            browsedProjectId: nil
        )
        let filtered = workspaceSidebarFilteredWorkspacesByProject(visible, projects: snapshot.projects, query: searchText)
        let projects = snapshot.projects.isEmpty
            ? [WorkspaceSidebarProjectViewModel(id: snapshot.activeProjectId, displayName: "Workspaces", colorHex: nil)]
            : snapshot.projects
        return projects.compactMap { project in
            let workspaces = filtered[project.id] ?? []
            return searchText.isEmpty || !workspaces.isEmpty ? (project, workspaces) : nil
        }
    }

    private func projectColumnsCard(layout: WorkspaceSidebarConfiguration, maxSize: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: workspaceSidebarFloatingViewCornerRadius, style: .continuous)
        let inset = workspaceSidebarContentLeadingInset
        let columnWidth = workspaceSidebarSectionWidth(1, layout: layout)
        let columns = projectColumnsContent()
        let columnsWidth = workspaceSidebarProjectColumnsWidth(columnCount: columns.count, columnWidth: columnWidth)
        let cardWidth = min(columnsWidth + inset * 2, maxSize.width)
        let headerHeight = workspaceSidebarDropdownHeight + workspaceSidebarProjectColumnHeaderSpacing
        let maximumListHeight = max(maxSize.height - projectColumnsToolbarHeight - headerHeight
            - workspaceSidebarProjectColumnsBottomPadding, workspaceSidebarProjectColumnMinimumListHeight)
        let listHeight = min(max(projectColumnsListHeight, workspaceSidebarProjectColumnMinimumListHeight), maximumListHeight)

        return VStack(alignment: .leading, spacing: 0) {
            projectColumnsToolbar(layout: layout, columnWidth: columnWidth)
                .background {
                    GeometryReader { toolbar in
                        Color.clear.preference(key: WorkspaceSidebarProjectColumnsToolbarHeightPreferenceKey.self,
                            value: toolbar.size.height)
                    }
                }
            if columns.isEmpty {
                Text("No matching workspaces")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, inset + 8)
                    .padding(.bottom, 14)
            } else {
                GeometryReader { viewport in
                    ScrollViewReader { scroll in
                        ScrollView(.horizontal, showsIndicators: columnsWidth + inset * 2 > cardWidth + 0.5) {
                            HStack(alignment: .top, spacing: workspaceSidebarProjectColumnGap) {
                                ForEach(columns, id: \.project.id) { column in
                                    projectColumn(column.project, workspaces: column.workspaces, layout: layout,
                                        width: columnWidth, listHeight: listHeight)
                                        .id(column.project.id)
                                }
                            }
                            .padding(.horizontal, inset)
                            .padding(.bottom, workspaceSidebarProjectColumnsBottomPadding)
                        }
                        .onChange(of: selectedSearchTarget) { target in
                            guard let projectId = projectColumnId(containing: target, in: columns) else { return }
                            scroll.scrollTo(projectId)
                        }
                    }
                    .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) { targets in
                        targets = workspaceSidebarClippedDropTargets(targets,
                            to: viewport.frame(in: .named("workspaceSidebarContent")))
                    }
                }
                .frame(height: headerHeight + listHeight + workspaceSidebarProjectColumnsBottomPadding)
            }
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .onPreferenceChange(WorkspaceSidebarProjectColumnsToolbarHeightPreferenceKey.self) { height in
            if abs(height - projectColumnsToolbarHeight) > 0.5 { projectColumnsToolbarHeight = height }
        }
        .onPreferenceChange(WorkspaceSidebarProjectColumnHeightPreferenceKey.self) { height in
            if abs(height - projectColumnsListHeight) > 0.5 { projectColumnsListHeight = height }
        }
        .background {
            WorkspaceSidebarSurface(shape: shape, configuration: snapshot.configuration,
                reduceTransparencyOverride: reduceSidebarTransparency)
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.white.opacity(GlassToken.separatorOpacity), lineWidth: StrokeToken.hairline)
                .allowsHitTesting(false)
        }
        .contentShape(shape)
        .environment(\.colorScheme, .dark)
    }

    private func projectColumnsToolbar(layout: WorkspaceSidebarConfiguration, columnWidth: CGFloat) -> some View {
        let inset = workspaceSidebarContentLeadingInset
        return VStack(alignment: .leading, spacing: 0) {
            if shouldShowTopFilterBar {
                monitorSelectorSection(layout: layout, expansionProgress: 1, leadingInset: inset, trailingInset: inset)
            }
            HStack(alignment: .top, spacing: 8) {
                if isSearchEditing || !searchText.isEmpty {
                    sidebarSearchSection(layout: layout, expansionProgress: 1, leadingInset: inset, trailingInset: 0)
                } else {
                    sidebarSearchButton(leadingInset: inset, trailingInset: 0)
                        .frame(width: columnWidth + inset, alignment: .leading)
                }
                Spacer(minLength: 0)
                Button { actions.send(.createProject) } label: {
                    Label("New Project", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .lineLimit(1)
                        .frame(height: workspaceSidebarSearchHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Create a project")
                .padding(.trailing, inset + 4)
            }
            .padding(.top, shouldShowTopFilterBar ? 0 : snapshot.configuration.topPadding)
        }
    }

    private func projectColumn(_ project: WorkspaceSidebarProjectViewModel,
                               workspaces: [WorkspaceSidebarWorkspaceViewModel],
                               layout: WorkspaceSidebarConfiguration,
                               width: CGFloat, listHeight: CGFloat) -> some View {
        let allowsActivation = snapshot.selectedMonitorScopeId == workspaceSidebarDefaultScopeId ||
            snapshot.selectedMonitorScopeId == snapshot.targetMonitorScopeId
        return VStack(alignment: .leading, spacing: workspaceSidebarProjectColumnHeaderSpacing) {
            projectColumnHeader(project)
            GeometryReader { viewport in
                ScrollViewReader { scroll in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: workspaceSidebarSectionGap) {
                            ForEach(workspaces) { workspace in
                                workspaceSection(layout: layout, workspace: workspace, expansionProgress: 1,
                                    emitsDropTarget: true, allowsWorkspaceActivation: allowsActivation,
                                    isPinnedActiveWorkspace: false, allowsProjectMove: true)
                                    .id(workspace.name)
                            }
                            if searchText.isEmpty {
                                projectCreateWorkspaceSection(projectId: project.id, layout: layout)
                            }
                        }
                        .frame(width: width, alignment: .topLeading)
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(key: WorkspaceSidebarProjectColumnHeightPreferenceKey.self,
                                    value: content.size.height)
                            }
                        }
                    }
                    .onChange(of: selectedSearchTarget) { target in
                        guard let target, let workspace = workspaces.first(where: {
                            workspaceSidebarSearchSelections(workspaces: [$0]).contains(target)
                        }) else { return }
                        scroll.scrollTo(workspace.name)
                    }
                }
                .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) { targets in
                    targets = workspaceSidebarClippedDropTargets(targets,
                        to: viewport.frame(in: .named("workspaceSidebarContent")))
                }
            }
            .frame(width: width, height: listHeight)
        }
        .frame(width: width, alignment: .topLeading)
        .modifier(WorkspaceSidebarProjectDropModifier(projectId: project.id, actions: actions))
    }

    private func projectColumnHeader(_ project: WorkspaceSidebarProjectViewModel) -> some View {
        let isActive = project.id == snapshot.activeProjectId
        let label = HStack(spacing: 6) {
            Circle()
                .fill(workspaceSidebarProjectColor(projectId: project.id, configuredHex: project.colorHex))
                .frame(width: 7, height: 7)
            if let emoji = project.emoji {
                Text(emoji).font(.system(size: 14))
            }
            Text(project.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: workspaceSidebarDropdownHeight)
        .background {
            RoundedRectangle(cornerRadius: workspaceSidebarDropdownCornerRadius, style: .continuous)
                .fill(Color.white.opacity(isActive ? 0.12 : 0.05))
        }
        return Group {
            if renamingProjectId == project.id {
                WorkspaceSidebarProjectRenameField(project: project, text: $renamingProjectText,
                    onCommit: { finishProjectRename() }, onCancel: { finishProjectRename(cancelled: true) })
            } else if snapshot.projects.isEmpty {
                // A snapshot without projects shows its workspaces under a plain label.
                label
            } else {
                Button { actions.send(.selectProject(project.id)) } label: {
                    label.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isActive ? project.displayName : "Switch to \(project.displayName)")
                .accessibilityLabel(isActive ? "\(project.displayName), current project" : "Switch to \(project.displayName)")
                .contextMenu { projectContextMenu(project) }
            }
        }
        .foregroundStyle(Color.white.opacity(isActive ? 0.95 : 0.72))
        .frame(height: workspaceSidebarDropdownHeight)
    }

    private func projectColumnId(
        containing target: WorkspaceSidebarSearchSelection?,
        in columns: [(project: WorkspaceSidebarProjectViewModel, workspaces: [WorkspaceSidebarWorkspaceViewModel])]
    ) -> WorkspaceProjectId? {
        guard let target else { return nil }
        return columns.first { column in
            workspaceSidebarSearchSelections(workspaces: column.workspaces).contains(target)
        }?.project.id
    }
}

struct WorkspaceSidebarExpandedSurfaceFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// The tallest column's natural list height. Shorter columns share that height.
struct WorkspaceSidebarProjectColumnHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct WorkspaceSidebarProjectColumnsToolbarHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
