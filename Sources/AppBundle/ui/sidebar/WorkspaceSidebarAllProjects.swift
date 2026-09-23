import SwiftUI

extension WorkspaceSidebarView {
    /// A pinned bottom Dock keeps its reserved height and lists every project in one column.
    var usesExpandedProjectList: Bool {
        snapshot.configuration.showAppIcons && snapshot.configuration.alwaysExpanded
            && snapshot.configuration.dockPosition == .bottom
    }

    /// A collapsible Dock stays in place and opens one floating column per project.
    var usesProjectColumns: Bool { snapshot.configuration.floatsExpandedView }

    /// Both expanded Dock presentations show every project, so neither browses a second one.
    var showsAllProjects: Bool { usesProjectColumns || usesExpandedProjectList }

    func allProjectsContent(
        layout: WorkspaceSidebarConfiguration,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        topPadding: CGFloat,
        workspacesByProject: [WorkspaceProjectId: [WorkspaceSidebarWorkspaceViewModel]]
    ) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { scroll in
                ScrollView(.vertical) {
                    // Keep the native drag source mounted as its project scrolls out of view.
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(snapshot.projects) { project in
                            VStack(alignment: .leading, spacing: workspaceSidebarSectionGap) {
                                expandedProjectHeader(project)
                                if !collapsedProjectIds.contains(project.id) || !searchText.isEmpty {
                                    ForEach(workspacesByProject[project.id] ?? []) { workspace in
                                        workspaceSection(layout: layout, workspace: workspace, expansionProgress: 1,
                                            emitsDropTarget: true,
                                            allowsWorkspaceActivation: snapshot.selectedMonitorScopeId == workspaceSidebarDefaultScopeId ||
                                                snapshot.selectedMonitorScopeId == snapshot.targetMonitorScopeId,
                                            isPinnedActiveWorkspace: false, allowsProjectMove: true)
                                            .id(workspace.name)
                                    }
                                    if searchText.isEmpty {
                                        projectCreateWorkspaceSection(projectId: project.id, layout: layout)
                                    }
                                }
                            }
                            .frame(width: workspaceSidebarSectionWidth(1, layout: layout), alignment: .leading)
                            .modifier(WorkspaceSidebarProjectDropModifier(projectId: project.id, actions: actions,
                                onWorkspaceDrop: { collapsedProjectIds.remove(project.id) }))
                        }
                    }
                    .padding(.leading, leadingInset)
                    .padding(.trailing, trailingInset)
                    .padding(.top, topPadding)
                    .padding(.bottom, 10)
                }
                .onChange(of: selectedSearchTarget) { target in
                    guard let target, let workspace = snapshot.workspaces.first(where: {
                        workspaceSidebarSearchSelections(workspaces: [$0]).contains(target)
                    }) else { return }
                    scroll.scrollTo(workspace.name)
                }
                .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) { targets in
                    targets = workspaceSidebarClippedDropTargets(targets,
                        to: viewport.frame(in: .named("workspaceSidebarContent")))
                }
            }
        }
    }

    private func expandedProjectHeader(_ project: WorkspaceSidebarProjectViewModel) -> some View {
        HStack(spacing: 6) {
            if renamingProjectId == project.id {
                WorkspaceSidebarProjectRenameField(project: project, text: $renamingProjectText,
                    onCommit: { finishProjectRename() }, onCancel: { finishProjectRename(cancelled: true) })
            } else {
                Button {
                    guard searchText.isEmpty else { return }
                    if !collapsedProjectIds.insert(project.id).inserted {
                        collapsedProjectIds.remove(project.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: collapsedProjectIds.contains(project.id) && searchText.isEmpty
                            ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
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
                    .frame(height: workspaceSidebarDropdownHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(collapsedProjectIds.contains(project.id) && searchText.isEmpty ? "Expand" : "Collapse") \(project.displayName)")
                .contextMenu { projectContextMenu(project) }
            }
        }
        .foregroundStyle(Color.white.opacity(project.id == snapshot.activeProjectId ? 0.95 : 0.75))
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    func projectContextMenu(_ project: WorkspaceSidebarProjectViewModel) -> some View {
        Button("Switch to Project") { actions.send(.selectProject(project.id)) }
        Button("Rename Project") { beginProjectRename(project) }
        Menu("Color") {
            Button("Auto") { actions.send(.setProjectColor(project.id, colorHex: nil)) }
            ForEach(workspaceSidebarProjectColorPresets) { preset in
                Button(preset.name) { actions.send(.setProjectColor(project.id, colorHex: preset.hex)) }
            }
        }
        Button("Edit Emoji…") { actions.send(.editProjectEmoji(project.id)) }
        Button("Reset Emoji") { actions.send(.setProjectEmoji(project.id, emoji: nil)) }
        Button("Delete Project", role: .destructive) { actions.send(.deleteProject(project.id)) }
            .disabled(!canDeleteWorkspaceProject(project.id))
    }

    @ViewBuilder
    func projectCreateWorkspaceSection(projectId: WorkspaceProjectId, layout: WorkspaceSidebarConfiguration) -> some View {
        if workspaceSidebarShowsCreateWorkspace(selectedScopeId: snapshot.selectedMonitorScopeId) {
            let scopeId = workspaceSidebarWorkspaceCreateScope(selectedScopeId: snapshot.selectedMonitorScopeId,
                targetMonitorScopeId: snapshot.targetMonitorScopeId, focusedScopeId: snapshot.focusedMonitorScopeId)
            WorkspaceSidebarCreateWorkspaceSection(projectId: projectId, monitorScopeId: scopeId,
                dragPreview: snapshot.dropPreview, expansionProgress: 1, layout: layout, emitsDropTarget: true,
                onCreateWorkspace: { actions.send(.createWorkspace(projectId: projectId, monitorScopeId: scopeId)) },
                onDropPayload: { payload in
                    switch payload {
                        case .window(let id):
                            actions.send(.moveWindowToNewWorkspace(id, projectId: projectId, monitorScopeId: scopeId))
                        case .tabGroup(let id):
                            actions.send(.moveTabGroupToNewWorkspace(id, projectId: projectId, monitorScopeId: scopeId))
                    }
                }, actions: actions)
        }
    }
}
