@testable import Cli
import Common
import Foundation
import XCTest

final class CliHelpTest: XCTestCase {
    func testEveryCliCommandAppearsExactlyOnceInTopLevelHelp() {
        let advertisedCommands = subcommandDescriptions.map {
            $0[0].trimmingCharacters(in: .whitespaces)
        }
        let expectedCommands = CmdKind.allCases
            .filter { $0 != .execAndForget }
            .map(\.rawValue)

        XCTAssertEqual(advertisedCommands.count, Set(advertisedCommands).count, "Top-level CLI help contains duplicate commands")
        XCTAssertEqual(Set(advertisedCommands), Set(expectedCommands))
    }

    /// The help and version text the CLI prints, now shared with WinMux's MCP server, is as the CLI printed it.
    func testTheSharedHelpAndVersionTextIsTheCLIsOwn() {
        let table = subcommandDescriptions.sortedBy { $0[0] }.toPaddingTable(columnSeparator: "   ").joined(separator: "\n")
        let head = "USAGE: winmux [-h|--help] [-v|--version] <subcommand> [<args>...]\n\nSUBCOMMANDS:\n"
        XCTAssertEqual(winmuxUsage(program: "winmux"),
            head + "chrome-extension install   Register the installed app as Chrome’s native host\n" + table)
        XCTAssertEqual(winmuxUsage(program: "winmux", includesClientCommands: false), head + table)
        XCTAssertEqual(usage, winmuxUsage(program: CommandLine.arguments.first ?? "winmux"))
        XCTAssertEqual(winmuxVersionText(clientVersionAndHash: "1.0 abc", serverVersionAndHash: nil),
            "winmux CLI client version: 1.0 abc\nWinMux.app server version: Unknown. The server is not running")
        XCTAssertEqual(winmuxVersionText(clientVersionAndHash: nil, serverVersionAndHash: "1.0 abc"), "WinMux.app server version: 1.0 abc")
    }
}
