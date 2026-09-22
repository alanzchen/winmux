import SwiftUI

extension WorkspaceSidebarView {
    @ViewBuilder
    func dockOrSidebarContent(expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration) -> some View {
        if layout.showAppIcons, layout.dockPosition == .bottom {
            ZStack {
                if expansionProgress < 1 {
                    bottomDockContent(layout: layout)
                        .opacity(Double(1 - expansionProgress))
                        .allowsHitTesting(expansionProgress == 0)
                        .accessibilityHidden(expansionProgress != 0)
                        .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) {
                            if expansionProgress >= workspaceSidebarRowsRevealProgress { $0 = [] }
                        }
                }
                if expansionProgress > 0 {
                    // Keep search, rename, and Override in the same state-owning view.
                    // Only the compact shelf is horizontal; expanded rows remain upright.
                    sidebarContent(expansionProgress: 1, layout: layout, drawsSurface: false)
                        .frame(width: fittedVisibleWidth(layout: layout))
                        .opacity(Double(expansionProgress))
                        .allowsHitTesting(expansionProgress >= 1)
                        .accessibilityHidden(expansionProgress < 1)
                        .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) {
                            if expansionProgress < workspaceSidebarRowsRevealProgress { $0 = [] }
                        }
                }
            }
            .background { sidebarSurface(in: sidebarShape(layout: layout)) }
        } else {
            sidebarContent(expansionProgress: expansionProgress, layout: layout)
        }
    }

    private func bottomDockContent(layout: WorkspaceSidebarConfiguration) -> some View {
        let workspaces = currentFilteredProjectWorkspaces()
        let projectId = projectPagerDisplayIndex.flatMap {
            snapshot.projects.indices.contains($0) ? snapshot.projects[$0].id : nil
        } ?? snapshot.activeProjectId
        return HStack(spacing: 0) {
            if shouldShowCompactMonitorSelector {
                WorkspaceSidebarCompactMonitorSelector(scopes: snapshot.monitorScopes,
                    selectedScopeId: snapshot.selectedMonitorScopeId, sectionWidth: 32,
                    onSelectScope: { scope in
                        browseMode = .activeProject
                        activeInUseOverrideWorkspaceName = nil
                        actions.send(.selectMonitorScope(scope))
                    })
                    .padding(.trailing, 4)
            }
            workspacePage(layout: layout, projectId: projectId, workspaces: workspaces,
                expansionProgress: 0, leadingInset: layout.compactHorizontalInset,
                trailingInset: layout.compactHorizontalInset, topPadding: 10,
                isInteractive: true, showsCreateWorkspace: browsedProjectId == nil)
                .frame(maxWidth: .infinity)
            Button {
                guard !isWorkspaceSidebarDragInProgress() else { return }
                dockMotion.reset()
                actions.send(.expandSidebar)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: layout.compactRailWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand sidebar")
            .help("Expand sidebar")
            if snapshot.projects.count > 1 {
                projectPagerSection(layout: layout, expansionProgress: 0, leadingInset: 0,
                    trailingInset: 0, swipeDirection: nil, switchProgress: 0, edgeProgress: 0)
                    .padding(.horizontal, 4)
            }
            if layout.showsClock {
                WorkspaceSidebarStatusView(sectionWidth: 112, isCompact: true,
                    showsSeconds: layout.showsSeconds, showsDate: layout.showsDate,
                    showsWeekday: layout.showsWeekday, horizontal: true,
                    availableHeight: layout.compactRailWidth)
                    .frame(width: 112).padding(.leading, 8)
            }
            hiddenWorkspaceReminderSection(layout: layout)
        }
        .padding(.horizontal, 6)
        .frame(height: layout.compactRailWidth)
        .environment(\.colorScheme, .dark)
    }
}
