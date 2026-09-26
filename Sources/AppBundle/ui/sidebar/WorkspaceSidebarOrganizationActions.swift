import AppKit
import Common

@MainActor
func handleWorkspaceSidebarOrganizationAction(_ action: WorkspaceSidebarAction) {
    guard !serverArgs.isReadOnly else { return }
    var launcherTab: WorkspaceLauncherNewTab?
    var editorTarget: WorkspaceSidebarIdentityTarget?
    runWorkspaceSidebarSession(afterLayout: {
        if let editorTarget { WorkspaceSidebarIdentityMenu.show(editorTarget, selectName: true) }
        if let launcherTab {
            if !WorkspaceLauncherPanel.shared.show(forWorkspaceNamed: launcherTab.workspace.name, newTab: launcherTab), launcherTab.isNew {
                runWorkspaceSidebarSession { closeUnusedNewTab(launcherTab) }
            }
        }
    }) {
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
                if favorite { try saveWorkspaceSidebarIdentity(workspace) }
                try store.update { state in
                    state.workspaces[name, default: .init()].isFavorite = favorite
                    if favorite {
                        for index in state.collections.indices { state.collections[index].workspaceNames.removeAll { $0 == name } }
                    }
                }
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
                try store.edit(id) { $0.isCollapsed.toggle() }
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
