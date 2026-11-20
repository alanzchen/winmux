import AppKit
import Common
import SwiftUI

extension WorkspaceSidebarView {
    var projectCreationPage: some View {
        Button(action: activateProjectCreationPage) {
            ViewThatFits(in: .horizontal) {
                Label("New Project", systemImage: "plus").fixedSize()
                Image(systemName: "plus")
            }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Project")
        .help("New Project")
    }

    func showProjectCreationPage() {
        finishSidebarSearch(clearText: true)
        browseMode = .activeProject
        showsProjectCreationPage = true
        guard let panel = currentPanel() else { return }
        projectCreationInputPanel = panel
        // Page navigation needs keyboard ownership, but does not pin the sidebar's width.
        panel.beginInlineTextEditing(purpose: .projectCreation, locksExpansion: false,
            cancelsOnPointerExit: true, expandsSidebar: false,
            onCancel: { leaveProjectCreationPage() },
            onKeyDown: handleProjectCreationKey)
    }

    func handleProjectCreationKey(_ key: WorkspaceSidebarInlineTextKey) -> Bool {
        guard showsProjectCreationPage else { return false }
        guard let action = workspaceSidebarProjectCreationAction(for: key) else {
            // Continuing keyboard work belongs to the current app, including IME composition.
            leaveProjectCreationPage(restorePreviousApplication: true, afterPassingKey: true)
            return false
        }
        switch action {
            case .create: activateProjectCreationPage()
            case .leave: leaveProjectCreationPage(restorePreviousApplication: true)
        }
        return true
    }

    func leaveProjectCreationPage(restorePreviousApplication: Bool = false, afterPassingKey: Bool = false) {
        guard showsProjectCreationPage || projectCreationInputPanel != nil else { return }
        resetProjectSwipeWithoutAnimation()
        showsProjectCreationPage = false
        let panel = projectCreationInputPanel
        projectCreationInputPanel = nil
        panel?.endInlineTextEditing(restorePreviousApplication: restorePreviousApplication, afterPassingKey: afterPassingKey)
    }

    func activateProjectCreationPage() {
        guard showsProjectCreationPage else { return }
        leaveProjectCreationPage(restorePreviousApplication: false)
        actions.send(.createProject)
    }

    func handleProjectSwipeChanged(
        horizontalTranslation: CGFloat,
        verticalTranslation: CGFloat,
        expansionProgress: CGFloat,
    ) {
        guard shouldHandleProjectSwipe(
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: verticalTranslation,
            expansionProgress: expansionProgress,
        ) else {
            resetProjectSwipe()
            return
        }
        // A swipe takes over from a switch still sliding into place.
        projectSwipeNavigationSerial += 1
        endProjectPageTransition()
        if !showsProjectCreationPage, projectSwipeStartProjectId == nil,
           let selectedProjectIndex {
            projectSwipeStartProjectId = snapshot.projects[selectedProjectIndex].id
        }
        projectSwipeTranslation = horizontalTranslation
        guard let direction = workspaceSidebarProjectSwipeDirection(
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: verticalTranslation,
        ) else {
            return
        }
        let activeProjectIndex = projectPagerDisplayIndex
        let shouldNavigate = workspaceSidebarProjectSwipeTargetIndex(
            currentIndex: activeProjectIndex, projectCount: snapshot.projects.count,
            direction: direction, distance: abs(horizontalTranslation)) != nil
        if shouldNavigate && !projectSwipeDidCrossBreakPoint {
            projectSwipeDidCrossBreakPoint = true
            performWorkspaceSidebarProjectHaptic(.alignment)
        } else if !shouldNavigate {
            projectSwipeDidCrossBreakPoint = false
        }
    }

    func shouldHandleProjectSwipe(
        horizontalTranslation: CGFloat,
        verticalTranslation: CGFloat,
        expansionProgress: CGFloat,
    ) -> Bool {
        guard isProjectSwipeEnabled(expansionProgress: expansionProgress) else { return false }
        return workspaceSidebarProjectSwipeDirection(
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: verticalTranslation,
        ) != nil
    }

    func isProjectSwipeEnabled(expansionProgress: CGFloat) -> Bool {
        !snapshot.projects.isEmpty && !isWorkspaceSidebarDragInProgress() &&
            (showsProjectCreationPage || !(showsAllProjects && expansionProgress >= workspaceSidebarRowsRevealProgress))
    }
}

enum WorkspaceSidebarProjectCreationAction: Equatable {
    case create, leave
}

func workspaceSidebarProjectCreationAction(for key: WorkspaceSidebarInlineTextKey) -> WorkspaceSidebarProjectCreationAction? {
    switch key {
        case .commit: .create
        case .cancel: .leave
        default: nil
    }
}
