import AppKit
import Common

struct OpenLauncherCommand: Command {
    let args: OpenLauncherCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        var workspace = focus.workspace
        if args.newWorkspace {
            let monitor = workspace.workspaceMonitor
            workspace = getOrCreateAdjacentBlankWorkspace(projectId: activeWorkspaceProjectId(for: monitor), monitor: monitor)
            guard workspace.focusWorkspace() else { return io.err("Couldn't switch to a new workspace") }
        }
        let name = workspace.name
        // Shown once this command's session has laid the workspace out.
        DispatchQueue.main.async { WorkspaceLauncherPanel.shared.show(forWorkspaceNamed: name) }
        return true
    }
}
