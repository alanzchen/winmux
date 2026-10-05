@testable import AppBundle
import AppKit
import Common
import XCTest

/// Tabs mode: a pin with no window is its app's home. A window of that app that would otherwise
/// get a new tab goes into the pin instead, while WinMux knows no other window of the app.
@MainActor
final class SavedWorkspaceEmptyPinTest: XCTestCase {
    private var defaultAppIsFrontmost: (@MainActor (Window) -> Bool)?

    private let telegram = "ru.keepcoder.Telegram"
    /// Running since long before WinMux started, so it's never armed.
    private lazy var telegramApp = TestApp(pid: 18293, bundleId: telegram, launchDate: savedTestNow.addingTimeInterval(-86400))
    private var running: [String: [SavedRunningApp]] {
        [telegram: [SavedRunningApp(pid: 18293, launchDate: savedTestNow.addingTimeInterval(-86400))]]
    }

    override func setUp() async throws {
        defaultAppIsFrontmost = newWindowAppIsFrontmost
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment(runningApps: running)
        workspaceSidebarOrganizationStore = .init()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        NewWindowIntentRegistry.shared.resetForTests()
        newWindowAppIsFrontmost = { _ in false }
    }

    override func tearDown() async throws {
        if let defaultAppIsFrontmost { newWindowAppIsFrontmost = defaultAppIsFrontmost }
        NewWindowIntentRegistry.shared.resetForTests()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
    }

    /// A pin in All Projects whose saved place held Telegram's window 571.
    private func pinTelegram(_ name: String = "22") throws -> Workspace {
        let layout = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [
            savedSlot("telegram", bundleId: telegram, title: "Telegram", windowId: 571, pid: 18293),
        ]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: name, displayName: "Telegram", layout: layout))
        materializeSavedWorkspaceNames()
        let pin = try XCTUnwrap(Workspace.existing(byName: name))
        try setWorkspaceSidebarTabPinScope(pin, .allProjects, projectId: pin.projectId)
        return pin
    }

    /// A tab with no window and no saved place left, whose saved apps are `apps`: pinned in All
    /// Projects, or in its project with `scope` nil, or not at all with `pinned` false.
    private func emptyTab(_ name: String, apps: [String]? = nil, scope: WorkspaceSidebarPinScope? = .allProjects,
                          pinned: Bool = true, projectId: WorkspaceProjectId? = nil) throws -> Workspace {
        var record = SavedWorkspaceRecord(workspaceName: name)
        record.launchApps = (apps ?? [telegram]).map { SavedLaunchApp(bundleId: $0) }
        savedWorkspaceStore.insert(record)
        materializeSavedWorkspaceNames()
        let tab = try XCTUnwrap(Workspace.existing(byName: name))
        if let projectId { tab.assignProject(projectId) }
        if pinned, let scope {
            try setWorkspaceSidebarTabPinScope(tab, scope, projectId: tab.projectId)
        } else if pinned {
            try setWorkspaceSidebarTabFavorite(tab, true)
        }
        return tab
    }

    /// The tab on screen, with a window of another app in it.
    private func workOnAnotherTab(_ name: String = "work") -> Workspace {
        let work = Workspace.get(byName: name)
        _ = TestWindow.new(id: 40, parent: work.rootTilingContainer, app: TestApp(pid: 77, bundleId: "com.example.editor"))
        XCTAssertTrue(work.focusWorkspace())
        return work
    }

    /// Checkpoints while Telegram keeps running with its window hidden, until the grace for a
    /// closed window has run out.
    private func captureUntilTheSlotIsDropped() {
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow, runningApps: running))
        let later = savedTestNow.addingTimeInterval(SavedWorkspaceTiming.closedWindowGrace + 1)
        savedWorkspaceRuntime.environment = .forTests(now: later, runningApps: running)
        captureSavedWorkspaces(facts: savedTestFacts(now: later, runningApps: running))
    }

    /// Detection of a window the app shows on the tab on screen.
    @discardableResult
    private func shows(_ id: UInt32, app: TestApp? = nil, isRegularWindow: Bool = true) async throws -> TestWindow {
        let window = TestWindow.new(id: id, parent: focus.workspace.rootTilingContainer, app: app ?? telegramApp, title: "Telegram")
        let restored = try await restoreOrDetectNewWindow(window, isRegularWindow: isRegularWindow)
        XCTAssertFalse(restored, "The pin is where a new tab would be, not a restore")
        return window
    }

    private func assertInANewTab(_ window: Window, not tabs: [Workspace], file: StaticString = #filePath, line: UInt = #line) {
        let target = window.nodeWorkspace
        XCTAssertNotNil(target, file: file, line: line)
        XCTAssertFalse(tabs.contains { $0 === target }, "\(target?.name ?? "nil")", file: file, line: line)
        XCTAssertEqual(target?.allLeafWindowsRecursive.map(\.windowId), [window.windowId], file: file, line: line)
    }

    // MARK: The pin takes its app's window

    func testTheSameWindowShownAgainAfterItsSlotWasDroppedGoesBackToTheEmptyPin() async throws {
        let pin = try pinTelegram()
        let work = workOnAnotherTab()
        captureUntilTheSlotIsDropped()
        let record = try XCTUnwrap(savedWorkspaceStore.record(named: "22"))
        XCTAssertEqual(record.layout.allSlots.count, 0, "Its window was hidden for longer than the grace: the slot is dropped")
        XCTAssertEqual(record.launchApps?.map(\.bundleId), [telegram], "The pin still shows Telegram, dimmed")
        let tabCount = Workspace.all.count

        // Telegram shows the same window again (alt-t, or the Dock).
        let window = try await shows(571)

        XCTAssertTrue(window.nodeWorkspace === pin, "It goes to the pin, not to a new tab")
        XCTAssertEqual(work.allLeafWindowsRecursive.map(\.windowId), [40])
        XCTAssertEqual(Workspace.all.count, tabCount, "No new tab")
        XCTAssertTrue(focus.workspace === work, "A window from an app in the background doesn't take focus")
        XCTAssertFalse(pin.isVisible)
        captureSavedWorkspaces(facts: savedTestFacts(now: savedWorkspaceRuntime.now, runningApps: running))
        let slots = try XCTUnwrap(savedWorkspaceStore.record(named: "22")).layout.allSlots
        XCTAssertEqual(slots.map(\.lastWindowId), [571], "Saved in the pin again")
        XCTAssertEqual(slots.map(\.lastPid), [18293])
    }

    func testTheFirstWindowOfARelaunchedAppGoesToItsEmptyPinAndFocusFollowsIt() async throws {
        let pin = try emptyTab("22")
        let work = workOnAnotherTab()
        newWindowAppIsFrontmost = { _ in true }
        let relaunched = TestApp(pid: 30001, bundleId: telegram, launchDate: savedTestNow.addingTimeInterval(-5))

        let window = try await shows(900, app: relaunched)

        XCTAssertTrue(window.nodeWorkspace === pin)
        XCTAssertEqual(work.allLeafWindowsRecursive.map(\.windowId), [40])
        XCTAssertTrue(focus.workspace === pin, "The window you just opened stays in view, as in a new tab")
        XCTAssertTrue(focus.windowOrNil === window)
        XCTAssertTrue(pin.visibleMonitor?.rect == mainMonitor.rect)
    }

    func testANewWindowOfARunningAppWithNoOtherWindowGoesToItsEmptyPin() async throws {
        let pin = try emptyTab("22")
        _ = workOnAnotherTab()

        let window = try await shows(572)

        XCTAssertTrue(window.nodeWorkspace === pin)
    }

    func testASplitPinIsTheHomeOfEachOfItsApps() async throws {
        let pin = try emptyTab("split", apps: ["com.example.notes", telegram])
        _ = workOnAnotherTab()

        let window = try await shows(572)

        XCTAssertTrue(window.nodeWorkspace === pin)
    }

    // MARK: What the pin never takes

    func testAnotherWindowOfTheAppKeepsTheEmptyPinFromTakingItsNewWindow() async throws {
        let pin = try emptyTab("22")
        let chats = Workspace.get(byName: "chats")
        _ = TestWindow.new(id: 600, parent: chats.rootTilingContainer, app: telegramApp)
        let work = workOnAnotherTab()

        let window = try await shows(572)

        assertInANewTab(window, not: [pin, work, chats])
    }

    func testAMinimizedWindowOfTheAppAlsoCounts() async throws {
        let pin = try emptyTab("22")
        _ = TestWindow.new(id: 600, parent: macosMinimizedWindowsContainer, app: telegramApp)
        let work = workOnAnotherTab()

        let window = try await shows(572)

        assertInANewTab(window, not: [pin, work])
    }

    func testAPopupOfTheAppDoesntCount() async throws {
        let pin = try emptyTab("22")
        _ = TestWindow.new(id: 600, parent: macosPopupWindowsContainer, app: telegramApp)
        _ = workOnAnotherTab()

        let window = try await shows(572)

        XCTAssertTrue(window.nodeWorkspace === pin)
    }

    func testAnotherWindowOfTheAppStillRegisteringKeepsItOut() async throws {
        // A refresh registers the app's windows one by one: the first isn't the only one.
        let pin = try emptyTab("22")
        let work = workOnAnotherTab()
        savedWorkspaceRuntime.aliveWindowPidsDuringRefresh = [571: 18293, 572: 18293]
        defer { savedWorkspaceRuntime.aliveWindowPidsDuringRefresh = [:] }

        let window = try await shows(571)

        assertInANewTab(window, not: [pin, work])
    }

    func testAnotherAppsWindowIsNotTaken() async throws {
        let pin = try emptyTab("22")
        let work = workOnAnotherTab()

        let window = try await shows(572, app: TestApp(pid: 30002, bundleId: "com.example.chat"))

        assertInANewTab(window, not: [pin, work])
    }

    func testDialogsAndPopupsAreNotTaken() async throws {
        let pin = try emptyTab("22")
        let work = workOnAnotherTab()
        let dialog = TestWindow.new(id: 572, parent: work, app: telegramApp)
        _ = try await restoreOrDetectNewWindow(dialog, isRegularWindow: false)
        XCTAssertTrue(dialog.nodeWorkspace === work)
        dialog.unbindFromParent()

        let popup = TestWindow.new(id: 573, parent: macosPopupWindowsContainer, app: telegramApp)
        _ = try await restoreOrDetectNewWindow(popup, isRegularWindow: true)

        XCTAssertTrue(popup.parent === macosPopupWindowsContainer)
        XCTAssertTrue(pin.isEffectivelyEmpty)
    }

    func testAPinWithAWindowIsNotEmpty() async throws {
        let pin = try emptyTab("split", apps: ["com.example.notes", telegram])
        _ = TestWindow.new(id: 600, parent: pin.rootTilingContainer, app: TestApp(pid: 30003, bundleId: "com.example.notes"))
        let work = workOnAnotherTab()

        let window = try await shows(572)

        assertInANewTab(window, not: [pin, work])
    }

    func testASavedTabThatIsntPinnedIsNotAHome() async throws {
        let saved = try emptyTab("22", pinned: false)
        let work = workOnAnotherTab()

        let window = try await shows(572)

        assertInANewTab(window, not: [saved, work])
    }

    func testNothingIsTakenWhileSavedWorkspacesAreReadOnly() async throws {
        let pin = try emptyTab("22")
        let work = workOnAnotherTab()
        savedWorkspaceStore = SavedWorkspaceStore(file: savedWorkspaceStore.file, url: nil, readOnlyReason: "WinMux is running with --read-only.")

        let window = try await shows(572)

        assertInANewTab(window, not: [pin, work])
    }

    func testPinsAreTabsModesOnly() async throws {
        let pin = try emptyTab("22")
        let work = workOnAnotherTab()
        config.workspaceSidebar.mode = .sidebar
        config.openNewWindowsInNewWorkspace = true

        let window = try await shows(572)

        XCTAssertFalse(window.nodeWorkspace === pin)
        XCTAssertFalse(window.nodeWorkspace === work)
    }

    func testWithoutNewWindowsInNewTabsTheWindowStaysWhereItOpened() async throws {
        // The pin takes only a window that would get a new tab.
        let pin = try emptyTab("22")
        let work = workOnAnotherTab()
        config.openNewWindowsInNewWorkspace = false

        let window = try await shows(572)

        XCTAssertTrue(window.nodeWorkspace === work)
        XCTAssertTrue(pin.isEffectivelyEmpty)
    }

    func testAnOnWindowDetectedRuleThatMovesTheWindowWins() async throws {
        let (parsed, errors) = parseConfig("""
            [[on-window-detected]]
            if.app-id = 'ru.keepcoder.Telegram'
            run = ['move-node-to-workspace mail']
            """)
        XCTAssertEqual(errors.descriptions, [])
        config.onWindowDetected = parsed.onWindowDetected
        let pin = try emptyTab("22")
        _ = workOnAnotherTab()

        let window = try await shows(572)

        XCTAssertEqual(window.nodeWorkspace?.name, "mail")
        XCTAssertTrue(pin.isEffectivelyEmpty)
    }

    // MARK: Which pin

    func testTheFirstEmptyPinInTileOrderTakesItAndTheOrderStays() async throws {
        let projectPin = try emptyTab("project-pin", scope: nil)
        let later = try emptyTab("later")
        let first = try emptyTab("first")
        try workspaceSidebarOrganizationStore.update {
            $0.workspaces["first"]?.pinOrder = 0
            $0.workspaces["later"]?.pinOrder = 1
        }
        XCTAssertEqual(workspacePinnedTabsInAllProjects().map(\.name), ["first", "later"])
        let order = workspaceSidebarOrganizationStore.state.workspaces.mapValues(\.pinOrder)
        _ = workOnAnotherTab()

        let window = try await shows(572)

        XCTAssertTrue(window.nodeWorkspace === first, "Pins in All Projects lead, as their tiles are arranged")
        XCTAssertTrue(later.isEffectivelyEmpty)
        XCTAssertTrue(projectPin.isEffectivelyEmpty)
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces.mapValues(\.pinOrder), order)
    }

    func testOnlyTheProjectOnScreensOwnPinsCount() async throws {
        let a = createWorkspaceProject().id
        let b = createWorkspaceProject().id
        let elsewhere = try emptyTab("a-pin", scope: nil, projectId: a)
        let own = try emptyTab("b-pin", scope: nil, projectId: b)
        let work = Workspace.get(byName: "work")
        work.assignProject(b)
        _ = TestWindow.new(id: 40, parent: work.rootTilingContainer, app: TestApp(pid: 77, bundleId: "com.example.editor"))
        XCTAssertTrue(work.focusWorkspace())
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), b)
        XCTAssertEqual(workspacePinnedTabs(in: a).map(\.name), ["a-pin"], "Project A has its own empty Telegram pin")

        let window = try await shows(572)

        XCTAssertTrue(window.nodeWorkspace === own)
        XCTAssertTrue(elsewhere.isEffectivelyEmpty)
    }

    // MARK: Displays

    private func twoDisplays() -> (left: Monitor, right: Monitor, work: Workspace, shownRight: Workspace) {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT")
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        Workspace.reconcileWorkspaceState()
        let shownRight = Workspace.get(byName: "shown-right")
        _ = TestWindow.new(id: 41, parent: shownRight.rootTilingContainer, app: TestApp(pid: 78, bundleId: "com.example.mail"))
        XCTAssertTrue(right.setActiveWorkspace(shownRight))
        let work = workOnAnotherTab()
        XCTAssertTrue(work.visibleMonitor?.rect == left.rect)
        return (left, right, work, shownRight)
    }

    func testAPinOfAnotherDisplayIsNotTakenWithoutSharedPins() async throws {
        let pin = try emptyTab("22")
        let (_, right, work, _) = twoDisplays()
        pin.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(pin.workspaceMonitor.rect == right.rect)

        let window = try await shows(572)

        assertInANewTab(window, not: [pin, work])
    }

    func testASharedEmptyPinComesToTheDisplayTheWindowOpenedOn() async throws {
        config.workspaceSidebar.sharePinnedTabs = true
        let pin = try emptyTab("22")
        let (left, right, _, shownRight) = twoDisplays()
        let home = try XCTUnwrap(SavedDisplayAffinity(monitor: right))
        savedWorkspaceStore.update(named: "22") { $0.display = home }
        pin.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(pin.workspaceMonitor.rect == right.rect)
        newWindowAppIsFrontmost = { _ in true }

        let window = try await shows(572)

        XCTAssertTrue(window.nodeWorkspace === pin)
        XCTAssertTrue(pin.visibleMonitor?.rect == left.rect, "It shows where the window opened, as a click on it there would")
        XCTAssertTrue(shownRight.visibleMonitor?.rect == right.rect, "The other display keeps its tab")
        XCTAssertEqual(savedWorkspaceStore.record(named: "22")?.display?.uuid, "LEFT")
    }

    func testAPinOnScreenOnAnotherDisplayIsNotTaken() async throws {
        config.workspaceSidebar.sharePinnedTabs = true
        let pin = try emptyTab("22")
        let (_, right, work, _) = twoDisplays()
        XCTAssertTrue(right.setActiveWorkspace(pin))

        let window = try await shows(572)

        assertInANewTab(window, not: [pin, work])
        XCTAssertTrue(pin.visibleMonitor?.rect == right.rect)
    }

    func testAPinHeldToAnotherDisplayIsNotTaken() async throws {
        config.workspaceSidebar.sharePinnedTabs = true
        let pin = try emptyTab("22")
        let (_, right, work, _) = twoDisplays()
        let home = try XCTUnwrap(SavedDisplayAffinity(monitor: right))
        savedWorkspaceStore.update(named: "22") {
            $0.display = home
            $0.isPinnedToDisplay = true
        }

        let window = try await shows(572)

        assertInANewTab(window, not: [pin, work])
    }

    // MARK: Placed once

    func testAWindowClaimedForAnotherTabIsNotDivertedToThePin() async throws {
        let pin = try emptyTab("22")
        _ = workOnAnotherTab()
        let asked = Workspace.get(byName: "asked")
        let registry = NewWindowIntentRegistry.shared
        XCTAssertNotNil(registry.register(bundleId: telegram, pid: 18293, targetWorkspace: asked, preexistingWindowIds: [],
            focusGeneration: focusChangeGeneration, timeout: newWindowIntentTimeout, completion: nil))
        XCTAssertTrue(registry.claim(windowId: 572, pid: 18293, bundleId: telegram, firstSeenUptime: registry.now()) === asked)
        let binding = newWindowIntentBinding(targetWorkspace: asked)
        let window = TestWindow.new(id: 572, parent: binding.parent, app: telegramApp)

        let placed = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertTrue(placed)
        XCTAssertTrue(window.nodeWorkspace === asked)
        XCTAssertTrue(pin.isEffectivelyEmpty)
    }

    func testASavedPlaceWaitingForTheWindowTakesItBeforeAnEmptyPin() async throws {
        let pin = try emptyTab("22")
        let layout = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [
            savedSlot("chat", bundleId: telegram, title: "Telegram", windowId: 571, pid: 18293),
        ]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "chats", layout: layout))
        materializeSavedWorkspaceNames()
        _ = workOnAnotherTab()

        let window = TestWindow.new(id: 571, parent: focus.workspace.rootTilingContainer, app: telegramApp)
        let placed = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertTrue(placed)
        XCTAssertEqual(window.nodeWorkspace?.name, "chats")
        XCTAssertTrue(pin.isEffectivelyEmpty)
    }
}
