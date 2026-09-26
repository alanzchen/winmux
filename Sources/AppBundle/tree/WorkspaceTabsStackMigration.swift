import Common

/// Tabs mode has one navigation surface. Keep the selected entry in place and move
/// each other stack entry to its own workspace, retaining the entry's split subtree.
/// This also handles stacks restored from saved layouts while Tabs mode is running.
@MainActor
func migrateWindowStacksToSidebarTabs() {
    guard config.usesBrowserTabs else { return }
    var pending = Workspace.all
    var nextIndex = 0
    while nextIndex < pending.count {
        let workspace = pending[nextIndex]
        nextIndex += 1
        func firstStack(_ node: TreeNode) -> TilingContainer? {
            if let container = node as? TilingContainer, container.layout == .tabGroup { return container }
            for child in node.children {
                if let result = firstStack(child) { return result }
            }
            return nil
        }
        while let stack = firstStack(workspace.rootTilingContainer) {
            let entries = stack.children
            let focused = focus.windowOrNil
            let kept = entries.first { entry in entry.allLeafWindowsRecursive.contains { $0 === focused } }
                ?? entries.first { entry in entry.allLeafWindowsRecursive.contains { $0 === stack.mostRecentWindowRecursive } }
                ?? entries.first
            var after = workspace
            let collectionId = workspaceSidebarOrganizationStore.collection(containing: workspace.name)?.id
            for entry in entries where entry !== kept {
                let tab = createWorkspace(after: after, projectId: workspace.projectId, monitor: workspace.workspaceMonitor)
                entry.bind(to: tab.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                if workspace.isSaved { try? saveWorkspaceSidebarIdentity(tab) }
                if let collectionId { try? assignWorkspaceToSidebarCollection(tab, collectionId: collectionId) }
                pending.append(tab)
                after = tab
            }
            stack.layout = .tiles
        }
    }
}
