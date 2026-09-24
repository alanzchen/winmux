@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class SavedWorkspaceRoutingTest: XCTestCase {
    private let editor = "com.test.editor"
    private let terminal = "com.test.terminal"
    private let browser = "com.test.browser"

    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
    }

    /// Saves `h[editor v[terminal browser]]` for windows of a previous session.
    private func saveCodeWorkspace(name: String = "code") -> Workspace {
        let layout = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [
            savedSlot("editor", bundleId: editor, title: "main.swift — App", windowId: 11, pid: 900),
            savedContainer(.tiles, .v, [
                savedSlot("terminal", bundleId: terminal, title: "zsh", windowId: 12, pid: 901),
                savedSlot("browser", bundleId: browser, title: "Docs", windowId: 13, pid: 902, isMostRecent: true),
            ]),
        ]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: name, displayName: "Code", layout: layout))
        materializeSavedWorkspaceNames()
        return Workspace.existing(byName: name).orDie()
    }

    private func relaunched(_ bundleId: String, pid: Int32, launchedAgo: TimeInterval = 5) -> TestApp {
        TestApp(pid: pid, bundleId: bundleId, launchDate: savedTestNow.addingTimeInterval(-launchedAgo))
    }

    private func newWindow(_ id: UInt32, _ app: TestApp, title: String? = nil) -> TestWindow {
        TestWindow.new(id: id, parent: focus.workspace.rootTilingContainer, app: app, title: title)
    }

    func testFastPathRoutesSameWindowAfterWinMuxRestartWithoutArming() async throws {
        let code = saveCodeWorkspace()
        let app = TestApp(pid: 900, bundleId: editor, launchDate: savedTestNow.addingTimeInterval(-86400))
        let window = newWindow(11, app)

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertTrue(routed)
        XCTAssertTrue(window.nodeWorkspace === code)
    }

    func testFastPathRequiresSamePid() async throws {
        let code = saveCodeWorkspace()
        let app = TestApp(pid: 999, bundleId: editor, launchDate: savedTestNow.addingTimeInterval(-86400))
        let window = newWindow(11, app)

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertFalse(routed)
        XCTAssertFalse(window.nodeWorkspace === code)
    }

    func testArmedRelaunchRebuildsSavedTreeAndSkipsOnWindowDetected() async throws {
        let code = saveCodeWorkspace()
        let editorWindow = newWindow(21, relaunched(editor, pid: 1001))
        let terminalWindow = newWindow(22, relaunched(terminal, pid: 1002))

        let editorRestored = try await restoreOrDetectNewWindow(editorWindow, isRegularWindow: true)
        let terminalRestored = try await restoreOrDetectNewWindow(terminalWindow, isRegularWindow: true)

        XCTAssertTrue(editorRestored)
        XCTAssertTrue(terminalRestored)
        XCTAssertEqual(liveShape(code.rootTilingContainer), "h[21 v[22]]")
        let slots = try XCTUnwrap(savedWorkspaceStore.record(named: "code")).layout.root.allSlots
        XCTAssertEqual(slots.map(\.id), ["editor", "terminal", "browser"])
        XCTAssertEqual(slots.map(\.lastWindowId), [21, 22, 13])
    }

    func testReverseArrivalOrderConvergesOnSavedStructureWithMostRecentTab() async throws {
        let code = saveCodeWorkspace()
        let browserWindow = newWindow(23, relaunched(browser, pid: 1003))
        let terminalWindow = newWindow(22, relaunched(terminal, pid: 1002))
        let editorWindow = newWindow(21, relaunched(editor, pid: 1001))

        for window in [browserWindow, terminalWindow, editorWindow] {
            let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)
            XCTAssertTrue(routed)
        }

        XCTAssertEqual(liveShape(code.rootTilingContainer), "h[21 v[22 23]]")
        let nested = try XCTUnwrap(code.rootTilingContainer.children.last as? TilingContainer)
        XCTAssertTrue(nested.mostRecentChild === browserWindow)
    }

    func testTitleMatchBeatsSavedOrder() async throws {
        let first = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("one", bundleId: editor, title: "a.swift — ProjectOne", windowId: 11, pid: 900)]))
        let second = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("two", bundleId: editor, title: "b.swift — ProjectTwo", windowId: 12, pid: 900)]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "one", layout: first))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "two", layout: second))
        materializeSavedWorkspaceNames()
        let window = newWindow(31, relaunched(editor, pid: 1001), title: "b.swift — ProjectTwo")

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertTrue(routed)
        XCTAssertEqual(window.nodeWorkspace?.name, "two")
    }

    func testUntitledWindowFallsBackToSavedOrder() async throws {
        saveCodeWorkspace()
        let second = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("other", bundleId: editor, windowId: 99, pid: 900)]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "later", layout: second))
        materializeSavedWorkspaceNames()
        let window = newWindow(31, relaunched(editor, pid: 1001), title: "")

        _ = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertEqual(window.nodeWorkspace?.name, "code")
    }

    func testUnarmedWindowIsNotRouted() async throws {
        let code = saveCodeWorkspace()
        let window = newWindow(21, relaunched(editor, pid: 1001, launchedAgo: 600))

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertFalse(routed)
        XCTAssertFalse(window.nodeWorkspace === code)
    }

    func testManualOpenArmsAnAlreadyRunningApp() async throws {
        let code = saveCodeWorkspace()
        let window = newWindow(21, relaunched(editor, pid: 1001, launchedAgo: 600))
        savedWorkspaceRuntime.manualArmUntilByBundleId[editor] = savedTestNow.addingTimeInterval(10)

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertTrue(routed)
        XCTAssertTrue(window.nodeWorkspace === code)
    }

    func testStartupRestoreWindowArmsEveryApp() async throws {
        let code = saveCodeWorkspace()
        savedWorkspaceRuntime.runtimeReadyAt = nil
        let window = newWindow(21, relaunched(editor, pid: 1001, launchedAgo: 600))

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertTrue(routed)
        XCTAssertTrue(window.nodeWorkspace === code)
    }

    func testAliveButUnregisteredSavedWindowSlotIsNotStolen() async throws {
        let code = saveCodeWorkspace()
        savedWorkspaceRuntime.runtimeReadyAt = nil
        // WinMux restarted: the editor (pid 900) still runs, and its saved window 11 is alive
        // but registers after window 41.
        savedWorkspaceRuntime.aliveWindowPidsDuringRefresh = [11: 900, 41: 900]
        let window = newWindow(41, TestApp(pid: 900, bundleId: editor))

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertFalse(routed)
        XCTAssertFalse(window.nodeWorkspace === code)
    }

    func testDialogsAndPopupsNeverClaimSlots() async throws {
        let code = saveCodeWorkspace()
        let app = relaunched(editor, pid: 1001)
        let dialog = TestWindow.new(id: 21, parent: focus.workspace, app: app)
        let popup = TestWindow.new(id: 22, parent: macosPopupWindowsContainer, app: app)

        let dialogRouted = try await routeNewWindowToSavedWorkspaceIfNeeded(dialog, isRegularWindow: false)
        let popupRouted = try await routeNewWindowToSavedWorkspaceIfNeeded(popup, isRegularWindow: true)

        XCTAssertFalse(dialogRouted)
        XCTAssertFalse(popupRouted)
        XCTAssertFalse(dialog.nodeWorkspace === code)
    }

    func testOtherAppIsNotRouted() async throws {
        let code = saveCodeWorkspace()
        let window = newWindow(21, relaunched("com.test.unrelated", pid: 1001))

        let restored = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertFalse(restored)
        XCTAssertFalse(window.nodeWorkspace === code)
    }

    func testTilingDisabledRoutesAsFloating() async throws {
        config.automaticallyTileNewWindows = false
        let code = saveCodeWorkspace()
        let window = TestWindow.new(id: 21, parent: focus.workspace, app: relaunched(editor, pid: 1001))

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertTrue(routed)
        XCTAssertTrue(window.parent === code)
    }

    func testFilledSlotIsNotClaimedTwice() async throws {
        let code = saveCodeWorkspace()
        let first = newWindow(21, relaunched(editor, pid: 1001))
        let second = newWindow(22, relaunched(editor, pid: 1001))

        let firstRouted = try await routeNewWindowToSavedWorkspaceIfNeeded(first, isRegularWindow: true)
        let secondRouted = try await routeNewWindowToSavedWorkspaceIfNeeded(second, isRegularWindow: true)

        XCTAssertTrue(firstRouted)
        XCTAssertFalse(secondRouted)
        XCTAssertTrue(first.nodeWorkspace === code)
        XCTAssertFalse(second.nodeWorkspace === code)
    }

    func testRoutingKeepsUnrelatedWindowsAlreadyInTheWorkspace() async throws {
        let code = saveCodeWorkspace()
        let extra = TestWindow.new(id: 50, parent: code.rootTilingContainer, app: TestApp(pid: 1500, bundleId: "com.test.notes"))
        let window = newWindow(21, relaunched(editor, pid: 1001))

        _ = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertTrue(extra.nodeWorkspace === code)
        XCTAssertEqual(Set(code.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)), [21, 50])
    }
}
