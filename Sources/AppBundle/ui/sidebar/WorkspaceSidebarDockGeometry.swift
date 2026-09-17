import CoreGraphics
import SwiftUI

/// Fit the resting column before hover animation runs. The configured size remains
/// a ceiling; very crowded columns keep scrolling at a usable 16-point minimum.
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
    let maximum = min(configuration.dockIconSize,
                      max(configuration.compactRailWidth - workspaceSidebarCompactRailHorizontalInset * 2, 1))
    let iconCount = appCounts.reduce(0) { $0 + 1 + max($1, 0) }
    guard iconCount > 0, availableHeight.isFinite else { return maximum }
    let height = workspaceSidebarDockContentHeight(
        appCounts: appCounts, configuration: configuration,
        showsCreateWorkspace: showsCreateWorkspace, showsMonitorSelector: showsMonitorSelector,
        projectCount: projectCount
    )
    guard height > availableHeight else { return maximum }
    // Everything except icon canvases (separators, spacing, controls) stays fixed.
    let fitted = maximum - (height - max(availableHeight, 0)) / CGFloat(iconCount)
    return min(maximum, max(min(16, maximum), floor(fitted * 2) / 2))
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
    let iconWidth: CGFloat = max(configuration.compactRailWidth - workspaceSidebarCompactRailHorizontalInset * 2, 1)
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
        ? (configuration.showsSeconds ? 92 : 68) + 8 + workspaceSidebarStatusBottomPadding(isCompact: true)
        : 0
    let footerHeight: CGFloat = workspaceSidebarFooterBottomPadding(showsClock: configuration.showsClock)
    let expandHeight: CGFloat = configuration.dockMagnification ? 32 : 0
    let contentHeight: CGFloat = pageHeight + monitorHeight + projectHeight + clockHeight + footerHeight + expandHeight
    return max(contentHeight, 1)
}

func workspaceSidebarSurfaceFrame(
    availableSize: CGSize,
    visibleWidth: CGFloat,
    compactHeight: CGFloat,
    expansionProgress: CGFloat,
    fitsDockContent: Bool
) -> CGRect {
    let availableHeight = max(availableSize.height, 0)
    let progress = fitsDockContent ? min(max(expansionProgress, 0), 1) : 1
    let compact = min(max(compactHeight, 0), availableHeight)
    let height = compact + (availableHeight - compact) * progress
    return CGRect(x: 0, y: (availableHeight - height) / 2, width: max(visibleWidth, 0), height: height)
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
