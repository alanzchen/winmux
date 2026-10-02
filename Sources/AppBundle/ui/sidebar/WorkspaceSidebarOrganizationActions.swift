import AppKit
import Common

@MainActor
@discardableResult
func handleWorkspaceSidebarOrganizationAction(_ action: WorkspaceSidebarAction, targetMonitorScopeId: String? = nil)
    -> Task<Void, Never>? {
    guard !serverArgs.isReadOnly else { return nil }
    var launcherTab: WorkspaceLauncherNewTab?
    var editorTarget: WorkspaceSidebarIdentityTarget?
    return runWorkspaceSidebarSession(afterLayout: {
        if let editorTarget { WorkspaceSidebarIdentityMenu.show(editorTarget, selectName: true) }
        if let launcherTab {
            if !WorkspaceLauncherPanel.shared.show(forWorkspaceNamed: launcherTab.workspace.name, newTab: launcherTab), launcherTab.isNew {
                runWorkspaceSidebarSession { closeUnusedNewTab(launcherTab) }
            }
        }
    }, undoTitle: workspaceSidebarOrganizationUndoTitle(action)) {
        let store = workspaceSidebarOrganizationStore
        switch action {
            case .setWorkspaceColor(let name, let color):
                guard let workspace = Workspace.existing(byName: name) else { return }
                if color != nil { try saveWorkspaceSidebarIdentity(workspace) }
                try store.update { $0.workspaces[name, default: .init()].colorHex = color.flatMap(normalizedWorkspaceSidebarColorHex) }
            case .setWorkspaceEmoji(let name, let emoji):
                guard let workspace = Workspace.existing(byName: name) else { return }
                if emoji != nil { try saveWorkspaceSidebarIdentity(workspace) }
                try store.update { $0.workspaces[name, default: .init()].emoji = emoji.flatMap(normalizedWorkspaceProjectEmoji) }
            case .setWorkspaceFavorite(let name, let favorite):
                guard let workspace = Workspace.existing(byName: name) else { return }
                if favorite {
                    try setWorkspaceSidebarTabFavorite(workspace, true)
                } else {
                    // A pin in All Projects unpinned stays in the project the sidebar shows.
                    try unpinWorkspaceSidebarTab(workspace, into: workspaceSidebarContextProjectId(for: workspace,
                        targetMonitorScopeId: targetMonitorScopeId))
                }
            case .setWorkspacePinScope(let name, let scope, let projectId):
                guard let workspace = Workspace.existing(byName: name) else { return }
                try setWorkspaceSidebarTabPinScope(workspace, scope, projectId: projectId)
            case .setTabsFavorite(let names, let favorite):
                let tabs = names.compactMap(Workspace.existing(byName:))
                if favorite {
                    try setWorkspaceSidebarTabsFavorite(tabs, true)
                } else if let first = tabs.first {
                    // Pins in All Projects unpinned stay in the project the sidebar shows.
                    try unpinWorkspaceSidebarTabs(tabs, into: workspaceSidebarContextProjectId(for: first,
                        targetMonitorScopeId: targetMonitorScopeId))
                }
            case .setTabsPinScope(let names, let scope, let projectId):
                try setWorkspaceSidebarTabsPinScope(names.compactMap(Workspace.existing(byName:)), scope, projectId: projectId)
            case .createTabCollectionFromTabs(let names):
                let tabs = names.compactMap(Workspace.existing(byName:))
                // A group belongs to one project; the selection comes from one page, so one project.
                guard config.usesBrowserTabs, let projectId = tabs.first?.projectId,
                      tabs.allSatisfy({ $0.projectId == projectId }) else { return }
                try saveWorkspaceSidebarIdentities(tabs)
                let group = try store.create(projectId: projectId, workspaceNames: tabs.map(\.name))
                editorTarget = .collection(group.id)
            case .assignTabsToCollection(let names, let id):
                let tabs = names.compactMap(Workspace.existing(byName:))
                guard config.usesBrowserTabs, let projectId = tabs.first?.projectId,
                      tabs.allSatisfy({ $0.projectId == projectId }),
                      id.map({ id in store.state.collections.contains { $0.id == id && $0.projectId == projectId } }) ?? true
                else { return }
                if id != nil { try saveWorkspaceSidebarIdentities(tabs) }
                try store.assign(tabs.map(\.name), projectId: projectId, to: id)
            case .createTabCollection(let name):
                guard config.usesBrowserTabs, let workspace = Workspace.existing(byName: name) else { return }
                try saveWorkspaceSidebarIdentity(workspace)
                let group = try store.create(projectId: workspace.projectId, workspaceNames: [name])
                editorTarget = .collection(group.id)
            case .renameTabCollection(let id, let name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                try store.edit(id) { $0.name = trimmed }
            case .setTabCollectionColor(let id, let color):
                try store.edit(id) { $0.colorHex = color.flatMap(normalizedWorkspaceSidebarColorHex) }
            case .setTabCollectionEmoji(let id, let emoji):
                try store.edit(id) { $0.emoji = emoji.flatMap(normalizedWorkspaceProjectEmoji) }
            case .toggleTabCollection(let id):
                try toggleWorkspaceSidebarTabCollection(id,
                    monitorScopeId: targetMonitorScopeId ?? TrayMenuModel.shared.workspaceSidebarTargetMonitorScopeId)
            case .assignTabCollection(let name, let id):
                guard config.usesBrowserTabs, let workspace = Workspace.existing(byName: name) else { return }
                try assignWorkspaceToSidebarCollection(workspace, collectionId: id)
            case .moveTabCollection(let id, let projectId):
                guard config.usesBrowserTabs else { return }
                try moveWorkspaceSidebarCollection(id, to: projectId)
            case .ungroupTabCollection(let id):
                try store.update { $0.collections.removeAll { $0.id == id } }
            case .createTabInCollection(let id, let scope):
                guard config.usesBrowserTabs, let monitor = workspaceSidebarMonitor(forScopeId: scope),
                      let tab = try newTabInSidebarCollection(id, monitor: monitor) else { return }
                if tab.workspace.focusWorkspace() { launcherTab = tab }
                else { closeUnusedNewTab(tab) }
            case .toggleTabsSidebar:
                let expanded = !config.workspaceSidebar.tabsAlwaysExpanded
                if !isUnitTest {
                    let url = preferredEditableConfigUrl()
                    let text = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try updateWorkspaceSidebarScalarConfig(in: text, key: "tabs-always-expanded", renderedValue: expanded ? "true" : "false")
                        .write(to: url, atomically: true, encoding: .utf8)
                }
                config.workspaceSidebar.tabsAlwaysExpanded = expanded
            default: return
        }
        await updateWorkspaceSidebarModel()
    }
}

func workspaceSidebarOrganizationUndoTitle(_ action: WorkspaceSidebarAction) -> String? {
    switch action {
        case .setWorkspaceFavorite(_, let pinned): pinned ? "Pin Tab" : "Unpin Tab"
        case .setWorkspacePinScope(_, let scope, _): workspaceSidebarPinScopeUndoTitle(scope)
        case .createTabCollection: "Create Group"
        case .assignTabCollection, .assignTabsToCollection: "Move to Group"
        case .createTabCollectionFromTabs: "Group Tabs"
        case .setTabsFavorite(_, let pinned): pinned ? "Pin Tabs" : "Unpin Tabs"
        case .setTabsPinScope(_, let scope, _): workspaceSidebarTabsPinScopeUndoTitle(scope)
        case .ungroupTabCollection: "Ungroup Tabs"
        case .moveTabCollection: "Move Group"
        case .renameTabCollection: "Rename Group"
        case .setWorkspaceColor, .setWorkspaceEmoji, .setTabCollectionColor, .setTabCollectionEmoji: "Change Appearance"
        default: nil
    }
}
