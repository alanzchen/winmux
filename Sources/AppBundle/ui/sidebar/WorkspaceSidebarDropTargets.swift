import SwiftUI

enum WorkspaceSidebarDropTargetKind: Equatable {
    case workspace(String)
    case newWorkspace(projectId: WorkspaceProjectId, monitorScopeId: String)
    case monitor(String)
}

struct WorkspaceSidebarDropTarget {
    let kind: WorkspaceSidebarDropTargetKind
    let rect: Rect
}

struct WorkspaceSidebarDropTargetFrame: Equatable {
    let kind: WorkspaceSidebarDropTargetKind
    let frame: CGRect
}

struct WorkspaceSidebarDropTargetPreferenceKey: PreferenceKey {
    static let defaultValue: [WorkspaceSidebarDropTargetFrame] = []

    static func reduce(value: inout [WorkspaceSidebarDropTargetFrame], nextValue: () -> [WorkspaceSidebarDropTargetFrame]) {
        value.append(contentsOf: nextValue())
    }
}

@MainActor
func workspaceSidebarDropTarget(at mouseLocation: CGPoint, hitSlop: NSEdgeInsets = NSEdgeInsets()) -> WorkspaceSidebarDropTarget? {
    let screenPoint = CGPoint(x: mouseLocation.x, y: mainMonitor.height - mouseLocation.y)
    return WorkspaceSidebarPanel.visiblePanels.first { $0.visibleSurfaceFrameOnScreen.contains(screenPoint) }?
        .dropTarget(atScreenPoint: screenPoint, hitSlop: hitSlop)
}

/// SwiftUI/hosting coordinates have their origin at the top left. Keep targets local
/// so scrolling, panel moves and monitor removal never leave a stale screen-space cache.
func workspaceSidebarLocalDropTarget(
    at point: CGPoint,
    targets: [WorkspaceSidebarDropTargetFrame],
    surface: CGRect,
    hitSlop: NSEdgeInsets = NSEdgeInsets()
) -> WorkspaceSidebarDropTargetFrame? {
    guard surface.contains(point) else { return nil }
    for target in targets.reversed() {
        let clipped = target.frame.intersection(surface)
        guard !clipped.isNull, !clipped.isEmpty else { continue }
        let hitRect = CGRect(x: clipped.minX - hitSlop.left, y: clipped.minY - hitSlop.top,
            width: clipped.width + hitSlop.left + hitSlop.right,
            height: clipped.height + hitSlop.top + hitSlop.bottom)
        if hitRect.contains(point) {
            return .init(kind: target.kind, frame: clipped)
        }
    }
    return nil
}
