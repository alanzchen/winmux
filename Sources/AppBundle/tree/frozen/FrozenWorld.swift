import AppKit
import Common

struct FrozenWorld: Codable, Sendable {
    let workspaces: [FrozenWorkspace]
    let monitors: [FrozenMonitor]
    let windowIds: Set<UInt32>
}

@MainActor
func snapshotCurrentFrozenWorld() -> FrozenWorld {
    let workspaces = restorableWorkspaces(Workspace.all)
    return FrozenWorld(
        workspaces: workspaces.map(FrozenWorkspace.init),
        monitors: monitors.map(FrozenMonitor.init),
        windowIds: workspaces.flatMap { collectAllWindowIds(workspace: $0) }.toSet(),
    )
}

@MainActor
func restorableWorkspaces(_ workspaces: [Workspace]) -> [Workspace] {
    workspaces.filter { !collectAllWindowIds(workspace: $0).isEmpty }
}

@MainActor
func collectAllWindowIds(workspace: Workspace) -> [UInt32] {
    workspace.floatingWindows.map { $0.windowId } +
        workspaceOwnedMinimizedWindows(workspace).map { $0.windowId } +
        (workspace.existingMacOsNativeFullscreenWindowsContainer?.children.filterIsInstance(of: Window.self).map { $0.windowId } ?? []) +
        (workspace.existingMacOsNativeHiddenAppsWindowsContainer?.children.filterIsInstance(of: Window.self).map { $0.windowId } ?? []) +
        collectAllWindowIdsRecursive(workspace.rootTilingContainer)
}

func collectAllWindowIdsRecursive(_ node: TreeNode) -> [UInt32] {
    switch node.nodeCases {
        case .macosFullscreenWindowsContainer,
             .macosHiddenAppsWindowsContainer,
             .macosMinimizedWindowsContainer,
             .macosPopupWindowsContainer,
             .workspace: []
        case .tilingContainer(let c):
            c.children.reduce(into: [UInt32]()) { partialResult, elem in
                partialResult += collectAllWindowIdsRecursive(elem)
            }
        case .window(let w): [w.windowId]
    }
}

/// Windows the user put somewhere on purpose, numbered in order. A restore that began before a
/// placement works from an older snapshot, so it leaves that window where the user put it.
@MainActor private(set) var explicitWindowPlacementCount: UInt64 = 0
@MainActor private var explicitWindowPlacements: [UInt32: UInt64] = [:]

/// The user put `window` in `workspace` on purpose, as reopening an app from its tab does.
/// Snapshots taken before forget where the window was, so restoring them for another window
/// can't take it back, and they remember the display showing `workspace`. Restores already
/// under way leave the window alone.
@MainActor
func noteExplicitWindowPlacement(_ window: Window, in workspace: Workspace) {
    explicitWindowPlacementCount += 1
    explicitWindowPlacements = explicitWindowPlacements.filter { Window.get(byId: $0.key) != nil }
    explicitWindowPlacements[window.windowId] = explicitWindowPlacementCount
    supersedeClosedWindowsCache(placementOf: window, in: workspace)
    supersedePendingPersistedFrozenWorld(placementOf: window, in: workspace)
}

/// Whether the user placed the window after placement number `count`.
@MainActor
func wasPlacedExplicitly(_ windowId: UInt32, after count: UInt64) -> Bool {
    explicitWindowPlacements[windowId].map { $0 > count } ?? false
}

extension FrozenWorld {
    /// This world once the user put `window` in `workspace`: the window is no longer remembered
    /// where it was, and a display showing `workspace` is remembered showing it. Every other
    /// window keeps its remembered place. A world without the window is left as it is.
    @MainActor
    func superseding(placementOf window: Window, in workspace: Workspace) -> FrozenWorld {
        guard windowIds.contains(window.windowId) else { return self }
        var frozenWorkspaces = workspaces.map { $0.removing(windowId: window.windowId) }
        var frozenMonitors = monitors
        var ids = windowIds.subtracting([window.windowId])
        let monitor = workspace.workspaceMonitor
        if monitor.activeWorkspace === workspace {
            // A restore shows a remembered workspace, so the one on screen has to be among them.
            if !frozenWorkspaces.contains(where: { $0.name == workspace.name }) {
                frozenWorkspaces.append(FrozenWorkspace(workspace))
                ids.formUnion(collectAllWindowIds(workspace: workspace))
            }
            frozenMonitors = frozenMonitors.filter { $0.topLeftCorner != monitor.rect.topLeftCorner } + [FrozenMonitor(monitor)]
        }
        return FrozenWorld(workspaces: frozenWorkspaces, monitors: frozenMonitors, windowIds: ids)
    }
}

extension FrozenWorkspace {
    init(name: String, projectId: WorkspaceProjectId, namingStyle: WorkspaceNamingStyle, monitor: FrozenMonitor,
         rootTilingNode: FrozenContainer, floatingWindows: [FrozenWindow], macosUnconventionalWindows: [FrozenWindow]) {
        self.name = name
        self.projectId = projectId
        self.namingStyle = namingStyle
        self.monitor = monitor
        self.rootTilingNode = rootTilingNode
        self.floatingWindows = floatingWindows
        self.macosUnconventionalWindows = macosUnconventionalWindows
    }

    func removing(windowId: UInt32) -> FrozenWorkspace {
        FrozenWorkspace(name: name, projectId: projectId, namingStyle: namingStyle, monitor: monitor,
            rootTilingNode: rootTilingNode.removing(windowId: windowId),
            floatingWindows: floatingWindows.filter { $0.id != windowId },
            macosUnconventionalWindows: macosUnconventionalWindows.filter { $0.id != windowId })
    }
}

extension FrozenContainer {
    init(children: [FrozenTreeNode], layout: Layout, orientation: Orientation, weight: CGFloat) {
        self.children = children
        self.layout = layout
        self.orientation = orientation
        self.weight = weight
    }

    /// Without the window, and without containers it leaves empty.
    func removing(windowId: UInt32) -> FrozenContainer {
        FrozenContainer(children: children.compactMap { child in
            switch child {
                case .window(let window):
                    return window.id == windowId ? nil : child
                case .container(let container):
                    let rest = container.removing(windowId: windowId)
                    return rest.children.isEmpty ? nil : .container(rest)
            }
        }, layout: layout, orientation: orientation, weight: weight)
    }
}
