import AppKit

let workspaceSidebarSplitHoverDelay: TimeInterval = 0.25
/// How far the pointer may drift while pausing over a tab and still arm its split.
let workspaceSidebarSplitHoverTolerance: CGFloat = 12
/// A pause ends with the pointer at rest: within this distance for `workspaceSidebarSplitRestDuration`.
/// A steady drag faster than about 15 pt/s never rests, so it keeps reordering however little it
/// has moved overall; that's as slow as the original 6 pt / 0.4 s hold allowed.
let workspaceSidebarSplitRestDistance: CGFloat = 2
let workspaceSidebarSplitRestDuration: TimeInterval = 0.13

/// A moving pointer reorders. A brief pause over a tab arms its split; once armed, the split
/// stays armed anywhere over that tab, and the highlighted half follows the pointer.
struct WorkspaceSidebarTabSplitHover {
    private var target: String?
    private var anchor: CGPoint = .zero
    private var restPoint: CGPoint = .zero
    private var restingSince: TimeInterval = 0
    private var isArmed = false
    private(set) var startedAt: TimeInterval?

    /// When the split arms if the pointer stays where it is; nil once armed.
    var armsAt: TimeInterval? {
        guard !isArmed, let startedAt else { return nil }
        return max(startedAt + workspaceSidebarSplitHoverDelay, restingSince + workspaceSidebarSplitRestDuration)
    }

    /// `restPoint` is where the pointer really is now. Drag events can be sparse, so a check made
    /// between them must not mistake the last reported point for a pointer at rest.
    mutating func update(target: String, side _: WorkspaceSidebarTabDropPlacement, point: CGPoint, now: TimeInterval,
                         restPoint livePoint: CGPoint? = nil) -> Bool {
        let point = livePoint ?? point
        if self.target != target {
            self.target = target
            isArmed = false
            anchor = point
            startedAt = now
            restPoint = point
            restingSince = now
        } else if !isArmed {
            if hypot(point.x - anchor.x, point.y - anchor.y) > workspaceSidebarSplitHoverTolerance {
                anchor = point
                startedAt = now
            }
            if hypot(point.x - restPoint.x, point.y - restPoint.y) > workspaceSidebarSplitRestDistance {
                restPoint = point
                restingSince = now
            }
        }
        if let armsAt, now >= armsAt { isArmed = true }
        return isArmed
    }
}

@MainActor
final class WorkspaceSidebarTabSplitHoverController {
    static let shared = WorkspaceSidebarTabSplitHoverController()
    private var state = WorkspaceSidebarTabSplitHover()
    private var wake: Task<Void, Never>?
    private var displayed: (source: UInt32, hitKind: WorkspaceSidebarDropTargetKind,
                            target: WorkspaceSidebarDropTarget, placement: WorkspaceSidebarTabDropPlacement?,
                            pinGridIsShared: Bool)?

    func reset() {
        wake?.cancel()
        wake = nil
        state = .init()
        displayed = nil
    }

    /// `pinGridIsShared` is the pin rule the preview was made with, which its drop keeps.
    func noteDisplayed(source: UInt32, hitKind: WorkspaceSidebarDropTargetKind, target: WorkspaceSidebarDropTarget,
                       placement: WorkspaceSidebarTabDropPlacement?, pinGridIsShared: Bool = false) {
        displayed = (source, hitKind, target, placement, pinGridIsShared)
    }

    /// The pin rule the preview now shown for `source` was made with.
    func displayedPinGridIsShared(source: UInt32) -> Bool? {
        displayed.flatMap { $0.source == source ? $0.pinGridIsShared : nil }
    }

    func clearDisplayed() { displayed = nil }

    func commitTarget(source: UInt32, hitTarget: WorkspaceSidebarDropTarget, point: CGPoint) -> WorkspaceSidebarDropTarget? {
        guard let displayed, displayed.source == source, displayed.hitKind == hitTarget.kind,
              displayed.target.rect == hitTarget.rect, displayed.target.surface == hitTarget.surface else {
            // Audit F3: a release refused because the last preview shown isn't for this target.
            debugWorkspaceSidebarCrossDisplayDragLog("commitRefused hit=\(hitTarget.kind) hitRect=\(hitTarget.rect)"
                + " displayed=\(String(describing: displayed?.hitKind)) displayedRect=\(String(describing: displayed?.target.rect))"
                + " " + workspaceSidebarCrossDisplayDragDescription(event: "release", point: point))
            return nil
        }
        if let placement = displayed.placement, placement != .stack {
            let side: WorkspaceSidebarTabDropPlacement = point.x < hitTarget.rect.center.x ? .left : .right
            guard side == placement else { return nil }
        }
        // A split shown over a pinned tile's middle, or a window shown going into an empty pin, isn't
        // made by a release nearer the tile's side: that's not where the drop was shown.
        if case .workspace = displayed.target.kind,
           hitTarget.tabReorderDestination?.pauseArmsSplit(at: point, rect: hitTarget.rect) == false { return nil }
        return displayed.target
    }

    func isReady(target: String, side: WorkspaceSidebarTabDropPlacement, point: CGPoint, livePoint: CGPoint? = nil) -> Bool {
        let previous = state.armsAt
        let now = ProcessInfo.processInfo.systemUptime
        let ready = state.update(target: target, side: side, point: point, now: now, restPoint: livePoint)
        // A pointer at rest sends no events, so check again when the pause would arm.
        if let armsAt = state.armsAt, armsAt != previous {
            wake?.cancel()
            wake = Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(0, armsAt - now) + 0.01))
                guard !Task.isCancelled else { return }
                refreshActiveWorkspaceSidebarDragPreviewIfNeeded()
                refreshActiveSidebarPinnedTabDragPreview()
            }
        }
        return ready
    }
}

@MainActor
func workspaceSidebarDeliberateTabDropTarget(_ target: WorkspaceSidebarDropTarget, sourceWindow: Window,
                                            point: CGPoint, livePoint: CGPoint? = nil) -> WorkspaceSidebarDropTarget? {
    let hover = WorkspaceSidebarTabSplitHoverController.shared
    guard config.usesBrowserTabs, target.acceptsSides, case .workspace(let name) = target.kind,
          let workspace = Workspace.existing(byName: name) else {
        hover.reset()
        return target
    }
    let side: WorkspaceSidebarTabDropPlacement = point.x < target.rect.center.x ? .left : .right
    // Near a pinned tile's sides, a tab always goes beside it: the pause starts over in its middle.
    // A pin lending its window, or a pinned split, takes no split at all: a tab only goes beside it.
    if target.tabReorderDestination?.pauseArmsSplit(at: point, rect: target.rect) == false
        || !workspaceSidebarTakesSplit(workspace) {
        hover.reset()
    } else if hover.isReady(target: name, side: side, point: point, livePoint: livePoint) {
        var armed = target
        armed.acceptsSides = !sourceWindow.isFloating && workspaceTabDropTargetWindow(workspace)?.isFloating == false
        return armed
    }
    guard let destination = target.tabReorderDestination else { return nil }
    return .init(kind: destination.reorderTarget(beside: name, rect: target.rect, point: point), rect: target.rect,
        surface: target.surface)
}
