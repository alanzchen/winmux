import Common
import Foundation

struct AgentWorkspaceLayout: Codable {
    let name: String
    let focusPane: AgentPaneRef?
    let layout: AgentLayoutNode
    let floating: [AgentPaneRef]?

    private enum CodingKeys: String, CodingKey {
        case name
        case focusPane = "focus"
        case layout
        case floating
    }

    @MainActor
    func validate(appendTo errors: inout [String]) async throws {
        var orderedWindowIds: [UInt32] = []
        layout.collectWindowIds(result: &orderedWindowIds)
        for ref in floating ?? [] {
            ref.resolveNode()?.allLeafWindowsRecursive.forEach { orderedWindowIds.append($0.windowId) }
        }

        let windowIds = Set(orderedWindowIds)
        for windowId in duplicateAgentWindowIds(in: orderedWindowIds) {
            errors.append("setWorkspaceLayout '\(name)': window \(windowId) appears more than once")
        }
        for windowId in windowIds where Window.get(byId: windowId) == nil {
            errors.append("setWorkspaceLayout '\(name)': window \(windowId) does not exist")
        }
        for ref in floating ?? [] where ref.resolveNode() == nil {
            errors.append("setWorkspaceLayout '\(name)': floating pane does not exist")
        }
        if let refusal = pinRefusal() { errors.append(refusal.message) }
    }

    /// The windows this layout puts in its tab, laid out or floating, wherever they are now.
    @MainActor
    private var placedWindows: [Window] {
        var windowIds: [UInt32] = []
        layout.collectWindowIds(result: &windowIds)
        return windowIds.compactMap { Window.get(byId: $0) } + (floating ?? []).flatMap { $0.resolveNode()?.allLeafWindowsRecursive ?? [] }
    }

    /// Why the pins' rule refuses this layout, before anything changes; nil where it may be made. A
    /// pin takes in no window it hasn't got, but an empty pin one.
    @MainActor
    func pinRefusal() -> WorkspaceSidebarPinPolicyRefusal? {
        guard let target = Workspace.existing(byName: name) else { return nil }
        return workspaceSidebarPinLayoutRefusal(placedWindows, for: target).map { .init("setWorkspaceLayout '\(name)': \($0.message)") }
    }

    @MainActor
    func apply() async throws {
        // The pinned splits it takes windows from, or lays out, keep track of their windows, saved first.
        if config.usesBrowserTabs {
            try saveWorkspaceSidebarPinCompositions(of: ([Workspace.existing(byName: name)] + placedWindows.map(\.nodeWorkspace))
                .compactMap { $0 })
        }
        // Checked again as it's made: an earlier change in the same request may have changed the pins.
        if let refusal = pinRefusal() { throw refusal }
        let existedBefore = Workspace.existing(byName: name) != nil
        let workspace = Workspace.get(byName: name)
        if !existedBefore {
            workspace.assignProject(workspaceContextProjectId(of: focus.workspace))
        }
        workspace.seedMonitorIfNeeded(focusPane?.resolveNode()?.nodeMonitor ?? focus.workspace.workspaceMonitor)
        let oldWindows = workspace.allLeafWindowsRecursive
        // A pin whose one window goes into this ordinary tab lends it there, as a move does. Saved first,
        // so nothing changes if it can't be.
        let loans = workspaceSidebarIsPinned(workspace)
            ? [] : placedWindows.compactMap { workspaceSidebarPinLoan(taking: $0, to: workspace) }
        try lendWorkspaceSidebarPinWindows(loans)
        var referenced: Set<UInt32> = []
        layout.collectWindowIds(result: &referenced)
        for ref in floating ?? [] {
            ref.resolveNode()?.allLeafWindowsRecursive.forEach { referenced.insert($0.windowId) }
        }

        workspace.rootTilingContainer.unbindFromParent()
        switch layout {
            case .split:
                _ = try await layout.bind(into: workspace, index: INDEX_BIND_LAST)
            case .window, .tabGroup:
                _ = try await layout.bind(into: workspace.rootTilingContainer, index: INDEX_BIND_LAST)
        }
        bindFloatingPanes(to: workspace)
        restoreUnreferencedWindows(oldWindows, referenced: referenced, root: workspace.rootTilingContainer)
        layout.applySizeRatios(to: workspace.rootTilingContainer)
        if let focusNode = focusPane?.resolveNode() {
            _ = focusNode.mostRecentWindowRecursive?.focusWindow()
        }
    }

    @MainActor
    private func bindFloatingPanes(to workspace: Workspace) {
        for ref in floating ?? [] {
            if let node = ref.resolveNode(), let window = node as? Window {
                window.bindAsFloatingWindow(to: workspace)
            }
        }
    }

    @MainActor
    private func restoreUnreferencedWindows(_ oldWindows: [Window], referenced: Set<UInt32>, root: TilingContainer) {
        for window in oldWindows where !referenced.contains(window.windowId) && window.isBound {
            if window.nodeWorkspace == nil || window.nodeWorkspace == root.nodeWorkspace {
                window.bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
        }
    }
}
