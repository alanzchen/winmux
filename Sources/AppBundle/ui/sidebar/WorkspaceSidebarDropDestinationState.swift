import AppKit

/// How long the pointer rests on a display's hint before its list opens, or another opens in its place.
let workspaceSidebarDropDestinationDwell: TimeInterval = 0.22
/// How long the pointer may be away from the hints and the open list before the list closes.
let workspaceSidebarDropDestinationCloseDelay: TimeInterval = 0.30
/// How far past the hints and the open list the pointer may stray and still keep the list open.
let workspaceSidebarDropDestinationKeepOpenInset: CGFloat = 12
/// How far outside a rail the pointer may drift while it pauses there: none. Rails stand 2 pt apart,
/// so any more would let one rail claim the edge of the next.
let workspaceSidebarDropDestinationHintTolerance: CGFloat = 0
/// A pause also needs the pointer at rest: within this distance for this long, as a split's does,
/// so a steady pass over a hint never opens it however long it takes.
let workspaceSidebarDropDestinationRestDistance: CGFloat = workspaceSidebarSplitRestDistance
let workspaceSidebarDropDestinationRestDuration: TimeInterval = workspaceSidebarSplitRestDuration

/// A wake scheduled for a deadline must count as reaching it despite rounding.
private let workspaceSidebarDropDestinationTimeSlack: TimeInterval = 0.000_5

/// A rail the pointer is pausing on.
struct WorkspaceSidebarDropDestinationArming: Equatable {
    let id: String
    let since: TimeInterval
    /// Where the pointer came to rest, and since when.
    var restPoint: CGPoint
    var restingSince: TimeInterval
    /// Where the pointer was at the last sample: movement from there towards an open list is
    /// passing on, however little.
    var lastPoint: CGPoint

    init(id: String, since: TimeInterval, at point: CGPoint = .zero) {
        self.id = id
        self.since = since
        restPoint = point
        restingSince = since
        lastPoint = point
    }

    /// When the pause is over if the pointer stays where it is.
    var opensAt: TimeInterval {
        max(since + workspaceSidebarDropDestinationDwell, restingSince + workspaceSidebarDropDestinationRestDuration)
    }
}

/// What one drag's hints and other-display list are doing. Plain data: a pointer that stays where
/// it is gives back an equal state, so nothing is published.
struct WorkspaceSidebarDropDestinationState: Equatable {
    /// The hint the pointer is pausing on, to open or switch to its list.
    var arming: WorkspaceSidebarDropDestinationArming?
    /// The display whose list is open, by scope.
    var openId: String?
    /// When the pointer left the open list's keep-open region.
    var outsideSince: TimeInterval?

    /// When the state changes if the pointer stays put: a pause completing, or the list closing.
    var nextWake: TimeInterval? {
        [arming.map(\.opensAt),
         outsideSince.map { $0 + workspaceSidebarDropDestinationCloseDelay }].compactMap(\.self).min()
    }
}

/// One pointer sample, or a wake with the pointer where it is now. `hints` are the rails' frames by
/// display scope; `keepOpen` is the region that keeps an open list open: the rails and the list.
/// `listSide` is which way the open list lies from the rails: +1 to the right, -1 to the left.
func workspaceSidebarDropDestinationStep(
    _ state: WorkspaceSidebarDropDestinationState,
    pointer: CGPoint,
    now: TimeInterval,
    hints: [(id: String, frame: CGRect)],
    keepOpen: CGRect?,
    listSide: CGFloat? = nil,
) -> WorkspaceSidebarDropDestinationState {
    var next = state
    let tolerance = workspaceSidebarDropDestinationHintTolerance
    let hovered = hints.first { $0.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(pointer) }
    // Crossing a rail on the way from the open one into its list: any movement on towards the
    // list since the last sample is passing it, not pausing on it, however slow or small. Holding
    // still, or moving back, is a pause as anywhere else.
    let isInTransit = hovered.map { hovered in
        guard let side = listSide, let open = hints.first(where: { $0.id == state.openId }) else { return false }
        return (hovered.frame.midX - open.frame.midX) * side > 0
    } ?? false
    if let hovered = hovered?.id, hovered != next.openId {
        if next.arming?.id != hovered {
            next.arming = .init(id: hovered, since: now, at: pointer)
        } else if isInTransit, let arming = next.arming, (pointer.x - arming.lastPoint.x) * (listSide ?? 0) > 0 {
            next.arming = .init(id: hovered, since: now, at: pointer)
        } else if let arming = next.arming,
                  hypot(pointer.x - arming.restPoint.x, pointer.y - arming.restPoint.y) > workspaceSidebarDropDestinationRestDistance {
            next.arming?.restPoint = pointer
            next.arming?.restingSince = now
        }
        next.arming?.lastPoint = pointer
        if let arming = next.arming, now + workspaceSidebarDropDestinationTimeSlack >= arming.opensAt {
            // The pause is over: this display's list opens, in place of any other.
            next.openId = hovered
            next.arming = nil
            next.outsideSince = nil
        }
    } else {
        next.arming = nil
    }
    guard next.openId != nil else {
        next.outsideSince = nil
        return next
    }
    let inset = workspaceSidebarDropDestinationKeepOpenInset
    if keepOpen?.insetBy(dx: -inset, dy: -inset).contains(pointer) == true || hovered != nil {
        next.outsideSince = nil
    } else {
        let since = next.outsideSince ?? now
        if now - since + workspaceSidebarDropDestinationTimeSlack >= workspaceSidebarDropDestinationCloseDelay {
            next.openId = nil
            next.outsideSince = nil
        } else {
            next.outsideSince = since
        }
    }
    return next
}
