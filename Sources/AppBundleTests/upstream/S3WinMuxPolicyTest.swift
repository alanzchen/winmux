@testable import AppBundle
import Common
import Foundation
import XCTest

/// WinMux's S3 decisions (docs/upstream-sync.md, S3 outcome): the CLI's exit codes, reload with minor or severe
/// errors, and the config-version warning's link.
@MainActor
final class S3WinMuxPolicyTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func cli(_ args: [String]) async -> ServerAnswer {
        await runCliRequest(ClientRequest(args: args, stdin: "", windowId: nil, workspace: nil))
    }

    func testCliReportsAFailedCommandAsOneAndConditionsAsUpstream() async {
        let focused = focus.workspace.name
        let noop = await cli(["workspace", "--fail-if-noop", focused])
        XCTAssertEqual(noop.exitCode, 1, "a failed command exits 1, as docs/cli.md documents")
        let succeeded = await cli(["workspace", focused])
        XCTAssertEqual(succeeded.exitCode, 0)

        let code1 = await cli(["test", "%{workspace}", "=", focused]).exitCode
        XCTAssertEqual(code1, 0, "test: true")
        let code2 = await cli(["test", "%{workspace}", "=", "not-\(focused)"]).exitCode
        XCTAssertEqual(code2, 1, "test: false")
        let code3 = await cli(["test", "%{workspace-is-focused}", "~=", "x"]).exitCode
        XCTAssertEqual(code3, 2, "test: error")
        let code4 = await cli(["true"]).exitCode
        XCTAssertEqual(code4, 0)
        let code5 = await cli(["false"]).exitCode
        XCTAssertEqual(code5, 1)
    }

    func testReloadAppliesAConfigWithMinorErrorsAndKeepsOneWithSevereErrors() async throws {
        let previous = config
        let previousUrl = configUrl
        defer { config = previous; configUrl = previousUrl }
        let directory = FileManager.default.temporaryDirectory.appending(path: "s3-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let args = ReloadConfigCmdArgs(rawArgs: []).copy(\.noGui, true)

        let minor = directory.appending(path: "minor.toml")
        try "config-version = 2\ntab-group-padding = 47\nunknown-key = 1\n".write(to: minor, atomically: true, encoding: .utf8)
        let applied = try await reloadConfig(args: args, forceConfigUrl: minor)
        XCTAssertTrue(applied.appliedConfig)
        XCTAssertFalse(applied.isOk)
        XCTAssertEqual(config.tabGroupPadding, 47)
        XCTAssertTrue(applied.stdout.hasPrefix("Failed to parse '\(minor.path)'. 1 error(s). 0 warning(s)"), applied.stdout)
        XCTAssertTrue(applied.stdout.contains("[ERROR] unknown-key: Unknown top-level key"), applied.stdout)

        let severe = directory.appending(path: "severe.toml")
        try "tab-group-padding = 12\nnot toml = = =\n".write(to: severe, atomically: true, encoding: .utf8)
        let kept = try await reloadConfig(args: args, forceConfigUrl: severe)
        XCTAssertFalse(kept.appliedConfig)
        XCTAssertEqual(config.tabGroupPadding, 47, "a severe error keeps the previous config")
    }

    func testOutdatedConfigVersionWarningLinksWinMuxDocs() {
        let result = parseConfig("")
        XCTAssertEqual(result.errors, [])
        XCTAssertTrue(result.allowReloadConfig)
        XCTAssertEqual(result.strWarnings.count, 1)
        XCTAssertTrue(result.strWarnings[0].contains(winMuxConfigVersionGuideUrl), result.strWarnings[0])
        XCTAssertFalse(result.strWarnings[0].contains("nikitabobko"))
    }
}
