import SwiftUI

func workspaceSidebarProjectSwipeDirection(
    horizontalTranslation: CGFloat,
    verticalTranslation: CGFloat,
    minimumDistance: CGFloat = workspaceSidebarProjectSwipeIntentThreshold,
) -> Int? {
    let horizontalDistance = abs(horizontalTranslation)
    guard horizontalDistance >= minimumDistance,
          horizontalDistance > abs(verticalTranslation) * 1.8
    else { return nil }
    return horizontalTranslation < 0 ? 1 : -1
}

/// The final page (index `projectCount`) is the creation page. Neither edge wraps or creates.
func workspaceSidebarProjectIndexAfterSwipe(currentIndex: Int?, projectCount: Int, direction: Int) -> Int? {
    guard let currentIndex, projectCount > 0, (0 ... projectCount).contains(currentIndex) else { return nil }
    let nextIndex = currentIndex + direction
    return (0 ... projectCount).contains(nextIndex) ? nextIndex : nil
}

func workspaceSidebarProjectSwipeTargetIndex(currentIndex: Int?, projectCount: Int, direction: Int, distance: CGFloat) -> Int? {
    guard distance >= workspaceSidebarProjectSwipeNavigateThreshold else { return nil }
    return workspaceSidebarProjectIndexAfterSwipe(currentIndex: currentIndex, projectCount: projectCount, direction: direction)
}

func shouldRenderWorkspaceSidebarProjectPage(index: Int, displayIndex: Int, swipeDirection: Int?, projectCount: Int) -> Bool {
    guard index != displayIndex else { return true }
    guard let swipeDirection else { return false }
    return index == workspaceSidebarProjectIndexAfterSwipe(
        currentIndex: displayIndex,
        projectCount: projectCount,
        direction: swipeDirection,
    )
}
func workspaceSidebarProjectResistedOffset(
    horizontalTranslation: CGFloat,
    currentIndex: Int?,
    projectCount: Int,
) -> CGFloat {
    let direction = horizontalTranslation < 0 ? 1 : -1
    let isPastProjectEdge = workspaceSidebarProjectIndexAfterSwipe(
        currentIndex: currentIndex,
        projectCount: projectCount,
        direction: direction,
    ) == nil
    let divisor: CGFloat = isPastProjectEdge ? 2.2 : 1.0
    let limit: CGFloat = isPastProjectEdge ? 52 : 72
    return max(-limit, min(limit, horizontalTranslation / divisor))
}

func workspaceSidebarProjectPagerDragOffset(
    horizontalTranslation: CGFloat,
    currentIndex: Int?,
    projectCount: Int,
    pageWidth: CGFloat,
) -> CGFloat {
    guard pageWidth > 0,
          let direction = workspaceSidebarProjectSwipeDirection(
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: 0,
            minimumDistance: 1,
          )
    else { return 0 }
    guard workspaceSidebarProjectIndexAfterSwipe(
        currentIndex: currentIndex,
        projectCount: projectCount,
        direction: direction,
    ) != nil else {
        return workspaceSidebarProjectResistedOffset(
            horizontalTranslation: horizontalTranslation,
            currentIndex: currentIndex,
            projectCount: projectCount,
        )
    }
    return max(-pageWidth, min(pageWidth, horizontalTranslation))
}
func workspaceSidebarProjectSwipeSwitchProgress(distance: CGFloat) -> CGFloat {
    min(max(distance / workspaceSidebarProjectSwipeNavigateThreshold, 0), 1)
}

func workspaceSidebarProjectSwipeTranslationAfterScroll(currentTranslation: CGFloat, scrollingDeltaX: CGFloat) -> CGFloat {
    currentTranslation - scrollingDeltaX
}
