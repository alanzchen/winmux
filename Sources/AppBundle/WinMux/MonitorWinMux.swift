import AppKit
import Common

extension Monitor {
    /// Standard tiled windows leave one point clear for macOS cross-display size clamping.
    @MainActor
    var standardTilingRect: Rect {
        workspaceStandardTilingRect(visibleRectPaddedByOuterGaps)
    }

    @MainActor
    var workspaceSidebarInset: CGFloat {
        guard config.workspaceSidebar.enabled else { return 0 }
        return workspaceSidebarResolvedPanelMonitors().contains { $0.rect.topLeftCorner == rect.topLeftCorner }
            ? workspaceSidebarReservedWidth(config.workspaceSidebar.onDisplay(self),
                availableHeight: max(rect.height - CGFloat(config.workspaceSidebar.menuBarReserveHeight), 0))
            : 0
    }
}

func workspaceStandardTilingRect(_ paddedRect: Rect) -> Rect {
    var rect = paddedRect
    rect.height -= 1
    return rect
}

extension WinMuxHooks {
    /// Replaces `Monitor.visibleRectPaddedByOuterGaps`: upstream's outer gaps, plus the sidebar or Dock's reserved
    /// width on its side, never narrower or shorter than one point.
    @MainActor
    static func visibleRectPaddedByOuterGaps(_ monitor: some Monitor) -> Rect {
        let visibleRect = monitor.visibleRect
        let topLeft = visibleRect.topLeftCorner
        let gaps = ResolvedGaps(gaps: config.gaps, monitor: monitor)
        let position = config.workspaceSidebar.effectiveDockPosition
        let reserved = monitor.workspaceSidebarInset
        let leftInset = gaps.outer.left.toDouble() + (position == .left ? reserved : 0)
        let rightInset = gaps.outer.right.toDouble() + (position == .right ? reserved : 0)
        let bottomInset = gaps.outer.bottom.toDouble() + (position == .bottom ? reserved : 0)
        return Rect(
            topLeftX: topLeft.x + leftInset,
            topLeftY: topLeft.y + gaps.outer.top.toDouble(),
            width: max(1, visibleRect.width - leftInset - rightInset),
            height: max(1, visibleRect.height - gaps.outer.top.toDouble() - bottomInset),
        )
    }
}
