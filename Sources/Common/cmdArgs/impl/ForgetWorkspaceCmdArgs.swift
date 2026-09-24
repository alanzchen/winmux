public struct ForgetWorkspaceCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .forgetWorkspace,
        allowInConfig: false,
        help: forget_workspace_help_generated,
        flags: [
            "--workspace": optionalWorkspaceFlag(),
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
            "--json": trueBoolFlag(\.json),
        ],
        posArgs: [],
    )

    public var failIfNoop = false
    public var json = false
}
