public struct ExecAndForgetCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public static let parser: CmdParser<Self> = .init(
        kind: .execAndForget,
        allowInConfig: true,
        help: exec_and_forget_help_generated,
        flags: [:],
        posArgs: [],
    )

    public init(bashScript: String) {
        self.commonState = .init([bashScript])
        self.bashScript = bashScript
    }

    /// Config keeps the Bash suffix verbatim, after an exact WinMux command name.
    public init?(configCommand: String) {
        let name = "exec-and-forget"
        guard configCommand.hasPrefix(name) else { return nil }
        let script = configCommand.dropFirst(name.count)
        guard script.isEmpty || script.first?.isWhitespace == true else { return nil }
        self.init(bashScript: String(script))
    }

    public let bashScript: String
}
