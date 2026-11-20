extension TilingContainer {
    @MainActor
    var allAgentTabGroupsRecursive: [TilingContainer] {
        WorkspaceTabSnapshot.layout(of: self).agentTabGroups.map(\.source)
    }

    @MainActor
    var agentTabWindows: [Window] { WorkspaceTabSnapshot.tabRepresentatives(of: self) }

    @MainActor
    func agentRawLayoutNode() -> AgentRawLayoutNode { WorkspaceTabSnapshot.layout(of: self).agentRawLayoutNode() }


}

extension WorkspaceTabLayoutContainer {
    @MainActor
    func agentWorldLines(prefix: String) -> [String] {
        let nodeId = layout == .tabGroup && children.count > 1
            ? "tabGroup:\(agentTabGroupId(source))"
            : "container:\(orientation.rawValue):\(layout.rawValue)"
        let weightText = hasTilingParent ? "|weight:\(weight)" : ""
        return ["\(prefix)|\(nodeId)\(weightText)|children:\(children.count)"] + children.enumerated().flatMap { index, node in
            let childPrefix = "\(prefix).\(index)"
            switch node {
                case .window(let leaf): return ["\(childPrefix)|window:\(leaf.window.windowId)|weight:\(leaf.weight)"]
                case .container(let nested): return nested.agentWorldLines(prefix: childPrefix)
            }
        }
    }

    var agentTabGroups: [WorkspaceTabLayoutContainer] {
        if layout == .tabGroup && children.count > 1 { return [self] }
        return children.flatMap { node in
            if case .container(let nested) = node { return nested.agentTabGroups }
            return []
        }
    }

    @MainActor func agentRawLayoutNode() -> AgentRawLayoutNode {
        if layout == .tabGroup && children.count > 1 {
            return .tabGroup(tabGroupId: agentTabGroupId(source), activeWindowId: source.tabActiveWindow?.windowId,
                tabs: tabRepresentatives.map(\.windowId), size: source.agentSizeRatio)
        }
        return .split(direction: orientation == .h ? .horizontal : .vertical, layout: layout.rawValue,
            size: source.agentSizeRatio, children: children.map { node in
                switch node {
                    case .window(let leaf): .window(windowId: leaf.window.windowId, size: leaf.window.agentSizeRatio)
                    case .container(let nested): nested.agentRawLayoutNode()
                }
            })
    }
}
