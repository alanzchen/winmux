@testable import AppBundle
import Common
import XCTest

@MainActor
final class LayoutCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    override func tearDown() async throws {
        NewWindowIntentRegistry.shared.resetForTests()
        config = defaultConfig
    }

    func testEmptyWorkspaceChangesRootLayoutWithoutAWindow() async throws {
        let workspace = focus.workspace
        let result = try await parseCommand("layout vertical").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(workspace.rootTilingContainer.orientation, .v)
        XCTAssertNil(focus.windowOrNil)
    }

    func testBackgroundWorkspaceRootTargetDoesNotChangeFocusOrNestedGroup() async throws {
        let focused = focus.workspace
        let background = Workspace.get(byName: "background")
        let nested = TilingContainer(parent: background.rootTilingContainer, adaptiveWeight: 1, .h, .tabGroup, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: nested)
        TestWindow.new(id: 2, parent: nested)
        let result = try await parseCommand("layout --workspace background --root vertical").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(background.rootTilingContainer.orientation, .v)
        XCTAssertEqual(nested.orientation, .h)
        XCTAssertEqual(nested.layout, .tabGroup)
        XCTAssertTrue(focus.workspace === focused)
    }

    func testRootFlagTargetsRootInsteadOfWindowParent() async throws {
        let root = focus.workspace.rootTilingContainer
        let nested = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tiles, index: INDEX_BIND_LAST)
        let window = TestWindow.new(id: 1, parent: nested)
        XCTAssertTrue(window.focusWindow())
        let result = try await parseCommand("layout --root vertical").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(root.orientation, .v)
        XCTAssertEqual(nested.orientation, .h)
    }

    func testNoopIsSuccessfulUnlessRequestedToFail() async throws {
        for (command, exitCode) in [("layout horizontal", 0), ("layout --fail-if-noop horizontal", 1)] {
            let result = try await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
            XCTAssertEqual(result.exitCode, Int32(exitCode))
        }
    }

    func testWindowModesStillFailOnEmptyWorkspace() async throws {
        for mode in ["tiling", "floating"] {
            let result = try await parseCommand("layout \(mode)").cmdOrDie.run(.defaultEnv, .emptyStdin)
            XCTAssertEqual(result.exitCode, 1)
        }
    }

    func testBrowserTabsStillRejectTabGroupAtRoot() async throws {
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        let result = try await parseCommand("layout --root tab-group").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(focus.workspace.rootTilingContainer.layout, .tiles)
    }

    func testTargetingAndModeFlagConflictsAreRejected() {
        for command in [
            "layout --root floating", "layout --root tiling", "layout --workspace a vertical",
            "layout --window-id 1 --workspace a --root horizontal",
            "layout --fail-if-noop horizontal vertical",
            "layout --for-next-detected-window horizontal",
            "layout --for-next-detected-window tiling floating",
            "layout --for-next-detected-window --root tiling",
            "layout --for-next-detected-window --fail-if-noop floating",
        ] {
            XCTAssertNotNil(parseCommand(command).errorOrNil, command)
        }
    }
}
