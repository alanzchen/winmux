extension Workspace {
    @MainActor
    func agentPaneInfos(content: WorkspaceTabSnapshot? = nil) -> [AgentPaneInfo] {
        let content = content ?? WorkspaceTabSnapshot(self)
        var result = content.floatingMembers.map { agentFloatingPaneInfo($0.window) }
        visitAgentPaneInfos(.container(content.root), result: &result)
        return result
    }

    @MainActor
    private func visitAgentPaneInfos(_ node: WorkspaceTabLayoutNode, result: inout [AgentPaneInfo]) {
        switch node {
            case .window(let leaf):
                result.append(agentWindowPaneInfo(leaf.window))
            case .container(let container):
                if container.layout == .tabGroup && container.children.count > 1 {
                    result.append(agentTabGroupPaneInfo(container))
                } else {
                    for child in container.children {
                        visitAgentPaneInfos(child, result: &result)
                    }
                }

        }
    }

    @MainActor
    private func agentFloatingPaneInfo(_ window: Window) -> AgentPaneInfo {
        AgentPaneInfo(
            paneId: "pane-\(window.windowId)",
            kind: .window,
            workspace: name,
            windowId: window.windowId,
            tabGroupId: nil,
            label: window.app.name ?? window.app.rawAppBundleId ?? "Window \(window.windowId)",
            size: window.agentPaneSizingNode.agentSizeRatio,
            sizeAxis: window.agentPaneSizingNode.agentSizeAxis,
            frame: (window.lastKnownActualRect ?? window.lastAppliedLayoutPhysicalRect ?? window.lastAppliedLayoutVirtualRect).map(AgentRect.init),
        )
    }

    @MainActor
    private func agentWindowPaneInfo(_ window: Window) -> AgentPaneInfo {
        agentFloatingPaneInfo(window)
    }

    @MainActor
    private func agentTabGroupPaneInfo(_ content: WorkspaceTabLayoutContainer) -> AgentPaneInfo {
        let container = content.source
        let tabGroupId = agentTabGroupId(container)
        return AgentPaneInfo(
            paneId: agentPaneIdForTabGroup(tabGroupId: tabGroupId),
            kind: .tabGroup,
            workspace: name,
            windowId: nil,
            tabGroupId: tabGroupId,
            label: "Tab Group \(content.tabRepresentatives.map(\.windowId))",
            size: container.agentSizeRatio,
            sizeAxis: container.agentSizeAxis,
            frame: (container.lastAppliedLayoutPhysicalRect ?? container.lastAppliedLayoutVirtualRect).map(AgentRect.init),
        )
    }
}
