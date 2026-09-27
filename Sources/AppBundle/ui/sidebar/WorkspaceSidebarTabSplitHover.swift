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

    mutating func update(target: String, side _: WorkspaceSidebarTabDropPlacement, point: CGPoint, now: TimeInterval) -> Bool {
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
                            target: WorkspaceSidebarDropTarget, placement: WorkspaceSidebarTabDropPlacement?)?

    func reset() {
        wake?.cancel()
        wake = nil
        state = .init()
        displayed = nil
    }

    func noteDisplayed(source: UInt32, hitKind: WorkspaceSidebarDropTargetKind, target: WorkspaceSidebarDropTarget,
                       placement: WorkspaceSidebarTabDropPlacement?) {
        displayed = (source, hitKind, target, placement)
    }

    func clearDisplayed() { displayed = nil }

    func commitTarget(source: UInt32, hitTarget: WorkspaceSidebarDropTarget, point: CGPoint) -> WorkspaceSidebarDropTarget? {
        guard let displayed, displayed.source == source, displayed.hitKind == hitTarget.kind,
              displayed.target.rect == hitTarget.rect else { return nil }
        if let placement = displayed.placement, placement != .stack {
            let side: WorkspaceSidebarTabDropPlacement = point.x < hitTarget.rect.center.x ? .left : .right
            guard side == placement else { return nil }
        }
        return displayed.target
    }

    func isReady(target: String, side: WorkspaceSidebarTabDropPlacement, point: CGPoint) -> Bool {
        let previous = state.armsAt
        let now = ProcessInfo.processInfo.systemUptime
        let ready = state.update(target: target, side: side, point: point, now: now)
        // A pointer at rest sends no events, so check again when the pause would arm.
        if let armsAt = state.armsAt, armsAt != previous {
            wake?.cancel()
            wake = Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(0, armsAt - now) + 0.01))
                guard !Task.isCancelled else { return }
                refreshActiveWorkspaceSidebarDragPreviewIfNeeded()
            }
        }
        return ready
    }
}

@MainActor
func workspaceSidebarDeliberateTabDropTarget(_ target: WorkspaceSidebarDropTarget, sourceWindow: Window,
                                            point: CGPoint) -> WorkspaceSidebarDropTarget? {
    let hover = WorkspaceSidebarTabSplitHoverController.shared
    guard config.usesBrowserTabs, target.acceptsSides, case .workspace(let name) = target.kind,
          let workspace = Workspace.existing(byName: name) else {
        hover.reset()
        return target
    }
    let side: WorkspaceSidebarTabDropPlacement = point.x < target.rect.center.x ? .left : .right
    if hover.isReady(target: name, side: side, point: point) {
        var armed = target
        armed.acceptsSides = !sourceWindow.isFloating && workspaceTabDropTargetWindow(workspace)?.isFloating == false
        return armed
    }
    guard let destination = target.tabReorderDestination else { return nil }
    return .init(kind: .tabGap(projectId: destination.projectId, monitorScopeId: destination.monitorScopeId,
        gap: .init(workspaceName: name, isAfter: point.y >= target.rect.center.y,
            collectionId: destination.collectionId)), rect: target.rect)
}
