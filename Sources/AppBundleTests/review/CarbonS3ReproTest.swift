@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class CarbonS3ReproTest: XCTestCase {
    private var savedActiveMode: String?
    private var savedIsEnabled = true
    private var savedConfigUrl: URL!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        savedActiveMode = activeMode
        savedIsEnabled = TrayMenuModel.shared.isEnabled
        savedConfigUrl = configUrl
        // Prevent any reloadConfig call from registering real Carbon hotkeys in tests.
        activeMode = nil
        WinMuxToastPanel.shared.dismiss()
    }

    override func tearDown() async throws {
        resetHotKeys()
        activeMode = savedActiveMode
        TrayMenuModel.shared.isEnabled = savedIsEnabled
        TrayMenuModel.shared.lastReloadConfigContainedWarnings = false
        configUrl = savedConfigUrl
        WinMuxToastPanel.shared.dismiss()
    }

    /// S3-C1a: Over MCP (`runCliRequest`), parse/usage errors on `test` and `test-not`
    /// return exitCode 1 ("false") instead of 2 ("error"), and `--format` parse errors
    /// return exitCode 1 instead of 2.
    func testMcpAndSocketRunCliRequestMisreportsParseErrorsAsExitCodeOne() async throws {
        let badTest = await runCliRequest(
            ClientRequest(args: ["test", "not-a-var", "=", "1"], stdin: "", windowId: nil, workspace: nil)
        )
        XCTAssertEqual(
            badTest.exitCode,
            2,
            "S3-C1a: `test` parse error returned \(badTest.exitCode) ('false') instead of 2 ('error'): \(badTest.stderr)",
        )

        let badTestNot = await runCliRequest(
            ClientRequest(args: ["test-not", "--unknown-flag"], stdin: "", windowId: nil, workspace: nil)
        )
        XCTAssertEqual(
            badTestNot.exitCode,
            2,
            "S3-C1a: `test-not` usage error returned \(badTestNot.exitCode) ('false') instead of 2 ('error'): \(badTestNot.stderr)",
        )

        let badFormat = await runCliRequest(
            ClientRequest(args: ["list-windows", "--all", "--format", "%{nonexistent}"], stdin: "", windowId: nil, workspace: nil)
        )
        XCTAssertEqual(
            badFormat.exitCode,
            2,
            "S3-C1a: MCP/socket `--format` parse error returned \(badFormat.exitCode) instead of documented usage/parse exit code 2",
        )
    }

    /// S3-C1b: When the WinMux server is disabled (`winmux enable off`), `test` and `test-not`
    /// return exitCode 1 ("false") instead of 2 ("error").
    func testDisabledServerMisreportsConditionalCommandsAsFalseExitCodeOne() async throws {
        TrayMenuModel.shared.isEnabled = false

        let answer = await runCliRequest(
            ClientRequest(args: ["test", "%{workspace}", "=", "1"], stdin: "", windowId: nil, workspace: nil)
        )
        XCTAssertEqual(
            answer.exitCode,
            2,
            "S3-C1b: Disabled server returned exitCode \(answer.exitCode) ('false') for `test` instead of 2 ('error')",
        )
    }

    /// S3-C1c: `trigger-binding` rewrites `test` runtime error exit code 2 -> 1 ("false").
    func testTriggerBindingClobbersConditionalErrorExitCodeTwoIntoOne() async throws {
        let parsed = parseConfig(
            """
            config-version = 2
            [mode.main.binding]
                alt-t = 'test %{window-id} = 1'
            """
        )
        XCTAssertTrue(parsed.errors.isEmpty, "\(parsed.errors)")
        config = parsed.config
        XCTAssertNil(focus.windowOrNil)

        let answer = await runCliRequest(
            ClientRequest(args: ["trigger-binding", "alt-t", "--mode", "main"], stdin: "", windowId: nil, workspace: nil)
        )
        XCTAssertEqual(
            answer.exitCode,
            2,
            "S3-C1c: `trigger-binding` mapped `test` error 2 to \(answer.exitCode) ('false'): \(answer.stderr)",
        )
    }

    /// S3-C2: On v0.6.422, `trigger-binding` on `['move-node-to-workspace 1', 'workspace 1']`
    /// (from default-config.toml) exited 1 when `move-node-to-workspace 1` failed with no focused
    /// window. On S3, `WinMuxHooks.runCmdSeq` returns only the last command's exit code, turning
    /// that failure into exitCode 0 while printing an error to stderr.
    func testTriggerBindingMultiCommandSequenceMasksEarlierCommandFailure() async throws {
        let parsed = parseConfig(
            """
            config-version = 2
            [mode.main.binding]
                alt-shift-1 = ['move-node-to-workspace 1', 'workspace 1']
            """
        )
        XCTAssertTrue(parsed.errors.isEmpty, "\(parsed.errors)")
        config = parsed.config
        _ = Workspace.get(byName: "2").focusWorkspace()
        XCTAssertNil(focus.windowOrNil)

        let answer = await runCliRequest(
            ClientRequest(args: ["trigger-binding", "alt-shift-1", "--mode", "main"], stdin: "", windowId: nil, workspace: nil)
        )
        XCTAssertTrue(answer.stderr.contains("No window is focused"), "Expected stderr error, got: \(answer.stderr)")
        XCTAssertEqual(
            answer.exitCode,
            1,
            "S3-C2: `trigger-binding` exited \(answer.exitCode) despite `move-node-to-workspace 1` failing (v0.6.422 exited 1)",
        )
    }

    /// S3-C3a: Applying a config with a minor error (`persistent-workspaces = ["1", 2]`) resets
    /// `config.persistentWorkspaces` to `[]`, causing `reconcileWorkspaceState()` ->
    /// `clearOrphanedWorkspaceSidebarLabels()` to drop `[workspace-sidebar.labels]` for empty
    /// persistent workspaces and pass `validateConfigEdit` when deleting them from `winmux.toml`.
    func testMinorErrorInPersistentWorkspacesDestroysConfiguredWorkspaceLabels() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "CarbonS3MinorErrorLoss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appending(path: "winmux.toml")
        let brokenEdit = """
            config-version = 2
            persistent-workspaces = ["1", 2]

            [workspace-sidebar.workspace-labels]
            1 = "Code"
            2 = "Mail"
            """
        try brokenEdit.write(to: file, atomically: true, encoding: .utf8)
        _ = Workspace.get(byName: "1").focusWorkspace()

        let result = try await reloadConfig(args: ReloadConfigCmdArgs(rawArgs: ["--no-gui"]), forceConfigUrl: file)
        XCTAssertTrue(result.appliedConfig)

        // Simulate the reconcile pass scheduled by applyReloadedConfigurationToRunningApp().
        Workspace.reconcileWorkspaceState()

        // In production (`!isUnitTest`), `clearWorkspaceSidebarLabelIfNeeded("2")` also runs
        // `persistWorkspaceSidebarLabel(workspaceName: "2", label: nil)` against `configUrl`,
        // which `validateConfigEdit` permits because no *new* error was added!
        try persistWorkspaceSidebarLabel(workspaceName: "2", label: nil, targetUrl: file)
        let onDiskAfter = try String(contentsOf: file, encoding: .utf8)

        XCTAssertEqual(
            config.workspaceSidebar.workspaceLabels["2"],
            "Mail",
            "S3-C3a: Minor error in `persistent-workspaces` caused reconcile to erase label 'Mail'; disk now has:\n\(onDiskAfter)",
        )
    }

    /// S3-C3b: A minor error in `workspace-sidebar.mode` (`mode = 'tab'`) silently flips a live
    /// Tabs-mode session back to Classic sidebar mode (`usesBrowserTabs == false`), sets
    /// `lastReloadConfigContainedWarnings = false`, and leaves zero persistent UI indicator
    /// once the 4-second toast expires.
    func testMinorErrorInSidebarModeFlipsTabsModeAndLeavesNoPersistentWarning() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "CarbonS3ModeFlip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appending(path: "winmux.toml")
        try """
        config-version = 2
        [workspace-sidebar]
        enabled = true
        mode = 'tabs'
        """.write(to: file, atomically: true, encoding: .utf8)

        let initial = try await reloadConfig(args: ReloadConfigCmdArgs(rawArgs: ["--no-gui"]), forceConfigUrl: file)
        XCTAssertTrue(initial.isOk)
        XCTAssertTrue(config.usesBrowserTabs)

        // User mistypes 'tabs' as 'tab' while editing.
        try """
        config-version = 2
        [workspace-sidebar]
        enabled = true
        mode = 'tab'
        """.write(to: file, atomically: true, encoding: .utf8)

        let reloaded = try await reloadConfig(args: ReloadConfigCmdArgs(rawArgs: []), forceConfigUrl: file)
        // Let showConfigMessage's deferred Task run.
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(reloaded.isOk)
        let keptTabsMode = config.usesBrowserTabs
        let hasPersistentMenuWarning = TrayMenuModel.shared.lastReloadConfigContainedWarnings
        XCTAssertTrue(
            keptTabsMode || hasPersistentMenuWarning,
            "S3-C3b: Minor error flipped live Tabs mode off (`usesBrowserTabs == false`) AND left `lastReloadConfigContainedWarnings == false` (no persistent menu warning after 4s toast)",
        )
    }
}
