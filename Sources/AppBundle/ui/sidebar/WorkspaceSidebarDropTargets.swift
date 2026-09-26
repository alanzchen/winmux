import SwiftUI

enum WorkspaceSidebarDropTargetKind: Equatable {
    case workspace(String)
    case newWorkspace(projectId: WorkspaceProjectId, monitorScopeId: String)
    case monitor(String)
    /// Tabs mode: the edge between two tabs, where a dropped tab moves, or a dropped window
    /// opens in a tab of its own.
    case tabGap(projectId: WorkspaceProjectId, monitorScopeId: String, gap: WorkspaceSidebarTabGap)
}

/// A place between tabs: just before or just after a workspace.
struct WorkspaceSidebarTabGap: Hashable {
    let workspaceName: String
    let isAfter: Bool
}

/// Where a tab dropped on another tab goes: beside its window on one side, or into a stack
/// with it.
enum WorkspaceSidebarTabDropPlacement: Hashable {
    case left, right, stack
}

/// Tabs mode only. Which half of the tab the pointer is over, or a stack while Option is held.
func workspaceSidebarTabDropPlacement(
    pointX: CGFloat,
    targetMidX: CGFloat,
    subject: WindowDragSubject,
    optionHeld: Bool,
) -> WorkspaceSidebarTabDropPlacement {
    if optionHeld, subject == .window { return .stack }
    return pointX < targetMidX ? .left : .right
}

/// Each tab's top and bottom edges are gaps; the middle takes the tab itself. The bands reach
/// a little past the tab, so the gap between two tabs is one target. A folder's bands stay
/// outside it, in the space around it, so every part of the folder takes the drop itself.
func workspaceSidebarTabGapBands(for frame: CGRect, inside maxInside: CGFloat = 7) -> (before: CGRect, after: CGRect) {
    let inside = min(maxInside, frame.height / 4)
    let outside: CGFloat = 3
    return (
        CGRect(x: frame.minX, y: frame.minY - outside, width: frame.width, height: inside + outside),
        CGRect(x: frame.minX, y: frame.maxY - inside, width: frame.width, height: inside + outside),
    )
}

struct WorkspaceSidebarDropTarget {
    let kind: WorkspaceSidebarDropTargetKind
    let rect: Rect
    /// A Tabs-mode tab, drawn as one: a dropped tab joins it on the half it was dropped on.
    var acceptsSides = false
}

struct WorkspaceSidebarDropTargetFrame: Equatable {
    let kind: WorkspaceSidebarDropTargetKind
    let frame: CGRect
    var acceptsSides = false
}

struct WorkspaceSidebarDropTargetPreferenceKey: PreferenceKey {
    static let defaultValue: [WorkspaceSidebarDropTargetFrame] = []

    static func reduce(value: inout [WorkspaceSidebarDropTargetFrame], nextValue: () -> [WorkspaceSidebarDropTargetFrame]) {
        value.append(contentsOf: nextValue())
    }
}

/// `includesTabGaps` is false for a window dragged in from the screen: it joins a tab or gets
/// a new one, and the gaps' thin bands would otherwise swallow the tabs under its hit slop.
@MainActor
func workspaceSidebarDropTarget(at mouseLocation: CGPoint, hitSlop: NSEdgeInsets = NSEdgeInsets(),
                                includesTabGaps: Bool = true) -> WorkspaceSidebarDropTarget? {
    let screenPoint = CGPoint(x: mouseLocation.x, y: mainMonitor.height - mouseLocation.y)
    return WorkspaceSidebarPanel.visiblePanels.first {
        $0.visibleSurfaceFrameOnScreen.contains(screenPoint) || $0.isScreenPointInsideExpandedSurface(screenPoint)
    }?
        .dropTarget(atScreenPoint: screenPoint, hitSlop: hitSlop, includesTabGaps: includesTabGaps)
}

/// SwiftUI/hosting coordinates have their origin at the top left. Keep targets local
/// so scrolling, panel moves and monitor removal never leave a stale screen-space cache.
func workspaceSidebarLocalDropTarget(
    at point: CGPoint,
    targets: [WorkspaceSidebarDropTargetFrame],
    surface: CGRect,
    hitSlop: NSEdgeInsets = NSEdgeInsets(),
    includesTabGaps: Bool = true,
) -> WorkspaceSidebarDropTargetFrame? {
    guard surface.contains(point) else { return nil }
    for target in targets.reversed() {
        if !includesTabGaps, case .tabGap = target.kind { continue }
        let clipped = target.frame.intersection(surface)
        guard !clipped.isNull, !clipped.isEmpty else { continue }
        let hitRect = CGRect(x: clipped.minX - hitSlop.left, y: clipped.minY - hitSlop.top,
            width: clipped.width + hitSlop.left + hitSlop.right,
            height: clipped.height + hitSlop.top + hitSlop.bottom)
        if hitRect.contains(point) {
            return .init(kind: target.kind, frame: clipped, acceptsSides: target.acceptsSides)
        }
    }
    return nil
}
