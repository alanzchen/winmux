import AppKit

/// The visible frame of the screen the pointer is on.
func windowDragCursorProxyScreenFrame(containing mouseScreenPoint: CGPoint) -> CGRect {
    NSScreen.screens
        .first(where: { $0.frame.contains(mouseScreenPoint) })?
        .visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
}

/// `pointer` puts the pointer at that point of the proxy, from its bottom-left corner; without it,
/// the proxy is centered on the pointer.
func windowDragCursorProxyFrame(mouseScreenPoint: CGPoint, proxySize: CGSize, pointer: CGPoint? = nil,
                                screenFrame: CGRect? = nil) -> CGRect {
    let screenFrame = screenFrame ?? windowDragCursorProxyScreenFrame(containing: mouseScreenPoint)

    var x = mouseScreenPoint.x - (pointer?.x ?? proxySize.width / 2)
    var y = mouseScreenPoint.y - (pointer?.y ?? proxySize.height / 2)
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
