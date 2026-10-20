import AppKit
import Common

@MainActor
func windowTabBarRect(forGroupFrameRect groupFrameRect: Rect) -> Rect {
    Rect(
        topLeftX: groupFrameRect.topLeftX,
        topLeftY: groupFrameRect.topLeftY,
        width: groupFrameRect.width,
        height: min(resolvedWindowTabBarHeight(), groupFrameRect.height),
    )
}

extension Rect {
    var toAppKitScreenRect: CGRect {
        CGRect(
            x: minX,
            y: mainMonitor.height - topLeftY - height,
            width: width,
            height: height,
        )
    }
}
