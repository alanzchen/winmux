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
    let maximum = min(configuration.dockIconSize,
                      max(configuration.compactRailWidth - workspaceSidebarCompactRailHorizontalInset * 2, 1))
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
