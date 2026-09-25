enum WorkspaceSidebarSearchSelection: Hashable {
    case workspace(String)
    case window(UInt32)
}

func workspaceSidebarSearchSelections(
    workspaces: [WorkspaceSidebarWorkspaceViewModel],
) -> [WorkspaceSidebarSearchSelection] {
    workspaces.flatMap { workspace in
        let itemSelections = workspace.items.flatMap { item -> [WorkspaceSidebarSearchSelection] in
            switch item.kind {
                case .window(let window):
                    return [.window(window.windowId)]
                case .tabGroup(let group):
                    // The same windows the stack renders, in the same order.
                    return workspaceSidebarTabGroupWindows(group).map { .window($0.windowId) }
            }
        }
        return itemSelections.isEmpty ? [.workspace(workspace.name)] : itemSelections
    }
}
