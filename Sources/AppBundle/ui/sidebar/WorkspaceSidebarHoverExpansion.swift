import AppKit

/// A popup stays open over its opening Dock even when expansion changes its shape.
/// This region participates only in hover retention, never click or drag hit testing.
struct WorkspaceSidebarExpansionHoverSource {
    let region: CGRect
    let panelFrame: CGRect
    let position: WorkspaceDockPosition
    private let compactWidth: CGFloat
    private let expandedWidth: Int
    private let gap: Int
    private let autoHide: Bool

    init(region: CGRect, panelFrame: CGRect, sidebarConfig: WorkspaceSidebarConfig) {
        self.region = region
        self.panelFrame = panelFrame
        position = sidebarConfig.effectiveDockPosition
        compactWidth = sidebarConfig.effectiveCollapsedWidth
        expandedWidth = sidebarConfig.width
        gap = sidebarConfig.effectiveLeftGap
        autoHide = sidebarConfig.autoHide
    }

    func matches(panelFrame: CGRect, sidebarConfig: WorkspaceSidebarConfig) -> Bool {
        self.panelFrame == panelFrame && position == sidebarConfig.effectiveDockPosition
            && compactWidth == sidebarConfig.effectiveCollapsedWidth && expandedWidth == sidebarConfig.width
            && gap == sidebarConfig.effectiveLeftGap && autoHide == sidebarConfig.autoHide
            && sidebarConfig.showAppIcons && !sidebarConfig.alwaysExpanded
    }

    func contains(_ point: CGPoint, panelFrame: CGRect, sidebarConfig: WorkspaceSidebarConfig) -> Bool {
        matches(panelFrame: panelFrame, sidebarConfig: sidebarConfig) && region.contains(point)
    }
}

func workspaceSidebarAllowsEdgeTrap(_ sidebarConfig: WorkspaceSidebarConfig) -> Bool {
    !sidebarConfig.alwaysExpanded
}

func workspaceSidebarRestingWidth(_ sidebarConfig: WorkspaceSidebarConfig) -> CGFloat {
    if sidebarConfig.alwaysExpanded {
        return CGFloat(sidebarConfig.width)
    }
    return sidebarConfig.autoHide ? 0 : CGFloat(sidebarConfig.effectiveCollapsedWidth)
}

func workspaceSidebarReservedWidth(_ sidebarConfig: WorkspaceSidebarConfig, availableHeight: CGFloat = 1000) -> CGFloat {
    if sidebarConfig.effectiveDockPosition == .bottom && sidebarConfig.alwaysExpanded {
        return workspaceSidebarBottomExpandedHeight(availableHeight: availableHeight)
    }
    let width = workspaceSidebarRestingWidth(sidebarConfig)
    // A hidden Dock reserves neither its rail nor the empty gap beside it.
    return width > 0 ? width + CGFloat(sidebarConfig.effectiveLeftGap) : 0
}

func workspaceSidebarHoverRegion(
    surface: CGRect,
    displayMinX: CGFloat,
    sidebarConfig: WorkspaceSidebarConfig,
    exitTolerance: CGFloat,
    fittedDockWidth: CGFloat? = nil
) -> CGRect {
    // Auto-hide must still reveal from the physical display edge, across the new gap.
    // This only extends the reveal region; the gap never captures clicks or magnifies icons.
    let revealGap = sidebarConfig.autoHide && !sidebarConfig.alwaysExpanded
        ? max(surface.minX - displayMinX, 0) : 0
    // Reveal uses the final resting fit, not the animated surface width. Otherwise
    // the hover target briefly contracts as an auto-hidden Dock starts to appear.
    let restingWidth = sidebarConfig.showAppIcons
        ? fittedDockWidth ?? workspaceSidebarHoverActivationWidth(sidebarConfig)
        : workspaceSidebarHoverActivationWidth(sidebarConfig)
    let activationWidth = max(surface.width, restingWidth)
    return CGRect(
        x: surface.minX - revealGap,
        y: surface.minY,
        width: activationWidth + exitTolerance + revealGap,
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
    // Two-project browsing is the only expanded layout wider than one configured pane.
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

func workspaceSidebarHoverRegion(surface: CGRect, displayFrame: CGRect,
    sidebarConfig: WorkspaceSidebarConfig, exitTolerance: CGFloat, fittedDockWidth: CGFloat? = nil) -> CGRect {
    let position = sidebarConfig.effectiveDockPosition
    if position == .left {
        return workspaceSidebarHoverRegion(surface: surface, displayMinX: displayFrame.minX,
            sidebarConfig: sidebarConfig, exitTolerance: exitTolerance, fittedDockWidth: fittedDockWidth)
    }
    let thickness = fittedDockWidth ?? workspaceSidebarHoverActivationWidth(sidebarConfig)
    let autoHide = sidebarConfig.autoHide && !sidebarConfig.alwaysExpanded
    if position == .right {
        let edge = autoHide ? displayFrame.maxX : surface.maxX
        let width = max(surface.width, thickness) + exitTolerance + max(edge - surface.maxX, 0)
        return CGRect(x: edge - width, y: surface.minY, width: width, height: surface.height)
    }
    let edge = autoHide ? displayFrame.minY : surface.minY
    return CGRect(x: surface.minX, y: edge, width: surface.width,
        height: max(surface.height, thickness) + exitTolerance + max(surface.minY - edge, 0))
}

func workspaceSidebarHoverDepth(point: CGPoint, displayFrame: CGRect,
    sidebarConfig: WorkspaceSidebarConfig, thickness: CGFloat) -> Bool {
    let gap = CGFloat(sidebarConfig.effectiveLeftGap)
    let distance: CGFloat
    switch sidebarConfig.effectiveDockPosition {
        case .left: distance = point.x - displayFrame.minX - gap
        case .right: distance = displayFrame.maxX - point.x - gap
        case .bottom: distance = point.y - displayFrame.minY - gap
    }
    return thickness > 0 && distance <= thickness * (1 - workspaceSidebarHoverOpenThresholdFraction)
}
