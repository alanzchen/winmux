@testable import AppBundle
import Common
import XCTest

/// The WinMux policies behind hooks in upstream files (docs/upstream-sync.md, phase 2). Each test fails when its hook
/// falls back to upstream's behavior.
@MainActor
final class WinMuxHooksTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testCommandsUpstreamDeclaresNotTreeChangingStillSyncTheClosedWindowsCache() {
        for raw in ["balance-sizes", "focus-back-and-forth", "fullscreen", "macos-native-fullscreen", "macos-native-minimize",
                    "workspace-back-and-forth", "workspace 1"]
        {
            let command = parseCommand(raw).cmdOrDie
            XCTAssertFalse(command.shouldResetClosedWindowsCache, "\(raw) keeps upstream's declaration")
            XCTAssertTrue(WinMuxHooks.syncsClosedWindowsCache(after: command), raw)
        }
        for raw in ["list-windows --all", "config --major-keys", "mode main"] {
            XCTAssertFalse(WinMuxHooks.syncsClosedWindowsCache(after: parseCommand(raw).cmdOrDie), raw)
        }
        XCTAssertTrue(WinMuxHooks.syncsClosedWindowsCache(after: parseCommand("move left").cmdOrDie),
                      "upstream's own declaration still counts")
    }

    func testCommandSequenceSeesTheTabsShownWhenItStarted() async throws {
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let shown = Set(Workspace.all.filter(workspaceTabIsShown).map(\.id))
        XCTAssertFalse(shown.isEmpty)
        let recorder = EnvRecordingCommand()
        _ = try await [recorder].runCmdSeq(.defaultEnv, .emptyStdin)
        XCTAssertEqual(recorder.seen.value, [shown])
    }

    func testDisablingEndsSidebarExpansion() async throws {
        TrayMenuModel.shared.isEnabled = true
        TrayMenuModel.shared.isWorkspaceSidebarExpanded = true
        let result = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(TrayMenuModel.shared.isWorkspaceSidebarExpanded)
        _ = try await parseCommand("enable on").cmdOrDie.run(.defaultEnv, .emptyStdin)
    }
}

private final class SeenTabs: @unchecked Sendable {
    var value: [Set<WorkspaceId>] = []
}

private struct EnvRecordingCommand: Command {
    typealias T = ListModesCmdArgs
    let args = ListModesCmdArgs(rawArgs: [])
    let shouldResetClosedWindowsCache = false
    let canSkipPostCommandRefresh = true
    let seen = SeenTabs()

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.seen === rhs.seen }

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        seen.value.append(env.tabsListedAtSequenceStart)
        return true
    }
}
