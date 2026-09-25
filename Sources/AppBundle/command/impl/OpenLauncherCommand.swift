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
        guard workspace.isVisible else { return io.err("The launcher opens only for a workspace on screen") }
        let name = workspace.name
        // Shown once the command yields the main actor; each refresh repositions it.
        Task { @MainActor in WorkspaceLauncherPanel.shared.show(forWorkspaceNamed: name) }
        return true
    }
}
