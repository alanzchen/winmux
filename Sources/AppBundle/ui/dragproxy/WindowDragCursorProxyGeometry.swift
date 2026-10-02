import AppKit

/// `pointerFromBottom` puts the pointer that far above the proxy's bottom; without it, the proxy is
/// centered on the pointer.
func windowDragCursorProxyFrame(mouseScreenPoint: CGPoint, proxySize: CGSize, pointerFromBottom: CGFloat? = nil) -> CGRect {
    let screenFrame = NSScreen.screens
        .first(where: { $0.frame.contains(mouseScreenPoint) })?
        .visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

    var x = mouseScreenPoint.x - (proxySize.width / 2)
    var y = mouseScreenPoint.y - (pointerFromBottom ?? proxySize.height / 2)
    if x + proxySize.width > screenFrame.maxX {
        x = screenFrame.maxX - proxySize.width
    } else if x < screenFrame.minX {
        x = screenFrame.minX
    }
    if y < screenFrame.minY {
        y = screenFrame.minY
    } else if y + proxySize.height > screenFrame.maxY {
        y = screenFrame.maxY - proxySize.height
    }
    return CGRect(x: x, y: y, width: proxySize.width, height: proxySize.height)
}
