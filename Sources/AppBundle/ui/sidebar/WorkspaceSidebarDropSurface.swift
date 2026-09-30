import AppKit

/// What a drag's pointer is over: a display's sidebar panel, or temporary drop UI shown only for
/// the drag. A temporary surface lists another display, but it isn't that display's panel.
enum WorkspaceSidebarSurfaceRef: Hashable {
    case panel(monitorScopeId: String)
    /// The other displays' hints and the list they open, fresh each time a list opens or switches.
    case dropDestination(generation: UInt64)

    /// The drop preview's owner while the pointer is over this surface.
    var ownerId: String {
        switch self {
            case .panel(let monitorScopeId): monitorScopeId
            case .dropDestination(let generation): "\(workspaceSidebarDropDestinationOwnerPrefix)\(generation)"
        }
    }

    var isTemporary: Bool {
        if case .dropDestination = self { true } else { false }
    }
}

let workspaceSidebarDropDestinationOwnerPrefix = "drop-destination:"

/// Whether a preview owner is temporary drop UI rather than a display's panel.
func workspaceSidebarDropPreviewOwnerIsTemporary(_ ownerId: String?) -> Bool {
    ownerId?.hasPrefix(workspaceSidebarDropDestinationOwnerPrefix) == true
}

/// Where a pointer is for a drop. The first surface containing it decides, in stacking order: a
/// drop on temporary UI never reaches the panel underneath, whether or not it finds a target.
enum WorkspaceSidebarSurfaceHit {
    case outside
    case inside(WorkspaceSidebarSurfaceRef)
    case target(WorkspaceSidebarDropTarget, WorkspaceSidebarSurfaceRef)

    var surface: WorkspaceSidebarSurfaceRef? {
        switch self {
            case .outside: nil
            case .inside(let surface), .target(_, let surface): surface
        }
    }

    var target: WorkspaceSidebarDropTarget? {
        if case .target(let target, _) = self { target } else { nil }
    }

    var isOutside: Bool { surface == nil }
    var isOnTemporarySurface: Bool { surface?.isTemporary == true }
}

/// Drop UI shown only during a drag, above the sidebars. Points and rects are normalized, as the
/// drag's pointer is.
@MainActor
protocol WorkspaceSidebarTemporaryDropSurface: AnyObject {
    var surfaceRef: WorkspaceSidebarSurfaceRef { get }
    /// Higher is above: the hints are above the list they open.
    var stackingOrder: Int { get }
    /// The display the surface lists, for a list; nil for the hints, which take no drops.
    var dropDestination: WorkspaceSidebarDropDestinationIdentity? { get }
    /// The part of the surface containing `point`, if any.
    func surfaceRectNormalized(containing point: CGPoint) -> Rect?
    func dropTarget(atNormalizedPoint point: CGPoint, hitSlop: NSEdgeInsets, includesTabGaps: Bool) -> WorkspaceSidebarDropTarget?
}

@MainActor
final class WorkspaceSidebarTemporaryDropSurfaces {
    static let shared = WorkspaceSidebarTemporaryDropSurfaces()

    private struct Entry {
        weak var surface: (any WorkspaceSidebarTemporaryDropSurface)?
    }

    private var entries: [Entry] = []

    init() {}

    /// The live surfaces, topmost first.
    var surfaces: [any WorkspaceSidebarTemporaryDropSurface] {
        entries.compactMap(\.surface).sorted { $0.stackingOrder > $1.stackingOrder }
    }

    var isEmpty: Bool { entries.allSatisfy { $0.surface == nil } }

    func register(_ surface: any WorkspaceSidebarTemporaryDropSurface) {
        entries.removeAll { $0.surface == nil || $0.surface === surface }
        entries.append(Entry(surface: surface))
    }

    func unregister(_ surface: any WorkspaceSidebarTemporaryDropSurface) {
        entries.removeAll { $0.surface == nil || $0.surface === surface }
    }

    func removeAll() { entries = [] }
}

extension WorkspaceSidebarPanel {
    var surfaceRef: WorkspaceSidebarSurfaceRef { .panel(monitorScopeId: monitorScopeId) }
}

/// Bumped whenever a sidebar surface reports new drop targets or a new shape, so a drag whose
/// pointer is still can tell that what's under it may have changed.
@MainActor
enum WorkspaceSidebarDropTargetsRevision {
    private(set) static var current: UInt64 = 0

    static func bump() { current &+= 1 }
}

/// The surface under a normalized point, with the part of it that contains the point.
@MainActor
func workspaceSidebarSurface(at point: CGPoint) -> (surface: WorkspaceSidebarSurfaceRef, rect: Rect)? {
    for surface in WorkspaceSidebarTemporaryDropSurfaces.shared.surfaces {
        if let rect = surface.surfaceRectNormalized(containing: point) { return (surface.surfaceRef, rect) }
    }
    for panel in WorkspaceSidebarPanel.visiblePanels {
        if let rect = panel.visibleScreenRectNormalized(containing: point) { return (panel.surfaceRef, rect) }
    }
    return nil
}

/// `includesTabGaps` is false for a window dragged in from the screen: it joins a tab or gets
/// a new one, and the gaps' thin bands would otherwise swallow the tabs under its hit slop.
@MainActor
func workspaceSidebarSurfaceHit(at point: CGPoint, hitSlop: NSEdgeInsets = NSEdgeInsets(),
                                includesTabGaps: Bool = true) -> WorkspaceSidebarSurfaceHit {
    for surface in WorkspaceSidebarTemporaryDropSurfaces.shared.surfaces
        where surface.surfaceRectNormalized(containing: point) != nil
    {
        let ref = surface.surfaceRef
        guard var target = surface.dropTarget(atNormalizedPoint: point, hitSlop: hitSlop, includesTabGaps: includesTabGaps)
        else { return .inside(ref) }
        target.surface = ref
        return .target(target, ref)
    }
    guard let panel = WorkspaceSidebarPanel.visiblePanels.first(where: { $0.visibleScreenRectNormalized(containing: point) != nil })
    else { return .outside }
    let screenPoint = CGPoint(x: point.x, y: mainMonitor.height - point.y)
    guard var target = panel.dropTarget(atScreenPoint: screenPoint, hitSlop: hitSlop, includesTabGaps: includesTabGaps)
    else { return .inside(panel.surfaceRef) }
    target.surface = panel.surfaceRef
    return .target(target, panel.surfaceRef)
}
