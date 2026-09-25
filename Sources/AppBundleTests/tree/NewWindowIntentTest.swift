@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class NewWindowIntentTest: XCTestCase {
    private var registry: NewWindowIntentRegistry { .shared }
    private var clock: TimeInterval = 1000

    override func setUp() async throws {
        try await super.setUp()
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        registry.resetForTests()
        clock = 1000
        registry.now = { [weak self] in self?.clock ?? 0 }
    }

    override func tearDown() async throws {
        registry.resetForTests()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        config = defaultConfig
        try await super.tearDown()
    }

    private let appId = "bobko.WinMux.test-app"

    @discardableResult
    private func register(
        pid: Int32? = 7,
        target: Workspace,
        preexisting: Set<UInt32> = [],
        timeout: TimeInterval = newWindowIntentTimeout,
        _ outcomes: ((NewWindowRequestOutcome) -> Void)? = nil,
    ) -> NewWindowIntent? {
        registry.register(bundleId: appId, pid: pid, targetWorkspace: target, preexistingWindowIds: preexisting,
            focusGeneration: focusChangeGeneration, timeout: timeout, completion: outcomes)
    }

    func testTheRequestedWindowIsClaimedOnceForItsWorkspace() throws {
        let target = Workspace.get(byName: "launched")
        var outcomes: [NewWindowRequestOutcome] = []
        XCTAssertNotNil(register(target: target, preexisting: [10]) { outcomes.append($0) })

        XCTAssertNil(registry.claim(windowId: 10, pid: 7, bundleId: appId, firstSeenUptime: clock),
            "A window the app already had is never the new one")
        XCTAssertNil(registry.claim(windowId: 11, pid: 8, bundleId: appId, firstSeenUptime: clock),
            "Another process of the same app isn't the one asked")
        XCTAssertNil(registry.claim(windowId: 11, pid: 7, bundleId: "com.other.app", firstSeenUptime: clock))
        XCTAssertNil(registry.claim(windowId: 11, pid: 7, bundleId: appId, firstSeenUptime: clock - 1),
            "A window first seen before the request, promoted from a popup now, isn't it")

        XCTAssertTrue(registry.claim(windowId: 11, pid: 7, bundleId: appId, firstSeenUptime: clock) === target)
        XCTAssertEqual(outcomes, [], "Claiming isn't placing: the request is still open")
        XCTAssertNil(registry.claim(windowId: 12, pid: 7, bundleId: appId, firstSeenUptime: clock),
            "The app's next window is placed normally")
        let claim = try XCTUnwrap(registry.consumeClaim(windowId: 11))
        XCTAssertTrue(claim.targetWorkspace === target)
        XCTAssertNil(registry.consumeClaim(windowId: 11))
    }

    func testTheRequestSucceedsOnlyOnceItsWindowIsInTheWorkspace() throws {
        let target = Workspace.get(byName: "launched")
        var outcomes: [NewWindowRequestOutcome] = []
        register(target: target) { outcomes.append($0) }
        _ = registry.claim(windowId: 11, pid: 7, bundleId: appId, firstSeenUptime: clock)
        let claim = try XCTUnwrap(registry.consumeClaim(windowId: 11))
        let strayed = TestWindow.new(id: 11, parent: focus.workspace.rootTilingContainer)

        registry.completeClaim(claim, window: strayed)

        XCTAssertEqual(outcomes, [.failed("The new window went to another workspace")])
    }

    func testAnAppThatWasntRunningMatchesByBundleUntilItsPidIsKnown() throws {
        let target = Workspace.get(byName: "launched")
        register(pid: nil, target: target)
        XCTAssertTrue(registry.claim(windowId: 20, pid: 99, bundleId: appId, firstSeenUptime: clock) === target)

        let second = try XCTUnwrap(register(pid: nil, target: target))
        registry.setPid(5, forIntent: second.id)
        XCTAssertNil(registry.claim(windowId: 21, pid: 6, bundleId: appId, firstSeenUptime: clock))
        XCTAssertNotNil(registry.claim(windowId: 21, pid: 5, bundleId: appId, firstSeenUptime: clock))
    }

    func testOneRequestPerAppAndRequestsExpire() {
        var outcomes: [NewWindowRequestOutcome] = []
        XCTAssertNotNil(register(target: Workspace.get(byName: "a")) { outcomes.append($0) })
        XCTAssertNil(register(target: Workspace.get(byName: "b")), "Two requests couldn't tell their windows apart")

        clock += newWindowIntentTimeout + 1
        registry.expireOverdueIntents()
        XCTAssertEqual(outcomes, [.timedOut])
        XCTAssertFalse(registry.hasPendingIntents)
        XCTAssertNil(registry.claim(windowId: 30, pid: 7, bundleId: appId, firstSeenUptime: clock),
            "A window arriving after the deadline follows the usual rules")
    }

    func testAPermissionPromptDoesntUseUpTheTimeForTheWindowToAppear() throws {
        var outcomes: [NewWindowRequestOutcome] = []
        let intent = try XCTUnwrap(register(target: Workspace.get(byName: "a"),
            timeout: newWindowScriptTimeout + newWindowIntentTimeout) { outcomes.append($0) })

        // The user reads the Automation prompt for most of a minute, then allows it.
        clock += newWindowScriptTimeout - 5
        registry.expireOverdueIntents()
        XCTAssertTrue(registry.isPending(intentId: intent.id))
        registry.restartDeadline(forIntent: intent.id)

        clock += newWindowIntentTimeout - 1
        registry.expireOverdueIntents()
        XCTAssertTrue(registry.isPending(intentId: intent.id), "The window still gets its usual time after the reply")
        clock += 2
        registry.expireOverdueIntents()
        XCTAssertEqual(outcomes, [.timedOut])
    }

    func testAPermissionPromptTakingFocusDoesntCostTheWindowItsFocus() throws {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        _ = first.focusWindow()
        let intent = try XCTUnwrap(register(pid: TestApp.shared.pid, target: workspace))
        registry.recordFocusWhenSent(forIntent: intent.id, .current)
        // The Automation prompt takes focus and gives it back; the window arrives before or
        // after the app's reply.
        let prompt = TestWindow.new(id: 9, parent: workspace.rootTilingContainer)
        _ = prompt.focusWindow()
        _ = first.focusWindow()

        _ = registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId, firstSeenUptime: clock)
        let window = TestWindow.new(id: 2, parent: newWindowIntentBinding(targetWorkspace: workspace).parent)
        finishNewWindowIntentPlacement(window, claim: try XCTUnwrap(registry.consumeClaim(windowId: 2)))
        XCTAssertTrue(focus.windowOrNil === window)
    }

    func testMovingOnWhileTheAppIsAskedKeepsFocusWhereTheUserWent() throws {
        let workspace = focus.workspace
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer).focusWindow()
        let intent = try XCTUnwrap(register(pid: TestApp.shared.pid, target: workspace))
        registry.recordFocusWhenSent(forIntent: intent.id, .current)
        // The user focuses another window while the app handles the request.
        let elsewhere = TestWindow.new(id: 5, parent: workspace.rootTilingContainer)
        _ = elsewhere.focusWindow()

        _ = registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId, firstSeenUptime: clock)
        let window = TestWindow.new(id: 2, parent: newWindowIntentBinding(targetWorkspace: workspace).parent)
        finishNewWindowIntentPlacement(window, claim: try XCTUnwrap(registry.consumeClaim(windowId: 2)))
        XCTAssertTrue(window.nodeWorkspace === workspace, "Placed as asked")
        XCTAssertTrue(focus.windowOrNil === elsewhere, "but focus stays where the user went")
    }

    func testMovingOnBeforeTheRequestIsSentIsNeverForgiven() throws {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        _ = first.focusWindow()
        let intent = try XCTUnwrap(register(pid: TestApp.shared.pid, target: workspace))
        // The user moves on and back while the app is still launching, before the script is sent.
        _ = TestWindow.new(id: 5, parent: workspace.rootTilingContainer).focusWindow()
        _ = first.focusWindow()
        registry.recordFocusWhenSent(forIntent: intent.id, .current)

        _ = registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId, firstSeenUptime: clock)
        let window = TestWindow.new(id: 2, parent: newWindowIntentBinding(targetWorkspace: workspace).parent)
        finishNewWindowIntentPlacement(window, claim: try XCTUnwrap(registry.consumeClaim(windowId: 2)))
        XCTAssertTrue(focus.windowOrNil === first)
    }

    func testWindowsBeingRestoredAreNeverClaimed() {
        let target = Workspace.get(byName: "launched")
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: [60]))
        register(target: target)

        XCTAssertNil(registry.claim(windowId: 60, pid: 7, bundleId: appId, firstSeenUptime: clock),
            "A window coming back from the closed-windows cache is an old window, not the new one")
        XCTAssertTrue(registry.claim(windowId: 61, pid: 7, bundleId: appId, firstSeenUptime: clock) === target)
    }

    func testAMissingDestinationIsNeverRecreated() {
        var outcomes: [NewWindowRequestOutcome] = []
        let target = Workspace.get(byName: "deleted-meanwhile")
        register(target: target) { outcomes.append($0) }
        removeWorkspaceFromRegistry(target, reason: .deleted)

        XCTAssertNil(registry.claim(windowId: 40, pid: 7, bundleId: appId, firstSeenUptime: clock))
        XCTAssertNil(Workspace.existing(byName: "deleted-meanwhile"))
        XCTAssertEqual(outcomes, [.cancelled])
    }

    func testAWorkspaceRecreatedUnderTheSameNameDoesntReceiveTheWindow() {
        var outcomes: [NewWindowRequestOutcome] = []
        let target = Workspace.get(byName: "reused-name")
        register(target: target) { outcomes.append($0) }
        removeWorkspaceFromRegistry(target, reason: .deleted)
        let recreated = Workspace.get(byName: "reused-name")
        XCTAssertNotEqual(recreated.id, target.id)

        XCTAssertNil(registry.claim(windowId: 41, pid: 7, bundleId: appId, firstSeenUptime: clock))
        XCTAssertEqual(outcomes, [.cancelled])
    }

    func testCancellingARequestLeavesItsWindowToTheUsualRules() throws {
        var outcomes: [NewWindowRequestOutcome] = []
        let intent = try XCTUnwrap(register(target: Workspace.get(byName: "a")) { outcomes.append($0) })
        registry.cancel(intentId: intent.id)
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertNil(registry.claim(windowId: 42, pid: 7, bundleId: appId, firstSeenUptime: clock))
    }

    func testDismissingAfterTheWindowWasClaimedLeavesItToTheUsualRules() async throws {
        config.openNewWindowsInNewWorkspace = true
        let origin = focus.workspace
        _ = TestWindow.new(id: 1, parent: origin.rootTilingContainer).focusWindow()
        var outcomes: [NewWindowRequestOutcome] = []
        let intent = try XCTUnwrap(register(pid: TestApp.shared.pid, target: origin) { outcomes.append($0) })
        let claimed = try XCTUnwrap(registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId,
            firstSeenUptime: clock))
        let window = TestWindow.new(id: 2, parent: newWindowIntentBinding(targetWorkspace: claimed).parent)

        // The user closes the launcher while detection is still suspended.
        registry.cancel(intentId: intent.id)
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertNotNil(registry.deadline(forIntent: intent.id), "Kept until detection sees it was withdrawn")

        let placedByWinMux = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
        XCTAssertFalse(placedByWinMux)
        XCTAssertFalse(window.nodeWorkspace === origin, "The new-workspace option applies again")
        XCTAssertEqual(outcomes, [.cancelled], "A withdrawn request reports nothing more")
    }

    func testAWindowWithdrawnInTheFocusedWorkspaceJoinsTheFocusedStackLikeAnyNewWindow() async throws {
        config.autoAddNewWindowsToTabGroup = true
        let workspace = focus.workspace
        let stack = TilingContainer(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, .v, .tabGroup,
            index: INDEX_BIND_LAST)
        _ = TestWindow.new(id: 1, parent: stack).focusWindow()
        let intent = try XCTUnwrap(register(pid: TestApp.shared.pid, target: workspace))
        _ = registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId, firstSeenUptime: clock)
        let window = TestWindow.new(id: 2, parent: newWindowIntentBinding(targetWorkspace: workspace).parent)
        XCTAssertFalse(window.parent === stack)
        registry.cancel(intentId: intent.id) // Esc, staying in the workspace.

        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertTrue(window.parent === stack)
    }

    func testDetectionThatConsumesAnotherRegistrationsClaimStillPlacesTheWindow() async throws {
        let target = Workspace.get(byName: "launched")
        var outcomes: [NewWindowRequestOutcome] = []
        register(pid: TestApp.shared.pid, target: target) { outcomes.append($0) }
        // This registration bound the window by the usual rules; a concurrent one claimed it.
        let window = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        _ = registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId, firstSeenUptime: clock)

        let placedByWinMux = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertTrue(placedByWinMux)
        XCTAssertTrue(window.nodeWorkspace === target)
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
    }

    func testAWindowWithdrawnAfterTheUserLeftGoesWhereNewWindowsGo() async throws {
        let launcherWorkspace = focus.workspace
        _ = TestWindow.new(id: 1, parent: launcherWorkspace.rootTilingContainer)
        let intent = try XCTUnwrap(register(pid: TestApp.shared.pid, target: launcherWorkspace))
        let claimed = try XCTUnwrap(registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId,
            firstSeenUptime: clock))
        let window = TestWindow.new(id: 2, parent: newWindowIntentBinding(targetWorkspace: claimed).parent)
        // Switching away closes the launcher, which withdraws the request.
        let elsewhere = Workspace.get(byName: "elsewhere")
        _ = elsewhere.focusWorkspace()
        registry.cancel(intentId: intent.id)

        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertTrue(window.nodeWorkspace === elsewhere, "Not left behind in the workspace the user left")
    }

    func testAConcurrentRegistrationLeavesTheClaimToTheDetectionInProgress() async throws {
        let (parsed, errors) = parseConfig("""
        [[on-window-detected]]
        if.app-id = 'bobko.WinMux.test-app'
        run = ['move-node-to-workspace mail']
        """)
        XCTAssertEqual(errors.descriptions, [])
        config.onWindowDetected = parsed.onWindowDetected
        let origin = focus.workspace
        let target = Workspace.get(byName: "launched")
        var outcomes: [NewWindowRequestOutcome] = []
        register(pid: TestApp.shared.pid, target: target) { outcomes.append($0) }
        // The other registration bound the window by the usual rules and is still detecting it.
        let window = TestWindow.new(id: 2, parent: origin.rootTilingContainer)
        registry.windowsBeingDetected.insert(2)
        _ = registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId, firstSeenUptime: clock)

        settleClaimAfterConcurrentRegistration(window)
        XCTAssertEqual(outcomes, [], "The detection in progress reports it")

        let placedByWinMux = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
        registry.windowsBeingDetected.remove(2)
        XCTAssertTrue(placedByWinMux)
        XCTAssertTrue(window.nodeWorkspace === target, "on-window-detected doesn't move it after all")
        XCTAssertNil(Workspace.existing(byName: "mail"))
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
    }

    func testAClaimArrivingAfterDetectionCheckedIsSettledWhenDetectionEnds() async throws {
        let (parsed, errors) = parseConfig("""
        [[on-window-detected]]
        if.app-id = 'bobko.WinMux.test-app'
        run = ['move-node-to-workspace mail']
        """)
        XCTAssertEqual(errors.descriptions, [])
        config.onWindowDetected = parsed.onWindowDetected
        let target = Workspace.get(byName: "launched")
        _ = TestWindow.new(id: 50, parent: target.rootTilingContainer) // Keeps it from being pruned.
        var outcomes: [NewWindowRequestOutcome] = []
        register(pid: TestApp.shared.pid, target: target) { outcomes.append($0) }
        let window = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        registry.windowsBeingDetected.insert(2)

        // Detection finds no claim and runs the usual rules; meanwhile another registration claims it.
        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
        XCTAssertEqual(window.nodeWorkspace?.name, "mail")
        // The callback's command snapshots the closed-windows cache, which would normally block
        // this claim; the settling is what's tested here.
        registry.isRestorationCandidate = { _ in false }
        XCTAssertNotNil(registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId, firstSeenUptime: clock))
        settleClaimAfterConcurrentRegistration(window)
        XCTAssertEqual(outcomes, [], "Left to the detection still in progress")

        settleClaimLeftAfterDetection(window) // Detection ends.
        registry.windowsBeingDetected.remove(2)

        XCTAssertTrue(window.nodeWorkspace === target, "The request still decides where it goes")
        XCTAssertEqual(outcomes, [.placed(windowId: 2)], "Exactly one success")
        settleClaimLeftAfterDetection(window)
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
    }

    func testAConcurrentRegistrationSettlesTheClaimOnceDetectionIsDone() throws {
        let workspace = focus.workspace
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer).focusWindow()
        var outcomes: [NewWindowRequestOutcome] = []
        register(pid: TestApp.shared.pid, target: workspace) { outcomes.append($0) }
        let window = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        _ = registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId, firstSeenUptime: clock)

        settleClaimAfterConcurrentRegistration(window)

        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
        XCTAssertTrue(focus.windowOrNil === window)
        XCTAssertNil(registry.consumeClaim(windowId: 2))
    }

    func testTheExpiryWatcherFollowsADeadlineThatMovesEarlier() async throws {
        registry.now = { ProcessInfo.processInfo.systemUptime }
        var outcomes: [NewWindowRequestOutcome] = []
        let intent = try XCTUnwrap(registry.register(bundleId: appId, pid: 7, targetWorkspace: Workspace.get(byName: "a"),
            preexistingWindowIds: [], focusGeneration: 0, timeout: newWindowScriptTimeout + newWindowIntentTimeout) {
                outcomes.append($0)
            })
        let watcher = Task { @MainActor in await watchNewWindowIntentExpiry(intent.id) }
        // The app replied at once, but no window follows.
        registry.restartDeadline(forIntent: intent.id, timeout: 0.2)

        await watcher.value

        XCTAssertEqual(outcomes, [.timedOut], "Reported within about a second, not after the original minute")
    }

    func testAClaimDetectionNeverFinishesStillEndsTheRequest() throws {
        var outcomes: [NewWindowRequestOutcome] = []
        let intent = try XCTUnwrap(register(target: Workspace.get(byName: "a")) { outcomes.append($0) })
        _ = registry.claim(windowId: 43, pid: 7, bundleId: appId, firstSeenUptime: clock)
        XCTAssertNotNil(registry.deadline(forIntent: intent.id), "The expiry loop keeps watching a claimed request")

        clock += newWindowIntentTimeout + 1
        registry.expireOverdueIntents()

        XCTAssertEqual(outcomes, [.failed("WinMux couldn't place the new window")])
        XCTAssertNil(registry.consumeClaim(windowId: 43))
        XCTAssertNil(registry.deadline(forIntent: intent.id))
    }

    func testAClaimedWindowKeepsItsDestinationOverOtherPlacementRules() async throws {
        let (parsed, errors) = parseConfig("""
        [[on-window-detected]]
        if.app-id = 'bobko.WinMux.test-app'
        run = ['move-node-to-workspace mail']
        """)
        XCTAssertEqual(errors.descriptions, [])
        config.onWindowDetected = parsed.onWindowDetected
        config.openNewWindowsInNewWorkspace = true
        let origin = focus.workspace
        _ = TestWindow.new(id: 1, parent: origin.rootTilingContainer)
        let target = Workspace.get(byName: "launched")
        var outcomes: [NewWindowRequestOutcome] = []

        register(pid: TestApp.shared.pid, target: target) { outcomes.append($0) }
        let claimed = try XCTUnwrap(registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId,
            firstSeenUptime: clock))
        let binding = newWindowIntentBinding(targetWorkspace: claimed)
        let window = TestWindow.new(id: 2, parent: binding.parent)

        let placedByWinMux = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertTrue(placedByWinMux, "New-window presentation treats it like a saved-workspace placement")
        XCTAssertTrue(window.nodeWorkspace === target,
            "Neither on-window-detected rules nor the new-workspace option move a window the launcher placed")
        XCTAssertNil(Workspace.existing(byName: "mail"))
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
    }

    func testThePlacedWindowTakesFocusUnlessTheUserMovedOn() throws {
        let workspace = focus.workspace
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer).focusWindow()

        register(pid: TestApp.shared.pid, target: workspace)
        _ = registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId, firstSeenUptime: clock)
        let window = TestWindow.new(id: 2, parent: newWindowIntentBinding(targetWorkspace: workspace).parent)
        finishNewWindowIntentPlacement(window, claim: try XCTUnwrap(registry.consumeClaim(windowId: 2)))
        XCTAssertTrue(focus.windowOrNil === window)

        register(pid: TestApp.shared.pid, target: workspace)
        _ = registry.claim(windowId: 3, pid: TestApp.shared.pid, bundleId: appId, firstSeenUptime: clock)
        let other = TestWindow.new(id: 4, parent: workspace.rootTilingContainer)
        _ = other.focusWindow()
        let late = TestWindow.new(id: 3, parent: newWindowIntentBinding(targetWorkspace: workspace).parent)
        finishNewWindowIntentPlacement(late, claim: try XCTUnwrap(registry.consumeClaim(windowId: 3)))
        XCTAssertTrue(focus.windowOrNil === other, "Focus moved while the window was opening; it stays put")
    }

    func testTheRequestedWindowSkipsTheFocusedStack() {
        config.autoAddNewWindowsToTabGroup = true
        let workspace = focus.workspace
        let stack = TilingContainer(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, .v, .tabGroup,
            index: INDEX_BIND_LAST)
        _ = TestWindow.new(id: 1, parent: stack).focusWindow()
        XCTAssertTrue(bindingDataForNewRegularWindow(workspace, window: nil).parent === stack,
            "Ordinary new windows join the focused stack")

        XCTAssertFalse(newWindowIntentBinding(targetWorkspace: workspace).parent === stack,
            "A window asked for from the launcher is its own window, not another tab")
    }

    func testTheRequestedWindowFloatsWhenNewWindowsDontTile() {
        config.automaticallyTileNewWindows = false
        let target = Workspace.get(byName: "launched")
        XCTAssertTrue(newWindowIntentBinding(targetWorkspace: target).parent === target)
    }

    func testUnclaimedWindowsStillFollowTheUsualRules() async throws {
        config.openNewWindowsInNewWorkspace = true
        let origin = focus.workspace
        _ = TestWindow.new(id: 1, parent: origin.rootTilingContainer)
        let window = TestWindow.new(id: 2, parent: origin.rootTilingContainer)
        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
        XCTAssertFalse(window.nodeWorkspace === origin, "Without an intent the new-workspace option still applies")
    }
}
