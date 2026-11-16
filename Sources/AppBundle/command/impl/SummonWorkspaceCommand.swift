import AppKit
import Common

struct SummonWorkspaceCommand: Command {
    let args: SummonWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let workspace = Workspace.existing(byName: args.target.val.raw),
              isUserFacingWorkspace(workspace)
        else {
            return .fail(io.err("Workspace '\(args.target.val.raw)' doesn't exist"))
        }
        let monitor = focus.workspace.workspaceMonitor
        if monitor.activeWorkspace == workspace {
            return switch args.failIfNoop {
                case true: .fail
                case false:
                    .succ(io.err("Workspace '\(workspace.name)' is already visible on the focused monitor. Tip: use --fail-if-noop to exit with non-zero code"))
            }
        }
        if savedPinBlocks(workspace, on: monitor) {
            return .fail(io.err(savedPinRefusalMessage(workspace)))
        }
        if activateWorkspaceOnMonitorPreservingSourceViewport(workspace, targetMonitor: monitor) {
            noteSavedWorkspacePlacedByUser(workspace, on: monitor)
            return .from(bool: workspace.focusWorkspace())
        } else {
            return .fail(io.err("Can't move workspace '\(workspace.name)' to monitor '\(monitor.name)'. workspace-to-monitor-force-assignment doesn't allow it"))
        }
    }
}
