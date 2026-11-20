@MainActor
func buildWorkspaceSidebarContainerItems(
    _ container: WorkspaceTabLayoutContainer,
    windows: [UInt32: WorkspaceSidebarWindowViewModel],
    workspaceName: String,
    currentFocus: LiveFocus,
) -> [WorkspaceSidebarItemViewModel] {
    if container.layout == .tabGroup, container.children.count > 1 {
        return makeWorkspaceSidebarTabGroupViewModel(for: container, windows: windows,
            workspaceName: workspaceName, currentFocus: currentFocus).map { [.init(kind: .tabGroup($0))] } ?? []
    }
    return container.children.flatMap { child -> [WorkspaceSidebarItemViewModel] in
        switch child {
            case .window(let leaf): return windows[leaf.window.windowId].map { [WorkspaceSidebarItemViewModel(kind: .window($0))] } ?? []
            case .container(let nested): return buildWorkspaceSidebarContainerItems(nested, windows: windows,
                workspaceName: workspaceName, currentFocus: currentFocus)
        }
    }
}

extension WorkspaceTabLayoutContainer {
    /// Rendering projection only: compact stacks need representatives, Tabs mode lists every member.
    @MainActor var sidebarWindows: [Window] {
        if layout == .tabGroup, children.count > 1 {
            return config.workspaceSidebar.usesTabsList ? windows : tabRepresentatives
        }
        return children.flatMap { child in
            switch child {
                case .window(let leaf): [leaf.window]
                case .container(let nested): nested.sidebarWindows
            }
        }
    }
}
