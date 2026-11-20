import AppKit
import Common

struct FrozenWorld: Codable, Sendable {
    let workspaces: [FrozenWorkspace]
    let monitors: [FrozenMonitor]
    let windowIds: Set<UInt32>
}

@MainActor
func snapshotCurrentFrozenWorld() -> FrozenWorld {
    // WINMUX-HOOK-BEGIN(tabContent)
    let contents = Workspace.all.map { WorkspaceTabSnapshot($0) }.filter { !$0.lifecycleMembers.isEmpty }
    return FrozenWorld(
        workspaces: contents.map { FrozenWorkspace(content: $0) },
        monitors: monitors.map(FrozenMonitor.init),
        windowIds: contents.flatMap { $0.lifecycleMembers.map(\.window.windowId) }.toSet(),
    )
    // WINMUX-HOOK-END(tabContent)
}

@MainActor
func restorableWorkspaces(_ workspaces: [Workspace]) -> [Workspace] {
    workspaces.filter { !collectAllWindowIds(workspace: $0).isEmpty }
}

@MainActor
func collectAllWindowIds(workspace: Workspace) -> [UInt32] {
    WorkspaceTabSnapshot(workspace).lifecycleMembers.map { $0.window.windowId } // WINMUX-HOOK(tabContent)
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
        var ids = windowIds.subtracting([window.windowId])
        var frozenWorkspaces: [FrozenWorkspace] = []
        for frozen in workspaces {
            let rest = frozen.removing(windowId: window.windowId)
            guard let live = Workspace.existing(byName: frozen.name) else {
                frozenWorkspaces.append(rest)
                continue
            }
            let display = FrozenMonitor(live.workspaceMonitor)
            if live === workspace {
                frozenWorkspaces.append(rest.appending(window, on: display))
                ids.insert(window.windowId)
            } else {
                frozenWorkspaces.append(rest.on(display))
            }
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

    /// With the window last, floating or in the root, as it is now, on the display it's on now.
    @MainActor
    func appending(_ window: Window, on monitor: FrozenMonitor) -> FrozenWorkspace {
        let frozenWindow = FrozenWindow(window)
        return FrozenWorkspace(name: name, projectId: projectId, namingStyle: namingStyle, monitor: monitor,
            rootTilingNode: window.isFloating ? rootTilingNode : FrozenContainer(children: rootTilingNode.children + [.window(frozenWindow)],
                layout: rootTilingNode.layout, orientation: rootTilingNode.orientation, weight: rootTilingNode.weight),
            floatingWindows: window.isFloating ? floatingWindows + [frozenWindow] : floatingWindows,
            macosUnconventionalWindows: macosUnconventionalWindows)
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
