/// Parsers for the commands WinMux adds, reached from upstream's `initSubcommands` (cmdArgsManifest.swift).
func winMuxSubcommandParser(_ kind: CmdKind) -> any SubCommandParserProtocol {
    switch kind {
        case .agent: SubCommandParser(parseAgentCmdArgs)
        case .createProject: SubCommandParser(parseCreateProjectCmdArgs)
        case .deleteProject: SubCommandParser(parseDeleteProjectCmdArgs)
        case .doctor: SubCommandParser(DoctorCmdArgs.init)
        case .forgetWorkspace: SubCommandParser(ForgetWorkspaceCmdArgs.init)
        case .listProjects: SubCommandParser(parseListProjectsCmdArgs)
        case .moveNodeToProject: SubCommandParser(parseMoveNodeToProjectCmdArgs)
        case .openLauncher: SubCommandParser(OpenLauncherCmdArgs.init)
        case .openSidebar: SubCommandParser(OpenSidebarCmdArgs.init)
        case .palette: SubCommandParser(PaletteCmdArgs.init)
        case .project: SubCommandParser(parseProjectCmdArgs)
        case .renameProject: SubCommandParser(parseRenameProjectCmdArgs)
        case .saveWorkspace: SubCommandParser(SaveWorkspaceCmdArgs.init)
        case .setProjectColor: SubCommandParser(parseSetProjectColorCmdArgs)
        case .stackWith: SubCommandParser(StackWithCmdArgs.init)
        default: die("\(kind.rawValue) is not a WinMux command")
    }
}
