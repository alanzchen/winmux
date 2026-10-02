import AppKit
import SwiftUI

enum WorkspaceSidebarDropTargetKind: Equatable {
    case workspace(String)
    /// Tabs mode: a group's header. `monitorScopeId` is the display whose list shows it: a tab
    /// from another display moves there as it joins the group, as it does between tabs.
    case tabCollection(String, monitorScopeId: String? = nil)
    case newWorkspace(projectId: WorkspaceProjectId, monitorScopeId: String)
    case monitor(String)
    /// Tabs mode: the edge between two tabs, where a dropped tab moves, or a dropped window
    /// opens in a tab of its own.
    case tabGap(projectId: WorkspaceProjectId, monitorScopeId: String, gap: WorkspaceSidebarTabGap)
    /// Tabs mode: the pinned tiles at the top, where a dropped tab is pinned: beside the pin in
    /// `gap`, or, with nothing pinned there yet, in the place that offers pinning. `monitorScopeId`
    /// is the display whose list shows the tiles: a tab from another display moves there.
    /// `projectId` is the project the list shows, and `section` which of its pins: those in All
    /// Projects, above, or the project's own.
    case pinnedTabs(projectId: WorkspaceProjectId, gap: WorkspaceSidebarTabGap? = nil, monitorScopeId: String? = nil,
                    section: WorkspaceSidebarPinSection = .project)
}

/// Tabs mode: the pinned tiles' two sections. Pins in All Projects sit above the project's own.
enum WorkspaceSidebarPinSection: Hashable {
    case allProjects, project

    init(_ scope: WorkspaceSidebarPinScope?) { self = scope == .allProjects ? .allProjects : .project }

    /// The scope a pin in this section has.
    var scope: WorkspaceSidebarPinScope? { self == .allProjects ? .allProjects : nil }

    /// The section `workspace` is pinned in, or would be pinned in by Pin Tab.
    @MainActor
    init(of workspace: Workspace) { self = workspaceIsPinnedInAllProjects(workspace) ? .allProjects : .project }
}

/// A pin dropped among the other section's pins: it goes to `scope`'s, and with nil, the pins of
/// `projectId`, the project the list shows, whichever project it was from.
struct WorkspaceSidebarPinMove: Hashable {
    let scope: WorkspaceSidebarPinScope?
    let projectId: WorkspaceProjectId

    init(to section: WorkspaceSidebarPinSection, in projectId: WorkspaceProjectId) {
        scope = section.scope
        self.projectId = projectId
    }

    var section: WorkspaceSidebarPinSection { .init(scope) }
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

/// Where a split's label sits on the tab: at one end of either half.
struct WorkspaceSidebarTabDropLabelSlot: Hashable {
    /// `.leading` for the tab's left half.
    let half: HorizontalEdge
    let edge: HorizontalEdge
    /// No slot clears the dragged tab on a tab this narrow, so the half's highlight goes unlabeled.
    var isHidden = false
}

/// Where a split's label goes so the dragged tab's image, centered on the pointer, doesn't
/// cover it. It prefers the joined half's far end, then its near end, then the other half, and
/// takes the first that clears the image by `clearance`. Where none does, or the label doesn't
/// fit in a half, it's hidden. It keeps its slot while that still clears, so small movements
/// don't bounce it around.
func workspaceSidebarTabDropLabelSlot(
    pointX: CGFloat,
    targetMinX: CGFloat,
    targetMaxX: CGFloat,
    placement: WorkspaceSidebarTabDropPlacement?,
    labelWidth: CGFloat,
    clearance: CGFloat,
    previous: WorkspaceSidebarTabDropLabelSlot? = nil,
) -> WorkspaceSidebarTabDropLabelSlot? {
    guard let placement, placement != .stack else { return nil }
    let midX = (targetMinX + targetMaxX) / 2
    let inset = workspaceSidebarTabDropLabelInset
    func distance(_ slot: WorkspaceSidebarTabDropLabelSlot) -> CGFloat {
        let (start, end) = slot.half == .leading ? (targetMinX, midX) : (midX, targetMaxX)
        let minX = slot.edge == .leading ? start + inset : end - inset - labelWidth
        return max(0, minX - pointX, pointX - (minX + labelWidth))
    }
    // A browser card's highlight is inset inside the target, so its halves are a little narrower.
    let fits = labelWidth + 2 * inset + 2 * workspaceSidebarTabGroupInset <= midX - targetMinX
    if fits, let previous, !previous.isHidden, distance(previous) >= clearance { return previous }
    let own: HorizontalEdge = placement == .left ? .leading : .trailing
    let other: HorizontalEdge = own == .leading ? .trailing : .leading
    let ownMidX = placement == .left ? (targetMinX + midX) / 2 : (midX + targetMaxX) / 2
    let far: HorizontalEdge = pointX < ownMidX ? .trailing : .leading
    let near: HorizontalEdge = far == .leading ? .trailing : .leading
    // Beside the joined half first, so the label still reads as the half's.
    let candidates = [
        WorkspaceSidebarTabDropLabelSlot(half: own, edge: far),
        WorkspaceSidebarTabDropLabelSlot(half: own, edge: near),
        WorkspaceSidebarTabDropLabelSlot(half: other, edge: own == .leading ? .leading : .trailing),
        WorkspaceSidebarTabDropLabelSlot(half: other, edge: own == .leading ? .trailing : .leading),
    ]
    return candidates.first { fits && distance($0) >= clearance }
        ?? WorkspaceSidebarTabDropLabelSlot(half: own, edge: far, isHidden: true)
}

let workspaceSidebarTabDropLabelInset: CGFloat = 6

/// The label's width, to keep it clear of the dragged tab.
func workspaceSidebarTabDropLabelWidth(_ text: String) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width) + 12
}

func workspaceSidebarTabDropLabelText(_ placement: WorkspaceSidebarTabDropPlacement) -> String {
    placement == .left ? "Split left" : "Split right"
}

/// A split half's label for this preview, where it isn't the side a window splits to: a tab that
/// joins a dragged pinned tab tiles into the pin. Short enough for half a tab at the sidebar's
/// default width.
func workspaceSidebarTabDropLabelText(for preview: WorkspaceSidebarDropPreviewViewModel?) -> String? {
    preview?.receivingPinnedTabName == nil ? nil : workspaceSidebarPinTilingLabel
}

let workspaceSidebarPinTilingLabel = "Tile into Pin"

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

/// The pinned tiles' drop targets, laid out as `WorkspaceSidebarPinnedGrid` places them. Each
/// tile is a tab: a tab moving across it goes before or after it among the pins, by the half
/// under the pointer, and a pause over it arms a split, as in the list. The tiles reach halfway
/// across the space between them, and past the last one, the rest of its row puts a tab last.
func workspaceSidebarPinnedDropTargets(names: [String], projectId: WorkspaceProjectId, monitorScopeId: String,
                                       frame: CGRect, columns: Int,
                                       section: WorkspaceSidebarPinSection = .project) -> [WorkspaceSidebarDropTargetFrame] {
    var targets: [WorkspaceSidebarDropTargetFrame] = []
    let columns = max(columns, 1)
    let slop = workspaceSidebarPinnedGridSpacing / 2
    let width = max((frame.width - CGFloat(columns - 1) * workspaceSidebarPinnedGridSpacing) / CGFloat(columns), 0)
    let destination = WorkspaceSidebarTabReorderDestination(projectId: projectId, monitorScopeId: monitorScopeId,
        collectionId: nil, arrangesPins: true, pinSection: section)
    for (index, name) in names.enumerated() {
        let tile = CGRect(x: frame.minX + CGFloat(index % columns) * (width + workspaceSidebarPinnedGridSpacing),
            y: frame.minY + CGFloat(index / columns) * (workspaceSidebarPinnedGridRowHeight + workspaceSidebarPinnedGridSpacing),
            width: width, height: workspaceSidebarPinnedGridRowHeight).insetBy(dx: -slop, dy: -slop)
        targets.append(WorkspaceSidebarDropTargetFrame(kind: .workspace(name), frame: tile, acceptsSides: true,
            tabReorderDestination: destination))
        if index == names.count - 1, index % columns < columns - 1 {
            targets.append(WorkspaceSidebarDropTargetFrame(kind: .pinnedTabs(projectId: projectId,
                gap: WorkspaceSidebarTabGap(workspaceName: name, isAfter: true), monitorScopeId: monitorScopeId, section: section),
                frame: CGRect(x: tile.maxX, y: tile.minY, width: frame.maxX + slop - tile.maxX, height: tile.height)))
        }
    }
    return targets
}

/// Whether a drop preview is for the list of the display `scopeId` names. Two displays can list
/// the same project's New Tab, pins and groups; only the list the tab goes to shows the drop.
func workspaceSidebarDropPreview(_ preview: WorkspaceSidebarDropPreviewViewModel?, targetsList scopeId: String) -> Bool {
    guard let target = preview?.targetMonitorScopeId else { return true }
    return target == scopeId
}

struct WorkspaceSidebarTabReorderDestination: Equatable {
    let projectId: WorkspaceProjectId
    let monitorScopeId: String
    let collectionId: String?
    /// A pinned tile, which a moving tab passes by its sides instead of its edges.
    var arrangesPins = false
    /// The pinned tile's section.
    var pinSection: WorkspaceSidebarPinSection = .project

    /// Where a tab moving across `name`'s tab goes before a pause arms a split: by the row's
    /// nearer edge, or among the pins by the tile's nearer side.
    func reorderTarget(beside name: String, rect: Rect, point: CGPoint) -> WorkspaceSidebarDropTargetKind {
        arrangesPins
            ? .pinnedTabs(projectId: projectId, gap: .init(workspaceName: name, isAfter: point.x >= rect.center.x),
                monitorScopeId: monitorScopeId, section: pinSection)
            : .tabGap(projectId: projectId, monitorScopeId: monitorScopeId,
                gap: .init(workspaceName: name, isAfter: point.y >= rect.center.y, collectionId: collectionId))
    }
}

struct WorkspaceSidebarDropTarget {
    let kind: WorkspaceSidebarDropTargetKind
    let rect: Rect
    /// A Tabs-mode tab, drawn as one: a dropped tab joins it on the half it was dropped on.
    var acceptsSides = false
    var tabReorderDestination: WorkspaceSidebarTabReorderDestination? = nil
    /// The surface it was found on. A target rebuilt from another keeps it.
    var surface: WorkspaceSidebarSurfaceRef? = nil
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

/// The target under a normalized point, on whichever surface is topmost there.
@MainActor
func workspaceSidebarDropTarget(at mouseLocation: CGPoint, hitSlop: NSEdgeInsets = NSEdgeInsets(),
                                includesTabGaps: Bool = true) -> WorkspaceSidebarDropTarget? {
    workspaceSidebarSurfaceHit(at: mouseLocation, hitSlop: hitSlop, includesTabGaps: includesTabGaps).target
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
    func hit(_ slop: NSEdgeInsets) -> WorkspaceSidebarDropTargetFrame? {
        for target in targets.reversed() {
            if !includesTabGaps, target.kind.isGap { continue }
            let clipped = target.frame.intersection(surface)
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            let hitRect = CGRect(x: clipped.minX - slop.left, y: clipped.minY - slop.top,
                width: clipped.width + slop.left + slop.right, height: clipped.height + slop.top + slop.bottom)
            if hitRect.contains(point) {
                return .init(kind: target.kind, frame: clipped, acceptsSides: target.acceptsSides,
                    tabReorderDestination: target.tabReorderDestination)
            }
        }
        return nil
    }
    // The target under the pointer wins over a neighbor that only the slop reaches.
    return hit(NSEdgeInsets()) ?? hit(hitSlop)
}

extension WorkspaceSidebarDropTargetKind {
    /// A place between tabs or pins rather than a tab, which a window from the screen doesn't take.
    var isGap: Bool {
        switch self {
            case .tabGap: true
            case .pinnedTabs(_, let gap, _, _): gap != nil
            default: false
        }
    }
}
