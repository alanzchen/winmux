import Common

/// Commands WinMux adds to AeroSpace's set, reached from upstream's `CmdArgs.toCommand` (cmdManifest.swift).
func winMuxCommand(_ args: any CmdArgs) -> any Command {
    switch args {
        case let args as AgentCmdArgs: AgentCommand(args: args)
        case let args as CreateProjectCmdArgs: CreateProjectCommand(args: args)
        case let args as DeleteProjectCmdArgs: DeleteProjectCommand(args: args)
        case let args as DoctorCmdArgs: DoctorCommand(args: args)
        case let args as ForgetWorkspaceCmdArgs: ForgetWorkspaceCommand(args: args)
        case let args as ListProjectsCmdArgs: ListProjectsCommand(args: args)
        case let args as MoveNodeToProjectCmdArgs: MoveNodeToProjectCommand(args: args)
        case let args as OpenLauncherCmdArgs: OpenLauncherCommand(args: args)
        case let args as OpenSidebarCmdArgs: OpenSidebarCommand(args: args)
        case let args as PaletteCmdArgs: PaletteCommand(args: args)
        case let args as ProjectCmdArgs: ProjectCommand(args: args)
        case let args as RenameProjectCmdArgs: RenameProjectCommand(args: args)
        case let args as SaveWorkspaceCmdArgs: SaveWorkspaceCommand(args: args)
        case let args as SetProjectColorCmdArgs: SetProjectColorCommand(args: args)
        case let args as StackWithCmdArgs: StackWithCommand(args: args)
        default: die("No WinMux command implementation for \(type(of: args).info.kind.rawValue)")
    }
}

extension Command {
    /// Some commands fully update the in-memory model and only need the light-session layout/UI pass.
    /// Native macOS state transitions or arbitrary side effects should keep the follow-up full refresh.
    var canSkipPostCommandRefresh: Bool {
        switch self {
            case is BalanceSizesCommand,
                 is ConfigCommand,
                 is CreateProjectCommand,
                 is DebugWindowsCommand,
                 is FlattenWorkspaceTreeCommand,
                 is FocusBackAndForthCommand,
                 is FocusCommand,
                 is FocusMonitorCommand,
                 is FullscreenCommand,
                 is JoinWithCommand,
                 is LayoutCommand,
                 is ListAppsCommand,
                 is ListExecEnvVarsCommand,
                 is ListModesCommand,
                 is ListMonitorsCommand,
                 is ListProjectsCommand,
                 is ListWindowsCommand,
                 is ListWorkspacesCommand,
                 is ModeCommand,
                 is MoveCommand,
                 is MoveMouseCommand,
                 is MoveNodeToMonitorCommand,
                 is MoveNodeToProjectCommand,
                 is MoveNodeToWorkspaceCommand,
                 is MoveWorkspaceToMonitorCommand,
                 is OpenSidebarCommand,
                 is ProjectCommand,
                 is RenameProjectCommand,
                 is ResizeCommand,
                 is SplitCommand,
                 is StackWithCommand,
                 is SetProjectColorCommand,
                 is SummonWorkspaceCommand,
                 is SwapCommand,
                 is VolumeCommand,
                 is WorkspaceBackAndForthCommand,
                 is WorkspaceCommand:
                true
            case is DeleteProjectCommand:
                false
            default:
                false
        }
    }
}

extension [Command] {
    var canSkipPostCommandRefresh: Bool {
        allSatisfy(\.canSkipPostCommandRefresh)
    }
}
