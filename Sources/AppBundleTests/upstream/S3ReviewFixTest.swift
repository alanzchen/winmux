@testable import AppBundle
import Common
import Foundation
import XCTest

/// The S3 review fixes (docs/upstream-sync.md, S3 review fixes): D-S3-1 config error state, D-S3-2 exit codes, D-S3-4
/// test isolation.
@MainActor
final class S3ReviewFixTest: XCTestCase {
    private var directory: URL!
    private var previousConfig: Config!
    private var previousConfigUrl: URL!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        previousConfig = config
        previousConfigUrl = configUrl
        directory = FileManager.default.temporaryDirectory.appending(path: "s3-review-fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        config = previousConfig
        configUrl = previousConfigUrl
        resetConfigErrorStateForTests()
        TrayMenuModel.shared.isEnabled = true
        TrayMenuModel.shared.lastReloadConfigContainedWarnings = false
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, _ name: String = "winmux.toml") throws -> URL {
        let url = directory.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func reload(_ url: URL) async throws -> ReloadConfigResult {
        try await reloadConfig(args: ReloadConfigCmdArgs(rawArgs: []).copy(\.noGui, true), forceConfigUrl: url)
    }

    private func cli(_ args: [String]) async -> ServerAnswer {
        await runCliRequest(ClientRequest(args: args, stdin: "", windowId: nil, workspace: nil))
    }

    // MARK: D-S3-1

    func testAfterACleanReloadAnErroredOneKeepsTheLiveConfigUntilTheNextCleanOne() async throws {
        let file = try write("config-version = 2\n[workspace-sidebar]\nenabled = true\nmode = 'tabs'\n")
        let clean = try await reload(file)
        XCTAssertTrue(clean.appliedConfig && clean.isOk)
        XCTAssertTrue(config.usesBrowserTabs)
        XCTAssertNil(TrayMenuModel.shared.configErrorDetails)
        XCTAssertFalse(configWriteBackSuspended)

        try "config-version = 2\n[workspace-sidebar]\nenabled = true\nmode = 'tab'\n".write(to: file, atomically: true, encoding: .utf8)
        let errored = try await reload(file)
        XCTAssertFalse(errored.appliedConfig, "any error keeps the live config after a clean one")
        XCTAssertFalse(errored.isOk)
        XCTAssertTrue(config.usesBrowserTabs, "Tabs mode stays")
        XCTAssertTrue(configWriteBackSuspended)
        let details = try XCTUnwrap(TrayMenuModel.shared.configErrorDetails, "the menu keeps an item until a clean reload")
        XCTAssertTrue(details.body.contains("Possible values: sidebar, dock, tabs"), details.body)
        XCTAssertTrue(TrayMenuModel.shared.lastReloadConfigContainedWarnings)

        // A warning (no config-version) doesn't block the reload; the error state clears.
        try "[workspace-sidebar]\nenabled = true\nmode = 'sidebar'\n".write(to: file, atomically: true, encoding: .utf8)
        let warned = try await reload(file)
        XCTAssertTrue(warned.appliedConfig)
        XCTAssertFalse(config.usesBrowserTabs)
        XCTAssertNil(TrayMenuModel.shared.configErrorDetails)
        XCTAssertFalse(configWriteBackSuspended)
        XCTAssertTrue(TrayMenuModel.shared.lastReloadConfigContainedWarnings, "the warnings item")
    }

    func testBeforeAnyCleanConfigWhatParsesIsLoadedAndTheErrorStateStays() async throws {
        let file = try write("config-version = 2\ntab-group-padding = 31\n[workspace-sidebar]\nmode = 'tab'\n")
        let result = try await reload(file)
        XCTAssertTrue(result.appliedConfig, "startup loads what parses, as upstream does")
        XCTAssertEqual(config.tabGroupPadding, 31)
        XCTAssertNotNil(TrayMenuModel.shared.configErrorDetails)
        XCTAssertTrue(configWriteBackSuspended)

        // Still no clean config: the next errored one loads too.
        try "config-version = 2\ntab-group-padding = 32\n[workspace-sidebar]\nmode = 'tab'\n".write(to: file, atomically: true, encoding: .utf8)
        let again = try await reload(file)
        XCTAssertTrue(again.appliedConfig)
        XCTAssertEqual(config.tabGroupPadding, 32)
    }

    func testDryRunLeavesTheErrorStateAlone() async throws {
        let file = try write("config-version = 2\n[workspace-sidebar]\nmode = 'tab'\n")
        _ = try await reloadConfig(args: ReloadConfigCmdArgs(rawArgs: []).copy(\.noGui, true).copy(\.dryRun, true), forceConfigUrl: file)
        XCTAssertNil(TrayMenuModel.shared.configErrorDetails)
        XCTAssertFalse(configWriteBackSuspended)
    }

    /// Carbon S3-C3a with WinMux's real key, `[workspace-sidebar.workspace-labels]`: the labels stay, in memory and on
    /// disk, byte for byte.
    func testAnErroredConfigsWorkspaceLabelsSurviveReconcileAndAutomaticWrites() async throws {
        let text = """
            config-version = 2
            persistent-workspaces = ["1", 2]

            [workspace-sidebar.workspace-labels]
            1 = "Code"
            2 = "Mail"
            """
        let file = try write(text)
        let before = try Data(contentsOf: file)
        _ = Workspace.get(byName: "1").focusWorkspace()

        let result = try await reload(file)
        XCTAssertTrue(result.appliedConfig)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["2"], "Mail")
        XCTAssertTrue(configWriteBackSuspended)

        Workspace.reconcileWorkspaceState()
        clearWorkspaceSidebarLabelIfNeeded("2")
        try persistWorkspaceSidebarLabel(workspaceName: "2", label: nil, targetUrl: file)
        try persistWorkspaceSidebarProjectOrder(["p1"], targetUrl: file)
        try persistWorkspaceSidebarProjectLabel(projectId: "p1", label: "Auto", targetUrl: file)

        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["2"], "Mail")
        XCTAssertEqual(try Data(contentsOf: file), before, "no automatic write while the config has errors")

        // The user's own edit still goes through the validated writer.
        try persistWorkspaceSidebarLabel(workspaceName: "2", label: "Inbox", targetUrl: file, userInitiated: true)
        let edited = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(edited.contains("\"2\" = \"Inbox\"") && !edited.contains("Mail"), edited)
        XCTAssertTrue(edited.contains("persistent-workspaces = [\"1\", 2]"), edited)
    }

    func testAutomaticWritesRunAgainAfterACleanReload() async throws {
        let file = try write("config-version = 2\n\n[workspace-sidebar.workspace-labels]\n9 = \"Gone\"\n")
        let result = try await reload(file)
        XCTAssertTrue(result.isOk)
        XCTAssertFalse(configWriteBackSuspended)
        try persistWorkspaceSidebarLabel(workspaceName: "9", label: nil, targetUrl: file)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Gone"))
    }

    // MARK: D-S3-2

    func testConditionalCommandsReportErrorsAsTwoOnEveryServerPath() async {
        let format = await cli(["list-windows", "--all", "--format", "%{nonexistent}"])
        XCTAssertEqual(format.exitCode, 2, "an invalid --format is a usage error")
        let unknownFlag = await cli(["list-windows", "--bogus"])
        XCTAssertEqual(unknownFlag.exitCode, 1, "other parse failures over MCP stay 1, as in v0.6.422")
        let badTest = await cli(["test"])
        XCTAssertEqual(badTest.exitCode, 2)
        let badTrigger = await cli(["trigger-binding", "alt-h", "--bogus"])
        XCTAssertEqual(badTrigger.exitCode, 1, "trigger-binding isn't a conditional command")

        TrayMenuModel.shared.isEnabled = false
        let disabledTestNot = await cli(["test-not", "%{workspace}", "=", "1"])
        XCTAssertEqual(disabledTestNot.exitCode, 2)
        let disabledWorkspace = await cli(["workspace", "1"])
        XCTAssertEqual(disabledWorkspace.exitCode, 1)
        let disabledTrigger = await cli(["trigger-binding", "alt-h", "--mode", "main"])
        XCTAssertEqual(disabledTrigger.exitCode, 1)
    }

    func testTriggerBindingReportsTheWholeBinding() async {
        let focused = focus.workspace.name
        let parsed = parseConfig(
            """
            config-version = 2
            [mode.main.binding]
                alt-a = ['test %{workspace} = \(focused)', 'workspace \(focused)']
                alt-b = ['test %{window-id} = 1', 'workspace \(focused)']
                alt-c = ['move-node-to-workspace 1', 'test %{window-id} = 1']
                alt-d = ['test %{workspace} = not-\(focused)', 'workspace \(focused)']
                alt-e = ['workspace \(focused)', 'move-node-to-workspace 1']
            """
        )
        XCTAssertTrue(parsed.errors.isEmpty, "\(parsed.errors)")
        config = parsed.config
        XCTAssertNil(focus.windowOrNil)

        func trigger(_ key: String) async -> Int32 {
            await cli(["trigger-binding", key, "--mode", "main"]).exitCode
        }
        let allSucceeded = await trigger("alt-a")
        XCTAssertEqual(allSucceeded, 0)
        let errorFirst = await trigger("alt-b")
        XCTAssertEqual(errorFirst, 2, "a conditional error is 2 even when a later command succeeds")
        let errorAfterFailure = await trigger("alt-c")
        XCTAssertEqual(errorAfterFailure, 2)
        let falseFirst = await trigger("alt-d")
        XCTAssertEqual(falseFirst, 1, "a false condition fails the binding, as any failed command does")
        let failureLast = await trigger("alt-e")
        XCTAssertEqual(failureLast, 1)
    }

    /// Astra S3-R2-A1: `trigger-binding`'s own failures are ordinary failed commands, 1 as in v0.6.422, through the CLI
    /// server and MCP, and so is a nested one. Only a conditional error is 2, nested or not.
    func testTriggerBindingLookupFailuresAreOrdinaryFailures() async throws {
        let focused = focus.workspace.name
        let parsed = parseConfig(
            """
            config-version = 2
            [mode.main.binding]
                alt-j = ['trigger-binding alt-h --mode main', 'workspace \(focused)']
                alt-k = ['trigger-binding alt-h --mode removed']
                alt-l = ['test %{window-id} = 1']
                alt-m = ['trigger-binding alt-l --mode main', 'workspace \(focused)']
            """
        )
        XCTAssertTrue(parsed.errors.isEmpty, "\(parsed.errors)")
        config = parsed.config
        XCTAssertNil(focus.windowOrNil)
        let tool = try XCTUnwrap(mcpTools.first { $0.name == "winmux" })

        for (args, expected) in [
            ("trigger-binding alt-h --mode main", 1),
            ("trigger-binding alt-h --mode removed", 1),
            ("trigger-binding alt-j --mode main", 1),
            ("trigger-binding alt-k --mode main", 1),
            ("trigger-binding alt-m --mode main", 2),
        ] as [(String, Int32)] {
            let split = try args.splitArgs().get()
            let server = await cli(split)
            XCTAssertEqual(server.exitCode, expected, "CLI server: \(args): \(server.stderr)")
            guard case .success(let json) = await tool.run(["args": .array(split.map(MCPJSON.string))]) else {
                XCTFail("MCP: \(args) failed")
                continue
            }
            XCTAssertEqual(json["structuredContent"]?["exitCode"], .int(Int(expected)), "MCP: \(args)")
        }
    }

    // MARK: D-S3-4

    func testLegacyLaunchAgentCleanupOnlyTouchesTheDirectoryATestPasses() throws {
        let agents = directory.appending(path: "LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appending(path: WinMuxHooks.legacyLaunchAgentPlists[0])
        try Data().write(to: plist)
        WinMuxHooks.cleanupLaunchAgentPlists(in: agents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }
}
