@testable import AppBundle
import Common
import XCTest

@MainActor
final class ExecCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseExecCommand() {
        testParseCommandSucc("exec-and-forget echo 'foo'", ExecAndForgetCmdArgs(bashScript: " echo 'foo'"))
    }

    func testExecPreservesBashSyntaxWithoutParsingItAsWinMuxCommands() {
        let script = #" printf '%s\n' "$(echo hello)" | cat && echo done; echo 'if then end' "#
        testParseCommandSucc("exec-and-forget" + script, ExecAndForgetCmdArgs(bashScript: script))
        XCTAssertEqual(canonicalConfigCommandScript("exec-and-forget" + script),
            ExecAndForgetCmdArgs(bashScript: script).description)
    }

    func testExecRequiresAnExactCommandName() {
        for command in ["exec-and-forgetful echo hello", "exec-and-forgetecho hello", "exec-and-forget; echo hello"] {
            XCTAssertNotNil(parseCommand(command).errorOrNil, command)
            XCTAssertNil(canonicalConfigCommandScript(command), command)
        }
    }

    func testExecAllowsWhitespaceBeforeItsScript() {
        for separator in [" ", "\t", "\n"] {
            let script = separator + "echo hello"
            testParseCommandSucc("exec-and-forget" + script, ExecAndForgetCmdArgs(bashScript: script))
            XCTAssertEqual(canonicalConfigCommandScript("exec-and-forget" + script),
                ExecAndForgetCmdArgs(bashScript: script).description)
        }
    }
}
