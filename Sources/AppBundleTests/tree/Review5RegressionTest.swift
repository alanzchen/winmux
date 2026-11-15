@testable import AppBundle
import AppKit
import Common
import XCTest

/// Round-5 review artifacts only. No production edits, native apps, or personal windows.
/// The external harness links the exact a269fd0b source and original test support.
@MainActor
final class Review5RegressionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetFocusCacheForTests()
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = nil
    }

    override func tearDown() async throws {
        setBlockingRefreshOverridesForTests()
        resetFocusCacheForTests()
        TestApp.shared.focusedWindow = nil
        appForTests = nil
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private func decide(_ registered: [UInt32: FakeLivenessWindow], server: WindowServerWindowList,
                        listed: [(UInt32, FakeLivenessWindow)] = [],
                        ledger: WindowLivenessLedger<FakeLivenessWindow> = .init(),
                        now: TimeInterval = 1000) throws -> RegisteredWindowsRefresh<FakeLivenessWindow> {
        try refreshRegisteredAxWindows(registered, frontmostAppBundleId: nil, windowServer: server,
            listed: { listed }, rebind: { _, fresh in fresh },
            register: { alive, id, element in alive[id] = element },
            confirmedClosed: ledger.confirmedClosed, closedSeenOffScreen: ledger.mayReturn(now: now),
            closedLingering: ledger.closedLingering(now: now), RunLoopJob())
    }

    /// A retained off-Space stale window has used its old recheck series. A subsequent row-7
    /// close of the same ID must start a fresh series for its newly created tombstone.
    func testADropRestartsRechecksWhenTheSameIdAlreadyExhaustedItsSeries() throws {
        var recheck = WindowLivenessRecheck()
        var windows: [UInt32: FakeLivenessWindow] = [9: .init((nil, .illegalArgument))]
        for _ in 0..<6 {
            let kept = try decide(windows, server: livenessWindowServer(listed: [1, 9], shown: [1]))
            XCTAssertEqual(kept.awaitsWindowServer, [9])
            _ = recheck.next(awaiting: kept.awaitsWindowServer)
            windows = kept.alive
        }
        XCTAssertEqual(recheck.attempt, 5)

        // The same window now closes on screen, while WindowServer lags the close.
        let closed = try decide(windows, server: livenessWindowServer(listed: [1, 9], shown: [1, 9]))
        XCTAssertEqual(Set(closed.dead.keys), [9])
        XCTAssertEqual(closed.awaitsWindowServer, [9])
        XCTAssertFalse(closed.asksForConfirmation)
        XCTAssertNotNil(recheck.next(awaiting: closed.awaitsWindowServer),
            "A new row-7 drop must get its own rechecks, even if this ID was already awaiting before the drop")
    }

    /// scheduleWindowLivenessChecks calls next after EVERY committed barrier, not only after
    /// its timer fires. Four ordinary barrier events can spend the series in 0.4 seconds;
    /// all five scheduled callbacks then finish at 8.4 seconds, before 15-second admission.
    func testInterveningRefreshesCannotExhaustAllTimersBeforeTheReadmissionBound() throws {
        var ledger = WindowLivenessLedger<FakeLivenessWindow>()
        var recheck = WindowLivenessRecheck()
        var windows: [UInt32: FakeLivenessWindow] = [9: .init((nil, .illegalArgument))]
        let reopened = FakeLivenessWindow((9, .success))
        var pending: [TimeInterval] = []
        var lastRefresh: TimeInterval = 1000

        func tick(at now: TimeInterval, closing: Bool = false) throws {
            let server = livenessWindowServer(listed: [1, 9], shown: [1, 9])
            let result = try decide(windows, server: server,
                listed: closing ? [] : [(UInt32(9), reopened)], ledger: ledger, now: now)
            ledger.hold(result, of: server)
            _ = ledger.commit(server, now: now)
            windows = result.alive
            if let delay = recheck.next(awaiting: result.awaitsWindowServer) {
                let parts = delay.components
                pending.append(now + Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
            }
            lastRefresh = now
        }

        try tick(at: 1000, closing: true)
        // Close/reopen happened before the first 0.5-second observation.
        for offset in [0.1, 0.2, 0.3, 0.4] { try tick(at: 1000 + offset) }
        while !pending.isEmpty {
            pending.sort()
            let now = pending.removeFirst()
            try tick(at: now)
        }
        XCTAssertTrue(windows[9] === reopened,
            "All scheduled callbacks ended at \(lastRefresh - 1000)s; the live on-screen window remains tombstoned, with no refresh at the 15s bound")
    }

    /// The cache may already name W before W closes. A close refresh samples W first
    /// (e.g. the app's focused-window attribute lags orderOut), then sets W aside.
    /// There is no observation of another native ID before W is reopened. The second
    /// updateFocusCache(W) must adopt W even though its cached numeric ID is unchanged.
    func testRestoredNativeFocusIsAdoptedWhenTheCacheStillNamesThatSameWindow() async throws {
        let main = focus.workspace
        let other = TestWindow.new(id: 100, parent: main.rootTilingContainer,
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600))
        let returning = TestWindow.new(id: 200, parent: main.rootTilingContainer,
            rect: Rect(topLeftX: 800, topLeftY: 0, width: 800, height: 600))
        _ = returning.focusWindow()
        TestApp.shared.focusedWindow = returning
        try await runHeavyCompleteRefreshSession(.ax(kAXFocusedWindowChangedNotification as String), layoutWorkspaces: false)
        XCTAssertEqual(focus.windowOrNil?.windowId, 200)

        // Native focus is sampled before the full refresh learns that W is ordered out.
        setBlockingRefreshOverridesForTests(refresh: { noteWindowPresentability([100: true, 200: false]) })
        try await runHeavyCompleteRefreshSession(.globalObserverLeftMouseUp, layoutWorkspaces: false)
        XCTAssertTrue(returning.isSetAsideAsNotPresentable)
        XCTAssertEqual(focus.windowOrNil?.windowId, 100, "The remaining sibling becomes logical focus")

        let before = other.nativeFocusCount
        setBlockingRefreshOverridesForTests(refresh: { noteWindowPresentability([100: true, 200: true]) })
        // macOS reopens and focuses the same retained W. No reset of the focus cache.
        try await runHeavyCompleteRefreshSession(.ax(kAXFocusedWindowChangedNotification as String))
        XCTAssertFalse(returning.isSetAsideAsNotPresentable)
        XCTAssertEqual(focus.windowOrNil?.windowId, 200, "Restoring the natively focused window must adopt it even when the cached ID matches")
        XCTAssertEqual(other.nativeFocusCount, before, "Must not steal native focus back to the sibling")
    }

    /// Same cached-ID case with the last window of a separate tab. Setting it aside
    /// hands the display to main; rebinding into chat does not itself focus chat.
    func testRestoredNativeFocusInAnotherTabIsAdoptedWhenItsIdIsAlreadyCached() async throws {
        let main = focus.workspace
        let other = TestWindow.new(id: 100, parent: main.rootTilingContainer,
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600))
        let chat = Workspace.get(byName: "chat")
        let returning = TestWindow.new(id: 200, parent: chat.rootTilingContainer,
            rect: Rect(topLeftX: 100, topLeftY: 100, width: 800, height: 600))
        _ = returning.focusWindow()
        TestApp.shared.focusedWindow = returning
        try await runHeavyCompleteRefreshSession(.ax(kAXFocusedWindowChangedNotification as String), layoutWorkspaces: false)
        XCTAssertEqual(focus.windowOrNil?.windowId, 200)
        XCTAssertTrue(chat.isVisible)

        setBlockingRefreshOverridesForTests(refresh: { noteWindowPresentability([100: true, 200: false]) })
        try await runHeavyCompleteRefreshSession(.globalObserverLeftMouseUp, layoutWorkspaces: false)
        XCTAssertTrue(returning.isSetAsideAsNotPresentable)
        XCTAssertEqual(focus.windowOrNil?.windowId, 100, "C4 hands the empty chat tab's display to main")
        XCTAssertTrue(main.isVisible)

        let before = other.nativeFocusCount
        setBlockingRefreshOverridesForTests(refresh: { noteWindowPresentability([100: true, 200: true]) })
        try await runHeavyCompleteRefreshSession(.ax(kAXFocusedWindowChangedNotification as String))
        XCTAssertFalse(returning.isSetAsideAsNotPresentable)
        XCTAssertEqual(focus.windowOrNil?.windowId, 200, "Restoration must focus chat despite the unchanged cached native ID")
        XCTAssertEqual(other.nativeFocusCount, before, "Must not steal native focus back to main")
        XCTAssertTrue(chat.isVisible, "The natively focused restored tab must be on screen")
    }

    /// Characterization, not a separate blocker: the explicitly chosen timeout can admit
    /// a live-looking corpse, and row 1 then keeps it after WindowServer finally removes it.
    func testCharacterizeLongLivedCorpseReadmissionAndSubsequentRow1Keep() throws {
        var ledger = WindowLivenessLedger<FakeLivenessWindow>()
        let closingServer = livenessWindowServer(listed: [1, 9], shown: [1, 9])
        let close = try decide([9: .init((nil, .illegalArgument))], server: closingServer)
        ledger.hold(close, of: closingServer)
        _ = ledger.commit(closingServer, now: 1000)
        let corpse = FakeLivenessWindow((9, .success))
        let lingering = livenessWindowServer(listed: [1, 9], shown: [1, 9])
        let admitted = try decide([:], server: lingering, listed: [(UInt32(9), corpse)], ledger: ledger, now: 1015.5)
        ledger.hold(admitted, of: lingering)
        _ = ledger.commit(lingering, now: 1015.5)
        XCTAssertTrue(admitted.alive[9] === corpse)
        let afterDisappearance = try decide(admitted.alive,
            server: livenessWindowServer(listed: [1], shown: [1]), ledger: ledger, now: 1016)
        XCTAssertTrue(afterDisappearance.alive[9] === corpse)
    }
}

