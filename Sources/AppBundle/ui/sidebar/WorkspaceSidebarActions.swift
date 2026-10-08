import AppKit
import Common
import SwiftUI

@MainActor
func focusWorkspaceFromSidebar(_ workspaceName: String, targetMonitorScopeId: String? = nil) {
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    optimisticallyMarkWorkspaceFocusedInSidebar(workspaceName)
    runWorkspaceSidebarSession {
        guard let workspace = Workspace.existing(byName: workspaceName) else { return }
        _ = focusWorkspaceFromSidebar(workspace, targetMonitorScopeId: targetMonitorScopeId)
    }
}

/// Perceived responsiveness: flip the sidebar's focused/visible highlight to the clicked
/// workspace on the same frame as the click. The session that follows rebuilds the real model
/// (after an AX round-trip and title fetches) and corrects any difference.
@MainActor
func optimisticallyMarkWorkspaceFocusedInSidebar(_ workspaceName: String) {
    guard let workspaces = workspaceSidebarWorkspacesMarkingFocused(
        workspaceName,
        in: TrayMenuModel.shared.workspaceSidebarWorkspaces,
    ) else { return }
    TrayMenuModel.shared.workspaceSidebarWorkspaces = workspaces
    WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
}

/// nil when the workspace is missing or already focused.
func workspaceSidebarWorkspacesMarkingFocused(
    _ workspaceName: String,
    in workspaces: [WorkspaceSidebarWorkspaceViewModel],
) -> [WorkspaceSidebarWorkspaceViewModel]? {
    guard let target = workspaces.first(where: { $0.name == workspaceName }), !target.isFocused else { return nil }
    return workspaces.map { w in
        let isFocused = w.name == workspaceName
        let isVisible = w.monitorScopeId == target.monitorScopeId ? isFocused : w.isVisible
        if isFocused == w.isFocused, isVisible == w.isVisible { return w }
        var copy = w
        copy.isFocused = isFocused
        copy.isVisible = isVisible
        return copy
    }
}

@MainActor
func focusWorkspaceFromSidebar(_ workspace: Workspace, targetMonitorScopeId: String? = nil) -> Bool {
    guard let targetMonitorScopeId,
          let targetMonitor = workspaceSidebarMonitor(forScopeId: targetMonitorScopeId)
    else {
        return workspace.focusWorkspace()
    }

    if workspace.isVisible {
        guard workspace.workspaceMonitor.rect.topLeftCorner == targetMonitor.rect.topLeftCorner else {
            return false
        }
        return workspace.focusWorkspace()
    }

    // A pinned workspace opens on its own display wherever it was clicked.
    if savedPinBlocks(workspace, on: targetMonitor) {
        return workspace.focusWorkspace()
    }
    guard targetMonitor.setActiveWorkspace(workspace) else { return false }
    noteSavedWorkspacePlacedByUser(workspace, on: targetMonitor)
    return workspace.focusWorkspace()
}

@MainActor
func overrideWorkspaceInUseFromSidebar(_ workspaceName: String, targetMonitorScopeId: String? = nil) {
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    runWorkspaceSidebarSession {
        guard let workspace = Workspace.existing(byName: workspaceName),
              let targetMonitorScopeId,
              let targetMonitor = workspaceSidebarMonitor(forScopeId: targetMonitorScopeId)
        else { return }
        _ = overrideWorkspaceOnMonitorBySwappingActiveViewports(workspace, targetMonitor: targetMonitor)
        _ = workspace.focusWorkspace()
    }
}

@MainActor
@discardableResult
func runWorkspaceSidebarSession(
    afterLayout: @escaping @MainActor () -> Void = {},
    undoTitle: String? = nil,
    _ body: @escaping @MainActor () async throws -> Void
) -> Task<Void, Never>? {
    guard let token: RunSessionGuard = .isServerEnabled else { return nil }
    return Task { @MainActor in
        do {
            var undoBefore: WorkspaceSidebarTabUndoSnapshot?
            var undoGeneration: UInt64?
            try await runLightSession(.menuBarButton, token) {
                if undoTitle != nil, config.usesBrowserTabs {
                    undoBefore = .init()
                    undoGeneration = workspaceInteractionSessionGeneration
                }
                try await body()
            }
            if let undoTitle, let undoBefore {
                if undoGeneration == workspaceInteractionSessionGeneration {
                    WorkspaceSidebarTabUndo.shared.record(undoTitle, before: undoBefore)
                } else { WorkspaceSidebarTabUndo.shared.clear() }
            }
            afterLayout()
        } catch {
            showWorkspaceSidebarError(error.localizedDescription)
        }
    }
}

@MainActor
func showWorkspaceSidebarError(_ body: String) {
    MessageModel.shared.message = Message(
        description: "Workspace Sidebar Error",
        body: body,
    )
}

@MainActor
func sidebarWorkspaceTargetMonitor(fallbackWindow: Window? = nil, fallbackPoint: CGPoint? = nil) -> Monitor {
    workspaceSidebarTargetMonitor(
        selectedMonitor: selectedWorkspaceSidebarMonitorScope(),
        fallbackPoint: fallbackPoint,
        fallbackWindowMonitor: fallbackWindow?.nodeMonitor,
        focusedMonitor: focus.workspace.workspaceMonitor,
    )
}

@MainActor
func workspaceSidebarTargetMonitor(
    selectedMonitor: Monitor?,
    fallbackPoint: CGPoint?,
    fallbackWindowMonitor: Monitor?,
    focusedMonitor: Monitor,
) -> Monitor {
    selectedMonitor ??
        fallbackPoint?.monitorApproximation ??
        fallbackWindowMonitor ??
        focusedMonitor
}

@MainActor
func selectedWorkspaceSidebarMonitorScope() -> Monitor? {
    let selectedScopeId = TrayMenuModel.shared.workspaceSidebarSelectedMonitorScopeId
    guard selectedScopeId != workspaceSidebarDefaultScopeId,
          selectedScopeId != workspaceSidebarFocusedScopeId
    else {
        return nil
    }
    return sortedMonitors.first { workspaceSidebarMonitorScopeId(for: $0) == selectedScopeId }
}

@MainActor
func workspaceSidebarTargetMonitor(
    scopeId: String,
    fallbackWindow: Window? = nil,
    fallbackPoint: CGPoint? = nil,
) -> Monitor {
    let selectedMonitor = workspaceSidebarMonitorForScopeId(scopeId)
    return workspaceSidebarTargetMonitor(
        selectedMonitor: selectedMonitor,
        fallbackPoint: fallbackPoint,
        fallbackWindowMonitor: fallbackWindow?.nodeMonitor,
        focusedMonitor: focus.workspace.workspaceMonitor,
    )
}

@MainActor
private func workspaceSidebarMonitorForScopeId(_ scopeId: String) -> Monitor? {
    guard scopeId != workspaceSidebarDefaultScopeId,
          scopeId != workspaceSidebarFocusedScopeId
    else {
        return nil
    }
    return sortedMonitors.first { workspaceSidebarMonitorScopeId(for: $0) == scopeId }
}

func workspaceSidebarWorkspaceCreateScope(
    selectedScopeId: String,
    targetMonitorScopeId: String,
    focusedScopeId: String,
) -> String {
    switch selectedScopeId {
        case workspaceSidebarDefaultScopeId:
            targetMonitorScopeId
        case workspaceSidebarFocusedScopeId:
            focusedScopeId
        default:
            selectedScopeId
    }
}

@MainActor
func selectWorkspaceSidebarMonitorScope(_ scopeId: String, viewModel: TrayMenuModel = TrayMenuModel.shared) {
    guard viewModel.workspaceSidebarMonitorScopes.contains(where: { $0.id == scopeId }) else { return }
    viewModel.workspaceSidebarMonitorScopeChoiceFilter = viewModel.workspaceSidebarAppearance.displayFilter
    guard viewModel.workspaceSidebarSelectedMonitorScopeId != scopeId else { return }
    viewModel.workspaceSidebarSelectedMonitorScopeId = scopeId
    let visibleWorkspaceNames = Set(viewModel.visibleWorkspaceSidebarWorkspaces.map(\.name))
    let sanitizedHoveredWorkspaceName = sanitizedWorkspaceSidebarHoveredWorkspaceName(
        visibleWorkspaceNames: visibleWorkspaceNames,
        hoveredWorkspaceName: viewModel.workspaceSidebarHoveredWorkspaceName,
    )
    if viewModel.workspaceSidebarHoveredWorkspaceName != sanitizedHoveredWorkspaceName {
        viewModel.workspaceSidebarHoveredWorkspaceName = sanitizedHoveredWorkspaceName
    }
}

@MainActor
func createWorkspaceFromSidebarButton() {
    let targetMonitor = sidebarWorkspaceTargetMonitor()
    createWorkspaceFromSidebarButton(
        projectId: activeWorkspaceProjectId(for: targetMonitor),
        monitorScopeId: TrayMenuModel.shared.workspaceSidebarSelectedMonitorScopeId,
    )
}

@MainActor
func createWorkspaceFromSidebarButton(projectId: WorkspaceProjectId, monitorScopeId: String) {
    if config.usesBrowserTabs {
        openNewTabFromSidebar(projectId: projectId, monitorScopeId: monitorScopeId)
        return
    }
    var launcherWorkspaceName: String?
    runWorkspaceSidebarSession(afterLayout: {
        // Like a browser's new tab: offer to open a new window in the empty workspace.
        guard let launcherWorkspaceName else { return }
        WorkspaceLauncherPanel.shared.show(forWorkspaceNamed: launcherWorkspaceName)
    }) {
        let targetMonitor = workspaceSidebarTargetMonitor(scopeId: monitorScopeId)
        let workspace = getOrCreateAdjacentBlankWorkspace(projectId: projectId, monitor: targetMonitor)
        if workspace.focusWorkspace(), config.workspaceSidebar.newWorkspaceLauncher, workspace.isEffectivelyEmpty {
            launcherWorkspaceName = workspace.name
        }
    }
}

/// Tabs mode's New Tab: a new tab after the current one, with the launcher, whatever the
/// launcher setting. Closing the launcher without opening anything closes the tab again.
@MainActor
func openNewTabFromSidebar(projectId: WorkspaceProjectId, monitorScopeId: String) {
    var launcherTab: WorkspaceLauncherNewTab?
    runWorkspaceSidebarSession(afterLayout: {
        guard let launcherTab else { return }
        if !WorkspaceLauncherPanel.shared.show(forWorkspaceNamed: launcherTab.workspace.name, newTab: launcherTab),
           launcherTab.isNew
        {
            runWorkspaceSidebarSession { closeUnusedNewTab(launcherTab) }
        }
    }) {
        let newTab = newTabWorkspace(projectId: projectId, monitor: workspaceSidebarTargetMonitor(scopeId: monitorScopeId))
        if newTab.workspace.focusWorkspace() { launcherTab = newTab }
    }
}

@MainActor
func createWorkspaceFromSidebarDrag(sourceNode: TreeNode, sourceWindow: Window) -> Bool {
    createWorkspaceFromSidebarDrag(sourceNode: sourceNode, sourceWindow: sourceWindow, projectId: nil, monitorScopeId: nil)
}

@MainActor
func createWorkspaceFromSidebarDrag(
    sourceNode: TreeNode,
    sourceWindow: Window,
    projectId: WorkspaceProjectId?,
    monitorScopeId: String?,
) -> Bool {
    let targetMonitor = monitorScopeId.map {
        workspaceSidebarTargetMonitor(
            scopeId: $0,
            fallbackWindow: sourceWindow,
            fallbackPoint: mouseLocation,
        )
    } ?? sidebarWorkspaceTargetMonitor(fallbackWindow: sourceWindow, fallbackPoint: mouseLocation)
    let projectId = projectId ?? activeWorkspaceProjectId(for: targetMonitor)
    let workspace = workspaceForDropOnNewTab(projectId: projectId, monitor: targetMonitor, sourceWindow: sourceWindow)
    let targetContainer: NonLeafTreeNodeObject
    if sourceNode is Window, sourceWindow.isFloating {
        targetContainer = workspace
    } else {
        targetContainer = workspace.rootTilingContainer
    }
    sourceNode.bind(to: targetContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    return true
}

@MainActor
func moveWindowFromSidebar(
    _ windowId: UInt32, toWorkspace workspaceName: String,
    validation: @escaping @MainActor () -> Bool = { true }
) {
    moveSidebarSource(windowId, subject: .window, toWorkspace: workspaceName, validation: validation)
}

@MainActor
func moveTabGroupFromSidebar(_ windowId: UInt32, toWorkspace workspaceName: String) {
    moveSidebarSource(windowId, subject: .group, toWorkspace: workspaceName)
}

@MainActor
func moveWindowToNewWorkspaceFromSidebar(_ windowId: UInt32, projectId: WorkspaceProjectId, monitorScopeId: String) {
    moveSidebarSourceToNewWorkspace(windowId, subject: .window, projectId: projectId, monitorScopeId: monitorScopeId)
}

@MainActor
func moveTabGroupToNewWorkspaceFromSidebar(_ windowId: UInt32, projectId: WorkspaceProjectId, monitorScopeId: String) {
    moveSidebarSourceToNewWorkspace(windowId, subject: .group, projectId: projectId, monitorScopeId: monitorScopeId)
}

@MainActor
@discardableResult
private func moveSidebarSource(
    _ windowId: UInt32, subject: WindowDragSubject, toWorkspace workspaceName: String,
    tabPlacement: WorkspaceSidebarTabDropPlacement? = nil, intent: WorkspaceSidebarDropIntent = .physical,
    settlingId: UUID? = nil, validation: @escaping @MainActor () -> Bool = { true }
) -> Task<Void, Never>? {
    let task = runWorkspaceSidebarSession(undoTitle: tabPlacement == nil ? "Move Tab" : "Split Tabs") {
        defer { if let settlingId { finishWorkspaceSidebarDockLift(id: settlingId) } }
        try intent.checkDestination()
        // What was released, onto the tab it was released on: a tab another display's list showed
        // takes the drop only while it's still on that display.
        guard validation(), intent.targetIsUnchanged, let source = intent.resolveSource(windowId: windowId, subject: subject),
              let targetWorkspace = Workspace.existing(byName: workspaceName), intent.accepts(targetWorkspace)
        else { return }
        let (sourceWindow, sourceNode) = (source.window, source.node)
        syncClosedWindowsCacheToCurrentWorld()
        suppressPostDragAxObserverEvents(for: sourceNode.allLeafWindowsRecursive.map(\.windowId))
        // A pin with one window keeps it as its own: a split with it goes to an ordinary tab.
        try moveWorkspaceSidebarNodeKeepingPins(sourceNode, onto: targetWorkspace) { destination in
            if let tabPlacement {
                applyTabDrop(sourceNode: sourceNode, sourceWindow: sourceWindow, targetWorkspace: destination,
                    placement: tabPlacement)
            } else {
                applySidebarWorkspaceMove(sourceNode: sourceNode, sourceWindow: sourceWindow, targetWorkspace: destination)
                if destination !== targetWorkspace { _ = sourceWindow.focusWindow() }
            }
        }
        await updateWorkspaceSidebarModel()
    }
    if task == nil, let settlingId { finishWorkspaceSidebarDockLift(id: settlingId) }
    return task
}

@MainActor
@discardableResult
private func moveSidebarSourceToTabGap(
    _ windowId: UInt32, subject: WindowDragSubject, projectId: WorkspaceProjectId, monitorScopeId: String,
    gap: WorkspaceSidebarTabGap, intent: WorkspaceSidebarDropIntent = .physical, settlingId: UUID? = nil,
) -> Task<Void, Never>? {
    let unpins = sidebarDragMovesWholePinnedTab(windowId, subject: subject)
    let task = runWorkspaceSidebarSession(undoTitle: unpins ? "Unpin Tab" : "Move Tab") {
        defer { if let settlingId { finishWorkspaceSidebarDockLift(id: settlingId) } }
        try intent.checkDestination()
        guard intent.targetIsUnchanged, let source = intent.resolveSource(windowId: windowId, subject: subject) else { return }
        let (sourceWindow, sourceNode) = (source.window, source.node)
        // The list's display, or none: a display that went away takes nothing.
        guard let monitor = workspaceSidebarDropTargetMonitor(scopeId: monitorScopeId, fallbackWindow: sourceWindow,
            fallbackPoint: mouseLocation) else { throw WorkspaceMutationError.displayUnavailable }
        syncClosedWindowsCacheToCurrentWorld()
        suppressPostDragAxObserverEvents(for: sourceNode.allLeafWindowsRecursive.map(\.windowId))
        // Unpinning, regrouping and moving go together: a drop that stops partway undoes the rest.
        try withWorkspaceSidebarDropTransaction {
            applyTabGapDrop(sourceNode: sourceNode, sourceWindow: sourceWindow, projectId: projectId, monitor: monitor, gap: gap)
        }
        await updateWorkspaceSidebarModel()
    }
    if task == nil, let settlingId { finishWorkspaceSidebarDockLift(id: settlingId) }
    return task
}

/// Whether the drag carries a whole pinned tab, not a window pulled out of one.
@MainActor
private func sidebarDragMovesWholePinnedTab(_ windowId: UInt32, subject: WindowDragSubject) -> Bool {
    guard let window = Window.get(byId: windowId) else { return false }
    let node = dragSubjectNode(for: window, subject: subject)
    guard let workspace = node.nodeWorkspace, !workspaceTabDragLeavesWindowsBehind(node) else { return false }
    return workspaceSidebarOrganizationStore.state.workspaces[workspace.name]?.isFavorite == true
}

/// A tab dropped on the pinned tiles is pinned, beside the pin it was dropped next to; a pinned
/// tab moves there. A window from a split first gets a tab of its own. Pins on another
/// display's list bring the tab to that display too.
@MainActor
@discardableResult
private func pinSidebarSource(_ windowId: UInt32, subject: WindowDragSubject, gap: WorkspaceSidebarTabGap?,
                              monitorScopeId: String? = nil, section: WorkspaceSidebarPinSection = .project,
                              projectId: WorkspaceProjectId? = nil, intent: WorkspaceSidebarDropIntent = .physical,
                              settlingId: UUID? = nil) -> Task<Void, Never>? {
    let movesPin = sidebarDragMovesWholePinnedTab(windowId, subject: subject)
    let changesScope = Window.get(byId: windowId).map {
        sidebarDragChangesPinScope(dragSubjectNode(for: $0, subject: subject), to: section)
    } == true
    let title = changesScope ? workspaceSidebarPinScopeUndoTitle(section.scope) : movesPin ? "Move Tab" : "Pin Tab"
    let task = runWorkspaceSidebarSession(undoTitle: title) {
        defer { if let settlingId { finishWorkspaceSidebarDockLift(id: settlingId) } }
        try intent.checkDestination()
        guard intent.targetIsUnchanged, intent.resolveSource(windowId: windowId, subject: subject) != nil else { return }
        try applySidebarPinDrop(windowId, subject: subject, gap: gap, monitorScopeId: monitorScopeId, section: section,
            projectId: projectId, pinGridIsShared: intent.pinGridIsShared)
        await updateWorkspaceSidebarModel()
    }
    if task == nil, let settlingId { finishWorkspaceSidebarDockLift(id: settlingId) }
    return task
}

/// Whether dragging `sourceNode` onto `section`'s pins changes a pin's scope: a whole pinned tab
/// from the other section's pins, or a tab pinned straight into All Projects.
@MainActor
private func sidebarDragChangesPinScope(_ sourceNode: TreeNode, to section: WorkspaceSidebarPinSection) -> Bool {
    guard let tab = sourceNode.nodeWorkspace else { return false }
    let movesPin = !workspaceTabDragLeavesWindowsBehind(sourceNode)
        && workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite == true
    return movesPin ? WorkspaceSidebarPinSection(of: tab) != section : section == .allProjects
}

/// The pin drop's changes, in the session it runs in. `section` is the pins it goes among, of
/// `projectId`, the project the list shows.
@MainActor
func applySidebarPinDrop(_ windowId: UInt32, subject: WindowDragSubject, gap: WorkspaceSidebarTabGap?,
                         monitorScopeId: String?, section: WorkspaceSidebarPinSection = .project,
                         projectId: WorkspaceProjectId? = nil, pinGridIsShared: Bool = workspaceSidebarPinGridIsShared()) throws {
    guard let sourceWindow = Window.get(byId: windowId) else { return }
    let sourceNode = dragSubjectNode(for: sourceWindow, subject: subject)
    // Pinning saves the tab; don't split a window out first when that can't be saved.
    if let reason = workspaceSidebarOrganizationStore.readOnlyReason ?? savedWorkspaceStore.readOnlyReason {
        showWorkspaceSidebarError(reason)
        return
    }
    // A display that's gone, or one a whole tab is held away from, refuses the drop before
    // anything changes. A window pulled out of a split gets a new tab, which may go anywhere.
    // Shared pins move no tab, so only a display that's gone refuses them.
    if let tab = sourceNode.nodeWorkspace {
        if !workspaceTabDragLeavesWindowsBehind(sourceNode) {
            try checkWorkspaceSidebarPinDropDisplay(tab, monitorScopeId: monitorScopeId, pinGridIsShared: pinGridIsShared)
        } else if case .gone = workspaceSidebarDropDisplay(for: tab, monitorScopeId: monitorScopeId) {
            throw WorkspaceMutationError.displayUnavailable
        }
    }
    suppressPostDragAxObserverEvents(for: sourceNode.allLeafWindowsRecursive.map(\.windowId))
    // If pinning can't be saved, everything goes back as it was, split, pins and all.
    try withWorkspaceSidebarDropTransaction {
        if sourceNode === sourceWindow, workspaceTabDragLeavesWindowsBehind(sourceNode) {
            // Pinned tabs leave their group, so the new tab never joins one: pinning is the
            // only organization write, and a failure leaves no stray membership behind.
            try detachWorkspaceTabWindow(sourceWindow, keepsGroup: false,
                destination: sidebarPinDropNewTabDestination(sourceWindow, section: section, monitorScopeId: monitorScopeId,
                    projectId: projectId))
        }
        guard let workspace = sourceNode.nodeWorkspace else { return true }
        let isPinned = workspaceSidebarOrganizationStore.state.workspaces[workspace.name]?.isFavorite == true
        // Into All Projects, or a pin back among the project's pins: still one write of the pins.
        let pin = {
            if section == .allProjects || isPinned && WorkspaceSidebarPinSection(of: workspace) != section {
                try setWorkspaceSidebarTabPinScope(workspace, section.scope, projectId: projectId ?? workspace.projectId, beside: gap)
            } else {
                try pinWorkspaceSidebarTab(workspace, beside: gap)
            }
        }
        // Pinned in All Projects before it comes to the list's display, which then stays in its project.
        if section == .allProjects { try pin() }
        // A window pulled out of a split keeps its new tab where it was made, among shared pins.
        if let monitor = workspaceSidebarPinDropDisplayChange(for: workspace, monitorScopeId: monitorScopeId,
            pinGridIsShared: pinGridIsShared) {
            syncClosedWindowsCacheToCurrentWorld()
            try moveWorkspaceTabToDisplay(workspace, monitor, focusing: sourceWindow)
        }
        if section != .allProjects { try pin() }
        return true
    }
}

/// Where a window pulled out of a split onto another project's own pins gets its new tab: in that
/// project, on the display whose list it was dropped on, so the display it came from stays in its
/// own. Its own project's pins, none named, or the pins in All Projects, which are no project's,
/// leave the new tab to be made where the window was, and to go where any tab dropped there goes.
@MainActor
private func sidebarPinDropNewTabDestination(_ window: Window, section: WorkspaceSidebarPinSection, monitorScopeId: String?,
                                             projectId: WorkspaceProjectId?) -> (projectId: WorkspaceProjectId, monitor: Monitor)? {
    guard section == .project, let source = window.nodeWorkspace, let projectId,
          projectId != workspaceContextProjectId(of: source) else { return nil }
    let monitor = monitorScopeId.flatMap { workspaceSidebarDropTargetMonitor(scopeId: $0, fallbackWindow: window) }
    return (projectId, monitor ?? source.workspaceMonitor)
}

/// A tab dropped on a group's header joins the group, as the whole tab it's in. A group on
/// another display's list brings the tab to that display too, as a drop between tabs does.
@MainActor
@discardableResult
private func groupSidebarSource(_ windowId: UInt32, collectionId: String, monitorScopeId: String?,
                                intent: WorkspaceSidebarDropIntent = .physical, settlingId: UUID?) -> Task<Void, Never>? {
    // The tab is the one the window was in at the release; the list's display goes with it,
    // so the session still brings it there if something moved it meanwhile.
    let tab = Window.get(byId: windowId)?.nodeWorkspace
    let task = runWorkspaceSidebarSession(undoTitle: "Move to Group") {
        defer { if let settlingId { finishWorkspaceSidebarDockLift(id: settlingId) } }
        try intent.checkDestination()
        guard let tab, intent.resolveSource(windowId: windowId, subject: .window) != nil else { return }
        try applySidebarGroupDrop(windowId, tab: tab, collectionId: collectionId, monitorScopeId: monitorScopeId)
        await updateWorkspaceSidebarModel()
    }
    if task == nil, let settlingId { finishWorkspaceSidebarDockLift(id: settlingId) }
    return task
}

/// The group drop's changes, in the session it runs in: the tab may have moved, closed, or lost
/// its group since the release. `tab` is the one the window was in then.
@MainActor
func applySidebarGroupDrop(_ windowId: UInt32, tab: Workspace, collectionId: String, monitorScopeId: String?) throws {
    guard config.usesBrowserTabs, let window = Window.get(byId: windowId), window.nodeWorkspace === tab,
          Workspace.existing(byName: tab.name) === tab,
          workspaceSidebarOrganizationStore.state.collections.contains(where: { $0.id == collectionId && $0.projectId == tab.projectId })
    else { return }
    // Before a move, a group that can't be saved leaves the tab where it is rather than moving it
    // and back. On its own display, grouping checks only the writes it needs, as it always has.
    if workspaceSidebarDropDisplayChange(for: tab, monitorScopeId: monitorScopeId) != nil,
       let reason = workspaceSidebarOrganizationStore.readOnlyReason {
        showWorkspaceSidebarError(reason)
        return
    }
    try withWorkspaceTabOnDropDisplay(tab, monitorScopeId: monitorScopeId, focusing: window) {
        try assignWorkspaceToSidebarCollection(tab, collectionId: collectionId)
    }
}

@MainActor
@discardableResult
private func moveSidebarSourceToNewWorkspace(
    _ windowId: UInt32,
    subject: WindowDragSubject,
    projectId: WorkspaceProjectId,
    monitorScopeId: String,
    intent: WorkspaceSidebarDropIntent = .physical,
    settlingId: UUID? = nil,
) -> Task<Void, Never>? {
    let task = runWorkspaceSidebarSession(undoTitle: "Move to New Tab") {
        defer { if let settlingId { finishWorkspaceSidebarDockLift(id: settlingId) } }
        try intent.checkDestination()
        guard let source = intent.resolveSource(windowId: windowId, subject: subject) else { return }
        let (sourceWindow, sourceNode) = (source.window, source.node)
        // The list's display, or none: a display that went away takes nothing.
        guard let targetMonitor = workspaceSidebarDropTargetMonitor(
            scopeId: monitorScopeId,
            fallbackWindow: sourceWindow,
            fallbackPoint: mouseLocation,
        ) else { throw WorkspaceMutationError.displayUnavailable }
        let workspace = workspaceForDropOnNewTab(projectId: projectId, monitor: targetMonitor, sourceWindow: sourceWindow)
        let targetContainer: NonLeafTreeNodeObject = sourceNode is Window && sourceWindow.isFloating
            ? workspace
            : workspace.rootTilingContainer
        syncClosedWindowsCacheToCurrentWorld()
        suppressPostDragAxObserverEvents(for: sourceNode.allLeafWindowsRecursive.map(\.windowId))
        sourceNode.bind(to: targetContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        await updateWorkspaceSidebarModel()
    }
    if task == nil, let settlingId { finishWorkspaceSidebarDockLift(id: settlingId) }
    return task
}

@MainActor
func previewWorkspaceSidebarDrop(_ windowId: UInt32, subject: WindowDragSubject, target: WorkspaceSidebarDropTargetKind,
                                 placement: WorkspaceSidebarTabDropPlacement? = nil,
                                 labelSlot: WorkspaceSidebarTabDropLabelSlot? = nil,
                                 owner: WorkspaceSidebarSurfaceRef?? = .none) {
    guard let sourceWindow = Window.get(byId: windowId) else {
        clearWorkspaceSidebarDropPreview()
        return
    }
    // Chosen tabs dragged together go where all of them can, even where the dragged one alone wouldn't move.
    let batch = currentActiveWorkspaceSidebarDrag()?.batch
    guard batch.map({ isActionableWorkspaceSidebarBatchDropTarget($0, target: target) })
        ?? isActionableSidebarDropTarget(sourceWindow: sourceWindow, subject: subject, target: target)
    else {
        clearWorkspaceSidebarDropPreview()
        return
    }
    if case .pinnedTabs(let projectId, let gap, let monitorScopeId, let section) = target {
        var preview = workspaceSidebarDropPreview(sourceWindow: sourceWindow, subject: subject,
            targetWorkspaceName: nil, targetsNewWorkspace: false, targetProjectId: projectId,
            targetMonitorScopeId: monitorScopeId)
        preview.targetsPinned = true
        preview.targetPinnedGap = gap
        preview.targetPinSection = section
        preview.changesPinScope = batch == nil
            ? sidebarDragChangesPinScope(dragSubjectNode(for: sourceWindow, subject: subject), to: section)
            : section == .allProjects
        setWorkspaceSidebarDropPreviewIfChanged(preview, owner: owner)
        return
    }
    if case .tabCollection(let id, let monitorScopeId) = target {
        var preview = workspaceSidebarDropPreview(sourceWindow: sourceWindow, subject: subject,
            targetWorkspaceName: nil, targetsNewWorkspace: false, targetProjectId: sourceWindow.nodeWorkspace?.projectId,
            targetMonitorScopeId: monitorScopeId)
        preview.targetCollectionId = id
        setWorkspaceSidebarDropPreviewIfChanged(preview, owner: owner)
        return
    }
    if case .tabGap(let projectId, let monitorScopeId, let gap) = target {
        var preview = workspaceSidebarDropPreview(sourceWindow: sourceWindow, subject: subject, targetWorkspaceName: nil,
            targetsNewWorkspace: false, targetProjectId: projectId, targetMonitorScopeId: monitorScopeId)
        preview.targetGap = gap
        // A batch moves whole tabs, so no window leaves its tab for a new one.
        preview.separatesFromTab = batch == nil && workspaceTabDragLeavesWindowsBehind(dragSubjectNode(for: sourceWindow, subject: subject))
        setWorkspaceSidebarDropPreviewIfChanged(preview, owner: owner)
        return
    }
    guard case .workspace(let workspaceName) = target else {
        if case .newWorkspace(let projectId, let monitorScopeId) = target {
            setWorkspaceSidebarDropPreviewIfChanged(workspaceSidebarDropPreview(
                sourceWindow: sourceWindow,
                subject: subject,
                targetWorkspaceName: nil,
                targetsNewWorkspace: true,
                targetProjectId: projectId,
                targetMonitorScopeId: monitorScopeId,
            ), owner: owner)
        } else {
            clearWorkspaceSidebarDropPreview()
        }
        return
    }
    var preview = workspaceSidebarDropPreview(
        sourceWindow: sourceWindow,
        subject: subject,
        targetWorkspaceName: workspaceName,
        targetsNewWorkspace: false,
        targetProjectId: nil,
    )
    preview.targetPlacement = placement
    preview.targetLabelSlot = placement == nil ? nil : labelSlot
    setWorkspaceSidebarDropPreviewIfChanged(preview, owner: owner)
}

@MainActor
func clearWorkspaceSidebarDropPreview() {
    setWorkspaceSidebarDropPreviewIfChanged(nil)
}

@MainActor
func workspaceSidebarSourcePreview(sourceWindow: Window, subject: WindowDragSubject) -> WorkspaceSidebarDropPreviewViewModel {
    workspaceSidebarDropPreview(
        sourceWindow: sourceWindow,
        subject: subject,
        targetWorkspaceName: nil,
        targetsNewWorkspace: false,
    )
}

@MainActor
func showWorkspaceSidebarDragCursorPreview(sourceWindow: Window, subject: WindowDragSubject, point: CGPoint) {
    WindowDragCursorProxyPanel.shared.show(
        preview: workspaceSidebarSourcePreview(sourceWindow: sourceWindow, subject: subject),
        mouseScreenPoint: denormalizedAppKitScreenPoint(point),
        style: currentActiveWorkspaceSidebarDrag()?.previewStyle ?? .row,
    )
}

func denormalizedAppKitScreenPoint(_ point: CGPoint) -> CGPoint {
    normalizeAppKitScreenPoint(point)
}

@MainActor
private func isActionableSidebarDropTarget(
    sourceWindow: Window,
    subject: WindowDragSubject,
    target: WorkspaceSidebarDropTargetKind,
    pinGridIsShared: Bool = workspaceSidebarPinGridIsShared(),
) -> Bool {
    let sourceNode = dragSubjectNode(for: sourceWindow, subject: subject)
    let sourceWorkspaceName = sourceNode.nodeWorkspace?.name
    // A whole tab dropped where it already is stays put; don't promise a move. A window
    // pulled out of its tab does get a new tab there.
    if case .tabGap(let projectId, let monitorScopeId, let gap) = target, !workspaceTabDragLeavesWindowsBehind(sourceNode),
       let tab = sourceNode.nodeWorkspace,
       workspaceTabGapKeepsTabInPlace(tab, projectId: projectId, monitorScopeId: monitorScopeId, gap: gap)
        || !workspaceSidebarDropCanReachDisplay(tab, monitorScopeId: monitorScopeId) { return false }
    if case .pinnedTabs(let projectId, let gap, let monitorScopeId, let section) = target {
        // A window pulled out of a split gets a pinned tab of its own; a whole tab is pinned
        // unless it already is, and a pinned one moves beside another pin, or to the other
        // section's pins. From another display, the tab also moves to the display whose pins these
        // are, if it may go there; shared pins take it nowhere.
        // Pins in All Projects are no project's, so a tab from another display's list may go there too.
        guard config.usesBrowserTabs, let workspace = sourceNode.nodeWorkspace,
              section == .allProjects || workspaceIsListed(workspace, inProject: projectId) else { return false }
        if workspaceTabDragLeavesWindowsBehind(sourceNode) {
            // It gets a new tab of its own, which may go to any display that's still there.
            if case .gone = workspaceSidebarDropDisplay(for: workspace, monitorScopeId: monitorScopeId) { return false }
            return true
        }
        guard workspaceSidebarPinDropCanReachDisplay(workspace, monitorScopeId: monitorScopeId,
            pinGridIsShared: pinGridIsShared) else { return false }
        // A split is pinned only from its menu, never by dragging it onto the pins.
        if workspaceSidebarOrganizationStore.state.workspaces[workspace.name]?.isFavorite != true {
            return sourceNode.allLeafWindowsRecursive.count <= 1
        }
        return WorkspaceSidebarPinSection(of: workspace) != section
            || gap.flatMap { workspacePinnedTabOrder(moving: workspace, beside: $0) } != nil
            || workspaceSidebarPinDropDisplayChange(for: workspace, monitorScopeId: monitorScopeId,
                pinGridIsShared: pinGridIsShared) != nil
    }
    if case .tabCollection(let id, let monitorScopeId) = target {
        guard config.usesBrowserTabs, let workspace = sourceWindow.nodeWorkspace,
              let group = workspaceSidebarOrganizationStore.state.collections.first(where: { $0.id == id }),
              group.projectId == workspace.projectId,
              workspaceSidebarDropCanReachDisplay(workspace, monitorScopeId: monitorScopeId) else { return false }
        return !group.workspaceNames.contains(workspace.name)
            || workspaceSidebarDropDisplayChange(for: workspace, monitorScopeId: monitorScopeId) != nil
    }
    // A pin lending its window, or a pinned split, takes no split and no window.
    if case .workspace(let name) = target, let workspace = Workspace.existing(byName: name),
       !workspaceSidebarTakesSplit(workspace) { return false }
    return isActionableSidebarWorkspaceDropTarget(sourceWorkspaceName: sourceWorkspaceName, targetKind: target)
}

@MainActor
private func workspaceSidebarDropPreview(
    sourceWindow: Window,
    subject: WindowDragSubject,
    targetWorkspaceName: String?,
    targetsNewWorkspace: Bool,
    targetProjectId: WorkspaceProjectId? = nil,
    targetMonitorScopeId: String? = nil,
) -> WorkspaceSidebarDropPreviewViewModel {
    let moveNode = dragSubjectNode(for: sourceWindow, subject: subject)
    let isTabGroup = moveNode is TilingContainer
    let sourceLabel = sidebarDragSourceTitle(for: sourceWindow, subject: subject)
    let appName = sourceWindow.app.name ?? sourceWindow.app.rawAppBundleId ?? "Window"
    let preview = WorkspaceSidebarDropPreviewViewModel(
        sourceWindowId: sourceWindow.windowId,
        label: sourceLabel,
        appName: appName,
        appBundleIdentifier: sourceWindow.app.rawAppBundleId,
        appBundlePath: sourceWindow.app.bundlePath,
        targetWorkspaceName: targetWorkspaceName,
        targetsNewWorkspace: targetsNewWorkspace,
        targetProjectId: targetProjectId,
        targetMonitorScopeId: targetMonitorScopeId,
        isTabGroup: isTabGroup,
        windowCount: max(moveNode.allLeafWindowsRecursive.count, 1),
        tabItems: workspaceSidebarDropPreviewTabs(for: moveNode, isTabGroup: isTabGroup),
    )
    // Chosen tabs dragged together read as their count.
    return currentActiveWorkspaceSidebarDrag()?.batch.map { $0.preview(preview) } ?? preview
}

@MainActor
private func workspaceSidebarDropPreviewTabs(
    for moveNode: TreeNode,
    isTabGroup: Bool,
) -> [WorkspaceSidebarDropPreviewTabItem] {
    guard isTabGroup else { return [] }
    return moveNode.allLeafWindowsRecursive.map { window in
        let appName = window.app.name ?? window.app.rawAppBundleId ?? "Window"
        return WorkspaceSidebarDropPreviewTabItem(
            title: cachedWindowTitle(for: window)?.takeIf { $0 != appName } ?? appName,
            appName: appName,
            appBundleIdentifier: window.app.rawAppBundleId,
            appBundlePath: window.app.bundlePath,
        )
    }
}

@MainActor
@discardableResult
func selectWorkspaceSidebarProject(
    _ projectId: WorkspaceProjectId,
    viewModel: TrayMenuModel = TrayMenuModel.shared,
    targetMonitorScopeId: String? = nil,
) -> Task<Void, Never>? {
    let knownProjects = workspaceProjects()
    let resolvedTargetScopeId = targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId
    debugWorkspaceSidebarProjectLog(
        "selectProjectBegin project=\(projectId.rawValue) known=\(knownProjects.map(\.id.rawValue)) targetScope=\(resolvedTargetScopeId) activeBefore=\(viewModel.workspaceSidebarActiveProjectId.rawValue)"
    )
    guard knownProjects.contains(where: { $0.id == projectId }) else {
        debugWorkspaceSidebarProjectLog("selectProjectAbort unknownProject=\(projectId.rawValue)")
        return nil
    }
    return runWorkspaceSidebarSession {
        let monitor = workspaceSidebarTargetMonitor(
            scopeId: targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId
        )
        debugWorkspaceSidebarProjectLog(
            "selectProjectSession project=\(projectId.rawValue) monitor=\(monitor.monitorAppKitNsScreenScreensId) visibleBefore=\(monitor.activeWorkspace.name) activeProjectBefore=\(activeWorkspaceProjectId(for: monitor).rawValue)"
        )
        if let workspace = switchWorkspaceProject(projectId, on: monitor) {
            debugWorkspaceSidebarProjectLog(
                "selectProjectSwitchResult project=\(projectId.rawValue) workspace=\(workspace.name) workspaceProject=\(workspace.projectId.rawValue)"
            )
            _ = workspace.focusWorkspace()
            viewModel.workspaceSidebarActiveProjectId = projectId
        } else {
            debugWorkspaceSidebarProjectLog("selectProjectSwitchResult project=\(projectId.rawValue) workspace=nil")
        }
        await updateWorkspaceSidebarModel()
        debugWorkspaceSidebarProjectLog(
            "selectProjectEnd project=\(projectId.rawValue) activeAfter=\(viewModel.workspaceSidebarActiveProjectId.rawValue)"
        )
    }
}

@MainActor
func createWorkspaceSidebarProject(
    viewModel: TrayMenuModel = TrayMenuModel.shared,
    targetMonitorScopeId: String? = nil,
) {
    runWorkspaceSidebarSession {
        let project = createWorkspaceProject()
        let monitor = workspaceSidebarTargetMonitor(
            scopeId: targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId
        )
        if let workspace = switchWorkspaceProject(project.id, on: monitor) {
            _ = workspace.focusWorkspace()
            viewModel.workspaceSidebarActiveProjectId = project.id
        }
        await updateWorkspaceSidebarModel()
    }
}

@MainActor
func renameWorkspaceSidebarProject(_ projectId: WorkspaceProjectId, displayName: String) {
    runWorkspaceSidebarSession {
        try renameWorkspaceProject(projectId, displayName: displayName)
        await updateWorkspaceSidebarModel()
    }
}

@MainActor
func moveWorkspaceSidebarProject(_ projectId: WorkspaceProjectId, relativeTo targetId: WorkspaceProjectId, after: Bool) {
    runWorkspaceSidebarSession {
        guard try moveWorkspaceProject(projectId, relativeTo: targetId, after: after) else { return }
        await updateWorkspaceSidebarModel()
    }
}

@MainActor
func setWorkspaceSidebarProjectColor(_ project: WorkspaceSidebarProjectViewModel, colorHex: String?) {
    runWorkspaceSidebarSession {
        try setWorkspaceProjectColor(project.id, colorHex: colorHex)
        await updateWorkspaceSidebarModel()
    }
}

@MainActor
func deleteWorkspaceSidebarProject(
    _ project: WorkspaceSidebarProjectViewModel,
    viewModel: TrayMenuModel = TrayMenuModel.shared,
) {
    guard canDeleteWorkspaceProject(project.id) else { return }
    guard confirmWorkspaceSidebarProjectDeletion(project) else { return }
    runWorkspaceSidebarSession {
        try await deleteWorkspaceProjectFromSidebar(project.id)
        await updateWorkspaceSidebarModel()
    }
}

@MainActor
private func confirmWorkspaceSidebarProjectDeletion(_ project: WorkspaceSidebarProjectViewModel) -> Bool {
    let windowCount = windowsInWorkspaceProject(project.id).count
    guard windowCount > 0 else { return true }

    let alert = NSAlert()
    switch config.workspaceSidebar.projectDeletionAction {
        case .closeWindows:
            alert.messageText = "Close Project Windows?"
            alert.informativeText = """
            WinMux will ask macOS to close \(windowCount) window\(windowCount == 1 ? "" : "s") in “\(project.displayName)”. Apps may show their own confirmation dialogs for unsaved work. If any window stays open, WinMux will keep the project.
            """
            alert.addButton(withTitle: "Close Project")
        case .moveWindowsToFallback:
            alert.messageText = "Delete Project?"
            alert.informativeText = """
            WinMux will delete “\(project.displayName)” and move \(windowCount) window\(windowCount == 1 ? "" : "s") to another project.
            """
            alert.addButton(withTitle: "Delete Project")
    }
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    return alert.runModal() == .alertFirstButtonReturn
}

@MainActor
func renameWorkspaceFromSidebar(_ workspaceName: String, displayName: String) {
    debugWorkspaceSidebarRenameLog("renameWorkspaceFromSidebar workspace=\(workspaceName) displayName=\(displayName)")
    runWorkspaceSidebarSession {
        try renameWorkspaceForSidebar(workspaceName: workspaceName, displayName: displayName)
        await updateWorkspaceSidebarModel()
    }
}

@MainActor
@discardableResult
func saveWorkspaceFromSidebar(_ workspaceName: String) -> Task<Void, Never>? {
    runWorkspaceSidebarSession {
        try saveWorkspaceForSidebar(workspaceName: workspaceName, displayName: nil)
        await updateWorkspaceSidebarModel()
    }
}

@MainActor
@discardableResult
func forgetSavedWorkspaceFromSidebar(_ workspaceName: String, targetMonitorScopeId: String? = nil) -> Task<Void, Never>? {
    runWorkspaceSidebarSession {
        // Forgetting unpins: a pin in All Projects stays a tab of the project the sidebar shows, as
        // unpinning it does, rather than of its home, which would hide it there.
        if let tab = Workspace.existing(byName: workspaceName), workspaceIsPinnedInAllProjects(tab) {
            let projectId = workspaceSidebarContextProjectId(for: tab, targetMonitorScopeId: targetMonitorScopeId)
            _ = try withWorkspaceSidebarDropTransaction {
                if tab.projectId != projectId,
                   !moveWorkspaceToProject(workspaceName: workspaceName, projectId: projectId, syncsSavedRecord: true) { return false }
                try forgetSavedWorkspaceForSidebar(workspaceName: workspaceName)
                return true
            }
        } else {
            try forgetSavedWorkspaceForSidebar(workspaceName: workspaceName)
        }
        await updateWorkspaceSidebarModel()
    }
}

@MainActor
@discardableResult
func setSavedWorkspacePinnedFromSidebar(_ workspaceName: String, pinned: Bool) -> Task<Void, Never>? {
    runWorkspaceSidebarSession {
        try setSavedWorkspacePinnedForSidebar(workspaceName: workspaceName, pinned: pinned)
        await updateWorkspaceSidebarModel()
    }
}

/// Launching can take seconds, so this doesn't hold a session open. Each launch refreshes the
/// sidebar, and the new windows return to their slots through normal window detection.
@MainActor
@discardableResult
func openSavedWorkspaceAppsFromSidebar(_ workspaceName: String) -> Task<SavedWorkspaceAppLaunchResult, Never>? {
    guard TrayMenuModel.shared.isEnabled else { return nil }
    return Task { @MainActor in
        let result = await openMissingSavedWorkspaceApps(workspaceNames: [workspaceName])
        if !result.failed.isEmpty {
            showWorkspaceSidebarError("Couldn't open \(result.failed.joined(separator: ", ")).")
        }
        return result
    }
}

/// A saved tab whose windows are gone, clicked: it comes to the screen, then its apps open into
/// it. An app that quit relaunches, and its windows return to their saved places, this tab's
/// first. Otherwise, a running app or one whose saved windows have expired, the app is asked
/// for a new window in this tab, as the launcher asks. A running app with no window at all is
/// opened again, as a Dock click does, and the window it shows comes to this tab.
@MainActor
func openSavedTabFromSidebar(_ name: String, targetMonitorScopeId: String? = nil) {
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    var opened: Workspace?
    runWorkspaceSidebarSession(afterLayout: {
        guard let opened, winMuxWorkspaceState.workspaceById[opened.id] === opened,
              !workspaceHasLifecycleWindows(opened) else { return }
        openSavedTabApps(opened)
    }) {
        guard let workspace = Workspace.existing(byName: name),
              focusWorkspaceFromSidebar(workspace, targetMonitorScopeId: targetMonitorScopeId) else { return }
        opened = workspace
    }
}

@MainActor
func openSavedTabApps(_ tab: Workspace, requestNewWindow: @MainActor (NewWindowRequestTarget, Workspace) -> Void = { target, tab in
    requestNewWindow(target, targetWorkspace: tab, reopensWindowlessApp: true) { outcome in
        if let message = savedTabAppFailureMessage(outcome, appName: target.appName) { showWorkspaceSidebarError(message) }
    }
}) {
    let apps = workspaceSidebarDistinctSavedApps(workspaceSidebarSavedApps(for: tab))
    let runningApps = savedWorkspaceRuntime.environment.runningApps()
    let waiting = Set(savedWorkspaceStore.record(named: tab.name)?.layout.allSlots.map(\.bundleId) ?? [])
    var relaunches = false
    for app in apps {
        if runningApps[app.bundleId] == nil, waiting.contains(app.bundleId) {
            savedWorkspaceRuntime.preferRestoring(bundleId: app.bundleId, into: tab.name)
            relaunches = true
        } else {
            // An app WinMux can only launch opens its window in the tab on screen, so saved
            // routing mustn't send it to another tab's saved place first.
            if runningApps[app.bundleId] == nil, newWindowMethod(bundleId: app.bundleId, isRunning: false,
                menuFallbackEnabled: config.workspaceSidebar.launcherMenuFallback) == .open {
                savedWorkspaceRuntime.preferRestoring(bundleId: app.bundleId, into: tab.name, bypassingRouting: true)
            }
            requestNewWindow(NewWindowRequestTarget(bundleId: app.bundleId, appName: app.name,
                bundleURL: app.bundlePath.map { URL(fileURLWithPath: $0) }), tab)
        }
    }
    if relaunches { openSavedWorkspaceAppsFromSidebar(tab.name) }
}

/// What a saved tab says when its app gave it no window: only once the app was really asked, and
/// never for a request that was withdrawn or that a newer click took over.
func savedTabAppFailureMessage(_ outcome: NewWindowRequestOutcome, appName: String) -> String? {
    switch outcome {
        case .failed(let reason): reason
        case .timedOut: "\(appName) didn't open a window."
        case .placed, .opened, .cancelled: nil
    }
}

@MainActor
func deleteWorkspaceFromSidebar(_ workspace: WorkspaceSidebarWorkspaceViewModel) {
    runWorkspaceSidebarSession {
        try deleteWorkspaceForSidebar(workspaceName: workspace.name)
        await updateWorkspaceSidebarModel()
    }
}

@MainActor
func focusWindowFromSidebar(_ windowId: UInt32, targetMonitorScopeId: String? = nil) {
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    runWorkspaceSidebarSession {
        guard let window = Window.get(byId: windowId), window.toLiveFocusOrNil() != nil else {
            if let fallbackName = workspaceSidebarFallbackWorkspaceName(for: windowId),
               let fallbackWorkspace = Workspace.existing(byName: fallbackName) {
                _ = focusWorkspaceFromSidebar(fallbackWorkspace, targetMonitorScopeId: targetMonitorScopeId)
            }
            return
        }
        _ = focusWindowFromSidebar(window, targetMonitorScopeId: targetMonitorScopeId)
    }
}

/// Selecting a split member keeps the same display-placement rules as selecting
/// the whole workspace, then focuses that member within the single layout session.
@MainActor
@discardableResult
func focusWindowFromSidebar(_ window: Window, targetMonitorScopeId: String?) -> Bool {
    guard let liveFocus = window.toLiveFocusOrNil() else { return false }
    if let targetMonitorScopeId,
       !focusWorkspaceFromSidebar(liveFocus.workspace, targetMonitorScopeId: targetMonitorScopeId) { return false }
    _ = setFocus(to: liveFocus)
    window.nativeFocus()
    return true
}

@MainActor
func workspaceSidebarFallbackWorkspaceName(for windowId: UInt32) -> String? {
    for workspace in TrayMenuModel.shared.workspaceSidebarWorkspaces {
        for item in workspace.items {
            switch item.kind {
                case .window(let window) where window.windowId == windowId:
                    return window.workspaceName
                case .tabGroup(let group) where group.representativeWindowId == windowId:
                    return group.workspaceName
                case .tabGroup(let group):
                    if group.tabs.contains(where: { $0.windowId == windowId }) {
                        return group.workspaceName
                    }
                case .window:
                    continue
            }
        }
    }
    return nil
}

@MainActor
func updateSidebarWindowDrag(_ windowId: UInt32, subject: WindowDragSubject = .window, pointer: CGPoint? = nil, previewStyle: WorkspaceSidebarDragPreviewStyle = .row) {
    // A cancelled or released gesture's late updates do nothing, before any side effect.
    guard WorkspaceSidebarDragSessions.shared.acceptUpdate() else { return }
    if let pointer {
        MousePointerTracker.shared.note(point: pointer)
        postWorkspaceSidebarDragPointerNotification(workspaceSidebarDragPointerChangedNotification, pointer: pointer)
    }
    guard let window = Window.get(byId: windowId) else {
        clearWorkspaceSidebarDropPreview()
        clearPendingWindowDragIntent()
        WindowDragCursorProxyPanel.shared.hide()
        clearActiveWorkspaceSidebarDrag()
        return
    }
    debugWorkspaceSidebarCrossDisplayDragLog(workspaceSidebarCrossDisplayDragDescription(
        event: "gesture", point: MousePointerTracker.shared.currentSample.point))
    beginActiveWorkspaceSidebarDrag(windowId: window.windowId, subject: subject, previewStyle: previewStyle)
    beginWorkspaceSidebarDockLift(source: window)
    let point = MousePointerTracker.shared.currentSample.point
    updateActiveWorkspaceSidebarDragPreview(sourceWindow: window, subject: subject)
    beginWindowMoveWithMouseSessionIfNeeded(
        windowId: window.windowId,
        subject: subject,
        detachOrigin: .window,
        startedInSidebar: true,
        anchorRect: resolvedDraggedWindowAnchorRect(for: window, subject: subject),
        refreshActualRects: true,
    )
    WindowMouseInteractionDriver.shared.startMove(
        windowId: window.windowId,
        subject: subject,
        detachOrigin: .window,
        startedInSidebar: true,
    )
    _ = updatePendingWindowDragIntent(
        sourceWindow: window,
        mouseLocation: point,
        subject: subject,
        detachOrigin: .window,
    )
    WorkspaceSidebarDropDestinationController.shared.noteDragUpdate()
}

@MainActor
func finishSidebarWindowDrag(pointer: CGPoint? = nil) {
    if let pointer {
        MousePointerTracker.shared.note(point: pointer)
        postWorkspaceSidebarDragPointerNotification(workspaceSidebarDragPointerEndedNotification, pointer: pointer)
    }
    // The release is consumed once: the gesture's end and the mouse-up cleanup both get here. The
    // second finds its press's drag over, released or cancelled, and has nothing left to do.
    let endedBefore = WorkspaceSidebarDragSessions.shared.hasEndedThisPress
    let release = WorkspaceSidebarDragSessions.shared.consumeRelease()
    if release == nil, endedBefore { return }
    let didCommitSidebarDrop = release != nil && commitActiveWorkspaceSidebarDragIfPossible()
    if didCommitSidebarDrop { noteWorkspaceSidebarConsumedRelease() }
    // Released over the Tabs sidebar, or over temporary drop UI, where it showed no drop: nothing
    // moves. The window drag's last frame must not find a target of its own there.
    let surface = workspaceSidebarSurface(at: MousePointerTracker.shared.currentSample.point)?.surface
    let releasedWithoutSidebarDrop = !didCommitSidebarDrop && workspaceSidebarOwnsDrag(
        usesBrowserTabs: config.usesBrowserTabs,
        startedInSidebar: getCurrentMouseDragStartedInSidebar(),
        hasActiveSidebarDrag: currentActiveWorkspaceSidebarDrag() != nil,
        isPointerInSidebar: surface != nil, isPointerOnTemporarySurface: surface?.isTemporary == true,
        carriesBatch: workspaceSidebarDragCarriesBatch())
    if release != nil, releasedWithoutSidebarDrop, surface?.isTemporary == true { noteWorkspaceSidebarConsumedRelease() }
    // The release is captured: the other displays' hints and list go. A release outside them keeps
    // the window drag's pending drop for the screen.
    WorkspaceSidebarDropDestinationController.shared.end()
    clearActiveWorkspaceSidebarDrag()
    if didCommitSidebarDrop || releasedWithoutSidebarDrop {
        clearPendingWindowDragIntent()
        cancelManipulatedWithMouseState()
        scheduleRefreshSession(.resetManipulatedWithMouse, optimisticallyPreLayoutWorkspaces: true)
        if releasedWithoutSidebarDrop {
            clearWorkspaceSidebarDropPreview()
            WindowDragCursorProxyPanel.shared.hide()
        }
        return
    }
    Task { @MainActor in
        try? await resetManipulatedWithMouseIfPossible()
    }
    clearWorkspaceSidebarDropPreview()
    WindowDragCursorProxyPanel.shared.hide()
}

/// Where a drag event was and which panels it involved, for the cross-display drag log.
@MainActor
func workspaceSidebarCrossDisplayDragDescription(event: String, point: CGPoint) -> String {
    let source = currentWorkspaceSidebarDragSourceScopeId()
    let sourcePanel = source.flatMap { WorkspaceSidebarPanel.panel(for: $0) }
    let under = workspaceSidebarSurface(at: point)?.surface.ownerId
    return "\(event) point=\(point) source=\(source ?? "nil") sourceIgnoresMouse=\(sourcePanel?.ignoresMouseEvents.description ?? "nil")"
        + " underPointer=\(under ?? "nil") crossesDisplay=\(under != nil && source != nil && under != source)"
}

@MainActor
func finishWorkspaceSidebarDragAfterMouseUp() {
    finishActiveSidebarPinnedTabDrag()
    let hasSidebarDragState = currentActiveWorkspaceSidebarDrag() != nil || isWorkspaceSidebarItemDragActive()
    let hasCursorProxy = WindowDragCursorProxyPanel.shared.currentContent != nil || WindowDragCursorProxyPanel.shared.isVisible
    guard hasSidebarDragState || hasCursorProxy else { return }
    noteCurrentMousePointerSample()
    finishSidebarWindowDrag()
    resetWorkspaceSidebarItemDrag()
}

@MainActor
private func postWorkspaceSidebarDragPointerNotification(_ name: Notification.Name, pointer: CGPoint) {
    NotificationCenter.default.post(
        name: name,
        object: nil,
        userInfo: [workspaceSidebarDragPointerUserInfoKey: NSValue(point: pointer)]
    )
}

@MainActor
private func workspaceSidebarDragTarget(for sourceWindow: Window, subject: WindowDragSubject, committing: Bool = false,
                                       pinGridIsShared: Bool = workspaceSidebarPinGridIsShared()) -> WorkspaceSidebarDropTarget? {
    // Drag events can be sparse; a preview between them, such as the split's pause check, uses
    // where the pointer really is, for the target, the pause, and the side alike.
    if !committing { MousePointerTracker.shared.note(point: mouseLocation) }
    let point = MousePointerTracker.shared.currentSample.point
    guard let target = workspaceSidebarSurfaceHit(at: point).target else {
        WorkspaceSidebarTabSplitHoverController.shared.reset()
        return nil
    }
    // Chosen tabs dragged together never pause into a split: over a tab they go beside it.
    if let batch = currentActiveWorkspaceSidebarDrag()?.batch {
        let resolved = committing
            ? WorkspaceSidebarTabSplitHoverController.shared.commitTarget(source: sourceWindow.windowId, hitTarget: target, point: point)
            : workspaceSidebarBatchDropTarget(target, point: point)
        guard let resolved, isActionableWorkspaceSidebarBatchDropTarget(batch, target: resolved.kind, pinGridIsShared: pinGridIsShared)
        else { return nil }
        return resolved
    }
    let resolved = committing && config.usesBrowserTabs
        ? WorkspaceSidebarTabSplitHoverController.shared.commitTarget(source: sourceWindow.windowId, hitTarget: target, point: point)
        : workspaceSidebarDeliberateTabDropTarget(target, sourceWindow: sourceWindow, point: point)
    guard let resolved, isActionableSidebarDropTarget(sourceWindow: sourceWindow, subject: subject, target: resolved.kind,
        pinGridIsShared: pinGridIsShared)
    else { return nil }
    return resolved
}

/// Tabs mode: the side of the tab under the pointer, or a stack while Option is held. Only a
/// target drawn as a tab takes a side; a folder takes a dropped tab as it always has. A stack
/// is offered only where one can be made, so the preview never promises what the drop won't do.
@MainActor
private func workspaceSidebarTabDropPlacement(for target: WorkspaceSidebarDropTarget, sourceWindow: Window,
                                              subject: WindowDragSubject) -> WorkspaceSidebarTabDropPlacement? {
    // A floating window stays floating wherever it goes, so it can't go beside another.
    guard target.acceptsSides, !sourceWindow.isFloating, case .workspace(let name) = target.kind else { return nil }
    let targetWindow = Workspace.existing(byName: name).flatMap(workspaceTabDropTargetWindow)
    let canStack = targetWindow.map { !$0.isFloating } == true
    return workspaceSidebarTabDropPlacement(pointX: MousePointerTracker.shared.currentSample.point.x,
        targetMidX: target.rect.center.x, subject: subject,
        optionHeld: canStack && NSEvent.modifierFlags.contains(.option))
}

@MainActor
func refreshActiveWorkspaceSidebarDragPreviewIfNeeded() {
    guard let activeDrag = currentActiveWorkspaceSidebarDrag(),
          let sourceWindow = Window.get(byId: activeDrag.windowId)
    else { return }
    updateActiveWorkspaceSidebarDragPreview(sourceWindow: sourceWindow, subject: activeDrag.subject)
}

@MainActor
private func updateActiveWorkspaceSidebarDragPreview(sourceWindow: Window, subject: WindowDragSubject) {
    showWorkspaceSidebarDragCursorPreview(
        sourceWindow: sourceWindow,
        subject: subject,
        point: MousePointerTracker.shared.currentSample.point
    )
    guard let target = workspaceSidebarDragTarget(for: sourceWindow, subject: subject) else {
        WorkspaceSidebarTabSplitHoverController.shared.clearDisplayed()
        clearWorkspaceSidebarDropPreview()
        return
    }
    let placement = workspaceSidebarTabDropPlacement(for: target, sourceWindow: sourceWindow, subject: subject)
    let current = TrayMenuModel.shared.workspaceSidebarDropPreview
    let labelSlot = placement.map { placement in
        workspaceSidebarTabDropLabelSlot(pointX: MousePointerTracker.shared.currentSample.point.x,
            targetMinX: target.rect.minX, targetMaxX: target.rect.maxX, placement: placement,
            labelWidth: workspaceSidebarTabDropLabelWidth(workspaceSidebarTabDropLabelText(placement)),
            clearance: workspaceSidebarDragImageHalfWidth(currentActiveWorkspaceSidebarDrag()?.previewStyle ?? .row) + 4,
            previous: current?.targetPlacement == placement && current?.targetWorkspaceName != nil
                ? current?.targetLabelSlot : nil)
    } ?? nil
    previewWorkspaceSidebarDrop(sourceWindow.windowId, subject: subject, target: target.kind, placement: placement,
        labelSlot: labelSlot, owner: target.surface)
    if config.usesBrowserTabs, TrayMenuModel.shared.workspaceSidebarDropPreview != nil,
       let hit = workspaceSidebarDropTarget(at: MousePointerTracker.shared.currentSample.point) {
        // The preview was made under the pin rule of now; its drop keeps that rule.
        WorkspaceSidebarTabSplitHoverController.shared.noteDisplayed(source: sourceWindow.windowId, hitKind: hit.kind,
            target: target, placement: placement, pinGridIsShared: workspaceSidebarPinGridIsShared())
    } else { WorkspaceSidebarTabSplitHoverController.shared.clearDisplayed() }
}

@MainActor
private func commitActiveWorkspaceSidebarDragIfPossible() -> Bool {
    guard let activeDrag = currentActiveWorkspaceSidebarDrag(),
          let sourceWindow = Window.get(byId: activeDrag.windowId)
    else {
        clearWorkspaceSidebarDropPreview()
        WindowDragCursorProxyPanel.shared.hide()
        return false
    }
    // The pin rule the drop was shown with goes with it. A drop on pin tiles shown under one rule
    // isn't made under another: the setting changed since, and what it showed no longer holds.
    let pinGridIsShared = WorkspaceSidebarTabSplitHoverController.shared.displayedPinGridIsShared(source: sourceWindow.windowId)
        ?? workspaceSidebarPinGridIsShared()
    guard let target = workspaceSidebarDragTarget(for: sourceWindow, subject: activeDrag.subject, committing: true,
              pinGridIsShared: pinGridIsShared),
          !target.kind.isPinTiles || pinGridIsShared == workspaceSidebarPinGridIsShared()
    else {
        clearWorkspaceSidebarDropPreview()
        WindowDragCursorProxyPanel.shared.hide()
        return false
    }
    // A list that closed before the release takes nothing: its drop can't be checked any more.
    guard var intent = WorkspaceSidebarDropIntent.captured(for: target,
        source: .init(window: sourceWindow, subject: activeDrag.subject)) else {
        clearWorkspaceSidebarDropPreview()
        WindowDragCursorProxyPanel.shared.hide()
        return false
    }
    intent.pinGridIsShared = pinGridIsShared
    let placement = workspaceSidebarTabDropPlacement(for: target, sourceWindow: sourceWindow, subject: activeDrag.subject)
    previewWorkspaceSidebarDrop(sourceWindow.windowId, subject: activeDrag.subject, target: target.kind, placement: placement,
        owner: target.surface)
    let settlingId = settleWorkspaceSidebarDockLift()
    clearWorkspaceSidebarDropPreview()
    WindowDragCursorProxyPanel.shared.hide()
    if case .monitor = target.kind { return false }
    if let batch = activeDrag.batch {
        queueWorkspaceSidebarBatchDrop(batch, target: target.kind, intent: intent, settlingId: settlingId)
        return true
    }
    queueWorkspaceSidebarDrop(sourceWindow.windowId, subject: activeDrag.subject, target: target.kind,
        placement: placement, intent: intent, settlingId: settlingId)
    return true
}

/// Queues the drop a release chose, as the release captured it. Returns its session, if one runs.
@MainActor
@discardableResult
func queueWorkspaceSidebarDrop(_ windowId: UInt32, subject: WindowDragSubject, target: WorkspaceSidebarDropTargetKind,
                               placement: WorkspaceSidebarTabDropPlacement?, intent: WorkspaceSidebarDropIntent,
                               settlingId: UUID? = nil) -> Task<Void, Never>? {
    switch target {
        case .tabCollection(let id, let monitorScopeId):
            groupSidebarSource(windowId, collectionId: id, monitorScopeId: monitorScopeId, intent: intent,
                settlingId: settlingId)
        case .pinnedTabs(let projectId, let gap, let monitorScopeId, let section):
            pinSidebarSource(windowId, subject: subject, gap: gap, monitorScopeId: monitorScopeId, section: section,
                projectId: projectId, intent: intent, settlingId: settlingId)
        case .workspace(let workspaceName):
            moveSidebarSource(windowId, subject: subject,
                toWorkspace: workspaceName, tabPlacement: placement, intent: intent, settlingId: settlingId)
        case .newWorkspace(let projectId, let monitorScopeId):
            moveSidebarSourceToNewWorkspace(windowId, subject: subject,
                projectId: projectId, monitorScopeId: monitorScopeId, intent: intent, settlingId: settlingId)
        case .tabGap(let projectId, let monitorScopeId, let gap):
            moveSidebarSourceToTabGap(windowId, subject: subject, projectId: projectId,
                monitorScopeId: monitorScopeId, gap: gap, intent: intent, settlingId: settlingId)
        case .monitor:
            nil
    }
}
