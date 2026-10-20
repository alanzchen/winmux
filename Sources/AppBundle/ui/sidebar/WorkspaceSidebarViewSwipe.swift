import AppKit
import Common
import SwiftUI

extension WorkspaceSidebarView {
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
        endProjectPageTransition()
        if projectSwipeStartProjectId == nil,
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
        let shouldCreate = shouldCreateWorkspaceSidebarProjectAfterSwipe(
            currentIndex: activeProjectIndex,
            projectCount: snapshot.projects.count,
            direction: direction,
            distance: abs(horizontalTranslation),
        )
        let shouldNavigate =
            workspaceSidebarProjectIndexAfterSwipe(
                currentIndex: activeProjectIndex,
                projectCount: snapshot.projects.count,
                direction: direction,
            ) != nil &&
            abs(horizontalTranslation) >= workspaceSidebarProjectSwipeNavigateThreshold
        let shouldCommit = shouldCreate || shouldNavigate
        if shouldCommit && !projectSwipeDidCrossBreakPoint {
            projectSwipeDidCrossBreakPoint = true
            performWorkspaceSidebarProjectHaptic(.alignment)
        } else if !shouldCommit {
            projectSwipeDidCrossBreakPoint = false
        }
    }

    func shouldHandleProjectSwipe(
        horizontalTranslation: CGFloat,
        verticalTranslation: CGFloat,
        expansionProgress: CGFloat,
    ) -> Bool {
        guard !snapshot.projects.isEmpty,
              !(showsAllProjects && expansionProgress >= workspaceSidebarRowsRevealProgress),
              !isWorkspaceSidebarDragInProgress()
        else {
            return false
        }
        return workspaceSidebarProjectSwipeDirection(
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: verticalTranslation,
        ) != nil
    }
}
