@testable import AppBundle
import AppKit
import Common
import XCTest

/// A saved or pinned tab whose window closed while its app kept running: clicking it opens the
/// app again, as a Dock click does, and the window the app shows comes to that tab.
@MainActor
final class PinReopenRequestTest: XCTestCase {
    private var registry: NewWindowIntentRegistry { .shared }
    private var clock: TimeInterval = 1000
    private var originalReopen: (@MainActor (URL) async throws -> Int32)!
    private var reopened: [URL] = []
    private var reopenResult: Result<Int32, any Error> = .success(0)

    private let appId = "bobko.WinMux.test-app"
    private let appURL = URL(fileURLWithPath: "/Applications/Probe.app")
    private var target: NewWindowRequestTarget { NewWindowRequestTarget(bundleId: appId, appName: "Probe", bundleURL: appURL) }
    private var pid: Int32 { TestApp.shared.pid }

    override func setUp() async throws {
        try await super.setUp()
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        registry.resetForTests()
        clock = 1000
        registry.now = { [weak self] in self?.clock ?? 0 }
        registry.isProcessAlive = { _ in true }
        originalReopen = reopenRunningApplication
        reopened = []
        reopenResult = .success(TestApp.shared.pid)
        reopenRunningApplication = { [weak self] url in
            guard let self else { return 0 }
            reopened.append(url)
            return try reopenResult.get()
        }
    }

    override func tearDown() async throws {
        reopenRunningApplication = originalReopen
        setPendingPersistedFrozenWorldForTests(nil)
        registry.resetForTests()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        config = defaultConfig
        try await super.tearDown()
    }

    /// Lets the request's main-actor task send the reopen and hear back.
    private func letTheRequestRun() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }

    @discardableResult
    private func clickPin(_ tab: Workspace, preexisting: Set<UInt32> = [],
                          _ outcome: @escaping @MainActor (NewWindowRequestOutcome) -> Void = { _ in }) -> Int? {
        startReopenRequest(target, pid: pid, appURL: appURL, targetWorkspace: tab, focusGeneration: focusChangeGeneration,
            preexistingWindowIds: { preexisting }, completion: outcome)
    }

    /// What detection does with a window the app showed: claim it, register it there, detect it.
    private func appShows(_ windowId: UInt32, reusing window: Window? = nil) async throws -> Window? {
        guard let tab = registry.claim(windowId: windowId, pid: pid, bundleId: appId, firstSeenUptime: clock) else { return nil }
        let binding = newWindowIntentBinding(targetWorkspace: tab)
        let shown: Window
        if let window {
            window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
            shown = window
        } else {
            shown = TestWindow.new(id: windowId, parent: binding.parent)
        }
        _ = try await restoreOrDetectNewWindow(shown, isRegularWindow: true)
        return shown
    }

    func testOnlyARunningAppWithoutAnAdapterOrAWindowIsReopened() {
        XCTAssertEqual(newWindowMethod(bundleId: "com.tinyspeck.slackmacgap", isRunning: true, reopensWhenWindowless: true,
            menuFallbackEnabled: false), .reopen, "Running with no window: reopened, as a Dock click does")
        XCTAssertEqual(newWindowMethod(bundleId: "com.tinyspeck.slackmacgap", isRunning: true, reopensWhenWindowless: true,
            menuFallbackEnabled: true), .reopen, "Also before its New Window menu item")
        XCTAssertEqual(newWindowMethod(bundleId: "com.tinyspeck.slackmacgap", isRunning: true, menuFallbackEnabled: false),
            .unsupported, "With a window somewhere, a reopen would only bring that one forward")
        XCTAssertEqual(newWindowMethod(bundleId: "com.tinyspeck.slackmacgap", isRunning: false, reopensWhenWindowless: true,
            menuFallbackEnabled: false), .open, "Not running: launched")
        XCTAssertEqual(newWindowMethod(bundleId: "com.apple.TextEdit", isRunning: true, reopensWhenWindowless: true,
            menuFallbackEnabled: false), .script("tell application id \"com.apple.TextEdit\" to make new document"),
            "An app with a tested adapter keeps it")
    }

    func testAnyWindowOfTheAppKeepsItFromBeingReopened() {
        let other = Workspace.get(byName: "other")
        let popup = TestWindow.new(id: 1, parent: macosPopupWindowsContainer)
        XCTAssertFalse(runningAppHasWindows(pid: pid, windows: [popup]), "A popup isn't what a reopen brings back")
        let stranger = TestWindow.new(id: 2, parent: other.rootTilingContainer,
            app: TestApp(pid: 77, bundleId: "com.example.other"))
        XCTAssertFalse(runningAppHasWindows(pid: pid, windows: [popup, stranger]))

        let tiled = TestWindow.new(id: 3, parent: other.rootTilingContainer)
        XCTAssertTrue(runningAppHasWindows(pid: pid, windows: [tiled]), "Another tab's window isn't taken from it")
        let minimized = TestWindow.new(id: 4, parent: macosMinimizedWindowsContainer)
        XCTAssertTrue(runningAppHasWindows(pid: pid, windows: [minimized]),
            "A reopen would deminiaturize a minimized window, which may be another tab's")
        let hidden = TestWindow.new(id: 5, parent: other.macOsNativeHiddenAppsWindowsContainer)
        XCTAssertTrue(runningAppHasWindows(pid: pid, windows: [hidden]))
        tiled.unbindFromParent()
        XCTAssertFalse(runningAppHasWindows(pid: pid, windows: [tiled]), "A window that closed doesn't count")
    }

    func testTheReopenIsTheDockClicksWithoutActivatingOrLaunchingAnotherCopy() {
        let configuration = reopenConfiguration()
        XCTAssertFalse(configuration.activates,
            "WinMux focuses the window once placed; an app activated early could pull focus back after the user moved on")
        XCTAssertFalse(configuration.createsNewApplicationInstance, "The running app is the one reopened")
        XCTAssertFalse(configuration.promptsUserIfNeeded)
        XCTAssertFalse(configuration.addsToRecentItems)
    }

    func testTheWindowsBeforeAReopenAreThoseWinMuxKnowsAndThoseOnScreen() {
        let other = Workspace.get(byName: "other")
        let known = TestWindow.new(id: 1, parent: other.rootTilingContainer)
        let unbound = TestWindow.new(id: 2, parent: other.rootTilingContainer)
        unbound.unbindFromParent()
        let stranger = TestWindow.new(id: 3, parent: other.rootTilingContainer,
            app: TestApp(pid: 77, bundleId: "com.example.other"))
        var asked: [Int32] = []
        let ids = windowIdsBeforeReopen(pid: pid, registered: [known, unbound, stranger],
            onScreen: { asked.append($0); return [7] })
        XCTAssertEqual(ids, [1, 2, 7], "An off-screen window the app hid on close isn't among them")
        XCTAssertEqual(asked, [pid])
    }

    func testTheAppIsAskedOnceAndTheWindowItShowsGoesToTheClickedTab() async throws {
        let pin = Workspace.get(byName: "pin")
        _ = pin.focusWorkspace()
        // A window that closed earlier, which this reopen doesn't bring back.
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: [9]))
        var outcomes: [NewWindowRequestOutcome] = []
        clickPin(pin, preexisting: [3]) { outcomes.append($0) }
        await letTheRequestRun()
        XCTAssertEqual(reopened, [appURL])

        XCTAssertNil(registry.claim(windowId: 3, pid: pid, bundleId: appId, firstSeenUptime: clock),
            "A window it had before isn't the one shown")
        let shown = try await appShows(5)
        let window = try XCTUnwrap(shown)
        XCTAssertTrue(window.nodeWorkspace === pin)
        XCTAssertEqual(outcomes, [.placed(windowId: 5)])
        XCTAssertTrue(focus.windowOrNil === window)
        XCTAssertEqual(savedTabAppFailureMessage(outcomes[0], appName: "Probe"), nil)
        XCTAssertTrue(closedWindowsCacheContains(windowId: 9), "A new window leaves what WinMux remembers alone")
    }

    func testWhereFocusWasIsRecordedWhenTheReopenIsAsked() throws {
        let pin = Workspace.get(byName: "pin")
        _ = pin.focusWorkspace()
        clickPin(pin)
        let intent = try XCTUnwrap(registry.intents.first)
        XCTAssertEqual(intent.focusWhenSent?.generation, intent.focusGeneration,
            "Before any other main-actor work can move focus")
    }

    func testAWindowTheAppHidWhenItClosedIsWhatTheReopenBringsBack() async throws {
        let pin = Workspace.get(byName: "pin")
        // The app kept its window when it was closed. WinMux saw it close and remembers it.
        registry.isRestorationCandidate = { $0 == 60 }
        let launcher = try XCTUnwrap(registry.register(bundleId: appId, pid: pid, targetWorkspace: pin,
            preexistingWindowIds: [], focusGeneration: focusChangeGeneration))
        XCTAssertNil(registry.claim(windowId: 60, pid: pid, bundleId: appId, firstSeenUptime: clock),
            "A launcher request for a new window never takes an old one")
        registry.cancel(intentId: launcher.id)

        clickPin(pin)
        await letTheRequestRun()
        XCTAssertTrue(registry.claim(windowId: 60, pid: pid, bundleId: appId, firstSeenUptime: clock) === pin)
    }

    func testAWindowShownAgainGoesToTheClickedTabNotBackToWhereItClosed() async throws {
        let old = Workspace.get(byName: "old")
        let pin = Workspace.get(byName: "pin")
        _ = TestWindow.new(id: 1, parent: old.rootTilingContainer)
        let hidden = TestWindow.new(id: 2, parent: old.rootTilingContainer)
        // The app hid its window on close; WinMux cached the world as it closed.
        replaceClosedWindowsCache(snapshotCurrentFrozenWorld())
        hidden.unbindFromParent()
        _ = pin.focusWorkspace()

        var outcomes: [NewWindowRequestOutcome] = []
        clickPin(pin) { outcomes.append($0) }
        await letTheRequestRun()
        _ = try await appShows(2, reusing: hidden)

        XCTAssertTrue(hidden.nodeWorkspace === pin, "The click asked for it here")
        XCTAssertTrue(pin.isVisible, "Restoring the old world would have switched the display back to its tab")
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
    }

    func testAnotherClosedWindowShownLaterDoesntTakeTheReopenedOneBack() async throws {
        let old = Workspace.get(byName: "old")
        let otherOld = Workspace.get(byName: "other-old")
        let pin = Workspace.get(byName: "pin")
        _ = TestWindow.new(id: 1, parent: old.rootTilingContainer)
        let first = TestWindow.new(id: 2, parent: old.rootTilingContainer)
        let second = TestWindow.new(id: 3, parent: otherOld.rootTilingContainer)
        // Both hid on close; the cached world has each where it was.
        replaceClosedWindowsCache(snapshotCurrentFrozenWorld())
        first.unbindFromParent()
        second.unbindFromParent()
        _ = pin.focusWorkspace()

        var outcomes: [NewWindowRequestOutcome] = []
        clickPin(pin) { outcomes.append($0) }
        await letTheRequestRun()
        _ = try await appShows(2, reusing: first)
        // The app shows its other window too, which no request waits for.
        let binding = bindingDataForNewRegularWindow(focus.workspace, window: nil)
        second.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        _ = try await restoreOrDetectNewWindow(second, isRegularWindow: true)

        XCTAssertTrue(first.nodeWorkspace === pin, "The cached world doesn't take it back")
        XCTAssertTrue(pin.isVisible, "nor switch the display away from the tab clicked")
        XCTAssertTrue(second.nodeWorkspace === otherOld, "The other window still returns to its own tab")
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
    }

    func testAWorldSavedBeforeWinMuxRestartedDoesntTakeTheReopenedWindowBack() async throws {
        let old = Workspace.get(byName: "old")
        let otherOld = Workspace.get(byName: "other-old")
        let pin = Workspace.get(byName: "pin")
        _ = TestWindow.new(id: 1, parent: old.rootTilingContainer)
        let first = TestWindow.new(id: 2, parent: old.rootTilingContainer)
        let second = TestWindow.new(id: 3, parent: otherOld.rootTilingContainer)
        // Saved as WinMux quit; both windows were hidden when it started again, so nothing restored.
        setPendingPersistedFrozenWorldForTests(snapshotCurrentFrozenWorld())
        first.unbindFromParent()
        second.unbindFromParent()
        _ = pin.focusWorkspace()

        clickPin(pin)
        await letTheRequestRun()
        _ = try await appShows(2, reusing: first)
        XCTAssertTrue(first.nodeWorkspace === pin)
        let binding = bindingDataForNewRegularWindow(focus.workspace, window: nil)
        second.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        _ = try await restoreOrDetectNewWindow(second, isRegularWindow: true)

        XCTAssertTrue(first.nodeWorkspace === pin, "The saved world doesn't take it back")
        XCTAssertTrue(pin.isVisible)
        XCTAssertTrue(second.nodeWorkspace === otherOld, "The other window still returns to its own tab")
    }

    func testARestoreAlreadyUnderWayLeavesTheReopenedWindowAlone() async throws {
        let old = Workspace.get(byName: "old")
        let otherOld = Workspace.get(byName: "other-old")
        let pin = Workspace.get(byName: "pin")
        _ = TestWindow.new(id: 1, parent: old.rootTilingContainer)
        let first = TestWindow.new(id: 2, parent: old.rootTilingContainer)
        let second = TestWindow.new(id: 3, parent: otherOld.rootTilingContainer)
        let world = snapshotCurrentFrozenWorld()
        first.unbindFromParent()
        second.unbindFromParent()
        _ = pin.focusWorkspace()
        // Another window's restore began with this snapshot and is waiting on an AX read.
        let restoreBegan = explicitWindowPlacementCount

        clickPin(pin)
        await letTheRequestRun()
        _ = try await appShows(2, reusing: first)
        let binding = bindingDataForNewRegularWindow(focus.workspace, window: nil)
        second.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        _ = try await restoreFrozenWorldIfNeeded(world, newlyDetectedWindow: second, placedSince: restoreBegan)

        XCTAssertTrue(first.nodeWorkspace === pin, "Placed after the restore's snapshot: left where the user put it")
        XCTAssertTrue(second.nodeWorkspace === otherOld)
    }

    func testForgettingAReopenedWindowsOldPlaceKeepsEveryOtherWindowsPlace() {
        let old = Workspace.get(byName: "old")
        let pin = Workspace.get(byName: "pin")
        let stack = TilingContainer(parent: old.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, .v, .tabGroup,
            index: INDEX_BIND_LAST)
        _ = TestWindow.new(id: 1, parent: old.rootTilingContainer)
        let reopened = TestWindow.new(id: 2, parent: stack)
        _ = TestWindow.new(id: 3, parent: old.rootTilingContainer)
        let world = snapshotCurrentFrozenWorld()
        _ = pin.focusWorkspace()
        reopened.bind(to: pin.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)

        let superseded = world.superseding(placementOf: reopened, in: pin)
        XCTAssertEqual(superseded.windowIds, [1, 3, 2], "The reopened window is remembered in its new tab")
        let oldTab = try? XCTUnwrap(superseded.workspaces.first { $0.name == old.name })
        XCTAssertEqual(oldTab?.rootTilingNode.children.count, 2, "Its old stack, left empty, is dropped")
        XCTAssertEqual(superseded.monitors.first { $0.topLeftCorner == pin.workspaceMonitor.rect.topLeftCorner }?
            .visibleWorkspace, pin.name)
        XCTAssertEqual(world.superseding(placementOf: TestWindow.new(id: 9, parent: pin.rootTilingContainer), in: pin)
            .windowIds, world.windowIds, "A world that never had the window is left alone")
    }

    func testClickingThePinAgainWhileTheAppReopensAsksItOnlyOnce() async throws {
        let pin = Workspace.get(byName: "pin")
        _ = pin.focusWorkspace()
        var first: [NewWindowRequestOutcome] = []
        var second: [NewWindowRequestOutcome] = []
        let firstId = clickPin(pin) { first.append($0) }
        await letTheRequestRun()
        let secondId = clickPin(pin) { second.append($0) }
        await letTheRequestRun()

        XCTAssertEqual(reopened.count, 1, "A second reopen could make a slow app open a second window")
        XCTAssertEqual(firstId, secondId)
        XCTAssertEqual(first, [.cancelled], "Taken over quietly, no error for a double click")
        _ = try await appShows(5)
        XCTAssertEqual(second, [.placed(windowId: 5)])
        XCTAssertEqual(first, [.cancelled], "Reported once")
    }

    func testAClickOnAnotherPinOfTheSameAppTakesThePendingReopenOver() async throws {
        let firstPin = Workspace.get(byName: "first")
        let secondPin = Workspace.get(byName: "second")
        var outcomes: [String: [NewWindowRequestOutcome]] = [:]
        _ = firstPin.focusWorkspace()
        clickPin(firstPin) { outcomes["first", default: []].append($0) }
        await letTheRequestRun()
        _ = secondPin.focusWorkspace()
        clickPin(secondPin) { outcomes["second", default: []].append($0) }
        await letTheRequestRun()

        XCTAssertEqual(reopened.count, 1)
        let shown = try await appShows(5)
        let window = try XCTUnwrap(shown)
        XCTAssertTrue(window.nodeWorkspace === secondPin, "The newest click is the one the window answers")
        XCTAssertTrue(firstPin.isEffectivelyEmpty)
        XCTAssertEqual(outcomes["first"], [.cancelled])
        XCTAssertEqual(outcomes["second"], [.placed(windowId: 5)])
        XCTAssertTrue(focus.windowOrNil === window)
    }

    func testAClickOnTheAppsNewProcessTakesThePendingReopenOver() async throws {
        let firstPin = Workspace.get(byName: "first")
        let secondPin = Workspace.get(byName: "second")
        var first: [NewWindowRequestOutcome] = []
        clickPin(firstPin) { first.append($0) }
        await letTheRequestRun()
        // The app quit and came back before LaunchServices replied; the next click finds its new process.
        startReopenRequest(target, pid: 42, appURL: appURL, targetWorkspace: secondPin, focusGeneration: focusChangeGeneration,
            preexistingWindowIds: { [] }, completion: { _ in })
        await letTheRequestRun()
        XCTAssertEqual(reopened.count, 1, "Not \"already opening a window\", and not asked twice")
        XCTAssertEqual(first, [.cancelled])
        XCTAssertTrue(registry.claim(windowId: 5, pid: pid, bundleId: appId, firstSeenUptime: clock) === secondPin)
    }

    func testAClickAfterTheDeadlineAsksTheAppAgain() async throws {
        let pin = Workspace.get(byName: "pin")
        var first: [NewWindowRequestOutcome] = []
        var second: [NewWindowRequestOutcome] = []
        clickPin(pin) { first.append($0) }
        await letTheRequestRun()
        // The deadline passed; the expiry watcher hasn't woken yet.
        clock += newWindowIntentTimeout + 1
        clickPin(pin) { second.append($0) }
        await letTheRequestRun()

        XCTAssertEqual(reopened.count, 2, "Taking over a request that already ended would time out at once")
        XCTAssertEqual(first, [.timedOut])
        XCTAssertEqual(second, [])
        XCTAssertTrue(registry.claim(windowId: 5, pid: pid, bundleId: appId, firstSeenUptime: clock) === pin)
    }

    func testAnAppThatShowsNoWindowSaysSoOnceItsTimeIsUp() async throws {
        var outcomes: [NewWindowRequestOutcome] = []
        let intentId = try XCTUnwrap(clickPin(Workspace.get(byName: "pin")) { outcomes.append($0) })
        XCTAssertEqual(registry.deadline(forIntent: intentId), clock + 2 * newWindowIntentTimeout,
            "Until the app takes the reopen")
        await letTheRequestRun()
        XCTAssertEqual(registry.deadline(forIntent: intentId), clock + newWindowIntentTimeout,
            "Then the usual time for its window")

        clock += newWindowIntentTimeout - 1
        registry.expireOverdueIntents()
        XCTAssertEqual(outcomes, [], "A slow app's window still has time")
        clock += 2
        registry.expireOverdueIntents()
        XCTAssertEqual(outcomes, [.timedOut])
        XCTAssertEqual(savedTabAppFailureMessage(.timedOut, appName: "Probe"), "Probe didn't open a window.")
        XCTAssertNil(registry.claim(windowId: 9, pid: pid, bundleId: appId, firstSeenUptime: clock),
            "A window long after follows the usual rules")
    }

    func testAReopenLaunchServicesRefusesSaysWhy() async throws {
        reopenResult = .failure(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The app was moved."]))
        var outcomes: [NewWindowRequestOutcome] = []
        clickPin(Workspace.get(byName: "pin")) { outcomes.append($0) }
        await letTheRequestRun()

        XCTAssertEqual(outcomes, [.failed("Probe couldn't be opened: The app was moved.")])
        XCTAssertEqual(savedTabAppFailureMessage(outcomes[0], appName: "Probe"), "Probe couldn't be opened: The app was moved.")
        XCTAssertFalse(registry.hasPendingIntents)
    }

    func testAPinRemovedWhileItsAppShowsNothingSaysNothing() async throws {
        let pin = Workspace.get(byName: "removed")
        var outcomes: [NewWindowRequestOutcome] = []
        clickPin(pin) { outcomes.append($0) }
        await letTheRequestRun()
        removeWorkspaceFromRegistry(pin, reason: .deleted)

        clock += 2 * newWindowIntentTimeout
        registry.expireOverdueIntents()
        XCTAssertEqual(outcomes, [.cancelled], "No \"didn't open a window\" for a tab that's gone")
    }

    func testAPinRemovedWhileItsAppReopensGetsNothingAndSaysNothing() async throws {
        let pin = Workspace.get(byName: "removed")
        var outcomes: [NewWindowRequestOutcome] = []
        clickPin(pin) { outcomes.append($0) }
        await letTheRequestRun()
        removeWorkspaceFromRegistry(pin, reason: .deleted)

        XCTAssertNil(registry.claim(windowId: 5, pid: pid, bundleId: appId, firstSeenUptime: clock),
            "The window follows the usual rules")
        XCTAssertNil(Workspace.existing(byName: "removed"), "Never recreated")
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertNil(savedTabAppFailureMessage(.cancelled, appName: "Probe"))
    }

    func testANewProcessWindowArrivingBeforeLaunchServicesRepliesIsTheOneAskedFor() throws {
        let pin = Workspace.get(byName: "pin")
        clickPin(pin) // LaunchServices hasn't replied yet.
        XCTAssertNil(registry.claim(windowId: 5, pid: 42, bundleId: appId, firstSeenUptime: clock),
            "While the process asked runs, another process's window isn't it")
        registry.isProcessAlive = { $0 != self.pid }
        XCTAssertTrue(registry.claim(windowId: 5, pid: 42, bundleId: appId, firstSeenUptime: clock) === pin,
            "Once it quit, the app's relaunched process is what the reopen reached")
    }

    func testAnotherCopyOfTheAppRunningAlreadyIsntTakenForTheRelaunch() {
        let pin = Workspace.get(byName: "pin")
        startReopenRequest(target, pid: pid, appURL: appURL, targetWorkspace: pin, focusGeneration: focusChangeGeneration,
            preexistingWindowIds: { [] }, runningInstancePids: { _ in [self.pid, 50] }, completion: { _ in })
        registry.isProcessAlive = { $0 != self.pid } // The copy asked quit before LaunchServices replied.

        XCTAssertNil(registry.claim(windowId: 5, pid: 50, bundleId: appId, firstSeenUptime: clock),
            "A copy that was already running opens windows of its own")
        XCTAssertTrue(registry.claim(windowId: 6, pid: 42, bundleId: appId, firstSeenUptime: clock) === pin)
    }

    func testAnAppThatQuitMeanwhileIsWaitedForInItsNewProcess() async throws {
        let pin = Workspace.get(byName: "pin")
        reopenResult = .success(42)
        clickPin(pin)
        await letTheRequestRun()

        XCTAssertNil(registry.claim(windowId: 5, pid: pid, bundleId: appId, firstSeenUptime: clock),
            "The process asked is gone")
        XCTAssertTrue(registry.claim(windowId: 5, pid: 42, bundleId: appId, firstSeenUptime: clock) === pin)
    }
}
