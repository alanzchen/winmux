@testable import AppBundle
import AppKit
import Common
import XCTest

/// A reopen claimed while another window's frozen-world restore is under way. The restore works
/// from an older snapshot that has the reopened window in its old tab, across its AX waits, so the
/// reopen is finished only once no restore is left, and then goes where the click asked.
@MainActor
final class PinReopenRestoreRaceTest: XCTestCase {
    private var registry: NewWindowIntentRegistry { .shared }
    private var clock: TimeInterval = 1000
    private var originalReopen: (@MainActor (URL) async throws -> Int32)!

    private let appId = "bobko.WinMux.test-app"
    private let appURL = URL(fileURLWithPath: "/Applications/Probe.app")
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
        reopenRunningApplication = { _ in TestApp.shared.pid }
    }

    override func tearDown() async throws {
        reopenRunningApplication = originalReopen
        registry.resetForTests()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        config = defaultConfig
        try await super.tearDown()
    }

    private func letTasksRun() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }

    @discardableResult
    private func clickPin(_ tab: Workspace, _ outcome: @escaping @MainActor (NewWindowRequestOutcome) -> Void) -> Int? {
        startReopenRequest(NewWindowRequestTarget(bundleId: appId, appName: "Probe", bundleURL: appURL), pid: pid,
            appURL: appURL, targetWorkspace: tab, focusGeneration: focusChangeGeneration, preexistingWindowIds: { [] },
            completion: outcome)
    }

    /// What detection does with the window the app showed: claim it, register it there, detect it.
    private func appShows(_ window: Window) async throws {
        let tab = try XCTUnwrap(registry.claim(windowId: window.windowId, pid: pid, bundleId: appId, firstSeenUptime: clock))
        let binding = newWindowIntentBinding(targetWorkspace: tab)
        window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
    }

    /// The reopened window lived in `old` (first there, so a unit-test restore reaches it), another
    /// app's window in `q`, and a hidden app's window in `held-first`, which a restore reads first.
    /// The first two closed; the user is on the empty pin.
    private func closedWorld() -> (old: Workspace, pin: Workspace, q: Workspace, held: TestWindow, reopened: TestWindow,
                                   other: TestWindow)
    {
        let heldFirst = Workspace.get(byName: "held-first")
        let old = Workspace.get(byName: "old")
        let q = Workspace.get(byName: "q")
        let pin = Workspace.get(byName: "pin")
        let held = TestWindow.new(id: 9, parent: heldFirst.macOsNativeHiddenAppsWindowsContainer)
        let reopened = TestWindow.new(id: 2, parent: old.rootTilingContainer)
        _ = TestWindow.new(id: 1, parent: old.rootTilingContainer)
        let other = TestWindow.new(id: 3, parent: q.rootTilingContainer, app: TestApp(pid: 77, bundleId: "com.example.other"))
        replaceClosedWindowsCache(snapshotCurrentFrozenWorld())
        reopened.unbindFromParent()
        other.unbindFromParent()
        _ = pin.focusWorkspace()
        return (old, pin, q, held, reopened, other)
    }

    /// Another app's window comes back; its restore of the old snapshot waits on an AX read of `held`
    /// until `release` runs. With `failing`, the read then throws.
    private func restoreWaitingOnAX(_ other: Window, held: TestWindow, failing: (any Error)? = nil) async
        -> (restore: Task<Bool, any Error>, release: () -> Void)
    {
        var resume: CheckedContinuation<Void, Never>?
        held.nativeStateGate = {
            await withCheckedContinuation { resume = $0 }
            if let failing { throw failing }
            try Task.checkCancellation()
        }
        let binding = bindingDataForNewRegularWindow(focus.workspace, window: nil)
        other.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        let restore = Task { @MainActor in try await restoreOrDetectNewWindow(other, isRegularWindow: true) }
        await letTasksRun()
        XCTAssertNotNil(resume, "The restore waits on the AX read")
        XCTAssertEqual(activeFrozenRestoreCount, 1)
        return (restore, {
            held.nativeStateGate = nil
            resume?.resume()
        })
    }

    func testAReopenClaimedWhileARestoreWaitsOnAXEndsInTheClickedTab() async throws {
        let (old, pin, q, held, reopened, other) = closedWorld()
        let (restore, release) = await restoreWaitingOnAX(other, held: held)
        var outcomes: [NewWindowRequestOutcome] = []
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)
        XCTAssertEqual(outcomes, [], "Not finished while a restore that could undo it runs")

        release()
        _ = try await restore.value

        XCTAssertTrue(reopened.nodeWorkspace === pin, "The older snapshot had it in \(old.name); the click asked for the pin")
        XCTAssertTrue(other.nodeWorkspace === q, "The other window still returns to its own tab")
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
        XCTAssertTrue(focus.windowOrNil === reopened, "The user hadn't moved on")
        XCTAssertTrue(pin.isVisible)
        XCTAssertEqual(activeFrozenRestoreCount, 0)
        XCTAssertFalse(closedWindowsCacheContains(windowId: 2) && reopened.nodeWorkspace !== pin)
    }

    func testAReopenWaitsForTheLastOfOverlappingRestores() async throws {
        let (_, pin, _, _, reopened, _) = closedWorld()
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        beginFrozenRestore()
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)

        endFrozenRestore()
        XCTAssertEqual(outcomes, [], "One restore is still under way")
        endFrozenRestore()
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
        XCTAssertTrue(reopened.nodeWorkspace === pin)
    }

    func testARestoreThatFailsStillLetsTheReopenFinish() async throws {
        let (_, pin, _, held, reopened, other) = closedWorld()
        let (restore, release) = await restoreWaitingOnAX(other, held: held, failing: CocoaError(.featureUnsupported))
        var outcomes: [NewWindowRequestOutcome] = []
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)

        release()
        do {
            _ = try await restore.value
            XCTFail("The AX read failed")
        } catch {}

        XCTAssertEqual(activeFrozenRestoreCount, 0)
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
        XCTAssertTrue(reopened.nodeWorkspace === pin)
    }

    func testACancelledRestoreStillLetsTheReopenFinish() async throws {
        let (_, pin, _, held, reopened, other) = closedWorld()
        let (restore, release) = await restoreWaitingOnAX(other, held: held)
        var outcomes: [NewWindowRequestOutcome] = []
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)

        restore.cancel()
        release()
        _ = try? await restore.value

        XCTAssertEqual(activeFrozenRestoreCount, 0)
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
        XCTAssertTrue(reopened.nodeWorkspace === pin)
    }

    func testATabClosedWhileItsReopenWaitsGetsNothingAndSaysNothing() async throws {
        let (old, pin, _, _, reopened, _) = closedWorld()
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)
        // The restore puts the window back in its old tab; then the pin is closed.
        reopened.bind(to: old.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        removeWorkspaceFromRegistry(pin, reason: .deleted)

        endFrozenRestore()
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertNil(savedTabAppFailureMessage(.cancelled, appName: "Probe"))
        XCTAssertTrue(reopened.nodeWorkspace === old, "Left where it is")
        XCTAssertNil(Workspace.existing(byName: "pin"), "Never recreated")
    }

    func testMovingOnWhileTheReopenWaitsKeepsTheUserThereAndStillPlacesTheWindow() async throws {
        let (old, pin, _, _, reopened, _) = closedWorld()
        let elsewhere = Workspace.get(byName: "elsewhere")
        let stay = TestWindow.new(id: 7, parent: elsewhere.rootTilingContainer)
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)
        reopened.bind(to: old.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        _ = stay.focusWindow()

        endFrozenRestore()
        XCTAssertTrue(reopened.nodeWorkspace === pin, "Still where the click asked")
        XCTAssertTrue(focus.windowOrNil === stay, "No focus steal")
        XCTAssertTrue(elsewhere.isVisible)
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
    }

    func testTheReopenGetsBackTheStateTheRequestGaveItNotTheOldSnapshots() async throws {
        config.automaticallyTileNewWindows = true
        let (old, pin, _, _, reopened, _) = closedWorld()
        beginFrozenRestore()
        clickPin(pin) { _ in }
        await letTasksRun()
        try await appShows(reopened)
        XCTAssertFalse(reopened.isFloating)
        // The old snapshot had it floating and full screen in its old tab.
        reopened.bindAsFloatingWindow(to: old)
        reopened.isFullscreen = true

        endFrozenRestore()
        XCTAssertTrue(reopened.nodeWorkspace === pin)
        XCTAssertFalse(reopened.isFloating, "Tiled, as new windows are")
        XCTAssertFalse(reopened.isFullscreen)
    }

    func testAReopenClaimedInsideARestoresOwnPathFinishesAsThatRestoreEnds() async throws {
        let (_, pin, _, _, reopened, _) = closedWorld()
        var outcomes: [NewWindowRequestOutcome] = []
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        // The claim happens within a restore's own registration path: nothing waits on anything.
        beginFrozenRestore()
        try await appShows(reopened)
        XCTAssertEqual(outcomes, [])
        endFrozenRestore()
        XCTAssertEqual(outcomes, [.placed(windowId: 2)], "Finished synchronously as the restore ends")
    }

    func testAReopenWaitingPastItsDeadlineFailsAndStaysWhereTheRestoreLeftIt() async throws {
        let (old, pin, _, _, reopened, _) = closedWorld()
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        let intentId = try XCTUnwrap(clickPin(pin) { outcomes.append($0) })
        await letTasksRun()
        try await appShows(reopened)
        reopened.bind(to: old.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        XCTAssertNotNil(registry.deadline(forIntent: intentId), "The expiry watcher keeps watching it")

        clock += newWindowIntentTimeout + 1
        registry.expireOverdueIntents()
        XCTAssertEqual(outcomes, [.failed("WinMux couldn't place the new window")])
        endFrozenRestore()
        XCTAssertTrue(reopened.nodeWorkspace === old, "Ended already; the late drain leaves it alone")
        XCTAssertEqual(outcomes.count, 1)
    }

    func testAnotherClickWhileTheWindowWaitsForRestoresAsksNothingAndSaysNothing() async throws {
        let (_, pin, _, _, reopened, _) = closedWorld()
        beginFrozenRestore()
        clickPin(pin) { _ in }
        await letTasksRun()
        try await appShows(reopened)

        var second: [NewWindowRequestOutcome] = []
        requestNewWindow(NewWindowRequestTarget(bundleId: appId, appName: "Probe", bundleURL: appURL), targetWorkspace: pin,
            reopensWindowlessApp: true) { second.append($0) }
        XCTAssertEqual(second, [.cancelled], "Not \"can't open a new window\"")
        endFrozenRestore()
        XCTAssertTrue(reopened.nodeWorkspace === pin)
    }

    func testARequestWithdrawnWhileItsWindowWaitsLeavesTheWindowWhereItIs() async throws {
        let (old, pin, _, _, reopened, _) = closedWorld()
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        let intentId = try XCTUnwrap(clickPin(pin) { outcomes.append($0) })
        await letTasksRun()
        try await appShows(reopened)
        reopened.bind(to: old.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)

        registry.cancel(intentId: intentId, outcome: .failed("Probe couldn't be opened: gone"))
        XCTAssertEqual(outcomes, [.failed("Probe couldn't be opened: gone")])
        endFrozenRestore()
        XCTAssertTrue(reopened.nodeWorkspace === old, "Withdrawn: the usual rules, not the click")
        XCTAssertEqual(outcomes.count, 1)
    }
}
