import AppKit
import Common

struct OpenLauncherCommand: Command {
    let args: OpenLauncherCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        var workspace = focus.workspace
        var newTab: WorkspaceLauncherNewTab?
        if args.newWorkspace {
            let monitor = workspace.workspaceMonitor
            let projectId = activeWorkspaceProjectId(for: monitor)
            if config.usesBrowserTabs {
                // A new tab, like the sidebar's New Tab, closed again if nothing opens in it.
                newTab = newTabWorkspace(projectId: projectId, monitor: monitor)
                workspace = newTab?.workspace ?? workspace
            } else {
                workspace = getOrCreateAdjacentBlankWorkspace(projectId: projectId, monitor: monitor)
            }
            guard workspace.focusWorkspace() else { return io.err("Couldn't switch to a new workspace") }
        }
        guard workspace.isVisible else { return io.err("The launcher opens only for a workspace on screen") }
        let name = workspace.name
        // Shown once the command yields the main actor; each refresh repositions it.
        Task { @MainActor [newTab] in
            if !WorkspaceLauncherPanel.shared.show(forWorkspaceNamed: name, newTab: newTab), let newTab, newTab.isNew {
                runWorkspaceSidebarSession { closeUnusedNewTab(newTab) }
            }
        }
        return true
    }
}
