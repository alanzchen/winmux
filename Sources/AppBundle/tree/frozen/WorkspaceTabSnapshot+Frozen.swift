import AppKit

extension FrozenWorkspace {
    @MainActor init(content: WorkspaceTabSnapshot) {
        let workspace = content.workspace
        self.init(name: workspace.name, projectId: workspace.projectId, namingStyle: workspace.namingStyle,
            monitor: FrozenMonitor(workspace.workspaceMonitor), rootTilingNode: FrozenContainer(content: content.root),
            floatingWindows: content.floatingMembers.map { FrozenWindow($0.window) },
            macosUnconventionalWindows: [.minimized, .hiddenWithApp, .nativeFullscreen].flatMap { state in
                content.lifecycleMembers.filter { $0.state == state }.map { FrozenWindow($0.window) }
            })
    }
}

extension FrozenContainer {
    @MainActor init(content: WorkspaceTabLayoutContainer) {
        self.init(children: content.children.map { node in
            switch node {
                case .window(let leaf): .window(FrozenWindow(leaf.window))
                case .container(let nested): .container(FrozenContainer(content: nested))
            }
        }, layout: content.layout, orientation: content.orientation, weight: content.weight)
    }
}
