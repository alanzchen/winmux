/// What `winmux --help` prints. Shared by the CLI, which prints it itself, and WinMux's MCP server, which answers it
/// the same way. `includesClientCommands`: the commands only the CLI runs, without WinMux.app.
public func winmuxUsage(program: String, includesClientCommands: Bool = true) -> String {
    let clientCommands = includesClientCommands ? "chrome-extension install   Register the installed app as Chrome’s native host\n" : ""
    return """
        USAGE: \(program) [-h|--help] [-v|--version] <subcommand> [<args>...]

        SUBCOMMANDS:
        \(clientCommands)\(subcommandDescriptions.sortedBy { $0[0] }.toPaddingTable(columnSeparator: "   ").joined(separator: "\n"))
        """
}

/// What `winmux --version` prints: the CLI's own version when the CLI asks, and WinMux.app's.
public func winmuxVersionText(clientVersionAndHash: String?, serverVersionAndHash: String?) -> String {
    let server = "WinMux.app server version: \(serverVersionAndHash ?? "Unknown. The server is not running")"
    return clientVersionAndHash.map { "winmux CLI client version: \($0)\n\(server)" } ?? server
}
