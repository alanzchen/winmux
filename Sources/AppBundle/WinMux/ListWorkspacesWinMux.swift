import AppKit
import Common

extension WinMuxHooks {
    /// Replaces `ListWorkspacesCommand.run`. Differences from upstream: workspaces come in sidebar order without
    /// hidden ones (`userFacingWorkspaces(orderedWorkspacesForPresentation())`), and `--empty` means "no window the
    /// sidebar shows" (`workspaceHasSidebarVisibleWindows`), so a workspace holding only native-fullscreen windows
    /// counts as empty.
    @MainActor
    static func listWorkspaces(_ args: ListWorkspacesCmdArgs, _ io: CmdIo) -> Bool {
        var result: [Workspace] = userFacingWorkspaces(orderedWorkspacesForPresentation())
        if let visible = args.filteringOptions.visible {
            result = result.filter { $0.isVisible == visible }
        }
        if !args.filteringOptions.onMonitors.isEmpty {
            let monitors: Set<CGPoint> = args.filteringOptions.onMonitors.resolveMonitors(io)
            if monitors.isEmpty { return false }
            result = result.filter { monitors.contains($0.workspaceMonitor.rect.topLeftCorner) }
        }
        if let empty = args.filteringOptions.empty {
            result = result.filter { !workspaceHasSidebarVisibleWindows($0) == empty }
        }

        if args.outputOnlyCount {
            return io.out("\(result.count)")
        } else {
            return result.map { AeroObj.workspace($0) }.writeFormattedOutput(
                to: io,
                format: args.format,
                json: args.json,
                ignoreRightPaddingVar: args._format.isEmpty,
            )
        }
    }
}
