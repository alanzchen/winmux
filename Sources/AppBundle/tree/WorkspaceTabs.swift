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
}

/// The tab New Tab opens: a new one after the tab on screen, or that tab itself if it's
/// already empty, so pressing New Tab again doesn't pile up empty tabs.
@MainActor
func newTabWorkspace(projectId: WorkspaceProjectId, monitor: Monitor) -> WorkspaceLauncherNewTab {
    let current = monitor.activeWorkspace
    let isCurrentProject = current.projectId == projectId && !current.isArchived
    if isCurrentProject, !workspaceHasLifecycleWindows(current), !current.isKeptWhenEmpty {
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
    guard winMuxWorkspaceState.workspaceById[tab.id] === tab, !tab.isArchived, tab.isVisible,
          !workspaceHasLifecycleWindows(tab), !tab.isKeptWhenEmpty
    else { return }
    let previous = newTab.previous.flatMap { previous in
        winMuxWorkspaceState.workspaceById[previous.id] === previous && !previous.isArchived && !previous.isVisible &&
            previous.workspaceMonitor.rect == tab.workspaceMonitor.rect ? previous : nil
    }
    guard let destination = previous ?? workspaceTabNeighbor(of: tab).flatMap({ $0.isVisible ? nil : $0 }) else { return }
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
/// dropped, or with Option into a stack with it. The combined tab comes forward with the
/// dropped window focused.
@MainActor
func applyTabDrop(sourceNode: TreeNode, sourceWindow: Window, targetWorkspace: Workspace,
                  placement: WorkspaceSidebarTabDropPlacement) {
    if placement == .stack, sourceNode === sourceWindow, !sourceWindow.isFloating,
       let target = targetWorkspace.mostRecentWindowRecursive, target !== sourceWindow, !target.isFloating
    {
        createOrAppendWindowTabStack(sourceWindow: sourceWindow, onto: target)
        _ = sourceWindow.focusWindow()
        return
    }
    applyWorkspaceZoneMove(sourceNode: sourceNode, sourceWindow: sourceWindow, targetWorkspace: targetWorkspace,
        zone: placement == .left ? .left : .right)
}

/// A tab dropped between tabs. A whole tab moves there; a window from a tab with others gets
/// a new tab there, and comes forward.
@MainActor
func applyTabGapDrop(sourceNode: TreeNode, sourceWindow: Window, projectId: WorkspaceProjectId, monitor: Monitor,
                     gap: WorkspaceSidebarTabGap) {
    let anchor = Workspace.existing(byName: gap.workspaceName).flatMap { $0.projectId == projectId ? $0 : nil }
    let moving = Set(sourceNode.allLeafWindowsRecursive.map(\.windowId))
    let sourceWorkspace = sourceNode.nodeWorkspace
    let isWholeTab = sourceWorkspace?.allLeafWindowsRecursive.allSatisfy { moving.contains($0.windowId) } == true
    // The tab it was dropped next to has gone meanwhile: leave the tab where it is.
    if isWholeTab, anchor == nil { return }
    if isWholeTab, let sourceWorkspace, let anchor, sourceWorkspace.projectId == projectId,
       sourceWorkspace.workspaceMonitor.rect == monitor.rect
    {
        winMuxWorkspaceState.moveWorkspace(sourceWorkspace.id, relativeTo: anchor.id, after: gap.isAfter)
        return
    }
    // Otherwise, including a whole tab from another display, the windows get a new tab here.
    let tab = createBlankWorkspace(projectId: projectId, monitor: monitor)
    if let anchor { winMuxWorkspaceState.moveWorkspace(tab.id, relativeTo: anchor.id, after: gap.isAfter) }
    let isFloatingWindow = sourceNode === sourceWindow && sourceWindow.isFloating
    sourceNode.bind(to: isFloatingWindow ? tab : tab.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    _ = sourceWindow.focusWindow()
}

