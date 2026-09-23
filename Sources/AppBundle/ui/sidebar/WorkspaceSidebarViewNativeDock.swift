import SwiftUI

extension WorkspaceSidebarView {
    // Keep an opt-out for controlled comparisons with the previous renderer.
    // Project paging and expansion retain the existing SwiftUI presentation.
    var usesNativeDock: Bool {
        ProcessInfo.processInfo.environment["WINMUX_NATIVE_DOCK"] != "0"
            && snapshot.configuration.showAppIcons
            && dockVisibleWidth <= snapshot.configuration.expansionStartWidth
            && browsedProjectId == nil && projectSwipeTranslation == 0
    }

    func nativeDock(layout: WorkspaceSidebarConfiguration) -> some View {
        let horizontal = layout.dockPosition == .bottom
        let projectId = projectPagerDisplayIndex.flatMap {
            snapshot.projects.indices.contains($0) ? snapshot.projects[$0].id : nil
        } ?? snapshot.activeProjectId
        let entries = currentFilteredProjectWorkspaces().map { workspace in
            let section = workspaceSection(layout: layout, workspace: workspace, expansionProgress: 0,
                emitsDropTarget: true, allowsWorkspaceActivation: allowsWorkspaceActivation(projectId: projectId),
                isPinnedActiveWorkspace: false)
            return WorkspaceSidebarNativeDockWorkspace(workspace: workspace,
                isActive: section.isActiveWorkspaceSelection, isEnabled: section.allowsWorkspaceActivation,
                opacity: section.compactFocusOpacity, select: section.handleSectionClick,
                selectApp: section.handleAppClick, rename: { beginWorkspaceRename(workspace) }, drop: section.handlePayloadDrop)
        }
        let leadingLength: CGFloat = shouldShowCompactMonitorSelector
            ? (horizontal ? 36 : workspaceSidebarDropdownHeight + layout.topPadding + workspaceSidebarSectionGap) : 0
        let projectLength: CGFloat = snapshot.projects.count > 1
            ? min(CGFloat(snapshot.projects.count), 5) * (horizontal ? 36 : workspaceSidebarProjectDotFrameHeight) + 8 : 0
        let clockLength: CGFloat = layout.showsClock
            ? (horizontal ? 120 : (layout.showsSeconds ? 92 : 68) * layout.compactDockScale
                + 8 + workspaceSidebarStatusBottomPadding(isCompact: true, layout: layout)) : 0
        let reminderLength = workspaceSidebarReminderLength(count: hiddenWorkspaceAppReminders.count, iconSize: layout.dockIconSize)
        let trailingLength: CGFloat = reminderLength + (horizontal || layout.dockMagnification ? 32 : 0) + projectLength + clockLength
            + (horizontal ? 0 : workspaceSidebarFooterBottomPadding(showsClock: layout.showsClock))
        return WorkspaceSidebarNativeDock(configuration: layout,
            visibleWidth: fittedVisibleWidth(layout: layout), compactLength: compactDockContentHeight(layout: layout),
            leadingLength: leadingLength, trailingLength: trailingLength,
            leading: AnyView(nativeDockLeading(layout: layout).environment(\.colorScheme, .dark)),
            trailing: AnyView(nativeDockTrailing(layout: layout).environment(\.colorScheme, .dark)),
            workspaces: entries, projectId: projectId,
            monitorScopeId: workspaceSidebarWorkspaceCreateScope(selectedScopeId: snapshot.selectedMonitorScopeId,
                targetMonitorScopeId: snapshot.targetMonitorScopeId, focusedScopeId: snapshot.focusedMonitorScopeId),
            showsCreate: workspaceSidebarShowsCreateWorkspace(selectedScopeId: snapshot.selectedMonitorScopeId),
            reduceTransparency: reduceSidebarTransparency, blockers: dockMagnificationBlockers,
            motion: dockMotion, hitRegions: dockHitRegions, actions: actions,
            pointerOverride: inheritedDockPointer, dropPreview: snapshot.dropPreview, reduceMotion: reduceDockMotion)
    }

    @ViewBuilder
    private func nativeDockLeading(layout: WorkspaceSidebarConfiguration) -> some View {
        if shouldShowCompactMonitorSelector {
            if layout.dockPosition == .bottom {
                WorkspaceSidebarCompactMonitorSelector(scopes: snapshot.monitorScopes,
                    selectedScopeId: snapshot.selectedMonitorScopeId, sectionWidth: 32,
                    onSelectScope: { scope in
                        browseMode = .activeProject
                        activeInUseOverrideWorkspaceName = nil
                        actions.send(.selectMonitorScope(scope))
                    }).padding(.trailing, 4)
            } else {
                compactMonitorSelectorSection(layout: layout, expansionProgress: 0,
                    leadingInset: layout.compactHorizontalInset, trailingInset: layout.compactHorizontalInset)
            }
        }
    }

    @ViewBuilder
    private func nativeDockTrailing(layout: WorkspaceSidebarConfiguration) -> some View {
        if layout.dockPosition == .bottom {
            HStack(spacing: 0) {
                nativeDockExpand(layout: layout)
                if snapshot.projects.count > 1 {
                    projectPagerSection(layout: layout, expansionProgress: 0, leadingInset: 0, trailingInset: 0,
                        swipeDirection: nil, switchProgress: 0, edgeProgress: 0).padding(.horizontal, 4)
                }
                if layout.showsClock {
                    WorkspaceSidebarStatusView(sectionWidth: 112, isCompact: true,
                        showsSeconds: layout.showsSeconds, showsDate: layout.showsDate,
                        showsWeekday: layout.showsWeekday, horizontal: true, availableHeight: layout.compactRailWidth)
                        .frame(width: 112).padding(.leading, 8)
                }
                hiddenWorkspaceReminderSection(layout: layout)
            }
        } else {
            VStack(spacing: 0) {
                if layout.dockMagnification { nativeDockExpand(layout: layout).padding(.bottom, 4) }
                projectPagerSection(layout: layout, expansionProgress: 0,
                    leadingInset: layout.compactHorizontalInset, trailingInset: layout.compactHorizontalInset,
                    swipeDirection: nil, switchProgress: 0, edgeProgress: 0)
                if layout.showsClock {
                    statusSection(layout: layout, expansionProgress: 0, isCompact: true,
                        leadingInset: layout.compactHorizontalInset, trailingInset: layout.compactHorizontalInset)
                }
                hiddenWorkspaceReminderSection(layout: layout)
                Color.clear.frame(height: workspaceSidebarFooterBottomPadding(showsClock: layout.showsClock))
            }
        }
    }

    private func nativeDockExpand(layout: WorkspaceSidebarConfiguration) -> some View {
        Button {
            guard !isWorkspaceSidebarDragInProgress() else { return }
            dockMotion.reset()
            actions.send(.expandSidebar)
        } label: {
            Image(systemName: layout.dockPosition == .bottom ? "chevron.up" : layout.dockPosition == .right ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: layout.dockPosition == .bottom ? 32 : layout.compactRailWidth,
                    height: layout.dockPosition == .bottom ? layout.compactRailWidth : 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand sidebar")
        .help("Expand sidebar")
    }
}
