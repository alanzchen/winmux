import AppKit
import Common

/// Tabs mode: a pinned tile drags as its whole tab, split or empty alike. It uses the sidebar's
/// drop targets and feedback, but no window drag, since a pin needn't have a window.
enum WorkspaceSidebarPinnedTabDrop: Equatable {
    /// Beside another pin.
    case rearrange(WorkspaceSidebarTabGap)
    /// Between the list's tabs, unpinned.
    case list(projectId: WorkspaceProjectId, monitorScopeId: String, gap: WorkspaceSidebarTabGap)
    /// Into a group, which unpins it.
    case group(String)
    /// On New Tab: unpinned where it is.
    case unpin
}

/// What dropping the pinned tab on this target does, or nil where it does nothing.
@MainActor
func workspaceSidebarPinnedTabDrop(_ tab: Workspace, target: WorkspaceSidebarDropTarget,
                                   point: CGPoint) -> WorkspaceSidebarPinnedTabDrop? {
    guard config.usesBrowserTabs, workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite == true
    else { return nil }
    switch target.kind {
        case .pinnedTabs(let projectId, let gap):
            guard projectId == tab.projectId, let gap, workspacePinnedTabOrder(moving: tab, beside: gap) != nil else { return nil }
            return .rearrange(gap)
        case .tabGap(let projectId, let monitorScopeId, let gap):
            guard Workspace.existing(byName: gap.workspaceName)?.projectId == projectId else { return nil }
            return .list(projectId: projectId, monitorScopeId: monitorScopeId, gap: gap)
        case .workspace(let name):
            // Over a tab or a pin, it goes by the nearer edge or side, as a moving tab does before a split
            // arms. A pinned tab doesn't split.
            guard let destination = target.tabReorderDestination, Workspace.existing(byName: name) != nil else { return nil }
            return workspaceSidebarPinnedTabDrop(tab, target: .init(kind: destination.reorderTarget(beside: name,
                rect: target.rect, point: point), rect: target.rect), point: point)
        case .tabCollection(let id):
            guard workspaceSidebarOrganizationStore.state.collections.contains(where: { $0.id == id && $0.projectId == tab.projectId })
            else { return nil }
            return .group(id)
        case .newWorkspace(let projectId, _):
            return projectId == tab.projectId ? .unpin : nil
        case .monitor:
            return nil
    }
}

@MainActor
private func workspaceSidebarPinnedTabDropUnderPointer(_ tab: Workspace, point: CGPoint) -> WorkspaceSidebarPinnedTabDrop? {
    guard WorkspaceSidebarPanel.panel(containing: point) != nil, let target = workspaceSidebarDropTarget(at: point) else { return nil }
    return workspaceSidebarPinnedTabDrop(tab, target: target, point: point)
}

/// The dragged pin, as the pointer carries it, and with where it would go.
@MainActor
func workspaceSidebarPinnedTabDropPreview(_ tab: Workspace, drop: WorkspaceSidebarPinnedTabDrop?) -> WorkspaceSidebarDropPreviewViewModel {
    let windows = tab.allLeafWindowsRecursive
    let window = tab.mostRecentWindowRecursive ?? windows.first
    let appName = window.map { $0.app.name ?? $0.app.rawAppBundleId ?? "Window" } ?? "Tab"
    var projectId = tab.projectId
    var monitorScopeId: String?
    if case .list(let listProjectId, let listMonitorScopeId, _) = drop {
        projectId = listProjectId
        monitorScopeId = listMonitorScopeId
    }
    var preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: window?.windowId ?? 0,
        label: windows.count > 1 ? "\(windows.count) windows" : window.flatMap { cachedWindowTitle(for: $0) } ?? appName,
        appName: appName, appBundleIdentifier: window?.app.rawAppBundleId, appBundlePath: window?.app.bundlePath,
        targetWorkspaceName: nil, targetsNewWorkspace: drop == .unpin, targetProjectId: projectId,
        targetMonitorScopeId: monitorScopeId, isTabGroup: false, windowCount: max(windows.count, 1))
    switch drop {
        case .rearrange(let gap):
            preview.targetsPinned = true
            preview.targetPinnedGap = gap
        case .list(_, _, let gap): preview.targetGap = gap
        case .group(let id): preview.targetCollectionId = id
        case .unpin, nil: break
    }
    return preview
}

/// The tab the drag began with. If it closes, or another tab takes its name, the drag drops nothing.
@MainActor
private var activeSidebarPinnedTabDrag: (name: String, tab: Workspace)?

@MainActor
func updateSidebarPinnedTabDrag(_ name: String, pointer: CGPoint) {
    MousePointerTracker.shared.note(point: pointer)
    if activeSidebarPinnedTabDrag?.name != name {
        guard let tab = Workspace.existing(byName: name) else { return }
        activeSidebarPinnedTabDrag = (name, tab)
    }
    guard let tab = activeSidebarPinnedTabDrag?.tab, Workspace.existing(byName: name) === tab else {
        clearSidebarPinnedTabDragFeedback()
        return
    }
    WorkspaceSidebarTabDragState.shared.set(true, pinnedTab: name)
    let drop = workspaceSidebarPinnedTabDropUnderPointer(tab, point: pointer)
    WindowDragCursorProxyPanel.shared.show(preview: workspaceSidebarPinnedTabDropPreview(tab, drop: nil),
        mouseScreenPoint: denormalizedAppKitScreenPoint(pointer), style: .appIcon(size: 22))
    setWorkspaceSidebarDropPreviewIfChanged(drop.map { workspaceSidebarPinnedTabDropPreview(tab, drop: $0) })
}

/// The drop happens once, from whichever sees the release first: the gesture's end, or the
/// mouse-up cleanup when the gesture ended without saying so.
@MainActor
func finishSidebarPinnedTabDrag(_ name: String, pointer: CGPoint) {
    guard let drag = activeSidebarPinnedTabDrag, drag.name == name else { return }
    activeSidebarPinnedTabDrag = nil
    MousePointerTracker.shared.note(point: pointer)
    let tab = Workspace.existing(byName: name) === drag.tab ? drag.tab : nil
    let drop = tab.flatMap { workspaceSidebarPinnedTabDropUnderPointer($0, point: pointer) }
    clearSidebarPinnedTabDragFeedback()
    guard let tab, let drop else { return }
    runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedTabDropUndoTitle(drop)) {
        try applyWorkspaceSidebarPinnedTabDrop(tab, drop)
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
private func clearSidebarPinnedTabDragFeedback() {
    WorkspaceSidebarTabDragState.shared.set(false)
    clearWorkspaceSidebarDropPreview()
    WindowDragCursorProxyPanel.shared.hide()
}

func workspaceSidebarPinnedTabDropUndoTitle(_ drop: WorkspaceSidebarPinnedTabDrop) -> String {
    switch drop {
        case .rearrange: "Move Tab"
        case .list, .unpin: "Unpin Tab"
        case .group: "Move to Group"
    }
}

/// Only the dragged tab itself, still pinned: the session can run after other events, which may
/// have closed it or given its name to another tab.
@MainActor
func applyWorkspaceSidebarPinnedTabDrop(_ tab: Workspace, _ drop: WorkspaceSidebarPinnedTabDrop) throws {
    guard Workspace.existing(byName: tab.name) === tab,
          workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite == true else { return }
    switch drop {
        case .rearrange(let gap):
            try pinWorkspaceSidebarTab(tab, beside: gap)
        case .list(let projectId, let monitorScopeId, let gap):
            let window = tab.mostRecentWindowRecursive ?? tab.anyLeafWindowRecursive
            let monitor = workspaceSidebarTargetMonitor(scopeId: monitorScopeId, fallbackWindow: window,
                fallbackPoint: mouseLocation)
            syncClosedWindowsCacheToCurrentWorld()
            suppressPostDragAxObserverEvents(for: tab.allLeafWindowsRecursive.map(\.windowId))
            moveWholeTabToGap(tab, projectId: projectId, monitor: monitor, gap: gap, focusing: window)
        case .group(let id):
            try assignWorkspaceToSidebarCollection(tab, collectionId: id)
        case .unpin:
            try setWorkspaceSidebarTabFavorite(tab, false)
    }
}
