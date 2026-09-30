import AppKit
import Common

// In Tabs mode the sidebar works like a browser's tab list: each workspace is a tab, new
// windows and New Tab open one right after the current tab, and a tab that ends up empty
// closes.

/// A blank workspace placed right after `anchor` in its project, like a browser's new tab.
@MainActor
func createWorkspace(after anchor: Workspace?, projectId: WorkspaceProjectId, monitor: Monitor) -> Workspace {
    let workspace = createBlankWorkspace(projectId: projectId, monitor: monitor)
    if let anchor, anchor !== workspace, anchor.projectId == projectId {
        winMuxWorkspaceState.moveWorkspace(workspace.id, after: anchor.id)
    }
    return workspace
}

/// Windows an app opens in a burst from one tab line up after it in the order they opened,
/// as links opened from a browser tab do.
private let workspaceTabOpeningBurst: TimeInterval = 2
@MainActor private var lastTabOpenedFrom: [WorkspaceId: (tab: WorkspaceId, uptime: TimeInterval)] = [:]

/// The tab a new window opens in: right after the tab it opened from, or after the tabs that
/// tab has just opened.
@MainActor
func createWorkspaceForNewWindow(openedFrom anchor: Workspace, monitor: Monitor,
                                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Workspace {
    let order = orderedWorkspaces(in: anchor.projectId)
    var after = anchor
    if let last = lastTabOpenedFrom[anchor.id], now - last.uptime < workspaceTabOpeningBurst,
       let lastTab = winMuxWorkspaceState.workspaceById[last.tab],
       let anchorIndex = order.firstIndex(where: { $0 === anchor }),
       let lastIndex = order.firstIndex(where: { $0 === lastTab }), lastIndex > anchorIndex
    {
        after = lastTab
    }
    let workspace = createWorkspace(after: after, projectId: anchor.projectId, monitor: monitor)
    lastTabOpenedFrom = lastTabOpenedFrom.filter { now - $0.value.uptime < workspaceTabOpeningBurst }
    lastTabOpenedFrom[anchor.id] = (workspace.id, now)
    return workspace
}

@MainActor func resetWorkspaceTabsForTests() { lastTabOpenedFrom = [:] }

/// A tab the launcher opened in, closed again if nothing opens in it.
struct WorkspaceLauncherNewTab {
    let workspace: Workspace
    /// The tab to go back to; nil means the nearest tab with windows.
    let previous: Workspace?
    /// False when New Tab reused the empty tab already on screen: closing the launcher then
    /// leaves it, unless it's the new tab the launcher was already showing.
    var isNew = true
    /// A group saves a fresh placeholder so its name is reserved. Cancelling its
    /// launcher should still discard it, without affecting an existing saved tab.
    var discardsSavedPlaceholderOnCancel = false
}

/// The tab New Tab opens: a new one after the tab on screen, or that tab itself if it's
/// already empty, so pressing New Tab again doesn't pile up empty tabs.
@MainActor
func newTabWorkspace(projectId: WorkspaceProjectId, monitor: Monitor) -> WorkspaceLauncherNewTab {
    let current = monitor.activeWorkspace
    let isCurrentProject = current.projectId == projectId && !current.isArchived
    if isCurrentProject, !workspaceHasLifecycleWindows(current), !current.isKeptWhenEmpty, !current.isSaved {
        return WorkspaceLauncherNewTab(workspace: current, previous: nil, isNew: false)
    }
    let workspace = createWorkspace(after: isCurrentProject ? current : nil, projectId: projectId, monitor: monitor)
    return WorkspaceLauncherNewTab(workspace: workspace, previous: isCurrentProject ? current : nil)
}

/// Where a window dropped on New Tab goes: a tab right after the one it came from, or after
/// the tab on screen when it came from another display.
@MainActor
func workspaceForDropOnNewTab(projectId: WorkspaceProjectId, monitor: Monitor, sourceWindow: Window) -> Workspace {
    guard config.usesBrowserTabs else { return getOrCreateAdjacentBlankWorkspace(projectId: projectId, monitor: monitor) }
    let anchor = [sourceWindow.nodeWorkspace, monitor.activeWorkspace].compactMap { $0 }
        .first { $0.projectId == projectId && $0.workspaceMonitor.rect == monitor.rect }
    return createWorkspace(after: anchor, projectId: projectId, monitor: monitor)
}

/// The nearest tab with windows on the same display: the next one, else the previous one.
/// A tab showing on another display stays there.
@MainActor
func workspaceTabNeighbor(of workspace: Workspace) -> Workspace? {
    let monitor = workspace.workspaceMonitor
    let tabs = orderedWorkspaces(in: workspace.projectId).filter { tab in
        tab === workspace || tab.workspaceMonitor.rect == monitor.rect
    }
    guard let index = tabs.firstIndex(where: { $0 === workspace }) else { return nil }
    // Windows, or a saved workspace, which is a tab even while empty.
    let isTab = { (tab: Workspace) in workspaceHasLifecycleWindows(tab) || tab.isKeptWhenEmpty }
    return tabs[(index + 1)...].first(where: isTab) ?? tabs[..<index].reversed().first(where: isTab)
}

/// Tabs mode: a tab whose windows have all gone, however they went. It closes once it's off
/// screen. A pinned or saved tab stays, as does a new tab that hasn't had a window yet, and
/// the tab the launcher is choosing an app for.
@MainActor
func workspaceTabWasLeftEmpty(_ tab: Workspace) -> Bool {
    workspaceTabWasLeftEmptyIgnoringLauncher(tab) && WorkspaceLauncherPanel.shared.workspace !== tab
}

@MainActor
func workspaceTabWasLeftEmptyIgnoringLauncher(_ tab: Workspace) -> Bool {
    config.usesBrowserTabs && tab.hasHadWindows && !tab.isArchived && !workspaceHasLifecycleWindows(tab) &&
        !tab.isKeptWhenEmpty && !tab.isAwaitingSavedWorkspaceRestoration
}

/// A tab left empty on screen gives its display to the next tab there, or the previous one,
/// in the order the sidebar shows; tabs with windows first. With no other tab on that
/// display, it stays, and the sidebar doesn't list it.
@MainActor
func leaveTabsLeftEmptyOnScreen() {
    guard config.usesBrowserTabs else { return }
    for tab in Workspace.all where tab.isVisible && workspaceTabWasLeftEmpty(tab) {
        guard let next = workspaceTabReplacingEmptyTab(tab) else { continue }
        if focus.workspace === tab { _ = next.focusWorkspace() } else { _ = tab.workspaceMonitor.setActiveWorkspace(next) }
    }
}

@MainActor
func workspaceTabReplacingEmptyTab(_ tab: Workspace) -> Workspace? {
    let monitor = tab.workspaceMonitor
    let tabs = workspaceNavigationTabs(current: tab).filter { $0 === tab || (!$0.isVisible && $0.workspaceMonitor.rect == monitor.rect) }
    guard let index = tabs.firstIndex(where: { $0 === tab }) else { return nil }
    let nearest = Array(tabs[(index + 1)...]) + tabs[..<index].reversed()
    return nearest.first(where: workspaceHasLifecycleWindows) ?? nearest.first(where: \.isKeptWhenEmpty)
}

/// Closing a tab's last window moves to the next tab, as closing a browser tab does. A saved
/// workspace stays: like a pinned tab, it's kept even when empty.
@MainActor
func workspaceTabAfterLastWindowClosed(_ workspace: Workspace) -> Workspace? {
    guard config.usesBrowserTabs, !workspace.isArchived, !workspace.isKeptWhenEmpty,
          !workspaceHasLifecycleWindows(workspace)
    else { return nil }
    return workspaceTabNeighbor(of: workspace)
}

/// Closes a tab the launcher opened when nothing was opened in it, going back to the tab
/// the user came from. If the user has gone to another display meanwhile, the tab's display
/// switches back without taking focus. The empty tab is then pruned like any other.
@MainActor
func closeUnusedNewTab(_ newTab: WorkspaceLauncherNewTab) {
    let tab = newTab.workspace
    // Not on screen: the user already switched tabs there.
    guard winMuxWorkspaceState.workspaceById[tab.id] === tab, !tab.isArchived,
          !workspaceHasLifecycleWindows(tab)
    else { return }
    let previous = newTab.previous.flatMap { previous in
        winMuxWorkspaceState.workspaceById[previous.id] === previous && !previous.isArchived && !previous.isVisible &&
            previous.workspaceMonitor.rect == tab.workspaceMonitor.rect ? previous : nil
    }
    if newTab.isNew, newTab.discardsSavedPlaceholderOnCancel, !tab.isConfiguredPersistent {
        if tab.isVisible, let previous {
            if tab === focus.workspace { _ = previous.focusWorkspace() }
            else { _ = tab.workspaceMonitor.setActiveWorkspace(previous) }
        }
        do { try deleteWorkspace(tab) }
        catch { showWorkspaceSidebarError(error.localizedDescription) }
        return
    }
    guard tab.isVisible, !tab.isKeptWhenEmpty else { return }
    guard let destination = previous ?? workspaceTabNeighbor(of: tab).flatMap({ $0.isVisible ? nil : $0 }) else {
        // Its display has no other tab: it stays on screen, left empty, and the list leaves it out.
        tab.hasHadWindows = true
        return
    }
    if tab === focus.workspace {
        _ = destination.focusWorkspace()
    } else {
        _ = tab.workspaceMonitor.setActiveWorkspace(destination)
    }
}

/// Gives every window but the one in use a tab of its own, right after, in layout order.
@MainActor
func separateWorkspaceIntoTabs(_ workspace: Workspace) {
    let windows = workspace.allLeafWindowsRecursive
    guard windows.count > 1 else { return }
    let kept = workspace.mostRecentWindowRecursive ?? windows[0]
    var after = workspace
    for window in windows where window !== kept {
        let tab = createWorkspace(after: after, projectId: workspace.projectId, monitor: workspace.workspaceMonitor)
        window.bind(to: window.isFloating ? tab : tab.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        after = tab
    }
}

/// Closes an empty workspace's tab: the next tab takes its place and it goes away. The only
/// tab, or a saved one, stays.
@MainActor
func closeEmptyTab(_ workspace: Workspace) {
    guard !workspace.isArchived, !workspaceHasLifecycleWindows(workspace), !workspace.isKeptWhenEmpty,
          orderedWorkspaces(in: workspace.projectId).contains(where: { $0 !== workspace })
    else { return }
    if workspace.isVisible {
        closeUnusedNewTab(WorkspaceLauncherNewTab(workspace: workspace, previous: nil))
    }
    if !workspace.isVisible { removeWorkspaceFromRegistry(workspace, reason: .pruned) }
}

/// A tab dropped on another tab: its window goes beside that tab's window on the side it was
/// dropped. Other modes may still request a stack. The combined tab comes forward with the
/// dropped window focused.
@MainActor
func applyTabDrop(sourceNode: TreeNode, sourceWindow: Window, targetWorkspace: Workspace,
                  placement: WorkspaceSidebarTabDropPlacement) {
    if !config.usesBrowserTabs, placement == .stack, sourceNode === sourceWindow, !sourceWindow.isFloating,
       let target = targetWorkspace.mostRecentWindowRecursive, target !== sourceWindow, !target.isFloating
    {
        createOrAppendWindowTabStack(sourceWindow: sourceWindow, onto: target)
        _ = sourceWindow.focusWindow()
        return
    }
    applyWorkspaceZoneMove(sourceNode: sourceNode, sourceWindow: sourceWindow, targetWorkspace: targetWorkspace,
        zone: placement == .left ? .left : .right)
}

/// The window a tab dropped on this tab goes beside: the one used last there, or, in a tab
/// not used since WinMux started, any of its windows.
@MainActor
func workspaceTabDropTargetWindow(_ workspace: Workspace) -> Window? {
    workspace.mostRecentWindowRecursive ?? workspace.anyLeafWindowRecursive
}

/// Whether dragging this node out of its tab leaves other windows there. A drop between tabs
/// then gives it a tab of its own instead of moving the whole tab.
@MainActor
func workspaceTabDragLeavesWindowsBehind(_ sourceNode: TreeNode) -> Bool {
    let moving = Set(sourceNode.allLeafWindowsRecursive.map(\.windowId))
    return sourceNode.nodeWorkspace?.allLeafWindowsRecursive.allSatisfy { moving.contains($0.windowId) } != true
}

/// Whether moving a whole tab to this gap leaves it where it is: beside itself, or next to
/// the neighbor it already has, in the same group and on the same display. A pinned tab
/// dropped in the list is unpinned there, so it always moves.
@MainActor
func workspaceTabGapKeepsTabInPlace(_ tab: Workspace, projectId: WorkspaceProjectId, monitorScopeId: String,
                                    gap: WorkspaceSidebarTabGap) -> Bool {
    guard tab.projectId == projectId,
          workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite != true,
          workspaceSidebarMonitorScopeIsSentinel(monitorScopeId)
              || workspaceSidebarMonitorScopeId(for: tab.workspaceMonitor) == monitorScopeId,
          workspaceSidebarOrganizationStore.collection(containing: tab.name)?.id == gap.collectionId
    else { return false }
    if gap.workspaceName == tab.name { return true }
    guard let anchor = Workspace.existing(byName: gap.workspaceName), anchor.projectId == projectId else { return false }
    let order = orderedWorkspaces(in: projectId).map(\.id)
    var moved = order.filter { $0 != tab.id }
    guard let index = moved.firstIndex(of: anchor.id) else { return false }
    moved.insert(tab.id, at: gap.isAfter ? index + 1 : index)
    return moved == order
}

/// A tab dropped between tabs. A whole tab moves there, leaving the pins if it was pinned; a
/// window from a tab with others gets a new tab there, and comes forward.
@MainActor
func applyTabGapDrop(sourceNode: TreeNode, sourceWindow: Window, projectId: WorkspaceProjectId, monitor: Monitor,
                     gap: WorkspaceSidebarTabGap) {
    let anchor = Workspace.existing(byName: gap.workspaceName).flatMap { $0.projectId == projectId ? $0 : nil }
    let sourceWorkspace = sourceNode.nodeWorkspace
    let isWholeTab = !workspaceTabDragLeavesWindowsBehind(sourceNode)
    // The tab it was dropped next to has gone meanwhile: leave the tab where it is.
    if isWholeTab, anchor == nil { return }
    if isWholeTab, let sourceWorkspace {
        moveWholeTabToGap(sourceWorkspace, projectId: projectId, monitor: monitor, gap: gap, focusing: sourceWindow)
        return
    }
    // One window pulled out of a split gets a new tab. A whole tab keeps its identity above.
    let tab = createBlankWorkspace(projectId: projectId, monitor: monitor)
    do { try assignWorkspaceToSidebarCollection(tab, collectionId: gap.collectionId, keepWhenEmpty: false) }
    catch { removeWorkspaceFromRegistry(tab, reason: .pruned); showWorkspaceSidebarError(error.localizedDescription); return }
    if let anchor { winMuxWorkspaceState.moveWorkspace(tab.id, relativeTo: anchor.id, after: gap.isAfter) }
    let isFloatingWindow = sourceNode === sourceWindow && sourceWindow.isFloating
    sourceNode.bind(to: isFloatingWindow ? tab : tab.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    captureNewAutomaticWorkspaceIdentity(tab)
    _ = sourceWindow.focusWindow()
}

/// A whole tab dropped between tabs moves there, into that group, project and display, and out
/// of the pins. `window` comes forward when it changes display; an empty tab comes forward itself.
@MainActor
func moveWholeTabToGap(_ tab: Workspace, projectId: WorkspaceProjectId, monitor: Monitor, gap: WorkspaceSidebarTabGap,
                       focusing window: Window?) {
    guard let anchor = Workspace.existing(byName: gap.workspaceName), anchor.projectId == projectId else { return }
    guard workspaceTabCanMove(tab, to: monitor) else {
        showWorkspaceSidebarError("This tab is assigned to another display.")
        return
    }
    let store = workspaceSidebarOrganizationStore
    // The group it was dropped in has gone meanwhile: leave the tab where it is.
    if let collectionId = gap.collectionId,
       !store.state.collections.contains(where: { $0.id == collectionId && $0.projectId == projectId }) { return }
    let isPinned = store.state.workspaces[tab.name]?.isFavorite == true
    let changesGroup = store.collection(containing: tab.name)?.id != gap.collectionId
    // Nothing moves unless its pin and group can be saved too; joining a group also saves the tab.
    if isPinned || changesGroup,
       let reason = store.readOnlyReason ?? (gap.collectionId == nil ? nil : savedWorkspaceStore.readOnlyReason) {
        showWorkspaceSidebarError(reason)
        return
    }
    // Unpinning doesn't depend on the project, so it goes first: if it can't be saved, the tab stays put.
    do { if isPinned { try setWorkspaceSidebarTabFavorite(tab, false) } }
    catch { showWorkspaceSidebarError(error.localizedDescription); return }
    let changesScope = tab.projectId != projectId || tab.workspaceMonitor.rect != monitor.rect
    if tab.projectId != projectId, !moveWorkspaceToProject(workspaceName: tab.name, projectId: projectId) { return }
    do { if changesGroup { try assignWorkspaceToSidebarCollection(tab, collectionId: gap.collectionId) } }
    catch { showWorkspaceSidebarError(error.localizedDescription); return }
    if changesScope {
        guard activateWorkspaceOnMonitorPreservingSourceViewport(tab, targetMonitor: monitor) else { return }
        noteSavedWorkspacePlacedByUser(tab, on: monitor)
        if let window { _ = window.focusWindow() } else { _ = tab.focusWorkspace() }
    }
    winMuxWorkspaceState.moveWorkspace(tab.id, relativeTo: anchor.id, after: gap.isAfter)
}

/// Whether a tab may be shown on `monitor`: neither `workspace-to-monitor-force-assignment` nor a
/// saved workspace kept on its display holds it to another one.
@MainActor
func workspaceTabCanMove(_ tab: Workspace, to monitor: Monitor) -> Bool {
    isValidAssignment(workspace: tab, screen: monitor.rect.topLeftCorner) && !savedPinBlocks(tab, on: monitor)
}

/// Brings a tab onto the display whose list it was dropped on, before it's pinned or grouped
/// there, as a drop between tabs does. `window` comes forward; an empty tab comes forward itself.
@MainActor
func moveWorkspaceTabToDisplay(_ tab: Workspace, _ monitor: Monitor, focusing window: Window?) throws {
    guard tab.workspaceMonitor.rect != monitor.rect else { return }
    guard workspaceTabCanMove(tab, to: monitor) else { throw WorkspaceMutationError.tabAssignedToAnotherDisplay }
    guard activateWorkspaceOnMonitorPreservingSourceViewport(tab, targetMonitor: monitor) else {
        throw WorkspaceMutationError.tabCannotShowOnDisplay
    }
    noteSavedWorkspacePlacedByUser(tab, on: monitor)
    if let window { _ = window.focusWindow() } else { _ = tab.focusWorkspace() }
}
