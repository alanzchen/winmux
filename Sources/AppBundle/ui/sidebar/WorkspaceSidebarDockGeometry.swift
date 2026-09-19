import CoreGraphics
import SwiftUI

/// Fit the column plus its maximum hover growth before animation runs. The configured
/// size remains a ceiling; very crowded columns still scroll at a usable 16-point minimum.
@MainActor
func workspaceSidebarFittedDockIconSize(
    appCounts: [Int],
    configuration: WorkspaceSidebarConfiguration,
    availableHeight: CGFloat,
    showsCreateWorkspace: Bool,
    showsMonitorSelector: Bool,
    projectCount: Int
) -> CGFloat {
    guard configuration.showAppIcons else { return configuration.dockIconSize }
    let maximum = configuration.dockIconSize
    let iconCount = appCounts.reduce(0) { $0 + 1 + max($1, 0) }
    guard iconCount > 0, availableHeight.isFinite else { return maximum }
    func fits(_ size: CGFloat) -> Bool {
        var layout = configuration
        layout.dockIconSize = size
        let height = workspaceSidebarDockContentHeight(
            appCounts: appCounts, configuration: layout,
            showsCreateWorkspace: showsCreateWorkspace, showsMonitorSelector: showsMonitorSelector,
            projectCount: projectCount
        )
        let hoverGrowth = layout.dockMagnification
            ? WorkspaceSidebarDockColumnMagnification.maximumGrowth(
                appCounts: appCounts, itemSize: size, amount: layout.dockMagnificationAmount)
            : 0
        return height + hoverGrowth <= max(availableHeight, 0)
    }
    guard !fits(maximum) else { return maximum }
    let minimum = min(16, maximum)
    guard maximum > minimum, fits(minimum) else { return minimum }
    // Hover growth depends on icon size too. Search half-point sizes once during
    // snapshot/viewport layout, never refitting in response to the moving pointer.
    var lower = Int(minimum * 2)
    var upper = Int(floor(maximum * 2))
    while lower < upper {
        let middle = (lower + upper + 1) / 2
        if fits(CGFloat(middle) / 2) { lower = middle }
        else { upper = middle - 1 }
    }
    return CGFloat(lower) / 2
}

/// The compact column uses fixed-size tiles and controls, so its ideal height does not
/// require a second offscreen sidebar or a feedback loop through ScrollView measurement.
@MainActor
func workspaceSidebarDockContentHeight(
    appCounts: [Int],
    configuration: WorkspaceSidebarConfiguration,
    showsCreateWorkspace: Bool,
    showsMonitorSelector: Bool,
    projectCount: Int
) -> CGFloat {
    if configuration.dockPosition == .bottom {
        return workspaceSidebarBottomDockLength(appCounts: appCounts, configuration: configuration,
            showsCreateWorkspace: showsCreateWorkspace, showsMonitorSelector: showsMonitorSelector,
            projectCount: projectCount)
    }
    let iconWidth: CGFloat = max(configuration.compactRailWidth - configuration.compactHorizontalInset * 2, 1)
    let workspaceHeights: [CGFloat] = appCounts.map {
        WorkspaceSidebarAppIconLayout(appCount: $0, availableWidth: iconWidth, magnificationEnabled: configuration.dockMagnification, iconSize: configuration.dockIconSize, magnificationAmount: configuration.dockMagnificationAmount).height + 6
    }
    let sectionCount = workspaceHeights.count + (showsCreateWorkspace ? 1 : 0)
    let workspaceHeight: CGFloat = workspaceHeights.reduce(CGFloat.zero, +)
    let createHeight: CGFloat = showsCreateWorkspace ? workspaceSidebarWorkspaceSectionHeightCompact : 0
    let sectionSpacing: CGFloat = CGFloat(max(sectionCount - 1, 0)) * 6
    let pageTopPadding: CGFloat = showsMonitorSelector ? 0 : configuration.topPadding
    let pageHeight: CGFloat = workspaceHeight + createHeight + sectionSpacing + pageTopPadding + 10
    let monitorHeight: CGFloat = showsMonitorSelector
        ? workspaceSidebarDropdownHeight + configuration.topPadding + workspaceSidebarSectionGap
        : 0
    // With one or no projects the compact pager is EmptyView, including its padding.
    let projectHeight: CGFloat = projectCount > 1
        ? min(CGFloat(projectCount), 5) * workspaceSidebarProjectDotFrameHeight + 8
        : 0
    let clockHeight: CGFloat = configuration.showsClock
        ? (configuration.showsSeconds ? 92 : 68) * configuration.compactDockScale + 8
            + workspaceSidebarStatusBottomPadding(isCompact: true, layout: configuration)
        : 0
    let footerHeight: CGFloat = workspaceSidebarFooterBottomPadding(showsClock: configuration.showsClock)
    // The visible chevron button is 28 points high with 4 points of bottom padding.
    let expandControlHeight: CGFloat = configuration.dockMagnification ? 32 : 0
    let contentHeight: CGFloat = pageHeight + monitorHeight + projectHeight + clockHeight + footerHeight + expandControlHeight
    return max(contentHeight, 1)
}

func workspaceSidebarSurfaceFrame(
    availableSize: CGSize,
    visibleWidth: CGFloat,
    compactHeight: CGFloat,
    expansionProgress: CGFloat,
    fitsDockContent: Bool,
    compactLeftGap: CGFloat = 0,
    position: WorkspaceDockPosition = .left
) -> CGRect {
    let availableHeight = max(availableSize.height, 0)
    if fitsDockContent, position == .bottom {
        let progress = min(max(expansionProgress, 0), 1)
        let length = min(max(compactHeight, 0), max(availableSize.width, 0))
        let width = length + (max(visibleWidth, 0) - length) * progress
        let height = max(visibleWidth, 0) * (1 - progress)
            + workspaceSidebarBottomExpandedHeight(availableHeight: availableHeight) * progress
        return CGRect(x: (availableSize.width - width) / 2,
            y: availableHeight - height - max(compactLeftGap, 0) * (1 - progress),
            width: width, height: height)
    }
    let progress = fitsDockContent ? min(max(expansionProgress, 0), 1) : 1
    let compact = min(max(compactHeight, 0), availableHeight)
    let height = compact + (availableHeight - compact) * progress
    // Keep the native panel on the screen edge. Only the compact shelf is inset;
    // its gap closes along with the existing expansion animation.
    let leftGap = max(compactLeftGap, 0) * (1 - progress)
    let width = max(visibleWidth, 0)
    return CGRect(x: position == .right ? availableSize.width - leftGap - width : leftGap,
        y: (availableHeight - height) / 2, width: width, height: height)
}

func workspaceSidebarClippedDropTargets(
    _ targets: [WorkspaceSidebarDropTargetFrame],
    to viewport: CGRect
) -> [WorkspaceSidebarDropTargetFrame] {
    targets.compactMap { target in
        let clipped = target.frame.intersection(viewport)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return WorkspaceSidebarDropTargetFrame(kind: target.kind, frame: clipped)
    }
}

struct WorkspaceSidebarSurfaceFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

struct WorkspaceSidebarDockRestingWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

func workspaceSidebarBottomExpandedHeight(availableHeight: CGFloat) -> CGFloat {
    // Leave usable space for application windows even on small displays.
    min(600, max(availableHeight, 0) * 0.6)
}

/// Compact horizontal controls keep the same thickness as the vertical shelf.
@MainActor
func workspaceSidebarBottomDockLength(appCounts: [Int], configuration: WorkspaceSidebarConfiguration,
    showsCreateWorkspace: Bool, showsMonitorSelector: Bool, projectCount: Int) -> CGFloat {
    let workspaces = appCounts.reduce(CGFloat.zero) {
        $0 + WorkspaceSidebarDockMagnification(itemSize: configuration.dockIconSize,
            count: 1 + max($1, 0), enabled: false).height + 6
    }
    let sections = appCounts.count + (showsCreateWorkspace ? 1 : 0)
    let page = workspaces + CGFloat(max(sections - 1, 0)) * 6 + (showsCreateWorkspace ? 32 : 0) + 20
    return page + (showsMonitorSelector ? 36 : 0) + 32
        + (projectCount > 1 ? min(CGFloat(projectCount), 5) * 36 + 8 : 0)
        + (configuration.showsClock ? 120 : 0) + 12
}

/// Reorient rectangles, never artwork. The baseline next to the display edge is fixed.
func workspaceSidebarDockOrientedFrame(_ frame: CGRect, crossAxis: CGFloat,
    position: WorkspaceDockPosition) -> CGRect {
    switch position {
        case .left: return frame
        case .right:
            return CGRect(x: crossAxis - frame.maxX, y: frame.minY, width: frame.width, height: frame.height)
        case .bottom:
            return CGRect(x: frame.minY, y: crossAxis - frame.maxX, width: frame.height, height: frame.width)
    }
}
