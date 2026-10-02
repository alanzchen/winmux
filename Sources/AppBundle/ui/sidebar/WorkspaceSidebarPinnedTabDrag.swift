import AppKit
import Common

/// Tabs mode: a pinned tile drags as its whole tab, split or empty alike. It uses the sidebar's
/// drop targets and feedback, but no window drag, since a pin needn't have a window. Each drop
/// names the display whose list it lands on; a pin from another display moves there.
enum WorkspaceSidebarPinnedTabDrop: Equatable {
    /// Beside another pin, or, with no gap, onto another display's pins, which may have none yet.
    case rearrange(WorkspaceSidebarTabGap?, monitorScopeId: String? = nil)
    /// Between the list's tabs, unpinned.
    case list(projectId: WorkspaceProjectId, monitorScopeId: String, gap: WorkspaceSidebarTabGap)
    /// Into a group, which unpins it.
    case group(String, monitorScopeId: String? = nil)
    /// On New Tab: unpinned there.
    case unpin(monitorScopeId: String? = nil)
    /// Paused over a tab in a display's list: that whole tab joins this pin's split. The pin stays
    /// pinned, and goes on `placement`'s half of the tab, as a window dropped there would.
    case join(String, placement: WorkspaceSidebarTabDropPlacement, monitorScopeId: String? = nil)

    var monitorScopeId: String? {
        switch self {
            case .rearrange(_, let scope), .group(_, let scope), .unpin(let scope), .join(_, _, let scope): scope
            case .list(_, let scope, _): scope
        }
    }

    /// A drop on the pin tiles, as opposed to the list, a group or New Tab.
    var isPinTiles: Bool {
        if case .rearrange = self { true } else { false }
    }
}

/// What dropping the pinned tab on this target does, or nil where it does nothing.
/// `pinGridIsShared` is the pin rule the drop is shown, and made, with.
@MainActor
func workspaceSidebarPinnedTabDrop(_ tab: Workspace, target: WorkspaceSidebarDropTarget, point: CGPoint,
                                   pinGridIsShared: Bool = workspaceSidebarPinGridIsShared()) -> WorkspaceSidebarPinnedTabDrop? {
    guard config.usesBrowserTabs, workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite == true
    else { return nil }
    // A pause counts only over a tab: leaving it, for anything else, starts the next one over.
    if case .workspace = target.kind {} else { WorkspaceSidebarTabSplitHoverController.shared.reset() }
    switch target.kind {
        case .pinnedTabs(let projectId, let gap, let monitorScopeId):
            // On this display it goes beside another pin; onto another display's pins it moves
            // there, even where that display has no pins yet. Shared pins only rearrange: the
            // tab stays where it is, so a drop that wouldn't change their order does nothing.
            guard projectId == tab.projectId,
                  workspaceSidebarPinDropCanReachDisplay(tab, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared),
                  gap.flatMap({ workspacePinnedTabOrder(moving: tab, beside: $0) }) != nil
                    || workspaceSidebarPinDropDisplayChange(for: tab, monitorScopeId: monitorScopeId,
                        pinGridIsShared: pinGridIsShared) != nil
            else { return nil }
            return .rearrange(gap, monitorScopeId: monitorScopeId)
        case .tabGap(let projectId, let monitorScopeId, let gap):
            guard Workspace.existing(byName: gap.workspaceName)?.projectId == projectId,
                  workspaceSidebarDropCanReachDisplay(tab, monitorScopeId: monitorScopeId) else { return nil }
            return .list(projectId: projectId, monitorScopeId: monitorScopeId, gap: gap)
        case .workspace(let name):
            guard let destination = target.tabReorderDestination, let other = Workspace.existing(byName: name) else {
                WorkspaceSidebarTabSplitHoverController.shared.reset()
                return nil
            }
            // Over another pin, it goes by the nearer side, as a moving tab does before a split arms:
            // pins rearrange, they don't split.
            guard !destination.arrangesPins else {
                WorkspaceSidebarTabSplitHoverController.shared.reset()
                return workspaceSidebarPinnedTabDrop(tab, target: .init(kind: destination.reorderTarget(beside: name,
                    rect: target.rect, point: point), rect: target.rect, surface: target.surface), point: point,
                    pinGridIsShared: pinGridIsShared)
            }
            // Over a tab in the list, it never leaves the pins: only the gaps between tabs, and New
            // Tab, unpin it. After a pause, that tab joins it instead; before, nothing happens.
            return workspaceSidebarPinnedTabJoin(tab, onto: other, target: target, monitorScopeId: destination.monitorScopeId,
                point: point)
        case .tabCollection(let id, let monitorScopeId):
            guard workspaceSidebarOrganizationStore.state.collections.contains(where: { $0.id == id && $0.projectId == tab.projectId }),
                  workspaceSidebarDropCanReachDisplay(tab, monitorScopeId: monitorScopeId)
            else { return nil }
            return .group(id, monitorScopeId: monitorScopeId)
        case .newWorkspace(let projectId, let monitorScopeId):
            guard projectId == tab.projectId, workspaceSidebarDropCanReachDisplay(tab, monitorScopeId: monitorScopeId)
            else { return nil }
            return .unpin(monitorScopeId: monitorScopeId)
        case .monitor:
            return nil
    }
}

/// A pinned tab paused over `other`'s tab in a list: `other` joins it, on the half the pointer is
/// on. Nil before the pause, and for a tab that can't: a pin, an empty one, another project's, or
/// one on a display the pin may not come to. The pin comes to that display, so the tab never
/// leaves it.
@MainActor
private func workspaceSidebarPinnedTabJoin(_ tab: Workspace, onto other: Workspace, target: WorkspaceSidebarDropTarget,
                                           monitorScopeId: String, point: CGPoint) -> WorkspaceSidebarPinnedTabDrop? {
    let hover = WorkspaceSidebarTabSplitHoverController.shared
    guard target.acceptsSides, other !== tab, other.projectId == tab.projectId,
          workspaceSidebarOrganizationStore.state.workspaces[other.name]?.isFavorite != true,
          workspaceSidebarWholeTabNode(other) != nil, workspaceTabCanMove(tab, to: other.workspaceMonitor)
    else {
        hover.reset()
        return nil
    }
    let side: WorkspaceSidebarTabDropPlacement = point.x < target.rect.center.x ? .left : .right
    guard hover.isReady(target: other.name, side: side, point: point) else { return nil }
    return .join(other.name, placement: side, monitorScopeId: monitorScopeId)
}

/// How a joining tab's tiled `node` goes into `row`, which lays out `length` long: whole, or, split
/// the same way as the row, as its windows, which keep their sizes within the share one piece takes.
/// Weights are lengths, and layout adds the same amount to every child to fill the row. So the row's
/// children are first made to fill it in proportion, as if laid out where the row now is: a wrapper
/// starts its one child at 1, and a pin brought from another display keeps that display's lengths.
/// Then the pieces end with the 1/(n + 1) of the row one WEIGHT_AUTO node would, and each of the n
/// children gives up what it would to that node.
@MainActor
private func makeRoomForWorkspaceSidebarJoin(_ node: TreeNode, in row: TilingContainer, length: CGFloat) -> [(TreeNode, CGFloat)] {
    let orientation = row.orientation
    let split = (node as? TilingContainer).flatMap { $0.orientation == orientation ? Array($0.children) : nil }
    let pieces = split ?? [node]
    let weights = split == nil ? [1] : pieces.map { $0.getWeight(orientation) }
    let total = weights.reduce(0, +)
    guard total > 0, length > 0 else { return pieces.map { ($0, WEIGHT_AUTO) } }
    let children = Array(row.children)
    let sum = CGFloat(children.sumOfDouble { $0.getWeight(orientation) })
    guard !children.isEmpty, sum > 0 else { return zip(pieces, weights).map { ($0, length * $1 / total) } }
    for child in children {
        child.setWeight(orientation, child.getWeight(orientation) * length / sum)
    }
    let count = CGFloat(children.count)
    let share = length / (count + 1)
    return zip(pieces, weights).map { ($0, share * $1 / total + share / count) }
}

/// What of `tab` tiles as one piece beside another tab's windows: its one tiled node, or its whole
/// tiled layout, so a split stays the split it is. Nil without tiled windows.
@MainActor
func workspaceSidebarWholeTabNode(_ tab: Workspace) -> TreeNode? {
    let root = tab.rootTilingContainer
    guard !root.allLeafWindowsRecursive.isEmpty else { return nil }
    return root.children.count == 1 ? root.children[0] : root
}

@MainActor
private func workspaceSidebarPinnedTabDropUnderPointer(_ tab: Workspace, batch: WorkspaceSidebarDragBatch?, point: CGPoint,
                                                       pinGridIsShared: Bool = workspaceSidebarPinGridIsShared())
    -> (drop: WorkspaceSidebarPinnedTabDrop?, hit: WorkspaceSidebarSurfaceHit)
{
    let hit = workspaceSidebarSurfaceHit(at: point)
    if hit.target == nil { WorkspaceSidebarTabSplitHoverController.shared.reset() }
    // Chosen pins dragged together go only where all of them can.
    if let batch {
        return (hit.target.flatMap { workspaceSidebarPinnedBatchDrop(batch, target: $0, point: point, pinGridIsShared: pinGridIsShared) },
            hit)
    }
    return (hit.target.flatMap { workspaceSidebarPinnedTabDrop(tab, target: $0, point: point, pinGridIsShared: pinGridIsShared) },
        hit)
}

/// The dragged pin, as the pointer carries it, and with where it would go.
@MainActor
func workspaceSidebarPinnedTabDropPreview(_ tab: Workspace, batch: WorkspaceSidebarDragBatch? = nil,
                                          drop: WorkspaceSidebarPinnedTabDrop?) -> WorkspaceSidebarDropPreviewViewModel {
    let windows = tab.allLeafWindowsRecursive
    let window = tab.mostRecentWindowRecursive ?? windows.first
    let appName = window.map { $0.app.name ?? $0.app.rawAppBundleId ?? "Window" } ?? "Tab"
    var projectId = tab.projectId
    if case .list(let listProjectId, _, _) = drop { projectId = listProjectId }
    let targetsNewTab = if case .unpin = drop { true } else { false }
    let joinedTab = if case .join(let name, _, _) = drop { name } else { String?.none }
    var preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: window?.windowId ?? 0,
        label: windows.count > 1 ? "\(windows.count) windows" : window.flatMap { cachedWindowTitle(for: $0) } ?? appName,
        appName: appName, appBundleIdentifier: window?.app.rawAppBundleId, appBundlePath: window?.app.bundlePath,
        targetWorkspaceName: joinedTab, targetsNewWorkspace: targetsNewTab, targetProjectId: projectId,
        targetMonitorScopeId: drop?.monitorScopeId, isTabGroup: false, windowCount: max(windows.count, 1))
    switch drop {
        case .rearrange(let gap, _):
            preview.targetsPinned = true
            preview.targetPinnedGap = gap
        case .list(_, _, let gap): preview.targetGap = gap
        case .group(let id, _): preview.targetCollectionId = id
        case .join(_, let placement, _):
            // The tab's half where the pin goes, and the pin that takes it in.
            preview.targetPlacement = placement
            preview.receivingPinnedTabName = tab.name
        case .unpin, nil: break
    }
    return batch.map { $0.preview(preview) } ?? preview
}

/// The tab the drag began with, and the chosen tabs it carries with it. If it closes, or another tab
/// takes its name, the drag drops nothing.
@MainActor
private var activeSidebarPinnedTabDrag: (name: String, tab: Workspace, batch: WorkspaceSidebarDragBatch?)?

/// The drop the dragged pin's preview shows, with the pin rule it was worked out with. The release
/// makes this drop, under this rule, or none.
@MainActor
private var displayedSidebarPinnedTabDrop: (drop: WorkspaceSidebarPinnedTabDrop?, pinGridIsShared: Bool)?

/// Shows where the dragged pin would go with the pointer at `point`.
@MainActor
private func previewSidebarPinnedTabDrop(_ tab: Workspace, point: CGPoint) {
    let pinGridIsShared = workspaceSidebarPinGridIsShared()
    let batch = activeSidebarPinnedTabDrag?.batch
    let (drop, hit) = workspaceSidebarPinnedTabDropUnderPointer(tab, batch: batch, point: point, pinGridIsShared: pinGridIsShared)
    displayedSidebarPinnedTabDrop = (drop, pinGridIsShared)
    setWorkspaceSidebarDropPreviewIfChanged(drop.map { workspaceSidebarPinnedTabDropPreview(tab, batch: batch, drop: $0) },
        owner: hit.surface)
}

@MainActor
func updateSidebarPinnedTabDrag(_ name: String, pointer: CGPoint) {
    guard WorkspaceSidebarDragSessions.shared.acceptUpdate() else { return }
    MousePointerTracker.shared.note(point: pointer)
    if activeSidebarPinnedTabDrag?.name != name {
        guard let tab = Workspace.existing(byName: name) else { return }
        // Frozen as the drag begins: choosing tabs during it changes nothing it carries.
        activeSidebarPinnedTabDrag = (name, tab, WorkspaceSidebarDragBatch(startingWith: name))
    }
    guard let tab = activeSidebarPinnedTabDrag?.tab, Workspace.existing(byName: name) === tab else {
        clearSidebarPinnedTabDragFeedback()
        return
    }
    let batch = activeSidebarPinnedTabDrag?.batch
    WorkspaceSidebarTabDragState.shared.set(true, pinnedTab: name, batch: batch?.names ?? [])
    WindowDragCursorProxyPanel.shared.show(preview: workspaceSidebarPinnedTabDropPreview(tab, batch: batch, drop: nil),
        mouseScreenPoint: denormalizedAppKitScreenPoint(pointer), style: .appIcon(size: 22))
    previewSidebarPinnedTabDrop(tab, point: pointer)
    WorkspaceSidebarDropDestinationController.shared.noteDragUpdate()
}

/// The drop happens once, from whichever sees the release first: the gesture's end, or the
/// mouse-up cleanup when the gesture ended without saying so.
@MainActor
func finishSidebarPinnedTabDrag(_ name: String, pointer: CGPoint) {
    guard let drag = activeSidebarPinnedTabDrag, drag.name == name else { return }
    activeSidebarPinnedTabDrag = nil
    let displayed = displayedSidebarPinnedTabDrop
    MousePointerTracker.shared.note(point: pointer)
    let released = WorkspaceSidebarDragSessions.shared.consumeRelease() != nil
    let tab = Workspace.existing(byName: name) === drag.tab ? drag.tab : nil
    // Worked out again under the rule the preview was shown with, which the drop keeps.
    let pinGridIsShared = displayed?.pinGridIsShared ?? workspaceSidebarPinGridIsShared()
    let underPointer = released
        ? tab.map { workspaceSidebarPinnedTabDropUnderPointer($0, batch: drag.batch, point: pointer, pinGridIsShared: pinGridIsShared) }
        : nil
    clearSidebarPinnedTabDragFeedback()
    // Released on temporary drop UI, with or without a drop: that release was the sidebar's.
    if underPointer?.hit.isOnTemporarySurface == true { noteWorkspaceSidebarConsumedRelease() }
    // A list that closed before the release takes nothing: its drop can't be checked any more.
    var intent = underPointer?.hit.target.flatMap { WorkspaceSidebarDropIntent.captured(for: $0) }
    intent?.pinGridIsShared = pinGridIsShared
    // The release is captured: the other displays' hints and list go.
    WorkspaceSidebarDropDestinationController.shared.end()
    // The drop made is the one shown. A drop on the pins shown under one pin rule isn't made under
    // another: the setting changed since, and what it showed no longer holds.
    guard let tab, let drop = underPointer?.drop, drop == displayed?.drop, let intent,
          !drop.isPinTiles || pinGridIsShared == workspaceSidebarPinGridIsShared() else { return }
    noteWorkspaceSidebarConsumedRelease()
    if let batch = drag.batch {
        runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedBatchDropUndoTitle(batch, drop)) {
            try intent.checkDestination()
            guard intent.targetIsUnchanged else { return }
            if try applyWorkspaceSidebarPinnedBatchDrop(batch, drop, pinGridIsShared: intent.pinGridIsShared) {
                WorkspaceSidebarTabSelection.shared.clear()
            }
            await updateWorkspaceSidebarModel()
        }
        return
    }
    runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedTabDropUndoTitle(drop)) {
        try intent.checkDestination()
        // The tab it went beside may have gone, or another tab may have taken its name. A tab it
        // joins must still be one the list shows: on another display's list, still on that display.
        guard intent.targetIsUnchanged else { return }
        if case .join(let name, _, _) = drop, let joined = Workspace.existing(byName: name), !intent.accepts(joined) { return }
        try applyWorkspaceSidebarPinnedTabDrop(tab, drop, pinGridIsShared: intent.pinGridIsShared)
        await updateWorkspaceSidebarModel()
    }
}

@MainActor
func finishActiveSidebarPinnedTabDrag() {
    guard let name = activeSidebarPinnedTabDrag?.name else { return }
    noteCurrentMousePointerSample()
    finishSidebarPinnedTabDrag(name, pointer: MousePointerTracker.shared.currentSample.point)
}

@MainActor
func isSidebarPinnedTabDragActive() -> Bool { activeSidebarPinnedTabDrag != nil }

/// The dragged pin's preview where the pointer is now, between the gesture's own updates: over
/// another display's list, only this keeps it live.
@MainActor
func refreshActiveSidebarPinnedTabDragPreview() {
    guard let tab = activeSidebarPinnedTabDrag?.tab, Workspace.existing(byName: tab.name) === tab else { return }
    previewSidebarPinnedTabDrop(tab, point: MousePointerTracker.shared.currentSample.point)
}

/// Drops the pinned tile being dragged without a drop: its payload goes, with its feedback.
@MainActor
func cancelActiveSidebarPinnedTabDrag() {
    guard activeSidebarPinnedTabDrag != nil else { return }
    activeSidebarPinnedTabDrag = nil
    clearSidebarPinnedTabDragFeedback()
}

@MainActor
private func clearSidebarPinnedTabDragFeedback() {
    displayedSidebarPinnedTabDrop = nil
    WorkspaceSidebarTabSplitHoverController.shared.reset()
    WorkspaceSidebarTabDragState.shared.set(false)
    clearWorkspaceSidebarDropPreview()
    WindowDragCursorProxyPanel.shared.hide()
}

func workspaceSidebarPinnedTabDropUndoTitle(_ drop: WorkspaceSidebarPinnedTabDrop) -> String {
    switch drop {
        case .rearrange: "Move Tab"
        case .list, .unpin: "Unpin Tab"
        case .group: "Move to Group"
        case .join: "Tile into Pinned Tab"
    }
}

/// Only the dragged tab itself, still pinned: the session can run after other events, which may
/// have closed it or given its name to another tab.
@MainActor
func applyWorkspaceSidebarPinnedTabDrop(_ tab: Workspace, _ drop: WorkspaceSidebarPinnedTabDrop,
                                        pinGridIsShared: Bool = workspaceSidebarPinGridIsShared()) throws {
    guard Workspace.existing(byName: tab.name) === tab,
          workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite == true else { return }
    let window = tab.mostRecentWindowRecursive ?? tab.anyLeafWindowRecursive
    switch drop {
        case .rearrange(let gap, let monitorScopeId):
            // Shared pins only rearrange; otherwise the tab comes to the list's display first.
            try withWorkspaceTabOnPinDropDisplay(tab, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared,
                focusing: window) {
                try pinWorkspaceSidebarTab(tab, beside: gap)
            }
        case .list(let projectId, let monitorScopeId, let gap):
            // The list's display, or none: a display that went away takes nothing.
            guard let monitor = workspaceSidebarDropTargetMonitor(scopeId: monitorScopeId, fallbackWindow: window,
                fallbackPoint: mouseLocation) else { throw WorkspaceMutationError.displayUnavailable }
            syncClosedWindowsCacheToCurrentWorld()
            suppressPostDragAxObserverEvents(for: tab.allLeafWindowsRecursive.map(\.windowId))
            // Unpinning, regrouping and moving go together: a drop that stops partway undoes the rest.
            try withWorkspaceSidebarDropTransaction {
                moveWholeTabToGap(tab, projectId: projectId, monitor: monitor, gap: gap, focusing: window)
            }
        case .group(let id, let monitorScopeId):
            try withWorkspaceTabOnDropDisplay(tab, monitorScopeId: monitorScopeId, focusing: window) {
                try assignWorkspaceToSidebarCollection(tab, collectionId: id)
            }
        case .unpin(let monitorScopeId):
            try withWorkspaceTabOnDropDisplay(tab, monitorScopeId: monitorScopeId, focusing: window) {
                try setWorkspaceSidebarTabFavorite(tab, false)
            }
        case .join(let name, let placement, let monitorScopeId):
            try joinWorkspaceTabIntoPinnedTab(name, pin: tab, placement: placement, listedOn: monitorScopeId)
    }
}

/// The tab `name` joins the pinned tab `pin`, whole, its split kept: the pin goes on `placement`'s
/// half of it, so the tab goes on the pin's other side. The pin stays pinned, in its place among the
/// pins, and comes to the tab's display, as a click brings it, so the tab never leaves it. A tab
/// dropped on a display's list must still be on that display, which must still be there. If any of
/// it can't be done, nothing changes.
@MainActor
func joinWorkspaceTabIntoPinnedTab(_ name: String, pin: Workspace, placement: WorkspaceSidebarTabDropPlacement,
                                   listedOn monitorScopeId: String? = nil) throws {
    // The session runs after other events: the tab may have closed, been pinned, or lost its windows.
    guard let tab = Workspace.existing(byName: name), tab !== pin, tab.projectId == pin.projectId,
          workspaceSidebarOrganizationStore.state.workspaces[name]?.isFavorite != true,
          let node = workspaceSidebarWholeTabNode(tab)
    else { return }
    let monitor = tab.workspaceMonitor
    if let monitorScopeId, workspaceSidebarMonitorScopePoint(monitorScopeId) != nil {
        guard let listed = workspaceSidebarDropTargetMonitor(scopeId: monitorScopeId) else {
            throw WorkspaceMutationError.displayUnavailable
        }
        guard listed.rect == monitor.rect else { return }
    }
    guard workspaceTabCanMove(pin, to: monitor) else { throw WorkspaceMutationError.tabAssignedToAnotherDisplay }
    let focused = tab.mostRecentWindowRecursive ?? tab.anyLeafWindowRecursive
    syncClosedWindowsCacheToCurrentWorld()
    suppressPostDragAxObserverEvents(for: (pin.allLeafWindowsRecursive + tab.allLeafWindowsRecursive).map(\.windowId))
    _ = try withWorkspaceSidebarDropTransaction {
        if pin.workspaceMonitor.rect != monitor.rect || !pin.isVisible {
            guard placeWorkspaceTabOnDisplay(pin, monitor) else { throw WorkspaceMutationError.tabCannotShowOnDisplay }
        }
        // Beside the pin's windows, side by side. A tab split the same way joins as its windows, in
        // order, so its split isn't nested and turned by normalization; any other split joins whole.
        let row = workspaceSiblingInsertionRoot(pin, orientation: .h)
        let first = placement == .left ? row.children.count : 0
        let tiling = workspaceStandardTilingRect(monitor.visibleRectPaddedByOuterGaps)
        let length = row.orientation == .h ? tiling.width : tiling.height
        for (offset, (piece, weight)) in makeRoomForWorkspaceSidebarJoin(node, in: row, length: length).enumerated() {
            piece.bind(to: row, adaptiveWeight: weight, index: first + offset)
        }
        for floating in tab.floatingWindows {
            floating.bind(to: pin, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        _ = focused?.focusWindow()
        return true
    }
}
