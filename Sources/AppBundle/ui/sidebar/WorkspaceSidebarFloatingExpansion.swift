import AppKit
import SwiftUI

/// Space between the resting Dock and its floating project columns. It must stay
/// below the hover exit tolerance so moving between the two never collapses the view.
let workspaceSidebarFloatingViewGap: CGFloat = 10
/// Keeps the floating view's rounded corners clear of the display edges.
let workspaceSidebarFloatingViewMargin: CGFloat = 8
let workspaceSidebarFloatingViewCornerRadius: CGFloat = RadiusToken.panel
let workspaceSidebarProjectColumnGap: CGFloat = 10

/// The floating view's available area beside the resting Dock, in panel coordinates
/// (top-left origin). Its content is aligned toward the Dock inside this area.
func workspaceSidebarFloatingViewRegion(
    availableSize: CGSize,
    dockThickness: CGFloat,
    dockGap: CGFloat,
    position: WorkspaceDockPosition
) -> CGRect {
    let inset = max(dockGap, 0) + max(dockThickness, 0) + workspaceSidebarFloatingViewGap
    let margin = workspaceSidebarFloatingViewMargin
    let width = max(availableSize.width, 0)
    let height = max(availableSize.height, 0)
    switch position {
        case .left:
            return CGRect(x: inset, y: margin, width: max(width - inset - margin, 0), height: max(height - margin * 2, 0))
        case .right:
            return CGRect(x: margin, y: margin, width: max(width - inset - margin, 0), height: max(height - margin * 2, 0))
        case .bottom:
            let regionHeight = min(workspaceSidebarFloatingViewMaximumHeight(availableHeight: height),
                max(height - inset - margin, 0))
            return CGRect(x: margin, y: max(height - inset - regionHeight, 0),
                width: max(width - margin * 2, 0), height: regionHeight)
    }
}

func workspaceSidebarFloatingViewAlignment(_ position: WorkspaceDockPosition) -> Alignment {
    switch position {
        case .left: .leading
        case .right: .trailing
        case .bottom: .bottom
    }
}

func workspaceSidebarFloatingViewMaximumHeight(availableHeight: CGFloat) -> CGFloat {
    // Leave most of a bottom-docked display usable for application windows.
    min(640, max(availableHeight, 0) * 0.7)
}

/// One fixed-width column per project, separated by a small gap.
func workspaceSidebarProjectColumnsWidth(columnCount: Int, columnWidth: CGFloat) -> CGFloat {
    let count = max(columnCount, 1)
    return CGFloat(count) * columnWidth + CGFloat(count - 1) * workspaceSidebarProjectColumnGap
}

extension WorkspaceSidebarPanel {
    func updateExpandedSurfaceFrame(_ frame: CGRect?) {
        guard frame != expandedSurfaceFrame else { return }
        expandedSurfaceFrame = frame
        scheduleHoverRecheckSoon()
    }

    func updateExpandedDropTargets(_ targets: [WorkspaceSidebarDropTargetFrame]) {
        guard targets != expandedDropTargetFrames else { return }
        expandedDropTargetFrames = targets
    }

    /// The floating view accepts input only while the Dock is fully expanded, matching its
    /// SwiftUI hit testing. A collapsing view keeps fading, but passes input through at once.
    var activeExpandedSurfaceFrameInHostingView: CGRect? {
        guard config.workspaceSidebar.floatsExpandedDockView,
              viewModel.workspaceSidebarVisibleWidth >= CGFloat(config.workspaceSidebar.width) - 0.5,
              let expandedSurfaceFrame, !expandedSurfaceFrame.isEmpty
        else { return nil }
        return expandedSurfaceFrame
    }

    var activeExpandedSurfaceFrameOnScreen: CGRect? {
        activeExpandedSurfaceFrameInHostingView.map { convertToScreen(hostingView.convert($0, to: nil)) }
    }

    func isScreenPointInsideExpandedSurface(_ point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        activeExpandedSurfaceFrameOnScreen?.insetBy(dx: -tolerance, dy: -tolerance).contains(point) == true
    }
}
