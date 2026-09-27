import SwiftUI

enum WorkspaceSidebarDropTargetKind: Equatable {
    case workspace(String)
    case tabCollection(String)
    case newWorkspace(projectId: WorkspaceProjectId, monitorScopeId: String)
    case monitor(String)
    /// Tabs mode: the edge between two tabs, where a dropped tab moves, or a dropped window
    /// opens in a tab of its own.
    case tabGap(projectId: WorkspaceProjectId, monitorScopeId: String, gap: WorkspaceSidebarTabGap)
    /// Tabs mode: the pinned tiles at the top, where a dropped tab is pinned.
    case pinnedTabs(projectId: WorkspaceProjectId)
}

/// A place between tabs: just before or just after a workspace.
struct WorkspaceSidebarTabGap: Hashable {
    let workspaceName: String
    let isAfter: Bool
    var collectionId: String? = nil
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
    // Tabs mode uses sidebar rows for switching; Option never creates a stack.
    return pointX < targetMidX ? .left : .right
}

/// The end of the joined half that a split's label sits at: the one farther from the pointer,
/// so the dragged tab's image, centered on the pointer, doesn't cover it. Near the half's middle
/// the label keeps its end, so small movements don't bounce it from end to end.
func workspaceSidebarTabDropLabelEdge(
    pointX: CGFloat,
    targetMinX: CGFloat,
    targetMaxX: CGFloat,
    placement: WorkspaceSidebarTabDropPlacement?,
    previous: HorizontalEdge? = nil,
) -> HorizontalEdge? {
    guard let placement, placement != .stack else { return nil }
    let targetMidX = (targetMinX + targetMaxX) / 2
    let halfMidX = placement == .left ? (targetMinX + targetMidX) / 2 : (targetMidX + targetMaxX) / 2
    if let previous, abs(pointX - halfMidX) < 10 { return previous }
    return pointX < halfMidX ? .trailing : .leading
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

struct WorkspaceSidebarTabReorderDestination: Equatable {
    let projectId: WorkspaceProjectId
    let monitorScopeId: String
    let collectionId: String?
}

struct WorkspaceSidebarDropTarget {
    let kind: WorkspaceSidebarDropTargetKind
    let rect: Rect
    /// A Tabs-mode tab, drawn as one: a dropped tab joins it on the half it was dropped on.
    var acceptsSides = false
    var tabReorderDestination: WorkspaceSidebarTabReorderDestination? = nil
}

struct WorkspaceSidebarDropTargetFrame: Equatable {
    let kind: WorkspaceSidebarDropTargetKind
    let frame: CGRect
    var acceptsSides = false
    var tabReorderDestination: WorkspaceSidebarTabReorderDestination? = nil
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
            return .init(kind: target.kind, frame: clipped, acceptsSides: target.acceptsSides,
                tabReorderDestination: target.tabReorderDestination)
        }
    }
    return nil
}
