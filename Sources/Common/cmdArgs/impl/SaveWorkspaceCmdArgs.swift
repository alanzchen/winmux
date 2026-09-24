public struct SaveWorkspaceCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .saveWorkspace,
        allowInConfig: true,
        help: save_workspace_help_generated,
        flags: [
            "--workspace": optionalWorkspaceFlag(),
            "--name": singleValueSubArgParser(\.displayName, "<name>") { $0 },
            "--pin-to-display": optionalTrueBoolFlag(\.pinToDisplay),
            "--unpin-display": optionalFalseBoolFlag(\.pinToDisplay),
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
            "--json": trueBoolFlag(\.json),
        ],
        posArgs: [],
        conflictingOptions: [
            ["--pin-to-display", "--unpin-display"],
        ],
    )

    public var displayName: String?
    /// true pins the workspace to its display, false unpins it, nil leaves the pin alone.
    public var pinToDisplay: Bool?
    public var failIfNoop = false
    public var json = false
}
