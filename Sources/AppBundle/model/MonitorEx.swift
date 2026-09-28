import AppKit

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

    @MainActor
    var visibleRectPaddedByOuterGaps: Rect {
        let topLeft = visibleRect.topLeftCorner
        let gaps = ResolvedGaps(gaps: config.gaps, monitor: self)
        let position = config.workspaceSidebar.effectiveDockPosition
        let reserved = workspaceSidebarInset
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

    @MainActor
    var monitorId_oneBased: Int? {
        sortedMonitors.firstIndex { $0.rect.topLeftCorner == rect.topLeftCorner }.map { $0 + 1 }
    }
}

func workspaceStandardTilingRect(_ paddedRect: Rect) -> Rect {
    var rect = paddedRect
    rect.height -= 1
    return rect
}
