import Common

/// The exit code WinMux's CLI and MCP `winmux` tool report for a command's result (docs/cli.md): 0 success, 1 a failed
/// command. Upstream (5ad04a76) exits 2 for a failed command; WinMux keeps 1, which scripts rely on, and keeps 2 for
/// local usage and parse errors. Conditional commands (`test`, `test-not`, `true`, `false`) keep upstream's 0 true,
/// 1 false, 2 error.
func winMuxCliExitCode(_ command: any Command, _ code: Int32ExitCode) -> Int32 {
    if isConditional(command.args) { return code.rawValue }
    return code.rawValue == EXIT_CODE_TWO ? 1 : code.rawValue
}

private func isConditional<T: CmdArgs>(_ args: T) -> Bool { T.ExitCodeType.self == ConditionalExitCode.self }
