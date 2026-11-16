import Common
import Darwin
import Foundation
import Network

let usage = winmuxUsage(program: CommandLine.arguments.first ?? "winmux")
private let cliUsageOrParseErrorExitCode: Int32 = 2

@main
struct Main {
    static func main() async {
        if ChromeNativeHost.handle(Array(CommandLine.arguments.dropFirst())) { return }
        let args = CommandLine.arguments.slice(1...) ?? []

        if args.isEmpty {
            exit(cliUsageOrParseErrorExitCode, err: usage)
        }
        if args.first == "--help" || args.first == "-h" {
            exit(EXIT_CODE_ZERO, out: usage)
        }

        if args.first == "--version" || args.first == "-v" {
            let connection = NWConnection(to: NWEndpoint.unix(path: socketPath), using: .tcp)
            let serverVersionAndHash: String?
            switch await connection.initConnection().error {
                case nil:
                    let ans = await run(connection, [], stdin: "", windowId: nil, workspace: nil, failExitCode: 1)
                    serverVersionAndHash = ans.serverVersionAndHash
                case .nwError:
                    serverVersionAndHash = nil
                case .customError(let error):
                    exit(1, err: error)
            }
            print(winmuxVersionText(clientVersionAndHash: cliClientVersionAndHash, serverVersionAndHash: serverVersionAndHash))
            if serverVersionAndHash != nil && cliClientVersionAndHash != serverVersionAndHash {
                eprint(
                    """
                    Warning: WinMux client/server versions don't match. Possible fixes:
                      - Restart WinMux.app (server restart is required after each update)
                      - Reinstall and restart WinMux (corrupted installation)
                    """,
                )
            }
            exit(EXIT_CODE_ZERO)
        }

        let parsedArgs: any CmdArgs
        switch parseCmdArgs(args) {
            // Upstream's shortcut: these answer without the server.
            case .cmd(_ as TrueCmdArgs): exit(ConditionalExitCode._true.rawValue)
            case .cmd(_ as FalseCmdArgs): exit(ConditionalExitCode._false.rawValue)
            case .cmd(let commandArgs):
                parsedArgs = commandArgs
            case .help(let help):
                exit(0, out: help)
            case .failure(let e):
                exit(cliUsageOrParseErrorExitCode, err: e.msg)
        }

        // WinMux's contract (docs/cli.md): a failure reaching or talking to the server exits 1; a conditional command
        // (test, true, false) keeps upstream's 2 for errors, since 1 means false.
        let failExitCode: Int32 = isConditionalCommand(parsedArgs) ? ConditionalExitCode.fail.rawValue : 1

        let connection = NWConnection(to: NWEndpoint.unix(path: socketPath), using: .tcp)

        switch await connection.initConnection().error {
            case nil:
                break
            case .nwError(let error):
                exit(failExitCode, err: "Can't connect to WinMux server. Is WinMux.app running?\n\(error.localizedDescription)")
            case .customError(let error):
                exit(failExitCode, err: error)
        }

        var stdin = ""
        if shouldReadAgentStdin(parsedArgs) {
            switch readBoundedUtf8Stdin() {
                case .success(let input): stdin = input
                case .failure(let error): exit(1, err: error)
            }
        } else if shouldReadRelativeWorkspaceStdin(parsedArgs), hasStdin() {
            if !hasExplicitRelativeWorkspaceStdinFlag(parsedArgs) {
                exit(
                    failExitCode,
                    err: """
                        ERROR: Implicit stdin is detected (stdin is not TTY). Implicit stdin was forbidden in AeroSpace v0.20.0.
                        1. Please supply '--stdin' flag to make stdin explicit and preserve the old behavior
                        2. You can also use '--no-stdin' flag to behave as if no stdin was supplied
                        Breaking change issue: https://github.com/nikitabobko/AeroSpace/issues/1683
                        """,
                )
            }
            if shouldUseRelativeWorkspaceStdin(parsedArgs) {
                var lineCount = 0
                while let line = readLine(strippingNewline: false) {
                    stdin += line
                    lineCount += 1
                    if lineCount > 1000 {
                        exit(failExitCode, err: "stdin number of lines limit is exceeded")
                    }
                }
            }
        }

        let environment = ProcessInfo.processInfo.environment
        let windowId = environment[AEROSPACE_WINDOW_ID].flatMap(UInt32.init)
        let workspace = environment[AEROSPACE_WORKSPACE]

        // Handle subscribe command specially
        if parsedArgs is SubscribeCmdArgs {
            await runSubscribe(connection, args, windowId: windowId, workspace: workspace, failExitCode: failExitCode)
            exit(EXIT_CODE_ZERO) // Should not reach here
        }

        let ans = await run(connection, args, stdin: stdin, windowId: windowId, workspace: workspace, failExitCode: failExitCode)

        if !ans.stdout.isEmpty { print(ans.stdout) }
        if !ans.stderr.isEmpty { eprint(ans.stderr) }
        if ans.exitCode != EXIT_CODE_ZERO && ans.serverVersionAndHash != cliClientVersionAndHash {
            eprint(
                """
                Warning: WinMux client/server versions don't match
                  - winmux CLI client version: \(cliClientVersionAndHash)
                  - WinMux.app server version: \(ans.serverVersionAndHash)
                  Possible fixes:
                  - Restart WinMux.app (server restart is required after each update)
                  - Reinstall and restart WinMux (corrupted installation)
                """,
            )
        }
        exit(ans.exitCode)
    }
}

func shouldReadAgentStdin(_ args: any CmdArgs) -> Bool {
    (args as? AgentCmdArgs)?.useStdin == true
}

private func shouldReadRelativeWorkspaceStdin(_ args: any CmdArgs) -> Bool {
    switch args {
        case let args as WorkspaceCmdArgs:
            args.target.val.isRelative
        case let args as MoveNodeToWorkspaceCmdArgs:
            args.target.val.isRelative
        default:
            false
    }
}

private func hasExplicitRelativeWorkspaceStdinFlag(_ args: any CmdArgs) -> Bool {
    switch args {
        case let args as WorkspaceCmdArgs:
            args.explicitStdinFlag != nil
        case let args as MoveNodeToWorkspaceCmdArgs:
            args.explicitStdinFlag != nil
        default:
            true
    }
}

private func shouldUseRelativeWorkspaceStdin(_ args: any CmdArgs) -> Bool {
    switch args {
        case let args as WorkspaceCmdArgs:
            args.useStdin
        case let args as MoveNodeToWorkspaceCmdArgs:
            args.useStdin
        default:
            false
    }
}

func runSubscribe(_ connection: NWConnection, _ args: StrArrSlice, windowId: UInt32?, workspace: String?, failExitCode: Int32) async {
    if let e = await connection.writeAtomic(ClientRequest(args: args.toArray(), stdin: "", windowId: windowId, workspace: workspace)).error {
        exit(failExitCode, err: "Failed to write to server socket: \(e)")
    }

    while true {
        switch await connection.readNonAtomic() {
            case .success(let data):
                if let str = String(data: data, encoding: .utf8) {
                    print(str)
                    unsafe fflush(stdout)
                } else {
                    exit(failExitCode, err: "Can't convert bytes to utf8 String")
                }
            case .failure(let e):
                exit(failExitCode, err: "runSubscribe error: \(e)")
        }
    }
}

func run(_ connection: NWConnection, _ args: StrArrSlice, stdin: String, windowId: UInt32?, workspace: String?, failExitCode: Int32) async -> ServerAnswer {
    if let e = await connection.writeAtomic(ClientRequest(args: args.toArray(), stdin: stdin, windowId: windowId, workspace: workspace)).error {
        exit(failExitCode, err: "Failed to write to server socket: \(e)")
    }

    switch await connection.readNonAtomic() {
        case .success(let answer):
            return (try? JSONDecoder().decode(ServerAnswer.self, from: answer)) ?? exitT(EXIT_CODE_TWO, err: "Failed to parse server response: \(String(data: answer, encoding: .utf8).prettyDescription)")
        case .failure(let error):
            exit(failExitCode, err: "Failed to read from server socket: \(error)")
    }
}

private func isConditionalCommand(_ args: any CmdArgs) -> Bool { isConditional(args) }
private func isConditional<T: CmdArgs>(_ args: T) -> Bool { T.ExitCodeType.self == ConditionalExitCode.self }
