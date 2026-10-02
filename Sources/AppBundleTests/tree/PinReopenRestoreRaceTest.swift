@testable import AppBundle
import AppKit
import Common
import XCTest

/// A reopen claimed while another window's frozen-world restore is under way. The restore works
/// from an older snapshot that has the reopened window in its old tab, across its AX waits, so it
/// leaves the claimed window alone, and the reopen is finished only once no restore is left.
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
        resetRegistry()
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

    private func resetRegistry() {
        registry.resetForTests()
        clock = 1000
        registry.now = { [weak self] in self?.clock ?? 0 }
        registry.isProcessAlive = { _ in true }
        // Test windows aren't registered with WinMux; a closed one is unbound.
        registry.isRegistered = { $0.isBound }
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

    /// The reopened window lived in `old` beside `sibling` (first there, so a unit-test restore
    /// reaches it), another app's window in `q`, and a hidden app's window in `held-first`, which a
    /// restore reads first. The reopened window and the other closed; the user is on the empty pin.
    private func closedWorld(configure: (TestWindow) -> Void = { _ in }) -> (
        old: Workspace, pin: Workspace, q: Workspace, held: TestWindow, reopened: TestWindow, sibling: TestWindow,
        other: TestWindow,
    ) {
        let heldFirst = Workspace.get(byName: "held-first")
        let old = Workspace.get(byName: "old")
        let q = Workspace.get(byName: "q")
        let pin = Workspace.get(byName: "pin")
        let held = TestWindow.new(id: 9, parent: heldFirst.macOsNativeHiddenAppsWindowsContainer)
        let reopened = TestWindow.new(id: 2, parent: old.rootTilingContainer)
        let sibling = TestWindow.new(id: 1, parent: old.rootTilingContainer)
        let other = TestWindow.new(id: 3, parent: q.rootTilingContainer, app: TestApp(pid: 77, bundleId: "com.example.other"))
        configure(reopened)
        replaceClosedWindowsCache(snapshotCurrentFrozenWorld())
        reopened.unbindFromParent()
        other.unbindFromParent()
        _ = pin.focusWorkspace()
        return (old, pin, q, held, reopened, sibling, other)
    }

    /// Another app's window comes back; its restore of the old snapshot waits on an AX read of `held`
    /// until `release` runs. With `failing`, the read then throws.
    private func restoreWaitingOnAX(_ other: Window, held: TestWindow, failing: (any Error)? = nil) async
        -> (restore: Task<Bool, any Error>, release: () -> Void)
    {
        var resume: CheckedContinuation<Void, Never>?
        let restoresBefore = activeFrozenRestoreCount
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
        XCTAssertEqual(activeFrozenRestoreCount, restoresBefore + 1)
        return (restore, {
            held.nativeStateGate = nil
            resume?.resume()
        })
    }

    func testAReopenClaimedWhileARestoreWaitsOnAXEndsInTheClickedTab() async throws {
        let (old, pin, q, held, reopened, sibling, other) = closedWorld()
        let (restore, release) = await restoreWaitingOnAX(other, held: held)
        var outcomes: [NewWindowRequestOutcome] = []
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)
        XCTAssertEqual(outcomes, [], "Not finished while a restore runs")

        release()
        _ = try await restore.value

        XCTAssertTrue(reopened.nodeWorkspace === pin, "The older snapshot had it in \(old.name); the click asked for the pin")
        XCTAssertTrue(sibling.nodeWorkspace === old, "The rest of its old stack is still restored")
        XCTAssertTrue(other.nodeWorkspace === q, "The other window still returns to its own tab")
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
        XCTAssertTrue(focus.windowOrNil === reopened, "The user hadn't moved on")
        XCTAssertTrue(pin.isVisible)
        XCTAssertEqual(activeFrozenRestoreCount, 0)

        // Once finished, the snapshots remember it in the pin: restoring the cache again leaves it there.
        _ = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: other)
        XCTAssertTrue(reopened.nodeWorkspace === pin)
    }

    func testAPopupClaimedWhileARestoreReadsItIsLeftWhereTheClaimPutIt() async throws {
        let old = Workspace.get(byName: "old")
        let q = Workspace.get(byName: "q")
        let pin = Workspace.get(byName: "pin")
        // The snapshot has the window hidden with its app in old; it's a popup now, promoted and
        // claimed for the pin while the restore reads its native state.
        let reopened = TestWindow.new(id: 2, parent: old.macOsNativeHiddenAppsWindowsContainer)
        let other = TestWindow.new(id: 3, parent: q.rootTilingContainer, app: TestApp(pid: 77, bundleId: "com.example.other"))
        replaceClosedWindowsCache(snapshotCurrentFrozenWorld())
        reopened.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        other.unbindFromParent()
        _ = pin.focusWorkspace()
        let (restore, release) = await restoreWaitingOnAX(other, held: reopened)
        var outcomes: [NewWindowRequestOutcome] = []
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)

        release()
        _ = try await restore.value
        XCTAssertTrue(reopened.nodeWorkspace === pin, "Checked again after the AX read")
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
    }

    func testARestoreUnderWayLeavesTheReopenedWindowsStateAlone() async throws {
        config.automaticallyTileNewWindows = true
        let (_, pin, _, held, reopened, _, other) = closedWorld { window in
            // The snapshot has it full screen in WinMux.
            window.isFullscreen = true
        }
        reopened.isFullscreen = false
        let (restore, release) = await restoreWaitingOnAX(other, held: held)
        clickPin(pin) { _ in }
        await letTasksRun()
        try await appShows(reopened)

        release()
        _ = try await restore.value
        XCTAssertTrue(reopened.nodeWorkspace === pin)
        XCTAssertFalse(reopened.isFullscreen, "The old snapshot's state isn't applied to it")
        XCTAssertFalse(reopened.isFloating)
    }

    func testARestoreLeavesAClaimedWindowItRemembersFloatingOrHiddenAloneWithoutReadingIt() async throws {
        for remembered in ["floating", "hidden"] {
            setUpWorkspacesForTests()
            resetRegistry()
            let old = Workspace.get(byName: "old")
            let pin = Workspace.get(byName: "pin")
            let reopened = TestWindow.new(id: 2, parent: old.rootTilingContainer)
            if remembered == "floating" {
                reopened.bindAsFloatingWindow(to: old)
            } else {
                reopened.bind(to: old.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
            let anchor = TestWindow.new(id: 1, parent: old.rootTilingContainer)
            let snapshot = snapshotCurrentFrozenWorld()
            reopened.unbindFromParent()
            _ = pin.focusWorkspace()
            beginFrozenRestore()
            clickPin(pin) { _ in }
            await letTasksRun()
            try await appShows(reopened)
            let readsBefore = reopened.nativeStateFetchCount

            _ = try await restoreFrozenWorldIfNeeded(snapshot, newlyDetectedWindow: anchor)
            XCTAssertTrue(reopened.nodeWorkspace === pin, "Remembered \(remembered) in old; claimed for the pin")
            XCTAssertFalse(reopened.isFloating)
            XCTAssertEqual(reopened.nativeStateFetchCount, readsBefore, "No AX reads for a window the restore leaves alone")
            endFrozenRestore()
        }
    }

    func testAWithdrawnClaimNoLongerKeepsRestoresAway() throws {
        let pin = Workspace.get(byName: "pin")
        let window = TestWindow.new(id: 2, parent: pin.rootTilingContainer)
        let intentId = try XCTUnwrap(clickPin(pin) { _ in })
        XCTAssertNotNil(registry.claim(windowId: 2, pid: pid, bundleId: appId, firstSeenUptime: clock))
        XCTAssertTrue(registry.holdsReopenClaim(on: window))
        registry.cancel(intentId: intentId)
        XCTAssertFalse(registry.holdsReopenClaim(on: window), "Withdrawn: the usual rules, restores included")
    }

    func testAReopenWaitsForTheLastOfOverlappingRestores() async throws {
        let (_, pin, _, _, reopened, _, _) = closedWorld()
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
        let (_, pin, _, held, reopened, _, other) = closedWorld()
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
        let (_, pin, _, held, reopened, _, other) = closedWorld()
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

    /// The pin itself is in the snapshot, with window `held` that a restore of it finds in the root it
    /// replaces, so it waits on `held`'s AX read in its orphan pass (or fails there, with `failing`).
    /// The reopened window was claimed into the pin before, while another restore ran.
    private func restoreReplacingThePinsRoot(failing: (any Error)? = nil) async throws
        -> (pin: Workspace, reopened: TestWindow, restore: Task<Bool, any Error>, release: () -> Void, outcomes: () -> [NewWindowRequestOutcome])
    {
        let old = Workspace.get(byName: "old")
        let q = Workspace.get(byName: "q")
        let pin = Workspace.get(byName: "pin")
        let held = TestWindow.new(id: 5, parent: pin.rootTilingContainer)
        // Remembered as coming back from macOS, so the orphan pass reads its native state.
        held.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: "pin")
        let reopened = TestWindow.new(id: 2, parent: old.rootTilingContainer)
        let other = TestWindow.new(id: 3, parent: q.rootTilingContainer, app: TestApp(pid: 77, bundleId: "com.example.other"))
        replaceClosedWindowsCache(snapshotCurrentFrozenWorld())
        reopened.unbindFromParent()
        other.unbindFromParent()
        _ = pin.focusWorkspace()
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)
        XCTAssertEqual(pin.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [5, 2])
        let (restore, release) = await restoreWaitingOnAX(other, held: held, failing: failing)
        XCTAssertEqual(activeFrozenRestoreCount, 2)
        return (pin, reopened, restore, release, { outcomes })
    }

    func testAWindowTheUserMovesWhileTheRestoreReplacingItsTabWaitsStaysWhereTheUserPutIt() async throws {
        let (pin, reopened, restore, release, outcomes) = try await restoreReplacingThePinsRoot()
        XCTAssertTrue(reopened.nodeWorkspace === pin, "Moved into the new root before the wait")
        let elsewhere = Workspace.get(byName: "elsewhere")
        _ = TestWindow.new(id: 7, parent: elsewhere.rootTilingContainer)
        reopened.bind(to: elsewhere.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)

        release()
        _ = try await restore.value
        XCTAssertTrue(reopened.nodeWorkspace === elsewhere, "The orphan pass doesn't put it back in the pin")
        endFrozenRestore()
        XCTAssertTrue(reopened.nodeWorkspace === elsewhere)
        XCTAssertEqual(outcomes(), [.cancelled])
    }

    func testARestoreThatFailsAfterReplacingTheTabsRootLeavesTheReopenedWindowInTheTab() async throws {
        let (pin, reopened, restore, release, outcomes) = try await restoreReplacingThePinsRoot(failing: CocoaError(.featureUnsupported))
        release()
        do {
            _ = try await restore.value
            XCTFail("The AX read failed")
        } catch {}
        XCTAssertTrue(reopened.parent === pin.rootTilingContainer, "Not stranded in the replaced root")
        endFrozenRestore()
        XCTAssertTrue(reopened.nodeWorkspace === pin)
        XCTAssertEqual(outcomes(), [.placed(windowId: 2)])
    }

    func testARestoreSkippingTheReopenedWindowRestoresTheRestOfItsStackInOrder() async throws {
        let old = Workspace.get(byName: "old")
        let parked = Workspace.get(byName: "parked")
        let pin = Workspace.get(byName: "pin")
        let reopened = TestWindow.new(id: 2, parent: old.rootTilingContainer)
        let sibling = TestWindow.new(id: 1, parent: old.rootTilingContainer)
        let next = TestWindow.new(id: 4, parent: old.rootTilingContainer)
        let snapshot = snapshotCurrentFrozenWorld()
        reopened.unbindFromParent()
        // Elsewhere for now, so the restore finds them.
        sibling.bind(to: parked.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        next.bind(to: parked.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        _ = pin.focusWorkspace()
        beginFrozenRestore()
        clickPin(pin) { _ in }
        await letTasksRun()
        try await appShows(reopened)

        _ = try await restoreFrozenWorldIfNeeded(snapshot, newlyDetectedWindow: sibling)
        XCTAssertTrue(reopened.nodeWorkspace === pin)
        XCTAssertEqual(old.rootTilingContainer.children.compactMap { ($0 as? Window)?.windowId }, [1, 4],
            "In their remembered order, without a gap where the reopened window was")
        endFrozenRestore()
    }

    func testAReopenedWindowInATabWhoseStackARestoreRebuildsStaysBesideTheStack() async throws {
        let pin = Workspace.get(byName: "pin")
        let parked = Workspace.get(byName: "parked")
        // The pin was remembered as one stack of two windows.
        pin.rootTilingContainer.layout = .tabGroup
        let first = TestWindow.new(id: 10, parent: pin.rootTilingContainer)
        let second = TestWindow.new(id: 11, parent: pin.rootTilingContainer)
        let snapshot = snapshotCurrentFrozenWorld()
        // They're elsewhere now, where the restore finds them, and the pin is a plain tab again.
        first.bind(to: parked.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        second.bind(to: parked.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        pin.rootTilingContainer.layout = .tiles
        _ = pin.focusWorkspace()
        let reopened = TestWindow.new(id: 2, parent: parked.rootTilingContainer)
        reopened.unbindFromParent()
        beginFrozenRestore()
        clickPin(pin) { _ in }
        await letTasksRun()
        try await appShows(reopened)

        _ = try await restoreFrozenWorldIfNeeded(snapshot, newlyDetectedWindow: first)
        XCTAssertTrue(first.parent === second.parent, "The stack is restored")
        XCTAssertEqual((first.parent as? TilingContainer)?.layout, .tabGroup)
        XCTAssertTrue(reopened.nodeWorkspace === pin)
        XCTAssertFalse(reopened.parent === first.parent, "Beside the stack, as requested windows are, not a tab in it")
        endFrozenRestore()
    }

    func testAWindowTheUserMovesWhileItWaitsStaysWhereTheUserPutIt() async throws {
        let (old, pin, _, _, reopened, _, _) = closedWorld()
        let elsewhere = Workspace.get(byName: "elsewhere")
        _ = TestWindow.new(id: 7, parent: elsewhere.rootTilingContainer)
        // old is even where the older snapshot remembers the window.
        for destination in [elsewhere, old] {
            resetRegistry()
            if reopened.isBound { reopened.unbindFromParent() }
            var outcomes: [NewWindowRequestOutcome] = []
            beginFrozenRestore()
            clickPin(pin) { outcomes.append($0) }
            await letTasksRun()
            try await appShows(reopened)
            // move-node-to-workspace, while an unrelated restore still runs
            reopened.bind(to: destination.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)

            endFrozenRestore()
            XCTAssertTrue(reopened.nodeWorkspace === destination, "A newer deliberate move into \(destination.name) isn't undone")
            XCTAssertEqual(outcomes, [.cancelled])
            XCTAssertNil(savedTabAppFailureMessage(outcomes[0], appName: "Probe"))
        }
    }

    func testFullScreenTheUserTurnsOnWhileItWaitsStays() async throws {
        let (_, pin, _, _, reopened, _, _) = closedWorld()
        beginFrozenRestore()
        clickPin(pin) { _ in }
        await letTasksRun()
        try await appShows(reopened)
        reopened.isFullscreen = true

        endFrozenRestore()
        XCTAssertTrue(reopened.nodeWorkspace === pin)
        XCTAssertTrue(reopened.isFullscreen)
    }

    func testAWindowThatClosedWhileItWaitedIsntPlaced() async throws {
        let (old, pin, _, _, reopened, _, _) = closedWorld()
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)
        // It closed, and a restore holding the old object bound it again.
        registry.isRegistered = { $0 !== reopened }
        reopened.bind(to: old.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)

        endFrozenRestore()
        XCTAssertTrue(reopened.nodeWorkspace === old, "Not moved into the pin")
        XCTAssertEqual(outcomes, [.cancelled])

        // Even one a stale restore left in the pin itself isn't reported as placed.
        resetRegistry()
        var again: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        clickPin(pin) { again.append($0) }
        await letTasksRun()
        reopened.unbindFromParent()
        try await appShows(reopened)
        registry.isRegistered = { $0 !== reopened }
        endFrozenRestore()
        XCTAssertEqual(again, [.cancelled])
    }

    func testMovingOnWhileTheReopenWaitsKeepsTheUserThereAndStillPlacesTheWindow() async throws {
        let (_, pin, _, _, reopened, _, _) = closedWorld()
        let elsewhere = Workspace.get(byName: "elsewhere")
        let stay = TestWindow.new(id: 7, parent: elsewhere.rootTilingContainer)
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)
        _ = stay.focusWindow()

        endFrozenRestore()
        XCTAssertTrue(reopened.nodeWorkspace === pin, "Still where the click asked")
        XCTAssertTrue(focus.windowOrNil === stay, "No focus steal")
        XCTAssertTrue(elsewhere.isVisible)
        XCTAssertEqual(outcomes, [.placed(windowId: 2)])
    }

    func testATabClosedWhileItsReopenWaitsGetsNothingAndSaysNothing() async throws {
        let (old, pin, _, _, reopened, _, _) = closedWorld()
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)
        reopened.bind(to: old.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        removeWorkspaceFromRegistry(pin, reason: .deleted)

        endFrozenRestore()
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertNil(savedTabAppFailureMessage(.cancelled, appName: "Probe"))
        XCTAssertTrue(reopened.nodeWorkspace === old, "Left where it is")
        XCTAssertNil(Workspace.existing(byName: "pin"), "Never recreated")
    }

    func testATabRemovedWithTheWindowStillInItReportsNothing() async throws {
        let (_, pin, _, _, reopened, _, _) = closedWorld()
        let elsewhere = Workspace.get(byName: "elsewhere")
        let stay = TestWindow.new(id: 7, parent: elsewhere.rootTilingContainer)
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)
        _ = stay.focusWindow()
        removeWorkspaceFromRegistry(pin, reason: .deleted)

        endFrozenRestore()
        XCTAssertEqual(outcomes, [.cancelled], "Not placed in a tab that's gone")
        XCTAssertTrue(focus.windowOrNil === stay)
    }

    func testAReopenClaimedInsideARestoresOwnPathFinishesAsThatRestoreEnds() async throws {
        let (_, pin, _, _, reopened, _, _) = closedWorld()
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

    func testAReopenWaitingPastItsDeadlineFails() async throws {
        let (_, pin, _, _, reopened, _, _) = closedWorld()
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        let intentId = try XCTUnwrap(clickPin(pin) { outcomes.append($0) })
        await letTasksRun()
        try await appShows(reopened)
        XCTAssertNotNil(registry.deadline(forIntent: intentId), "The expiry watcher keeps watching it")

        // The restores end after the deadline, before the expiry watcher wakes.
        clock += newWindowIntentTimeout + 1
        endFrozenRestore()
        XCTAssertEqual(outcomes, [.failed("WinMux couldn't place the new window")])
        registry.expireOverdueIntents()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(registry.holdsReopenClaim(on: reopened), "Over: restores no longer leave it alone")
    }

    func testATabRemovedBeforeAWaitingReopenExpiresSaysNothing() async throws {
        let (_, pin, _, _, reopened, _, _) = closedWorld()
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        clickPin(pin) { outcomes.append($0) }
        await letTasksRun()
        try await appShows(reopened)
        removeWorkspaceFromRegistry(pin, reason: .deleted)

        clock += newWindowIntentTimeout + 1
        registry.expireOverdueIntents()
        XCTAssertEqual(outcomes, [.cancelled], "No error for a tab that's gone")
        endFrozenRestore()
        XCTAssertEqual(outcomes.count, 1)
    }

    func testARequestWithdrawnWhileItsWindowWaitsLeavesTheWindowWhereItIs() async throws {
        let (old, pin, _, _, reopened, _, _) = closedWorld()
        var outcomes: [NewWindowRequestOutcome] = []
        beginFrozenRestore()
        let intentId = try XCTUnwrap(clickPin(pin) { outcomes.append($0) })
        await letTasksRun()
        try await appShows(reopened)
        reopened.bind(to: old.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)

        registry.cancel(intentId: intentId, outcome: .failed("Probe couldn't be opened: gone"))
        XCTAssertEqual(outcomes, [.failed("Probe couldn't be opened: gone")])
        XCTAssertFalse(registry.holdsReopenClaim(on: reopened))
        endFrozenRestore()
        XCTAssertTrue(reopened.nodeWorkspace === old, "Withdrawn: the usual rules, not the click")
        XCTAssertEqual(outcomes.count, 1)
    }

    func testAnotherClickWhileTheWindowWaitsForRestoresAsksNothingAndSaysNothing() async throws {
        let (_, pin, _, _, reopened, _, _) = closedWorld()
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

    func testTwoAppsReopenedWhileARestoreRunsBothEndInTheirOwnTabs() async throws {
        let (_, pin, _, _, reopened, _, _) = closedWorld()
        let otherPin = Workspace.get(byName: "other-pin")
        let otherApp = TestApp(pid: 88, bundleId: "com.example.second")
        let secondWindow = TestWindow.new(id: 12, parent: otherPin.rootTilingContainer, app: otherApp)
        secondWindow.unbindFromParent()
        let secondURL = URL(fileURLWithPath: "/Applications/Second.app")
        reopenRunningApplication = { [appURL] url in url == appURL ? TestApp.shared.pid : 88 }
        var outcomes: [String: [NewWindowRequestOutcome]] = [:]
        beginFrozenRestore()
        clickPin(pin) { outcomes["first", default: []].append($0) }
        startReopenRequest(NewWindowRequestTarget(bundleId: "com.example.second", appName: "Second", bundleURL: secondURL), pid: 88,
            appURL: secondURL, targetWorkspace: otherPin, focusGeneration: focusChangeGeneration, preexistingWindowIds: { [] },
            completion: { outcomes["second", default: []].append($0) })
        await letTasksRun()
        try await appShows(reopened)
        let tab = try XCTUnwrap(registry.claim(windowId: 12, pid: 88, bundleId: "com.example.second", firstSeenUptime: clock))
        let binding = newWindowIntentBinding(targetWorkspace: tab)
        secondWindow.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        _ = try await restoreOrDetectNewWindow(secondWindow, isRegularWindow: true)
        XCTAssertEqual(outcomes, [:], "Both wait")

        endFrozenRestore()
        XCTAssertTrue(reopened.nodeWorkspace === pin)
        XCTAssertTrue(secondWindow.nodeWorkspace === otherPin)
        XCTAssertEqual(outcomes["first"], [.placed(windowId: 2)])
        XCTAssertEqual(outcomes["second"], [.placed(windowId: 12)])
    }
}
