import CoreGraphics

/// Map each selected edge to a left edge for shared crossing/velocity logic.
/// Input and output use Quartz global coordinates; artwork is never transformed.
func workspaceSidebarEdgePoint(_ point: CGPoint, position: WorkspaceDockPosition, inverse: Bool = false) -> CGPoint {
    switch position {
        case .left: point
        case .right: CGPoint(x: -point.x, y: point.y)
        case .bottom: inverse ? CGPoint(x: point.y, y: -point.x) : CGPoint(x: -point.y, y: point.x)
    }
}

func workspaceSidebarEdgeRect(_ rect: Rect, position: WorkspaceDockPosition) -> CGRect {
    let a = workspaceSidebarEdgePoint(CGPoint(x: rect.minX, y: rect.minY), position: position)
    let b = workspaceSidebarEdgePoint(CGPoint(x: rect.maxX, y: rect.maxY), position: position)
    return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

func workspaceSidebarCrossesEdge(point: CGPoint, previous: CGPoint?, frame: CGRect, band: CGFloat) -> Bool {
    if point.y >= frame.minY, point.y < frame.maxY,
       point.x >= frame.minX - band, point.x <= frame.minX + band { return true }
    guard let previous else { return false }
    let crossedOut = previous.x >= frame.minX && point.x < frame.minX
    let crossedIn = previous.x < frame.minX && point.x >= frame.minX
    let crossedBand = previous.x > frame.minX + band && point.x < frame.minX - band
    return (crossedOut || crossedIn || crossedBand)
        && max(previous.y, point.y) >= frame.minY && min(previous.y, point.y) < frame.maxY
}

func workspaceSidebarHasAdjacentEdgeMonitor(frame: CGRect, otherFrames: [CGRect]) -> Bool {
    otherFrames.contains {
        abs($0.maxX - frame.minX) < 0.5 && $0.maxY > frame.minY && $0.minY < frame.maxY
    }
}
