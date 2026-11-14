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

/// The user put `window` in `workspace` on purpose, as reopening an app from its tab does.
/// Snapshots taken before forget where the window was, so restoring them for another window
/// can't take it back, and they remember the display showing `workspace`.
@MainActor
func noteExplicitWindowPlacement(_ window: Window, in workspace: Workspace) {
    supersedeClosedWindowsCache(placementOf: window, in: workspace)
    supersedePendingPersistedFrozenWorld(placementOf: window, in: workspace)
}

/// The displays connected now. Inside `FrozenWorld`, `monitors` is the remembered ones.
@MainActor
private func liveDisplays() -> [Monitor] { monitors }

extension FrozenWorld {
    /// This world once the user put `window` in `workspace`: the window is remembered there, last,
    /// where the request put it, and the displays and their workspaces are remembered as they are
    /// now, as a cache sync would. Every other window keeps its remembered place. A world without
    /// the window is left as it is.
    @MainActor
    func superseding(placementOf window: Window, in workspace: Workspace) -> FrozenWorld {
        guard windowIds.contains(window.windowId) else { return self }
        let belongsToWorkspace = window.nodeWorkspace === workspace || workspaceOwnedMinimizedWindows(workspace).contains(window)
        let isNative = window.parent is MacosFullscreenWindowsContainer || window.parent is MacosHiddenAppsWindowsContainer ||
            window.parent is MacosMinimizedWindowsContainer
        var ids = windowIds.subtracting([window.windowId])
        var frozenWorkspaces: [FrozenWorkspace] = []
        for frozen in workspaces {
            let rest = frozen.removing(windowId: window.windowId)
            guard let live = Workspace.existing(byName: frozen.name) else {
                frozenWorkspaces.append(rest)
                continue
            }
            let display = FrozenMonitor(live.workspaceMonitor)
            if live === workspace, belongsToWorkspace {
                frozenWorkspaces.append(rest.appending(window, on: display))
                ids.insert(window.windowId)
            } else {
                frozenWorkspaces.append(rest.on(display))
            }
        }
        // A native window need not show or focus its workspace when its request completes.
        if belongsToWorkspace, isNative, !workspace.isVisible, !frozenWorkspaces.contains(where: { $0.name == workspace.name }) {
            let monitor = FrozenMonitor(workspace.workspaceMonitor)
            let root = workspace.rootTilingContainer
            let destination = FrozenWorkspace(name: workspace.name, projectId: workspace.projectId, namingStyle: workspace.namingStyle,
                monitor: monitor, rootTilingNode: FrozenContainer(children: [], layout: root.layout, orientation: root.orientation, weight: 1),
                floatingWindows: [], macosUnconventionalWindows: [])
            frozenWorkspaces.append(destination.appending(window, on: monitor))
            ids.insert(window.windowId)
        }
        // A restore shows each remembered display's workspace, and only remembered workspaces.
        let displays = liveDisplays()
        for shown in displays.map(\.activeWorkspace) where !frozenWorkspaces.contains(where: { $0.name == shown.name }) {
            frozenWorkspaces.append(FrozenWorkspace(shown))
            ids.formUnion(collectAllWindowIds(workspace: shown))
        }
        return FrozenWorld(workspaces: frozenWorkspaces, monitors: displays.map(FrozenMonitor.init), windowIds: ids)
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

    /// With the window last in its current tiling, floating or native state, on its display now.
    @MainActor
    func appending(_ window: Window, on monitor: FrozenMonitor) -> FrozenWorkspace {
        let frozenWindow = FrozenWindow(window)
        let isTiling = window.parent is TilingContainer
        let isNative = window.parent is MacosFullscreenWindowsContainer || window.parent is MacosHiddenAppsWindowsContainer ||
            window.parent is MacosMinimizedWindowsContainer
        return FrozenWorkspace(name: name, projectId: projectId, namingStyle: namingStyle, monitor: monitor,
            rootTilingNode: isTiling ? FrozenContainer(children: rootTilingNode.children + [.window(frozenWindow)],
                layout: rootTilingNode.layout, orientation: rootTilingNode.orientation, weight: rootTilingNode.weight) : rootTilingNode,
            floatingWindows: window.isFloating ? floatingWindows + [frozenWindow] : floatingWindows,
            macosUnconventionalWindows: isNative ? macosUnconventionalWindows + [frozenWindow] : macosUnconventionalWindows)
    }

    /// On another display.
    func on(_ monitor: FrozenMonitor) -> FrozenWorkspace {
        FrozenWorkspace(name: name, projectId: projectId, namingStyle: namingStyle, monitor: monitor,
            rootTilingNode: rootTilingNode, floatingWindows: floatingWindows, macosUnconventionalWindows: macosUnconventionalWindows)
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
