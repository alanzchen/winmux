import Common

extension Workspace {
    @MainActor
    func agentPaneRelations(content: WorkspaceTabSnapshot? = nil) -> [AgentPaneRelation] {
        let content = content ?? WorkspaceTabSnapshot(self)
        var byPane: [String: AgentPaneRelation] = [:]
        visitAgentPaneRelations(.container(content.root), byPane: &byPane)
        return Array(byPane.values)
    }

    @MainActor
    private func visitAgentPaneRelations(_ node: WorkspaceTabLayoutNode, byPane: inout [String: AgentPaneRelation]) {
        guard case .container(let container) = node, !(container.layout == .tabGroup && container.children.count > 1) else { return }
        let childPaneIds = container.children.map(agentPaneIds)
        for index in childPaneIds.indices.dropLast() {
            for lhs in childPaneIds[index] {
                for rhs in childPaneIds[index + 1] {
                    setAgentPaneRelation(lhs, rhs, orientation: container.orientation, byPane: &byPane)
                }
            }
        }
        for child in container.children {
            visitAgentPaneRelations(child, byPane: &byPane)
        }
    }

    @MainActor
    private func setAgentPaneRelation(
        _ lhs: String,
        _ rhs: String,
        orientation: Orientation,
        byPane: inout [String: AgentPaneRelation],
    ) {
        if orientation == .h {
            setAgentPaneRelation(lhs, \.right, rhs, byPane: &byPane)
            setAgentPaneRelation(rhs, \.left, lhs, byPane: &byPane)
        } else {
            setAgentPaneRelation(lhs, \.below, rhs, byPane: &byPane)
            setAgentPaneRelation(rhs, \.above, lhs, byPane: &byPane)
        }
    }

    private func setAgentPaneRelation(
        _ paneId: String,
        _ keyPath: WritableKeyPath<AgentPaneRelation, String?>,
        _ value: String?,
        byPane: inout [String: AgentPaneRelation],
    ) {
        guard let value else { return }
        var item = byPane[paneId] ?? AgentPaneRelation(workspace: name, paneId: paneId)
        item[keyPath: keyPath] = value
        byPane[paneId] = item
    }

    @MainActor
    private func agentPaneIds(_ node: WorkspaceTabLayoutNode) -> [String] {
        switch node {
            case .window(let leaf): return ["pane-\(leaf.window.windowId)"]
            case .container(let container):
                if container.layout == .tabGroup && container.children.count > 1 { return [agentPaneIdForTabGroup(tabGroupId: agentTabGroupId(container.source))] }
                return container.children.flatMap(agentPaneIds)
        }
    }
}
