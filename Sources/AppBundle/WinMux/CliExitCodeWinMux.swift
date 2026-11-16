import Common

/// The exit code WinMux's CLI and MCP `winmux` tool report for a command's result (docs/cli.md): 0 success, 1 a failed
/// command. Upstream (5ad04a76) exits 2 for a failed command; WinMux keeps 1, which scripts rely on, and keeps 2 for
/// usage and parse errors. Conditional commands (`test`, `test-not`, `true`, `false`) keep upstream's 0 true, 1 false,
/// 2 error. `trigger-binding` already answers in these terms (`WinMuxHooks.runBindingForCli`).
func winMuxCliExitCode(_ command: any Command, _ code: Int32ExitCode) -> Int32 {
    if isConditional(command.args) || command is TriggerBindingCommand { return code.rawValue }
    return code.rawValue == EXIT_CODE_TWO ? 1 : code.rawValue
}

/// A request the server refuses before running it (WinMux disabled, the main thread unreachable): 1 as in v0.6.422,
/// but 2 for a conditional command, whose 1 means "false".
func winMuxRefusalExitCode(_ args: [String]) -> Int32 {
    isConditionalKind(args.first) ? ConditionalExitCode.fail.rawValue : 1
}

/// A request the server can't parse (MCP and raw socket clients; the CLI parses locally and exits 2). v0.6.422 answered
/// 1; that stays for existing commands. A conditional command's usage error and an invalid `--format` (which upstream
/// S3 moved from run time to parsing) answer 2, as on the CLI.
func winMuxServerParseFailureExitCode(_ args: [String]) -> Int32 {
    if isConditionalKind(args.first) { return ConditionalExitCode.fail.rawValue }
    if let index = args.firstIndex(of: "--format"), index + 1 < args.count {
        var withoutFormat = args
        withoutFormat.removeSubrange(index ... index + 1)
        // The arguments parse without the format: the format is what failed.
        if case .cmd = parseCommand(withoutFormat) { return EXIT_CODE_TWO }
    }
    return 1
}

private func isConditionalKind(_ name: String?) -> Bool {
    switch name.flatMap(CmdKind.init(rawValue:)) {
        case .test?, .testNot?, ._true?, ._false?: true
        default: false
    }
}

private func isConditional<T: CmdArgs>(_ args: T) -> Bool { T.ExitCodeType.self == ConditionalExitCode.self }
