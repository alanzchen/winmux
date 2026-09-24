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
    @discardableResult
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
        savedWorkspaceRuntime.firstWindowSeenByPid[999] = savedTestNow.addingTimeInterval(-86400)
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

    func testWithoutAnyTitlesSavedOrderDecides() async throws {
        let first = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("one", bundleId: editor, windowId: 11, pid: 900)]))
        let second = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("two", bundleId: editor, windowId: 12, pid: 900)]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "one", layout: first))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "two", layout: second))
        materializeSavedWorkspaceNames()
        let window = newWindow(31, relaunched(editor, pid: 1001), title: "")

        _ = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertEqual(window.nodeWorkspace?.name, "one")
    }

    func testUnrelatedTitledWindowDoesntTakeASlotWhenTheChoiceIsAmbiguous() async throws {
        let first = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("one", bundleId: editor, title: "a.swift — ProjectOne", windowId: 11, pid: 900)]))
        let second = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("two", bundleId: editor, title: "b.swift — ProjectTwo", windowId: 12, pid: 900)]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "one", layout: first))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "two", layout: second))
        materializeSavedWorkspaceNames()
        let window = newWindow(31, relaunched(editor, pid: 1001), title: "Scratch — Untitled")

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertFalse(routed)
    }

    func testOnlyWaitingSlotTakesTheAppsFirstWindowWhateverItsTitle() async throws {
        let layout = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("chat", bundleId: "com.test.chat", title: "general - Acme", windowId: 11, pid: 900)]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "chat", layout: layout))
        materializeSavedWorkspaceNames()
        let window = newWindow(31, relaunched("com.test.chat", pid: 1001), title: "random - Acme Corp")

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertTrue(routed)
        XCTAssertEqual(window.nodeWorkspace?.name, "chat")
    }

    func testAppWithoutLaunchDateIsArmedByItsFirstWindow() async throws {
        let code = saveCodeWorkspace()
        let window = newWindow(21, TestApp(pid: 1001, bundleId: editor, launchDate: nil))

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertTrue(routed)
        XCTAssertTrue(window.nodeWorkspace === code)
        XCTAssertEqual(savedWorkspaceRuntime.firstWindowSeenByPid[1001], savedTestNow)
    }

    func testUntitledWindowWaitsForItsTitleWhenSeveralPlacesFit() async throws {
        let first = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("one", bundleId: editor, title: "a.swift — ProjectOne", windowId: 11, pid: 900)]))
        let second = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("two", bundleId: editor, title: "b.swift — ProjectTwo", windowId: 12, pid: 900)]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "one", layout: first))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "two", layout: second))
        materializeSavedWorkspaceNames()
        let window = newWindow(31, relaunched(editor, pid: 1001), title: "")

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)
        XCTAssertFalse(routed)
        XCTAssertNotNil(savedWorkspaceRuntime.windowsAwaitingTitle[31])

        window.customTitle = "c.swift — ProjectTwo"
        await retrySavedWorkspaceRoutingForWindowsAwaitingTitles()

        XCTAssertEqual(window.nodeWorkspace?.name, "two")
        XCTAssertTrue(savedWorkspaceRuntime.windowsAwaitingTitle.isEmpty)
    }

    func testUnarmedWindowIsNotRouted() async throws {
        // A Cmd-N window of an app that has been showing windows for a while.
        let code = saveCodeWorkspace()
        savedWorkspaceRuntime.firstWindowSeenByPid[1001] = savedTestNow.addingTimeInterval(-600)
        let window = newWindow(21, relaunched(editor, pid: 1001, launchedAgo: 600))

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertFalse(routed)
        XCTAssertFalse(window.nodeWorkspace === code)
    }

    func testManualOpenArmsAnAlreadyRunningApp() async throws {
        let code = saveCodeWorkspace()
        savedWorkspaceRuntime.firstWindowSeenByPid[1001] = savedTestNow.addingTimeInterval(-600)
        let window = newWindow(21, relaunched(editor, pid: 1001, launchedAgo: 600))
        savedWorkspaceRuntime.manualArmUntilByBundleId[editor] = savedTestNow.addingTimeInterval(10)

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertTrue(routed)
        XCTAssertTrue(window.nodeWorkspace === code)
    }

    func testOpenMissingAppsLaunchesEachMissingAppOnceAndArmsIt() async throws {
        saveCodeWorkspace()
        var launched: [String] = []
        savedWorkspaceRuntime.environment = SavedWorkspaceEnvironment(
            now: { savedTestNow },
            runningApps: { [self.browser: [SavedRunningApp(pid: 5, launchDate: nil)]] },
            openApplication: { bundleId, _ in launched.append(bundleId); return true },
            frontmostAppBundleId: { nil },
        )

        let opened = await openMissingSavedWorkspaceApps(workspaceNames: ["code"])

        XCTAssertEqual(opened.opened.count, 2)
        XCTAssertEqual(opened.failed, [])
        XCTAssertEqual(launched.sorted(), [editor, terminal].sorted())
        XCTAssertNotNil(savedWorkspaceRuntime.manualArmUntilByBundleId[editor])
        XCTAssertNil(savedWorkspaceRuntime.manualArmUntilByBundleId[browser])
    }

    func testTitlePartsEveryPlaceSharesDontCount() {
        func location(_ name: String, _ title: String) -> SavedSlotLocation {
            SavedSlotLocation(workspaceName: name, slot: SavedWindowSlot(id: name, bundleId: browser, title: title), isFloating: false)
        }
        let candidates = [location("mail", "Inbox — Gmail — Chrome"), location("calendar", "Calendar — Gmail — Chrome")]

        XCTAssertNil(bestSavedSlot(for: "Drafts — Gmail — Chrome", among: candidates, appName: "Google Chrome"))
        XCTAssertEqual(bestSavedSlot(for: "Calendar — Gmail — Chrome", among: candidates, appName: "Google Chrome")?.workspaceName, "calendar")
    }

    func testOpenMissingAppsSeparatesOpenedAndFailedApps() async throws {
        saveCodeWorkspace()
        savedWorkspaceRuntime.environment = SavedWorkspaceEnvironment(
            now: { savedTestNow },
            runningApps: { [:] },
            openApplication: { bundleId, _ in bundleId != self.terminal },
            frontmostAppBundleId: { nil },
        )

        let result = await openMissingSavedWorkspaceApps(workspaceNames: ["code"])

        XCTAssertEqual(result.opened, [editor, browser])
        XCTAssertEqual(result.failed, [terminal])
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

    func testSameProcessWindowCantTakeASavedWindowsSlotBeforeRefreshRegistersIt() async throws {
        // WinMux restarted and the focused window registers before refresh() lists the others.
        let code = saveCodeWorkspace()
        savedWorkspaceRuntime.runtimeReadyAt = nil
        let app = TestApp(pid: 900, bundleId: editor)
        let other = newWindow(41, app)

        let otherRouted = try await routeNewWindowToSavedWorkspaceIfNeeded(other, isRegularWindow: true)
        let saved = newWindow(11, app)
        let savedRouted = try await routeNewWindowToSavedWorkspaceIfNeeded(saved, isRegularWindow: true)

        XCTAssertFalse(otherRouted)
        XCTAssertFalse(other.nodeWorkspace === code)
        XCTAssertTrue(savedRouted)
        XCTAssertTrue(saved.nodeWorkspace === code)
    }

    func testCaptureDuringRoutingDoesntGiveTheWindowANewSlot() async throws {
        // The window landed in a focused saved workspace and a checkpoint runs while its title
        // is being fetched.
        let focused = try makeSavedTestWorkspace("focused")
        XCTAssertTrue(focused.focusWorkspace())
        let later = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("real", bundleId: editor, title: "Notes", windowId: 11, pid: 900)]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "later", layout: later))
        materializeSavedWorkspaceNames()
        let window = TestWindow.new(id: 21, parent: focused.rootTilingContainer, app: relaunched(editor, pid: 1001), title: "Notes")
        savedWorkspaceRuntime.routingInFlightWindowIds = [21]
        captureSavedWorkspaces(facts: savedTestFacts())
        XCTAssertEqual(savedWorkspaceStore.record(named: "focused")?.layout.root.allSlots.count, 0)
        savedWorkspaceRuntime.routingInFlightWindowIds = []

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertTrue(routed)
        XCTAssertEqual(window.nodeWorkspace?.name, "later")
        XCTAssertTrue(savedWorkspaceRuntime.routingInFlightWindowIds.isEmpty)
    }

    func testMostRecentChildIsRestoredAtEveryLevel() async throws {
        // Root prefers the left column; the left column prefers a, the right column prefers d.
        let layout = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [
            .container(SavedLayoutContainer(layout: .tabGroup, orientation: .v, isMostRecentInParent: true, children: [
                savedSlot("a", bundleId: "com.test.a", windowId: 11, pid: 901, isMostRecent: true),
                savedSlot("b", bundleId: "com.test.b", windowId: 12, pid: 902),
            ])),
            .container(SavedLayoutContainer(layout: .tabGroup, orientation: .v, children: [
                savedSlot("c", bundleId: "com.test.c", windowId: 13, pid: 903),
                savedSlot("d", bundleId: "com.test.d", windowId: 14, pid: 904, isMostRecent: true),
            ])),
        ]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "tabs", layout: layout))
        materializeSavedWorkspaceNames()
        let workspace = try XCTUnwrap(Workspace.existing(byName: "tabs"))
        var windows: [String: TestWindow] = [:]
        for (index, name) in ["a", "b", "c", "d"].enumerated() {
            let window = newWindow(UInt32(21 + index), relaunched("com.test.\(name)", pid: Int32(1001 + index)))
            windows[name] = window
            let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)
            XCTAssertTrue(routed)
        }

        let root = workspace.rootTilingContainer
        XCTAssertEqual(liveShape(root), "h[t[21 22] t[23 24]]")
        let left = try XCTUnwrap(root.children.first as? TilingContainer)
        let right = try XCTUnwrap(root.children.last as? TilingContainer)
        XCTAssertTrue(root.mostRecentChild === left)
        XCTAssertTrue(left.mostRecentChild === windows["a"])
        XCTAssertTrue(right.mostRecentChild === windows["d"])
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
