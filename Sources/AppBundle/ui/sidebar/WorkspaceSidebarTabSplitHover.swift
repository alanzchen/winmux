import AppKit

let workspaceSidebarSplitHoverDelay: TimeInterval = 0.4

/// A moving pointer reorders. A brief, stationary hold over a row deliberately arms
/// its split target. Moving to the other half starts a fresh hold.
struct WorkspaceSidebarTabSplitHover {
    private var target: String?
    private var side: WorkspaceSidebarTabDropPlacement?
    private var anchor: CGPoint = .zero
    private(set) var startedAt: TimeInterval?

    mutating func update(target: String, side: WorkspaceSidebarTabDropPlacement, point: CGPoint, now: TimeInterval) -> Bool {
        if self.target != target || self.side != side || hypot(point.x - anchor.x, point.y - anchor.y) > 6 {
            self.target = target
            self.side = side
            anchor = point
            startedAt = now
        }
        return now - (startedAt ?? now) >= workspaceSidebarSplitHoverDelay
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
        let previous = state.startedAt
        let ready = state.update(target: target, side: side, point: point, now: ProcessInfo.processInfo.systemUptime)
        if previous != state.startedAt {
            wake?.cancel()
            wake = Task { @MainActor in
                try? await Task.sleep(for: .seconds(workspaceSidebarSplitHoverDelay + 0.01))
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
        armed.acceptsSides = !sourceWindow.isFloating && workspace.mostRecentWindowRecursive?.isFloating == false
        return armed
    }
    guard let destination = target.tabReorderDestination else { return nil }
    return .init(kind: .tabGap(projectId: destination.projectId, monitorScopeId: destination.monitorScopeId,
        gap: .init(workspaceName: name, isAfter: point.y >= target.rect.center.y,
            collectionId: destination.collectionId)), rect: target.rect)
}
