@testable import AppBundle
import Common
import XCTest

@MainActor
final class FullscreenGuardTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseGuardsPreservesFocusTargetRestrictions() {
        var focusArgs = FocusCmdArgs(rawArgs: [], targetArg: .direction(.left))
        focusArgs.failIfFullscreen = true
        focusArgs.failIfMacosNativeFullscreen = true
        testParseCommandSucc("focus --fail-if-fullscreen --fail-if-macos-native-fullscreen left", focusArgs)

        var moveArgs = MoveCmdArgs(rawArgs: [], .right)
        moveArgs.failIfFullscreen = true
        moveArgs.failIfMacosNativeFullscreen = true
        moveArgs.windowId = 42
        testParseCommandSucc("move --fail-if-fullscreen --fail-if-macos-native-fullscreen --window-id 42 right", moveArgs)

        for target in ["dfs-next", "dfs-prev", "tab-next", "tab-prev"] {
            XCTAssertEqual(
                parseCommand("focus --fail-if-fullscreen \(target)").errorOrNil,
                "--fail-if-fullscreen/--fail-if-macos-native-fullscreen require using (left|down|up|right) argument",
            )
        }
        for option in ["--tab-index 1", "--dfs-index 1", "--window-id 42"] {
            XCTAssertNotNil(parseCommand("focus --fail-if-macos-native-fullscreen \(option)").errorOrNil)
        }
    }

    func testFocusFullscreenGuardLeavesFocusAndFloatingBindingsUntouched() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let floating = TestWindow.new(id: 2, parent: workspace, rect: Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100))
        XCTAssertTrue(window.focusWindow())
        window.isFullscreen = true

        let result = try await parseCommand("focus --fail-if-fullscreen right").cmdOrDie.run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(focus.windowOrNil, window)
        XCTAssertTrue(floating.parent === workspace)
        XCTAssertEqual(floating.axRectFetchCount, 0)
        XCTAssertEqual(window.nativeStateFetchCount, 0)
    }

    func testFocusNativeFullscreenGuardReusesCacheAndInvalidatesOnTransition() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window = TestWindow.new(id: 1, parent: root)
        let sibling = TestWindow.new(id: 2, parent: root)
        XCTAssertTrue(window.focusWindow())
        window.nativeIsMacosFullscreen = true

        for _ in 0 ..< 2 {
            let result = try await parseCommand("focus --fail-if-macos-native-fullscreen right").cmdOrDie.run(.defaultEnv, .emptyStdin)
            XCTAssertEqual(result.exitCode, 1)
            XCTAssertEqual(focus.windowOrNil, window)
        }
        XCTAssertEqual(window.nativeStateFetchCount, 1)

        window.nativeIsMacosFullscreen = false
        let result = try await parseCommand("focus --fail-if-fullscreen --fail-if-macos-native-fullscreen right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(focus.windowOrNil, sibling)
        XCTAssertEqual(window.nativeStateFetchCount, 2)
    }

    func testMoveChecksExplicitWindowBeforeMovingItsTabGroup() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer
        let group = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabGroup, index: INDEX_BIND_LAST)
        let guarded = TestWindow.new(id: 1, parent: group)
        TestWindow.new(id: 2, parent: group)
        let focused = TestWindow.new(id: 3, parent: root)
        XCTAssertTrue(focused.focusWindow())
        guarded.isFullscreen = true
        let before = root.layoutDescription

        let result = try await parseCommand("move --window-id 1 --fail-if-fullscreen right").cmdOrDie.run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(root.layoutDescription, before)
        XCTAssertEqual(focus.windowOrNil, focused)
    }

    func testMoveNativeGuardAllowsRegularWindowAndDoesNotReadNativeStateByDefault() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        XCTAssertTrue(window.focusWindow())

        let ordinary = try await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(ordinary.exitCode, 0)
        XCTAssertEqual(window.nativeStateFetchCount, 0)
        let guarded = try await parseCommand("move --fail-if-fullscreen --fail-if-macos-native-fullscreen left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(guarded.exitCode, 0)
        XCTAssertEqual(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
        XCTAssertEqual(window.nativeStateFetchCount, 1)

        window.nativeIsMacosFullscreen = true
        let blocked = try await parseCommand("move --fail-if-macos-native-fullscreen right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(blocked.exitCode, 1)
        XCTAssertEqual(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testFailedNativeReadDoesNotMoveWindowOrPopulateCache() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        XCTAssertTrue(window.focusWindow())
        window.nativeStateGate = { throw NativeReadError.failed }

        do {
            _ = try await parseCommand("move --fail-if-macos-native-fullscreen right").cmdOrDie.run(.defaultEnv, .emptyStdin)
            XCTFail("Expected the native read failure to propagate")
        } catch NativeReadError.failed {
            XCTAssertEqual(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
            XCTAssertNil(window.lastKnownNativeFullscreen)
        }
    }

    func testNativeObservationDoesNotOverwriteInvalidatedCache() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window = TestWindow.new(id: 1, parent: root)
        XCTAssertTrue(window.focusWindow())
        window.nativeStateGate = { window.invalidateLastKnownNativeState() }

        let result = try await parseCommand("focus --fail-if-macos-native-fullscreen left").cmdOrDie.run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(window.lastKnownNativeFullscreen)
    }
}

private enum NativeReadError: Error { case failed }
