import AppKit
import Common
import SwiftUI

extension WorkspaceSidebarView {
    func sidebarContent(expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration) -> some View {
        let isCompact = expansionProgress < workspaceSidebarRowsRevealProgress
        let progress = min(max(expansionProgress, 0), 1)
        let leadingInset = layout.showAppIcons
            ? workspaceSidebarOuterLeadingPadding(isCompact: true, layout: layout) + progress * (workspaceSidebarOuterLeadingPadding(isCompact: false) - workspaceSidebarOuterLeadingPadding(isCompact: true, layout: layout))
            : workspaceSidebarOuterLeadingPadding(isCompact: isCompact)
        let trailingInset = layout.showAppIcons
            ? workspaceSidebarOuterTrailingPadding(isCompact: true, layout: layout) + progress * (workspaceSidebarOuterTrailingPadding(isCompact: false) - workspaceSidebarOuterTrailingPadding(isCompact: true, layout: layout))
            : workspaceSidebarOuterTrailingPadding(isCompact: isCompact)
        let showsMonitorSelector = !isCompact && shouldShowTopFilterBar
        let showsCompactMonitorSelector = isCompact && shouldShowCompactMonitorSelector
        let projectSwipeDirection = workspaceSidebarProjectSwipeDirection(
            horizontalTranslation: projectSwipeTranslation,
            verticalTranslation: 0,
            minimumDistance: 1,
        )
        let activeProjectIndex = projectPagerDisplayIndex
        let projectSwipeProgress = workspaceSidebarProjectEdgeCreationProgress(
            currentIndex: activeProjectIndex,
            projectCount: snapshot.projects.count,
            direction: projectSwipeDirection,
            distance: abs(projectSwipeTranslation),
        )
        let hasSwipeTarget = projectSwipeDirection.flatMap { direction in
            workspaceSidebarProjectIndexAfterSwipe(
                currentIndex: activeProjectIndex,
                projectCount: snapshot.projects.count,
                direction: direction,
            )
        } != nil
        let projectSwitchProgress = hasSwipeTarget
            ? workspaceSidebarProjectSwipeSwitchProgress(distance: abs(projectSwipeTranslation))
            : 0
        let visibleWorkspacesByProject = workspaceSidebarVisibleWorkspacesByProject(
            workspaces: snapshot.workspaces,
            selectedScopeId: snapshot.selectedMonitorScopeId,
            focusedMonitorScopeId: snapshot.focusedMonitorScopeId,
            browsedProjectId: browsedProjectId,
        )
        let filteredWorkspacesByProject = workspaceSidebarFilteredWorkspacesByProject(
            visibleWorkspacesByProject,
            projects: snapshot.projects,
            query: searchText,
        )

        return VStack(alignment: .leading, spacing: 0) {
            if showsCompactMonitorSelector {
                compactMonitorSelectorSection(
                    layout: layout,
                    expansionProgress: expansionProgress,
                    leadingInset: leadingInset,
                    trailingInset: trailingInset,
                )
            } else if showsMonitorSelector {
                monitorSelectorSection(
                    layout: layout,
                    expansionProgress: expansionProgress,
                    leadingInset: leadingInset,
                    trailingInset: trailingInset,
                )
            }

            if !isCompact, !isSearchEditing, searchText.isEmpty {
                sidebarSearchButton(leadingInset: leadingInset, trailingInset: trailingInset)
            }
            if !isCompact, isSearchEditing || !searchText.isEmpty {
                sidebarSearchSection(
                    layout: layout,
                    expansionProgress: expansionProgress,
                    leadingInset: leadingInset,
                    trailingInset: trailingInset,
                )
            }

            projectPagerContent(
                layout: layout,
                expansionProgress: expansionProgress,
                leadingInset: leadingInset,
                trailingInset: trailingInset,
                topPadding: showsMonitorSelector || showsCompactMonitorSelector ? 0 : layout.topPadding,
                visibleWorkspacesByProject: filteredWorkspacesByProject,
                swipeDirection: projectSwipeDirection,
            )
            .frame(
                width: workspaceSidebarContentFrameWidth(expansionProgress: expansionProgress, layout: layout),
                alignment: .topLeading
            )
            .frame(maxHeight: .infinity, alignment: .topLeading)

            if isCompact, layout.dockMagnification {
                Button {
                    guard !isWorkspaceSidebarDragInProgress() else { return }
                    dockMotion.reset()
                    actions.send(.expandSidebar)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand sidebar")
                .help("Expand sidebar")
                .padding(.bottom, 4)
            }

            if (isSidebarCollapsing && !isCompact) || (isSidebarExpanding && isCompact) {
                let compactProjectReserveHeight = min(
                    max(CGFloat(snapshot.projects.count) * workspaceSidebarProjectDotFrameHeight, workspaceSidebarPagerHeight),
                    workspaceSidebarProjectDotFrameHeight * 5
                )
                Color.clear
                    .frame(height: isCompact ? compactProjectReserveHeight + 8 : workspaceSidebarCollapseReservedProjectPagerHeight)
            } else {
                projectPagerSection(
                    layout: layout,
                    expansionProgress: expansionProgress,
                    leadingInset: leadingInset,
                    trailingInset: trailingInset,
                    swipeDirection: projectSwipeDirection,
                    switchProgress: projectSwitchProgress,
                    edgeProgress: projectSwipeProgress,
                )
            }

            if layout.showsClock {
                statusSection(
                    layout: layout,
                    expansionProgress: expansionProgress,
                    isCompact: isCompact,
                    leadingInset: leadingInset,
                    trailingInset: trailingInset,
                )
            }

            Color.clear
                .frame(height: workspaceSidebarFooterBottomPadding(
                    showsClock: layout.showsClock,
                ))
        }
        .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { frames in
            actions.setDropTargets(frames)
        }
        .background {
            sidebarSurface(in: sidebarShape(layout: layout))
                .contentShape(Rectangle())
                .onTapGesture {
                    NotificationCenter.default.post(name: workspaceSidebarDismissProjectMenusNotification, object: nil)
                }
        }
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(GlassToken.separatorOpacity))
                .frame(width: 0.5)
                .opacity(Double(dockSurfaceProgress))
        }
        .modifier(WorkspaceSidebarTrailingOverflowModifier(base: sidebarShape(layout: layout), overflow: dockMagnificationOverflow(layout: layout)))
        .overlay {
            sidebarSwipeCaptureOverlay(expansionProgress: expansionProgress)
        }
    }
}

private let workspaceSidebarCollapseReservedProjectPagerHeight = (workspaceSidebarPagerHeight * 2) + 10

extension WorkspaceSidebarView {
    var shouldShowTopFilterBar: Bool {
        let hasFocusFilter = snapshot.monitorScopes.contains { $0.id == workspaceSidebarFocusedScopeId }
        let hasOtherProjects = snapshot.projects.contains { $0.id != snapshot.activeProjectId }
        return hasFocusFilter || hasOtherProjects || shouldShowCompactMonitorSelector
    }

    func workspaceSidebarSplitSectionWidth(expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration? = nil) -> CGFloat {
        let sectionWidth = workspaceSidebarSectionWidth(expansionProgress, layout: layout ?? snapshot.configuration)
        return (sectionWidth * 2) + workspaceSidebarSplitPaneGap
    }

    func workspaceSidebarContentFrameWidth(expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration? = nil) -> CGFloat {
        let layout = layout ?? snapshot.configuration
        guard browsedProjectId != nil else {
            return max(fittedVisibleWidth(layout: layout), 0)
        }
        return workspaceSidebarSplitSectionWidth(expansionProgress: expansionProgress, layout: layout) +
            workspaceSidebarContentLeadingInset +
            workspaceSidebarContentTrailingInset
    }
}

let workspaceSidebarSplitPaneGap: CGFloat = 8
