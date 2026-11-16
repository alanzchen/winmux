@testable import AppBundle
import Common
import XCTest

final class ListWorkspacesTest: XCTestCase {
    func testParse() {
        assertNotNil(parseCommand("list-workspaces --all").cmdOrNil)
        assertNil(parseCommand("list-workspaces --all --visible").cmdOrNil)
        assertNil(parseCommand("list-workspaces --focused --visible").cmdOrNil)
        assertNil(parseCommand("list-workspaces --focused --all").cmdOrNil)
        assertNil(parseCommand("list-workspaces --visible").cmdOrNil)
        assertNotNil(parseCommand("list-workspaces --visible --monitor 2").cmdOrNil)
        assertNotNil(parseCommand("list-workspaces --monitor focused").cmdOrNil)
        assertNil(parseCommand("list-workspaces --focused --monitor 2").cmdOrNil)
        assertNotNil(parseCommand("list-workspaces --all --format %{workspace}").cmdOrNil)
        assertEquals(parseCommand("list-workspaces --all --format %{workspace} --count").errorOrNil, "ERROR: Conflicting options: --count, --format")
        assertEquals(parseCommand("list-workspaces --empty").errorOrNil, "Mandatory option is not specified (--all|--focused|--monitor)")
        assertEquals(parseCommand("list-workspaces --all --focused --monitor mouse").errorOrNil, "ERROR: Conflicting options: --all, --focused, --monitor")
    }

    @MainActor
    func testListWorkspacesUsesProjectViewportOrderInsteadOfRawNameSort() async throws {
        setUpWorkspacesForTests()
        let first = Workspace.get(byName: "10")
        first.markAsAutomaticallyNamed()
        _ = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        let second = Workspace.get(byName: "2")
        second.markAsAutomaticallyNamed()
        _ = TestWindow.new(id: 2, parent: second.rootTilingContainer)

        let io = CmdIo(stdin: .emptyStdin)
        let command = parseCommand("list-workspaces --all --format %{workspace}").cmdOrDie
        let succeeded = try await command.run(.defaultEnv, io)

        XCTAssertEqual(succeeded.rawValue, 0)
        XCTAssertEqual(io.stdout.filter { $0 != "setUpWorkspacesForTests" }, ["10", "2"])
    }

    /// WinMux's `--empty` goes by what the sidebar shows: a workspace whose only window is in native full screen is
    /// empty (upstream counts every leaf window).
    @MainActor
    func testEmptyIgnoresNativeFullscreenWindows() async throws {
        setUpWorkspacesForTests()
        let workspace = focus.workspace
        _ = TestWindow.new(id: 1, parent: workspace.macOsNativeFullscreenWindowsContainer)

        let empty = CmdIo(stdin: .emptyStdin)
        let listedEmpty = try await parseCommand("list-workspaces --monitor all --empty --format %{workspace}").cmdOrDie.run(.defaultEnv, empty)
        XCTAssertEqual(listedEmpty.rawValue, 0)
        XCTAssertTrue(empty.stdout.contains(workspace.name))

        let nonEmpty = CmdIo(stdin: .emptyStdin)
        let listedNonEmpty = try await parseCommand("list-workspaces --monitor all --empty no --format %{workspace}").cmdOrDie.run(.defaultEnv, nonEmpty)
        XCTAssertEqual(listedNonEmpty.rawValue, 0)
        XCTAssertFalse(nonEmpty.stdout.contains(workspace.name))
    }
}
