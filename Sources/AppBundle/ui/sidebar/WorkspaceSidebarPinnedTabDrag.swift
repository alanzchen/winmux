import AppKit
import Common

/// Tabs mode: a pinned tile drags as its whole tab, split or empty alike. It uses the sidebar's
/// drop targets and feedback, but no window drag, since a pin needn't have a window. Each drop
/// names the display whose list it lands on; a pin from another display moves there.
enum WorkspaceSidebarPinnedTabDrop: Equatable {
    /// Beside another pin, or, with no gap, onto another display's pins, which may have none yet.
    /// `move` takes it to the other section's pins: it stays pinned, with its tab and windows.
    case rearrange(WorkspaceSidebarTabGap?, monitorScopeId: String? = nil, move: WorkspaceSidebarPinMove? = nil)
    /// Between the list's tabs, unpinned.
    case list(projectId: WorkspaceProjectId, monitorScopeId: String, gap: WorkspaceSidebarTabGap)
    /// Into a group, which unpins it.
    case group(String, monitorScopeId: String? = nil)
    /// On New Tab: unpinned there, in `projectId`, the project of the list, for a pin in All Projects
    /// from another.
    case unpin(monitorScopeId: String? = nil, projectId: WorkspaceProjectId? = nil)
    /// Paused over a tab in a display's list. A pin with one window splits it with that tab, on
    /// `placement`'s half, as a window dropped there would: the window goes to the tab, which stays
    /// ordinary, and the pin lends it, grey. An empty pin takes in a tab with one window instead.
    case join(String, placement: WorkspaceSidebarTabDropPlacement, monitorScopeId: String? = nil)
    /// Paused over another pin's middle, both with one window: they split, on `placement`'s half of
    /// that pin, in a new ordinary tab, and both pins lend their windows, grey, keeping their places.
    /// `projectId` is the project of the list, which both must still be in when it's made.
    case split(String, placement: WorkspaceSidebarTabDropPlacement, projectId: WorkspaceProjectId, monitorScopeId: String? = nil)

    var monitorScopeId: String? {
        switch self {
            case .rearrange(_, let scope, _), .group(_, let scope), .unpin(let scope, _), .join(_, _, let scope),
                 .split(_, _, _, let scope): scope
            case .list(_, let scope, _): scope
        }
    }

    /// A drop that arranges the pins: beside another pin, or onto another display's pins. A split onto
    /// a pin isn't one, nor is a drop in the list, a group or New Tab.
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
        case .pinnedTabs(let projectId, let gap, let monitorScopeId, let section):
            return workspaceSidebarPinnedTabRearrange(tab, projectId: projectId, gap: gap, monitorScopeId: monitorScopeId,
                section: section, pinGridIsShared: pinGridIsShared)
        case .tabGap(let projectId, let monitorScopeId, let gap):
            guard Workspace.existing(byName: gap.workspaceName)?.projectId == projectId,
                  workspaceSidebarDropCanReachDisplay(tab, monitorScopeId: monitorScopeId) else { return nil }
            return .list(projectId: projectId, monitorScopeId: monitorScopeId, gap: gap)
        case .workspace(let name):
            guard let destination = target.tabReorderDestination, let other = Workspace.existing(byName: name) else {
                WorkspaceSidebarTabSplitHoverController.shared.reset()
                return nil
            }
            // Over another pin, a pause in its middle splits their windows in an ordinary tab, as a tab
            // from the list does. Elsewhere over it, and before the pause, it goes by the nearer side:
            // pins rearrange.
            guard !destination.arrangesPins else {
                if let split = workspaceSidebarPinnedTabSplit(tab, into: other, target: target, destination: destination,
                    point: point) { return split }
                guard case .pinnedTabs(let projectId, let gap, let monitorScopeId, let section) = destination.reorderTarget(
                    beside: name, rect: target.rect, point: point) else { return nil }
                return workspaceSidebarPinnedTabRearrange(tab, projectId: projectId, gap: gap, monitorScopeId: monitorScopeId,
                    section: section, pinGridIsShared: pinGridIsShared)
            }
            // Over a tab in the list, it never leaves the pins: only the gaps between tabs, and New
            // Tab, unpin it. After a pause, its window splits with that tab instead; before, nothing happens.
            return workspaceSidebarPinnedTabJoin(tab, onto: other, target: target, monitorScopeId: destination.monitorScopeId,
                point: point)
        case .tabCollection(let id, let monitorScopeId):
            // A group of the project whose list shows the pin: for a pin in All Projects, any project's.
            guard let group = workspaceSidebarOrganizationStore.state.collections.first(where: { $0.id == id }),
                  workspaceIsListed(tab, inProject: group.projectId),
                  workspaceSidebarDropCanReachDisplay(tab, monitorScopeId: monitorScopeId)
            else { return nil }
            return .group(id, monitorScopeId: monitorScopeId)
        case .newWorkspace(let projectId, let monitorScopeId):
            guard workspaceIsListed(tab, inProject: projectId), workspaceSidebarDropCanReachDisplay(tab, monitorScopeId: monitorScopeId)
            else { return nil }
            return .unpin(monitorScopeId: monitorScopeId, projectId: tab.projectId == projectId ? nil : projectId)
        case .monitor:
            return nil
    }
}

/// The pinned tab dropped among the pins: beside the pin in `gap`.
@MainActor
private func workspaceSidebarPinnedTabRearrange(_ tab: Workspace, projectId: WorkspaceProjectId, gap: WorkspaceSidebarTabGap?,
                                               monitorScopeId: String?, section: WorkspaceSidebarPinSection,
                                               pinGridIsShared: Bool) -> WorkspaceSidebarPinnedTabDrop? {
    // On this display it goes beside another pin; onto another display's pins it moves
    // there, even where that display has no pins yet. Shared pins only rearrange: the
    // tab stays where it is, so a drop that wouldn't change their order does nothing.
    // Among the other section's pins, it moves there: that's a change in itself.
    // Pins in All Projects are no project's: a pin from another display's list may go there too.
    let move = section == WorkspaceSidebarPinSection(of: tab) ? nil : WorkspaceSidebarPinMove(to: section, in: projectId)
    guard section == .allProjects || workspaceIsListed(tab, inProject: projectId),
          workspaceSidebarPinDropCanReachDisplay(tab, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared),
          move != nil
            || gap.flatMap({ workspacePinnedTabOrder(moving: tab, beside: $0) }) != nil
            || workspaceSidebarPinDropDisplayChange(for: tab, monitorScopeId: monitorScopeId,
                pinGridIsShared: pinGridIsShared) != nil
    else { return nil }
    return .rearrange(gap, monitorScopeId: monitorScopeId, move: move)
}

/// A pinned tab paused over the middle of `other`, another pin: their windows split on the half the
/// pointer is on, in an ordinary tab. Nil before the pause, nearer `other`'s sides, and where they
/// can't: either isn't a pin with one laid-out window, the dragged pin isn't in the list's project, or
/// `other` can't come to the list's display.
@MainActor
private func workspaceSidebarPinnedTabSplit(_ tab: Workspace, into other: Workspace, target: WorkspaceSidebarDropTarget,
                                            destination: WorkspaceSidebarTabReorderDestination,
                                            point: CGPoint) -> WorkspaceSidebarPinnedTabDrop? {
    let hover = WorkspaceSidebarTabSplitHoverController.shared
    guard target.acceptsSides, other !== tab, destination.pauseArmsSplit(at: point, rect: target.rect),
          workspaceSidebarOrganizationStore.state.workspaces[other.name]?.isFavorite == true,
          workspaceIsListed(tab, inProject: destination.projectId), workspaceIsListed(other, inProject: destination.projectId),
          workspaceSidebarPinSplitRole(tab).window != nil, workspaceSidebarPinSplitRole(other).window != nil,
          workspaceSidebarDropCanReachDisplay(other, monitorScopeId: destination.monitorScopeId)
    else {
        hover.reset()
        return nil
    }
    let side: WorkspaceSidebarTabDropPlacement = point.x < target.rect.center.x ? .left : .right
    guard hover.isReady(target: other.name, side: side, point: point) else { return nil }
    return .split(other.name, placement: side, projectId: destination.projectId, monitorScopeId: destination.monitorScopeId)
}

/// A pinned tab paused over `other`'s tab in a list, on the half the pointer is on: a pin with one
/// window splits it with `other`, and an empty pin takes `other` in when it has one window. Nil before
/// the pause, and for a tab that can't: a pin, an empty one, another project's, or one on a display
/// the pin may not come to; and for a pinned split, a pin lending its window, or an empty pin over a
/// split, since a pinned split is made only from a split tab's menu.
@MainActor
private func workspaceSidebarPinnedTabJoin(_ tab: Workspace, onto other: Workspace, target: WorkspaceSidebarDropTarget,
                                           monitorScopeId: String, point: CGPoint) -> WorkspaceSidebarPinnedTabDrop? {
    let hover = WorkspaceSidebarTabSplitHoverController.shared
    let joins = switch workspaceSidebarPinSplitRole(tab) {
        case .single: true
        case .empty: other.allLeafWindowsRecursive.count == 1
        case .refuses: false
    }
    // A tab of the project the list shows: a pin in All Projects takes one from any.
    guard joins, target.acceptsSides, other !== tab, workspaceIsListed(tab, inProject: other.projectId),
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
    if case .unpin(_, let listProjectId?) = drop { projectId = listProjectId }
    if case .rearrange(_, let monitorScopeId, let move) = drop {
        // The pins of the list's project: a pin in All Projects is among them in every one.
        projectId = move?.projectId ?? (workspaceIsPinnedInAllProjects(tab)
            ? monitorScopeId.flatMap(workspaceSidebarMonitor(forScopeId:)).map(activeWorkspaceProjectId(for:))
                ?? workspaceContextProjectId(of: tab)
            : tab.projectId)
    }
    let targetsNewTab = if case .unpin = drop { true } else { false }
    let joinedTab: String? = switch drop {
        case .join(let name, _, _), .split(let name, _, _, _): name
        default: nil
    }
    var preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: window?.windowId ?? 0,
        label: windows.count > 1 ? "\(windows.count) windows" : window.flatMap { cachedWindowTitle(for: $0) } ?? appName,
        appName: appName, appBundleIdentifier: window?.app.rawAppBundleId, appBundlePath: window?.app.bundlePath,
        targetWorkspaceName: joinedTab, targetsNewWorkspace: targetsNewTab, targetProjectId: projectId,
        targetMonitorScopeId: drop?.monitorScopeId, isTabGroup: false, windowCount: max(windows.count, 1))
    switch drop {
        case .rearrange(let gap, _, let move):
            preview.targetsPinned = true
            preview.targetPinnedGap = gap
            preview.targetPinSection = move?.section ?? WorkspaceSidebarPinSection(of: tab)
            preview.changesPinScope = move != nil
        case .list(_, _, let gap): preview.targetGap = gap
        case .group(let id, _): preview.targetCollectionId = id
        case .join(_, let placement, _):
            // The tab's half where the pin's window goes; an empty pin that takes the tab in lights up.
            preview.targetPlacement = placement
            if windows.isEmpty { preview.receivingPinnedTabName = tab.name }
        case .split(_, let placement, _, _):
            // The pin's half where this one goes, as for a tab from the list.
            preview.targetPlacement = placement
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
    var preview = drop.map { workspaceSidebarPinnedTabDropPreview(tab, batch: batch, drop: $0) }
    // A join's or split's label goes where the dragged tile, centered on the pointer, doesn't cover it.
    let current = TrayMenuModel.shared.workspaceSidebarDropPreview
    let split: (placement: WorkspaceSidebarTabDropPlacement, label: String, wasShown: Bool)? = switch drop {
        case .join(_, let placement, _) where tab.allLeafWindowsRecursive.isEmpty:
            (placement, workspaceSidebarPinTilingLabel, current?.receivingPinnedTabName == tab.name)
        case .join(let name, let placement, _), .split(let name, let placement, _, _):
            (placement, workspaceSidebarTabDropLabelText(placement), current?.targetWorkspaceName == name)
        default: nil
    }
    if let split, let rect = hit.target?.rect {
        preview?.targetLabelSlot = workspaceSidebarTabDropLabelSlot(pointX: point.x, targetMinX: rect.minX,
            targetMaxX: rect.maxX, placement: split.placement, labelWidth: workspaceSidebarTabDropLabelWidth(split.label),
            clearance: workspaceSidebarDragImageHalfWidth(.appIcon(size: 22)) + 4,
            previous: split.wasShown && current?.targetPlacement == split.placement ? current?.targetLabelSlot : nil)
    }
    setWorkspaceSidebarDropPreviewIfChanged(preview, owner: hit.surface)
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
    runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedTabDropUndoTitle(drop,
        fillsEmptyPin: tab.allLeafWindowsRecursive.isEmpty)) {
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

/// `fillsEmptyPin`: the dragged pin is empty, so a join takes the tab into it rather than splitting.
func workspaceSidebarPinnedTabDropUndoTitle(_ drop: WorkspaceSidebarPinnedTabDrop, fillsEmptyPin: Bool = false) -> String {
    switch drop {
        case .rearrange(_, _, let move?): workspaceSidebarPinScopeUndoTitle(move.scope)
        case .rearrange: "Move Tab"
        case .list, .unpin: "Unpin Tab"
        case .group: "Move to Group"
        case .join: fillsEmptyPin ? "Tile into Pinned Tab" : "Split Tabs"
        case .split: "Split Tabs"
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
        case .rearrange(let gap, let monitorScopeId, let move):
            // Shared pins only rearrange; otherwise the tab comes to the list's display first, or,
            // pinned in All Projects, just after. Among the other section's pins, it moves there,
            // still pinned.
            try withWorkspaceTabOnPinDropDisplay(tab, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared,
                focusing: window, editsFirst: move?.scope == .allProjects) {
                if let move {
                    try setWorkspaceSidebarTabPinScope(tab, move.scope, projectId: move.projectId, beside: gap)
                } else {
                    try pinWorkspaceSidebarTab(tab, beside: gap)
                }
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
                // A pin in All Projects joins another project's group as a tab of that project.
                _ = try withWorkspaceSidebarDropTransaction {
                    if let group = workspaceSidebarOrganizationStore.state.collections.first(where: { $0.id == id }),
                       group.projectId != tab.projectId {
                        try unpinWorkspaceSidebarTab(tab, into: group.projectId)
                        guard tab.projectId == group.projectId else { return false }
                    }
                    try assignWorkspaceToSidebarCollection(tab, collectionId: id)
                    return true
                }
            }
        case .unpin(let monitorScopeId, let projectId):
            try withWorkspaceTabOnDropDisplay(tab, monitorScopeId: monitorScopeId, focusing: window) {
                try unpinWorkspaceSidebarTab(tab, into: projectId ?? tab.projectId)
            }
        case .join(let name, let placement, let monitorScopeId):
            if tab.allLeafWindowsRecursive.isEmpty {
                try joinWorkspaceTabIntoPinnedTab(name, pin: tab, placement: placement, listedOn: monitorScopeId)
            } else {
                try splitPinnedTabWindowWithTab(tab, name, placement: placement, listedOn: monitorScopeId)
            }
        case .split(let name, let placement, let projectId, let monitorScopeId):
            try splitPinnedTabWindows(tab, with: name, placement: placement, listedIn: projectId, on: monitorScopeId)
    }
}

/// The tab `name`, with one window, goes into the empty pinned tab `pin`, which comes to the tab's
/// display, as a click brings it, so the window never leaves it. A tab dropped on a display's list
/// must still be on that display, which must still be there. A pin lending its window, or a tab with
/// more than one, changes nothing: a pinned split is made only from a split tab's menu. If any of it
/// can't be done, nothing changes.
@MainActor
func joinWorkspaceTabIntoPinnedTab(_ name: String, pin: Workspace, placement: WorkspaceSidebarTabDropPlacement,
                                   listedOn monitorScopeId: String? = nil) throws {
    // The session runs after other events: the tab may have closed, been pinned, or gained or lost
    // windows, and the pin may have taken a window or lent one. The window takes the pin's scope: a
    // pin in All Projects takes a tab from any project.
    guard let tab = Workspace.existing(byName: name), tab !== pin, workspaceIsListed(pin, inProject: tab.projectId),
          workspaceSidebarOrganizationStore.state.workspaces[name]?.isFavorite != true,
          workspaceSidebarPinSplitRole(pin) == .empty, tab.allLeafWindowsRecursive.count == 1,
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
    try tileWholeWorkspaceTab(node, of: tab, into: pin, placement: placement, on: monitor)
}

/// The pinned tab `pin`'s one window splits with the list's tab `name`, on `placement`'s half of it,
/// as a window dropped there would: it goes to that ordinary tab, on its display, and the pin keeps its
/// place and lends it, grey, until a click brings it back. A tab dropped on a display's list must still
/// be on that display, which must still be there. If any of it can't be done, nothing changes.
@MainActor
func splitPinnedTabWindowWithTab(_ pin: Workspace, _ name: String, placement: WorkspaceSidebarTabDropPlacement,
                                 listedOn monitorScopeId: String? = nil) throws {
    // The session runs after other events: the tab may have closed or been pinned, and the pin may
    // have gained, lost or lent its window.
    guard let tab = Workspace.existing(byName: name), tab !== pin, workspaceIsListed(pin, inProject: tab.projectId),
          !workspaceSidebarIsPinned(tab), workspaceSidebarWholeTabNode(tab) != nil,
          let window = workspaceSidebarPinSplitRole(pin).window
    else { return }
    if let monitorScopeId, workspaceSidebarMonitorScopePoint(monitorScopeId) != nil {
        guard let listed = workspaceSidebarDropTargetMonitor(scopeId: monitorScopeId) else {
            throw WorkspaceMutationError.displayUnavailable
        }
        guard listed.rect == tab.workspaceMonitor.rect else { return }
    }
    syncClosedWindowsCacheToCurrentWorld()
    suppressPostDragAxObserverEvents(for: (pin.allLeafWindowsRecursive + tab.allLeafWindowsRecursive).map(\.windowId))
    try moveWorkspaceSidebarNodeKeepingPins(window, onto: tab) { destination in
        applyTabDrop(sourceNode: window, sourceWindow: window, targetWorkspace: destination, placement: placement)
    }
}

/// The pinned tab `tab`'s one window splits with the pinned tab `name`'s, on `placement`'s half of
/// it, as a tab from the list would: both go to a new ordinary tab, on the display of the list it was
/// dropped on, `monitorScopeId`'s, and both pins keep their places and lend their windows, grey. Never
/// a pinned split. Both must still be pins with one window, listed in `projectId`, the list's
/// project, whose pins a pin in All Projects is among. If any of it can't be done, nothing changes.
@MainActor
func splitPinnedTabWindows(_ tab: Workspace, with name: String, placement: WorkspaceSidebarTabDropPlacement,
                           listedIn projectId: WorkspaceProjectId, on monitorScopeId: String? = nil) throws {
    // The session runs after other events: either may have been unpinned, gained, lost or lent its
    // window, or left the project of the list it was dropped on.
    guard let pin = Workspace.existing(byName: name), pin !== tab, workspaceSidebarIsPinned(pin),
          workspaceIsListed(tab, inProject: projectId), workspaceIsListed(pin, inProject: projectId),
          let window = workspaceSidebarPinSplitRole(tab).window, workspaceSidebarPinSplitRole(pin).window != nil
    else { return }
    let monitor: Monitor?
    switch workspaceSidebarDropDisplay(for: pin, monitorScopeId: monitorScopeId) {
        case .stays: monitor = nil
        case .moves(let display): monitor = display
        case .gone: throw WorkspaceMutationError.displayUnavailable
    }
    syncClosedWindowsCacheToCurrentWorld()
    suppressPostDragAxObserverEvents(for: (tab.allLeafWindowsRecursive + pin.allLeafWindowsRecursive).map(\.windowId))
    try moveWorkspaceSidebarNodeKeepingPins(window, onto: pin, newTabMonitor: monitor) { destination in
        applyTabDrop(sourceNode: window, sourceWindow: window, targetWorkspace: destination, placement: placement)
    }
}

/// `tab`'s windows join `pin` on `monitor`, with the pin on `placement`'s half: its tiled `node` beside
/// the pin's windows, side by side, and its floating windows with them. Its windows macOS holds apart,
/// a hidden app's, full screen or minimized, stay in `tab`. If any of it can't be done, nothing changes.
@MainActor
private func tileWholeWorkspaceTab(_ node: TreeNode, of tab: Workspace, into pin: Workspace,
                                   placement: WorkspaceSidebarTabDropPlacement, on monitor: Monitor) throws {
    // The window that comes forward is one that moves, the one used last: one left behind would take
    // the display back to `tab`.
    let moving = node.allLeafWindowsRecursive + tab.floatingWindows
    let focused = tab.mostRecentWorkspaceFocusableWindowRecursive.flatMap { window in moving.contains { $0 === window } ? window : nil }
        ?? node.mostRecentWindowRecursive ?? node.anyLeafWindowRecursive
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
        if let focused, focused.nodeWorkspace === pin { _ = focused.focusWindow() } else { _ = pin.focusWorkspace() }
        return true
    }
}
