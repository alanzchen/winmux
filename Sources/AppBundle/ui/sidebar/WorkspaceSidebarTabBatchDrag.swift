import AppKit
import Common

// Tabs mode: several chosen tabs dragged as one. A drag that starts on a chosen tab carries every
// chosen tab, whole, in the order the sidebar shows them; one that starts on another tab carries
// just that tab, and the choice stays. A batch goes only where every one of its tabs can: between
// tabs, into a group, or onto the pins. It moves all of them or none, with one Undo, and never
// splits with a tab, opens a New Tab, or lands on the screen.

/// Whether a batch released on the screen moves the window it was dragged by, as a single drag
/// does. It doesn't: the batch moves only where all of it can go.
let workspaceSidebarBatchScreenReleaseMovesDraggedWindow = false

/// The chosen tabs a drag carries, as they were when it began.
struct WorkspaceSidebarDragBatch: Equatable {
    enum Kind: Equatable {
        /// Tabs in the list.
        case tabs
        case pins
        /// Pins and tabs together, which go nowhere: a drop would unpin the pins or pin the tabs.
        case mixed
    }

    /// In the order the sidebar shows them: the pins, then the list.
    let names: [String]
    /// The tab the drag began on.
    let primary: String
    let projectId: WorkspaceProjectId
    let kind: Kind
    private let identities: [ObjectIdentifier]

    /// The batch a drag starting on tab `name` carries: the chosen tabs, if it's one of two or more.
    @MainActor
    init?(startingWith name: String, selection: WorkspaceSidebarTabSelection = .shared) {
        guard config.usesBrowserTabs, selection.isMultiple, selection.contains(name),
              let primary = Workspace.existing(byName: name) else { return nil }
        // A chosen tab that closed since isn't shown any more, so it isn't dragged.
        let tabs = selection.names.compactMap(Workspace.existing(byName:)).filter { $0.projectId == primary.projectId }
        guard tabs.count > 1 else { return nil }
        let pinned = tabs.map { workspaceSidebarOrganizationStore.state.workspaces[$0.name]?.isFavorite == true }
        names = tabs.map(\.name)
        self.primary = name
        projectId = primary.projectId
        kind = !pinned.contains(true) ? .tabs : !pinned.contains(false) ? .pins : .mixed
        identities = tabs.map(ObjectIdentifier.init)
    }

    /// The tabs, if every one is still the tab it was, in its project, and pinned or not as it was.
    /// One that closed, gave its name to another, or changed means the drop does nothing.
    @MainActor
    func resolve() -> [Workspace]? {
        guard kind != .mixed else { return nil }
        let tabs = names.compactMap(Workspace.existing(byName:))
        guard tabs.count == names.count, zip(tabs, identities).allSatisfy({ ObjectIdentifier($0) == $1 }),
              tabs.allSatisfy({ $0.projectId == projectId }) else { return nil }
        let isPinned = kind == .pins
        guard tabs.allSatisfy({ (workspaceSidebarOrganizationStore.state.workspaces[$0.name]?.isFavorite == true) == isPinned })
        else { return nil }
        return tabs
    }

    var label: String { "\(names.count) Tabs" }

    @MainActor
    func preview(_ preview: WorkspaceSidebarDropPreviewViewModel) -> WorkspaceSidebarDropPreviewViewModel {
        var preview = preview
        preview.label = label
        preview.isTabGroup = false
        preview.tabItems = []
        preview.windowCount = max(names.compactMap(Workspace.existing(byName:)).reduce(0) { $0 + $1.allLeafWindowsRecursive.count }, 1)
        return preview
    }
}

/// Tabs mode: where a batch dragged over `target` goes. Over a tab, beside it by the nearer edge,
/// as a single tab goes before a pause arms its split: a batch never splits with a tab.
@MainActor
func workspaceSidebarBatchDropTarget(_ target: WorkspaceSidebarDropTarget, point: CGPoint) -> WorkspaceSidebarDropTarget? {
    guard case .workspace(let name) = target.kind else { return target }
    guard let destination = target.tabReorderDestination else { return nil }
    return .init(kind: destination.reorderTarget(beside: name, rect: target.rect, point: point), rect: target.rect,
        surface: target.surface)
}

/// Whether a batch of tabs from the list may be dropped on `target`: every one of them can go there,
/// and the drop changes something. Pins and mixed batches take nothing from a window drag.
@MainActor
func isActionableWorkspaceSidebarBatchDropTarget(_ batch: WorkspaceSidebarDragBatch, target: WorkspaceSidebarDropTargetKind,
                                                 pinGridIsShared: Bool = workspaceSidebarPinGridIsShared()) -> Bool {
    guard batch.kind == .tabs, let tabs = batch.resolve() else { return false }
    switch target {
        case .tabGap(let projectId, let monitorScopeId, let gap):
            return workspaceSidebarBatchCanGo(tabs, toGap: gap, projectId: projectId, monitorScopeId: monitorScopeId)
        case .tabCollection(let id, let monitorScopeId):
            return workspaceSidebarBatchCanJoinGroup(tabs, id: id, monitorScopeId: monitorScopeId)
        case .pinnedTabs(let projectId, let gap, let monitorScopeId):
            guard projectId == batch.projectId, gap.map({ !batch.names.contains($0.workspaceName) }) ?? true else { return false }
            return tabs.allSatisfy {
                workspaceSidebarPinDropCanReachDisplay($0, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared)
            }
        case .workspace, .newWorkspace, .monitor:
            return false
    }
}

/// Every tab can go to the gap, beside a tab that isn't one of them, and at least one would move.
@MainActor
private func workspaceSidebarBatchCanGo(_ tabs: [Workspace], toGap gap: WorkspaceSidebarTabGap,
                                        projectId: WorkspaceProjectId, monitorScopeId: String) -> Bool {
    guard !tabs.contains(where: { $0.name == gap.workspaceName }),
          Workspace.existing(byName: gap.workspaceName)?.projectId == projectId,
          tabs.allSatisfy({ workspaceSidebarDropCanReachDisplay($0, monitorScopeId: monitorScopeId) })
    else { return false }
    return !workspaceSidebarBatchKeepsPlace(tabs, projectId: projectId, monitorScopeId: monitorScopeId, gap: gap)
}

/// Whether dropping `tabs` in `gap` would leave them all as they are: in the list, on its display,
/// in that group, and already in that order at that place.
@MainActor
private func workspaceSidebarBatchKeepsPlace(_ tabs: [Workspace], projectId: WorkspaceProjectId, monitorScopeId: String,
                                             gap: WorkspaceSidebarTabGap) -> Bool {
    let store = workspaceSidebarOrganizationStore
    guard tabs.allSatisfy({ tab in
        tab.projectId == projectId && store.state.workspaces[tab.name]?.isFavorite != true
            && (workspaceSidebarMonitorScopeIsSentinel(monitorScopeId)
                || workspaceSidebarMonitorScopeId(for: tab.workspaceMonitor) == monitorScopeId)
            && store.collection(containing: tab.name)?.id == gap.collectionId
    }) else { return false }
    let order = orderedWorkspaces(in: projectId).map(\.name)
    let names = tabs.map(\.name)
    var moved = order.filter { !names.contains($0) }
    guard let index = moved.firstIndex(of: gap.workspaceName) else { return false }
    moved.insert(contentsOf: names, at: gap.isAfter ? index + 1 : index)
    return moved == order
}

@MainActor
private func workspaceSidebarBatchCanJoinGroup(_ tabs: [Workspace], id: String, monitorScopeId: String?) -> Bool {
    guard let group = workspaceSidebarOrganizationStore.state.collections.first(where: { $0.id == id }),
          tabs.allSatisfy({ $0.projectId == group.projectId }),
          tabs.allSatisfy({ workspaceSidebarDropCanReachDisplay($0, monitorScopeId: monitorScopeId) })
    else { return false }
    return tabs.contains { !group.workspaceNames.contains($0.name) }
        || tabs.contains { workspaceSidebarDropDisplayChange(for: $0, monitorScopeId: monitorScopeId) != nil }
}

/// What dropping a batch of pins on `target` does, or nil where it does nothing: beside another pin,
/// between the list's tabs, or into a group. Over a tab in the list, nothing: a batch joins no tab.
@MainActor
func workspaceSidebarPinnedBatchDrop(_ batch: WorkspaceSidebarDragBatch, target: WorkspaceSidebarDropTarget, point: CGPoint,
                                     pinGridIsShared: Bool = workspaceSidebarPinGridIsShared()) -> WorkspaceSidebarPinnedTabDrop? {
    guard batch.kind == .pins, let tabs = batch.resolve() else { return nil }
    switch target.kind {
        case .pinnedTabs(let projectId, let gap, let monitorScopeId):
            guard projectId == batch.projectId,
                  tabs.allSatisfy({
                      workspaceSidebarPinDropCanReachDisplay($0, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared)
                  })
            else { return nil }
            let reorders = gap.flatMap { workspacePinnedTabOrder(placing: batch.names, beside: $0, in: projectId) } != nil
            let movesDisplay = tabs.contains {
                workspaceSidebarPinDropDisplayChange(for: $0, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared) != nil
            }
            guard reorders || movesDisplay else { return nil }
            return .rearrange(gap, monitorScopeId: monitorScopeId)
        case .tabGap(let projectId, let monitorScopeId, let gap):
            guard workspaceSidebarBatchCanGo(tabs, toGap: gap, projectId: projectId, monitorScopeId: monitorScopeId) else { return nil }
            return .list(projectId: projectId, monitorScopeId: monitorScopeId, gap: gap)
        case .workspace(let name):
            guard let destination = target.tabReorderDestination, destination.arrangesPins else { return nil }
            return workspaceSidebarPinnedBatchDrop(batch, target: .init(kind: destination.reorderTarget(beside: name,
                rect: target.rect, point: point), rect: target.rect, surface: target.surface), point: point,
                pinGridIsShared: pinGridIsShared)
        case .tabCollection(let id, let monitorScopeId):
            guard workspaceSidebarBatchCanJoinGroup(tabs, id: id, monitorScopeId: monitorScopeId) else { return nil }
            return .group(id, monitorScopeId: monitorScopeId)
        case .newWorkspace, .monitor:
            return nil
    }
}

/// The pins' names in order once `names` go beside another pin, together and in that order, or nil
/// where that changes nothing or the pin isn't there: beside one of them, or beside a tab that
/// isn't pinned.
@MainActor
func workspacePinnedTabOrder(placing names: [String], beside gap: WorkspaceSidebarTabGap,
                             in projectId: WorkspaceProjectId) -> [String]? {
    let pins = workspacePinnedTabs(in: projectId).map(\.name)
    var moved = pins.filter { !names.contains($0) }
    guard !names.contains(gap.workspaceName), let index = moved.firstIndex(of: gap.workspaceName) else { return nil }
    moved.insert(contentsOf: names, at: gap.isAfter ? index + 1 : index)
    return moved == pins ? nil : moved
}

func workspaceSidebarBatchDropUndoTitle(_ batch: WorkspaceSidebarDragBatch, target: WorkspaceSidebarDropTargetKind) -> String {
    switch target {
        case .tabCollection: "Move \(batch.label) to Group"
        case .pinnedTabs: "Pin \(batch.label)"
        case .tabGap, .workspace, .newWorkspace, .monitor: "Move \(batch.label)"
    }
}

func workspaceSidebarPinnedBatchDropUndoTitle(_ batch: WorkspaceSidebarDragBatch, _ drop: WorkspaceSidebarPinnedTabDrop) -> String {
    switch drop {
        case .rearrange, .join: "Move \(batch.label)"
        case .list, .unpin: "Unpin \(batch.label)"
        case .group: "Move \(batch.label) to Group"
    }
}

/// Queues the batch drop a release chose, as the release captured it. Returns its session.
@MainActor
@discardableResult
func queueWorkspaceSidebarBatchDrop(_ batch: WorkspaceSidebarDragBatch, target: WorkspaceSidebarDropTargetKind,
                                    intent: WorkspaceSidebarDropIntent, settlingId: UUID? = nil) -> Task<Void, Never>? {
    let task = runWorkspaceSidebarSession(undoTitle: workspaceSidebarBatchDropUndoTitle(batch, target: target)) {
        defer { if let settlingId { finishWorkspaceSidebarDockLift(id: settlingId) } }
        try intent.checkDestination()
        guard intent.targetIsUnchanged else { return }
        if try applyWorkspaceSidebarBatchDrop(batch, target: target, pinGridIsShared: intent.pinGridIsShared) {
            WorkspaceSidebarTabSelection.shared.clear()
        }
        await updateWorkspaceSidebarModel()
    }
    if task == nil, let settlingId { finishWorkspaceSidebarDockLift(id: settlingId) }
    return task
}

/// The batch drop's changes, in the session it runs in. Every tab must still be the one dragged and
/// still able to go there; if any can't, or a change fails partway, nothing changes. Returns
/// whether the tabs moved.
@MainActor
@discardableResult
func applyWorkspaceSidebarBatchDrop(_ batch: WorkspaceSidebarDragBatch, target: WorkspaceSidebarDropTargetKind,
                                    pinGridIsShared: Bool = workspaceSidebarPinGridIsShared()) throws -> Bool {
    guard config.usesBrowserTabs, batch.kind == .tabs, let tabs = batch.resolve() else { return false }
    switch target {
        case .tabGap(let projectId, let monitorScopeId, let gap):
            guard workspaceSidebarBatchCanGo(tabs, toGap: gap, projectId: projectId, monitorScopeId: monitorScopeId)
            else { return try refuseWorkspaceSidebarBatch(tabs, monitorScopeId: monitorScopeId) }
            return try moveWorkspaceSidebarBatchToGap(batch, tabs, projectId: projectId, monitorScopeId: monitorScopeId, gap: gap)
        case .tabCollection(let id, let monitorScopeId):
            guard workspaceSidebarBatchCanJoinGroup(tabs, id: id, monitorScopeId: monitorScopeId)
            else { return try refuseWorkspaceSidebarBatch(tabs, monitorScopeId: monitorScopeId) }
            return try moveWorkspaceSidebarBatchToGroup(batch, tabs, id: id, monitorScopeId: monitorScopeId)
        case .pinnedTabs(let projectId, let gap, let monitorScopeId):
            guard projectId == batch.projectId, gap.map({ !batch.names.contains($0.workspaceName) }) ?? true else { return false }
            return try pinWorkspaceSidebarBatch(batch, tabs, beside: gap, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared)
        case .workspace, .newWorkspace, .monitor:
            return false
    }
}

/// The batch-of-pins drop's changes, in the session it runs in, all or nothing. Returns whether the
/// pins moved.
@MainActor
@discardableResult
func applyWorkspaceSidebarPinnedBatchDrop(_ batch: WorkspaceSidebarDragBatch, _ drop: WorkspaceSidebarPinnedTabDrop,
                                          pinGridIsShared: Bool = workspaceSidebarPinGridIsShared()) throws -> Bool {
    guard config.usesBrowserTabs, batch.kind == .pins, let tabs = batch.resolve() else { return false }
    switch drop {
        case .rearrange(let gap, let monitorScopeId):
            if let gap, batch.names.contains(gap.workspaceName) { return false }
            return try pinWorkspaceSidebarBatch(batch, tabs, beside: gap, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared)
        case .list(let projectId, let monitorScopeId, let gap):
            guard workspaceSidebarBatchCanGo(tabs, toGap: gap, projectId: projectId, monitorScopeId: monitorScopeId)
            else { return try refuseWorkspaceSidebarBatch(tabs, monitorScopeId: monitorScopeId) }
            return try moveWorkspaceSidebarBatchToGap(batch, tabs, projectId: projectId, monitorScopeId: monitorScopeId, gap: gap)
        case .group(let id, let monitorScopeId):
            guard workspaceSidebarBatchCanJoinGroup(tabs, id: id, monitorScopeId: monitorScopeId)
            else { return try refuseWorkspaceSidebarBatch(tabs, monitorScopeId: monitorScopeId) }
            return try moveWorkspaceSidebarBatchToGroup(batch, tabs, id: id, monitorScopeId: monitorScopeId)
        case .unpin, .join:
            return false
    }
}

/// A batch that can no longer go where it was dropped: a display that went away, or a tab held to
/// another one, says so; otherwise, nothing happens.
@MainActor
private func refuseWorkspaceSidebarBatch(_ tabs: [Workspace], monitorScopeId: String?) throws -> Bool {
    for tab in tabs { try checkWorkspaceSidebarDropDisplay(tab, monitorScopeId: monitorScopeId) }
    return false
}

/// The tabs go to the gap one after another, each whole and after the one before, so they keep
/// their order. Each joins the gap's group, project and display, leaving the pins, as one tab
/// dropped there does.
@MainActor
private func moveWorkspaceSidebarBatchToGap(_ batch: WorkspaceSidebarDragBatch, _ tabs: [Workspace],
                                            projectId: WorkspaceProjectId, monitorScopeId: String,
                                            gap: WorkspaceSidebarTabGap) throws -> Bool {
    let monitors = try tabs.map { tab in
        // The list's display, or none: a display that went away takes nothing.
        guard let monitor = workspaceSidebarDropTargetMonitor(scopeId: monitorScopeId,
            fallbackWindow: tab.mostRecentWindowRecursive ?? tab.anyLeafWindowRecursive, fallbackPoint: mouseLocation)
        else { throw WorkspaceMutationError.displayUnavailable }
        guard workspaceTabCanMove(tab, to: monitor) else { throw WorkspaceMutationError.tabAssignedToAnotherDisplay }
        return monitor
    }
    syncClosedWindowsCacheToCurrentWorld()
    suppressPostDragAxObserverEvents(for: tabs.flatMap(\.allLeafWindowsRecursive).map(\.windowId))
    return try withWorkspaceSidebarDropTransaction {
        let leaves = zip(tabs, monitors).contains { $0.workspaceMonitor.rect != $1.rect || $0.projectId != projectId }
        var gap = gap
        for (tab, monitor) in zip(tabs, monitors) {
            guard moveWholeTabToGap(tab, projectId: projectId, monitor: monitor, gap: gap, focusing: nil),
                  tab.projectId == projectId, tab.workspaceMonitor.rect == monitor.rect,
                  workspaceSidebarOrganizationStore.collection(containing: tab.name)?.id == gap.collectionId
            else { return false }
            gap = .init(workspaceName: tab.name, isAfter: true, collectionId: gap.collectionId)
        }
        if leaves { focusWorkspaceSidebarBatchPrimary(batch) }
        return true
    }
}

/// The tabs join the group, in their order, after coming to the list's display if they aren't on it.
@MainActor
private func moveWorkspaceSidebarBatchToGroup(_ batch: WorkspaceSidebarDragBatch, _ tabs: [Workspace], id: String,
                                              monitorScopeId: String?) throws -> Bool {
    for tab in tabs { try checkWorkspaceSidebarDropDisplay(tab, monitorScopeId: monitorScopeId) }
    let moves = tabs.compactMap { tab in workspaceSidebarDropDisplayChange(for: tab, monitorScopeId: monitorScopeId).map { (tab, $0) } }
    // A group that can't be saved leaves the tabs where they are rather than moving them and back.
    if let reason = workspaceSidebarOrganizationStore.readOnlyReason {
        showWorkspaceSidebarError(reason)
        return false
    }
    syncClosedWindowsCacheToCurrentWorld()
    suppressPostDragAxObserverEvents(for: tabs.flatMap(\.allLeafWindowsRecursive).map(\.windowId))
    return try withWorkspaceSidebarDropTransaction {
        for (tab, monitor) in moves { try moveWorkspaceTabToDisplay(tab, monitor, focusing: nil) }
        try saveWorkspaceSidebarIdentities(tabs)
        try workspaceSidebarOrganizationStore.assign(tabs.map(\.name), projectId: batch.projectId, to: id)
        if !moves.isEmpty { focusWorkspaceSidebarBatchPrimary(batch) }
        return true
    }
}

/// The tabs are pinned, or pins move, together beside the pin `gap` names, in their order. Without
/// shared pins, pins on another display's list bring them to that display too.
@MainActor
private func pinWorkspaceSidebarBatch(_ batch: WorkspaceSidebarDragBatch, _ tabs: [Workspace], beside gap: WorkspaceSidebarTabGap?,
                                      monitorScopeId: String?, pinGridIsShared: Bool) throws -> Bool {
    let store = workspaceSidebarOrganizationStore
    // Pinning saves the tabs.
    if let reason = store.readOnlyReason ?? savedWorkspaceStore.readOnlyReason {
        showWorkspaceSidebarError(reason)
        return false
    }
    for tab in tabs { try checkWorkspaceSidebarPinDropDisplay(tab, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared) }
    let moves = tabs.compactMap { tab in
        workspaceSidebarPinDropDisplayChange(for: tab, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared).map { (tab, $0) }
    }
    let order = gap.flatMap { workspacePinnedTabOrder(placing: batch.names, beside: $0, in: batch.projectId) }
    let pinsTabs = batch.kind == .tabs
    guard pinsTabs || order != nil || !moves.isEmpty else { return false }
    syncClosedWindowsCacheToCurrentWorld()
    suppressPostDragAxObserverEvents(for: tabs.flatMap(\.allLeafWindowsRecursive).map(\.windowId))
    return try withWorkspaceSidebarDropTransaction {
        for (tab, monitor) in moves { try moveWorkspaceTabToDisplay(tab, monitor, focusing: nil) }
        if pinsTabs { try saveWorkspaceSidebarIdentities(tabs) }
        // Pinning and placing are one write, so a failure leaves neither behind.
        let names = Set(batch.names)
        try store.update { state in
            if pinsTabs {
                for name in batch.names { state.workspaces[name, default: .init()].setFavorite(true) }
                for index in state.collections.indices { state.collections[index].workspaceNames.removeAll(where: names.contains) }
            }
            for (index, name) in (order ?? []).enumerated() { state.workspaces[name, default: .init()].pinOrder = index }
        }
        if !moves.isEmpty { focusWorkspaceSidebarBatchPrimary(batch) }
        return true
    }
}

/// After tabs changed display, the one dragged comes forward, with its last-used window.
@MainActor
private func focusWorkspaceSidebarBatchPrimary(_ batch: WorkspaceSidebarDragBatch) {
    guard let primary = Workspace.existing(byName: batch.primary) else { return }
    if let window = primary.mostRecentWindowRecursive ?? primary.anyLeafWindowRecursive { _ = window.focusWindow() }
    else { _ = primary.focusWorkspace() }
}
