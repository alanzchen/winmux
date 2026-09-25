import AppKit
import Common
import SwiftUI

struct WorkspaceSidebarProjectPager: View {
    let projects: [WorkspaceSidebarProjectViewModel]
    let selectedProjectId: WorkspaceProjectId
    let expansionProgress: CGFloat
    let layout: WorkspaceSidebarConfiguration
    @Binding var renamingProjectId: WorkspaceProjectId?
    @Binding var renamingProjectText: String
    let onSelectProject: (WorkspaceProjectId) -> Void
    let onCreateProject: () -> Void
    let onBeginRenameProject: (WorkspaceSidebarProjectViewModel) -> Void
    let onCommitRenameProject: @MainActor @Sendable () -> Void
    let onCancelRenameProject: @MainActor @Sendable () -> Void
    let onSetProjectColor: (WorkspaceSidebarProjectViewModel, String?) -> Void
    let onDeleteProject: (WorkspaceSidebarProjectViewModel) -> Void
    var onEditProjectEmoji: (WorkspaceSidebarProjectViewModel) -> Void = { _ in }
    var onResetProjectEmoji: (WorkspaceSidebarProjectViewModel) -> Void = { _ in }

    @State var isHovered = false
    @State var hoveredProjectDotId: WorkspaceProjectId? = nil
    @State var projectTrackScrollTargetId: WorkspaceProjectId? = nil
    @State var projectTrackContentMinX: CGFloat = 0
    @State var projectTrackContentWidth: CGFloat = 0
    @State var projectTrackViewportWidth: CGFloat = 0

    var horizontalCompact: Bool { isCompact && layout.showAppIcons && layout.dockPosition == .bottom }
    var sectionWidth: CGFloat {
        horizontalCompact ? min(CGFloat(projects.count), 5) * 36 : workspaceSidebarSectionWidth(expansionProgress, layout: layout)
    }
    var isCompact: Bool { expansionProgress < workspaceSidebarRowsRevealProgress }
    var currentIndex: Int? {
        projects.firstIndex { $0.id == selectedProjectId }
            ?? projects.indices.first
    }
    var selectedProject: WorkspaceSidebarProjectViewModel? {
        if let renamingProjectId,
           let renamingProject = projects.first(where: { $0.id == renamingProjectId })
        {
            return renamingProject
        }
        return projects.first { $0.id == selectedProjectId }
            ?? projects.first
    }
    var showsProjectIndicator: Bool { projects.count > 1 }
    /// The expanded switcher and its New Project button share one row.
    var expandedProjectControlsHeight: CGFloat { workspaceSidebarPagerHeight }
    var pagerHeight: CGFloat {
        if isCompact, !showsProjectIndicator {
            return 0
        }
        return isCompact ? compactProjectControlsHeight : expandedProjectControlsHeight
    }
    var footerSpacing: CGFloat { isCompact ? 2 : 8 }
    var projectCreateButtonWidth: CGFloat { workspaceSidebarDropdownHeight }
    var projectControlsSpacing: CGFloat { 6 }
    var projectTrackWidth: CGFloat {
        if isCompact {
            return max(sectionWidth - 4, 12)
        }
        return max(sectionWidth - projectCreateButtonWidth - projectControlsSpacing, 24)
    }
    var compactProjectControlsHeight: CGFloat {
        if horizontalCompact { return min(workspaceSidebarProjectDotFrameHeight, layout.compactRailWidth) }
        let contentHeight = CGFloat(projects.count) * workspaceSidebarProjectDotFrameHeight
        let maxVisibleHeight = workspaceSidebarProjectDotFrameHeight * 5
        return min(max(contentHeight, workspaceSidebarPagerHeight), maxVisibleHeight)
    }

    var body: some View {
        if !projects.isEmpty, !isCompact || showsProjectIndicator {
            pagerContent
                .frame(width: sectionWidth, height: pagerHeight, alignment: .bottom)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovered = hovering
                }
                .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.86), value: isHovered)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
        }
    }

    var pagerContent: some View {
        Group {
            if isCompact {
                compactProjectIndicator
            } else {
                projectControls
                    .transaction { $0.animation = nil }
            }
        }
        .padding(.horizontal, isCompact && !horizontalCompact ? 2 : 0)
        .frame(width: sectionWidth, height: pagerHeight, alignment: .bottom)
        .contextMenu {
            Button("New Project") {
                onCreateProject()
            }
        }
        .transaction { $0.animation = nil }
    }
}
