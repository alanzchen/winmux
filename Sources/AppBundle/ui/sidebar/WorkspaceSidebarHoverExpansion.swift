import AppKit

func workspaceSidebarAllowsLeftEdgeTrap(_ sidebarConfig: WorkspaceSidebarConfig) -> Bool {
    !sidebarConfig.alwaysExpanded
}

func workspaceSidebarRestingWidth(_ sidebarConfig: WorkspaceSidebarConfig) -> CGFloat {
    if sidebarConfig.alwaysExpanded {
        return CGFloat(sidebarConfig.width)
    }
    return sidebarConfig.autoHide ? 0 : CGFloat(sidebarConfig.effectiveCollapsedWidth)
}

func workspaceSidebarReservedWidth(_ sidebarConfig: WorkspaceSidebarConfig) -> CGFloat {
    let width = workspaceSidebarRestingWidth(sidebarConfig)
    // A hidden Dock reserves neither its rail nor the empty gap beside it.
    return width > 0 ? width + CGFloat(sidebarConfig.effectiveLeftGap) : 0
}

func workspaceSidebarHoverRegion(
    surface: CGRect,
    sidebarConfig: WorkspaceSidebarConfig,
    exitTolerance: CGFloat
) -> CGRect {
    // Auto-hide must still reveal from the physical display edge, across the new gap.
    // This only extends the reveal region; the gap never captures clicks or magnifies icons.
    let revealGap = sidebarConfig.autoHide && !sidebarConfig.alwaysExpanded
        ? CGFloat(sidebarConfig.effectiveLeftGap) : 0
    return CGRect(
        x: surface.minX - revealGap,
        y: surface.minY,
        width: max(surface.width, workspaceSidebarHoverActivationWidth(sidebarConfig)) + exitTolerance + revealGap,
        height: surface.height
    )
}

func workspaceSidebarHoverActivationWidth(_ sidebarConfig: WorkspaceSidebarConfig) -> CGFloat {
    sidebarConfig.alwaysExpanded ? CGFloat(sidebarConfig.width) : CGFloat(sidebarConfig.effectiveCollapsedWidth)
}

func workspaceSidebarCollapsedContentWidth(_ sidebarConfig: WorkspaceSidebarConfig) -> CGFloat {
    sidebarConfig.autoHide && !sidebarConfig.alwaysExpanded ? 0 : CGFloat(sidebarConfig.effectiveCollapsedWidth)
}

func workspaceSidebarPersistentVisibleWidth(
    currentWidth: CGFloat,
    previousExpandedWidth: CGFloat?,
    expandedWidth: CGFloat,
) -> CGFloat {
    let wasShowingSplitBrowse = previousExpandedWidth.map { currentWidth > $0 + 0.5 } ?? false
    return wasShowingSplitBrowse ? expandedWidth * 2 : expandedWidth
}

func isWorkspaceSidebarHoverDeepEnoughToExpand(
    mouseX: CGFloat,
    sidebarMinX: CGFloat,
    collapsedWidth: CGFloat,
) -> Bool {
    guard collapsedWidth > 0 else { return false }
    let sidebarMaxX = sidebarMinX + collapsedWidth
    return sidebarMaxX - mouseX >= collapsedWidth * workspaceSidebarHoverOpenThresholdFraction
}

func shouldDelayWorkspaceSidebarExpansion(
    isExpanded: Bool,
    isExpansionLocked: Bool,
    isMouseWindowDragInProgress: Bool,
) -> Bool {
    !isExpanded && !isExpansionLocked && !isMouseWindowDragInProgress
}

func shouldSuppressWorkspaceSidebarHoverExpansionForDrag(
    isSidebarItemDragActive: Bool,
    isSidebarOriginatedDrag: Bool,
) -> Bool {
    isSidebarItemDragActive || isSidebarOriginatedDrag
}
