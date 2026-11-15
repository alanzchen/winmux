@testable import AppBundle
import AppKit
import XCTest

/// The survey of other window managers (2026-11-14), checked against the positive-evidence rule: a refresh's decision
/// takes effect only with the refresh still current; a closed window's id isn't taken again from an element handed out
/// later; no verdict on the window server while the session WinMux tracks is suspended, or on an app's list while a Space
/// switch is under way or the app is hidden; a window kept while the window server still lists it is looked at again,
/// for a while. Synthetic throughout.
@MainActor
final class WindowLivenessCommitTest: XCTestCase {
    private func decide(_ registered: [UInt32: FakeLivenessWindow], windowServer: WindowServerWindowList,
                        appLists: [(UInt32, FakeLivenessWindow)]? = [], appHidden: Bool = false) throws
        -> RegisteredWindowsRefresh<FakeLivenessWindow>
    {
        try refreshRegisteredAxWindows(registered, frontmostAppBundleId: nil, windowServer: windowServer, listed: { appLists },
            rebind: { _, fresh in fresh }, register: { alive, id, element in alive[id] = element }, appHidden: appHidden, RunLoopJob())
    }

    // MARK: (F) Committed only with the refresh still current

    /// What a refresh counted takes effect when the main actor commits that refresh, and not for another (one cancelled,
    /// superseded or past its app's deadline never is), nor twice.
    func testADecisionTakesEffectOnlyWhenItsRefreshCommits() throws {
        let window = FakeLivenessWindow((nil, .cannotComplete))
        let refresh = livenessWindowServer(listed: [1])
        var ledger = WindowLivenessLedger<FakeLivenessWindow>()
        ledger.hold(try decide([7: window], windowServer: refresh), of: refresh)
        XCTAssertEqual(window.windowServerAbsences, 0, "Decided, not committed")
        XCTAssertNil(ledger.commit(livenessWindowServer(listed: [1])), "Another refresh commits nothing")
        XCTAssertEqual(window.windowServerAbsences, 0)
        XCTAssertNotNil(ledger.commit(refresh))
        XCTAssertEqual(window.windowServerAbsences, 1)
        XCTAssertNil(ledger.commit(refresh), "Not twice")
    }

    /// A newer refresh's decision replaces the one held: the older refresh can't commit any more.
    func testANewerRefreshsDecisionReplacesTheOneHeld() throws {
        let window = FakeLivenessWindow((nil, .noValue))
        let (older, newer) = (livenessWindowServer(listed: [1]), livenessWindowServer(listed: [1, 7]))
        var ledger = WindowLivenessLedger<FakeLivenessWindow>()
        ledger.hold(try decide([7: window], windowServer: older), of: older)
        ledger.hold(try decide([7: window], windowServer: newer), of: newer)
        XCTAssertNil(ledger.commit(older))
        XCTAssertEqual(ledger.commit(newer)?.dead.count, 0, "Kept: the newer refresh's list has it")
    }

    /// Committed onto the registry as it is then: only windows the refresh saw change. A window registered since (on
    /// focus) stays, and one unregistered since (closed from WinMux) stays out.
    func testACommitChangesOnlyTheWindowsItsRefreshSaw() throws {
        let (kept, stale, closed, unregistered) = (FakeLivenessWindow((1, .success)), FakeLivenessWindow((nil, .illegalArgument)),
                                                   FakeLivenessWindow((nil, .noValue)), FakeLivenessWindow((4, .success)))
        let (fresh, new, onFocus, newOnFocus) = (FakeLivenessWindow((2, .success)), FakeLivenessWindow((5, .success)),
                                                 FakeLivenessWindow((6, .success)), FakeLivenessWindow((5, .success)))
        let decided = try decide([1: kept, 2: stale, 3: closed, 4: unregistered], windowServer: livenessWindowServer(listed: [1, 2, 4, 5]),
            appLists: [(1, kept), (2, fresh), (4, unregistered), (5, new)])
        XCTAssertEqual(decided.dead.count, 1)

        let registry = decided.applied(to: [1: kept, 2: stale, 3: closed, 6: onFocus])
        XCTAssertTrue(registry[1] === kept)
        XCTAssertTrue(registry[2] === fresh, "Rebound")
        XCTAssertNil(registry[3], "Closed")
        XCTAssertNil(registry[4], "Unregistered since: stays out")
        XCTAssertTrue(registry[5] === new, "Registered by the refresh")
        XCTAssertTrue(registry[6] === onFocus, "Registered since: stays")
        XCTAssertTrue(decided.applied(to: [1: kept, 2: stale, 3: closed, 4: unregistered, 5: newOnFocus])[5] === newOnFocus,
            "Registered since under the same id: the one there stays")
    }

    // MARK: A window let go comes back as a new window (coordinator's decision, 2026-11-15)

    /// Let go while the window server still shows it on screen (row 7): the drop starts a series of looks again. Listed
    /// by its app again, under an element for its id, it's registered again at once, as a new window: no live window is
    /// shut out, however soon it's shown again.
    func testAWindowLetGoIsRegisteredAgainAsNewOnceItsAppListsIt() throws {
        let onScreen = livenessWindowServer(listed: [1, 9], shown: [1, 9])
        let closing = try decide([1: FakeLivenessWindow((1, .success)), 9: FakeLivenessWindow((nil, .illegalArgument))],
            windowServer: onScreen, appLists: [(1, .init((1, .success)))])
        XCTAssertEqual(Set(closing.dead.keys), [9])
        XCTAssertEqual(closing.awaitsWindowServer, [9])
        XCTAssertTrue(closing.startsRecheckSeries, "Let go while listed: looks again start")
        let reopened = FakeLivenessWindow((9, .success))
        let again = try decide([1: FakeLivenessWindow((1, .success))], windowServer: onScreen,
            appLists: [(1, .init((1, .success))), (9, reopened)])
        XCTAssertTrue(again.alive[9] === reopened, "Listed again: registered again, at once")
        XCTAssertFalse(again.startsRecheckSeries)
    }

    /// An element for a window that did close (Slack hands out a live-looking one while the window server lags the
    /// close) brings back a ghost, short-lived: once the window server no longer lists the window, row 1b lets it go,
    /// whatever its element answers. With no window list to go by, it's kept until there's one.
    func testAGhostAnElementBringsBackGoesOnceTheWindowServerLetsItGo() throws {
        let lagging = livenessWindowServer(listed: [1, 9], shown: [1, 9])
        let corpse = FakeLivenessWindow((9, .success))
        let ghost = try decide([1: FakeLivenessWindow((1, .success))], windowServer: lagging, appLists: [(1, .init((1, .success))), (9, corpse)])
        XCTAssertTrue(ghost.alive[9] === corpse, "A short-lived ghost")
        let noList = try decide(ghost.alive, windowServer: livenessWindowServer(listed: nil))
        XCTAssertTrue(noList.alive[9] === corpse, "No window list: kept")
        let dropped = try decide(ghost.alive, windowServer: livenessWindowServer(listed: [1], shown: [1]))
        XCTAssertEqual(Set(dropped.dead.keys), [9], "The window server let it go: so does WinMux, live-looking element or not")
        XCTAssertNotNil(dropped.alive[1])
    }

    // MARK: (E) The session WinMux tracks

    /// While the session is suspended (`SavedWorkspaceRuntime.suspensions`: locked, switched away, asleep), the window
    /// server isn't read at all: no window is let go on it, and no busy absence is counted.
    func testWhileTheSessionIsSuspendedTheWindowServerSaysNothing() throws {
        let reads = WindowServerReads([[1: true]])
        let suspended = WindowServerWindowList(sessionSuspended: true, readWindows: { reads.next() })
        XCTAssertEqual(suspended.evidence(for: 7), .unusable)
        XCTAssertNil(suspended.lists(7))
        XCTAssertNil(suspended.readAgain())
        let (gone, busy) = (FakeLivenessWindow((nil, .invalidUIElement)), FakeLivenessWindow((nil, .cannotComplete)))
        for window in [gone, busy] {
            let decided = try decide([7: window], windowServer: suspended)
            decided.commit()
            XCTAssertNotNil(decided.alive[7])
            XCTAssertEqual(window.windowServerAbsences, 0)
        }
        XCTAssertEqual(reads.count, 0)
    }

    // MARK: (B) Covered by the app's list

    /// A Space switch under way, or the app hidden: a window on screen isn't taken as covered by its app's list, so
    /// leaving it out isn't evidence. Kept, unbound, and looked at again.
    func testDuringASpaceSwitchOrWithItsAppHiddenAnOmittedWindowIsKept() throws {
        let switching = WindowServerWindowList(spaceSwitching: true, readWindows: { [7: true, 1: true] })
        XCTAssertEqual(switching.evidence(for: 7), .listed(onShownSpace: false))
        let duringSwitch = try decide([7: FakeLivenessWindow((nil, .illegalArgument))], windowServer: switching,
            appLists: [(1, FakeLivenessWindow((1, .success)))])
        XCTAssertEqual(duringSwitch.unbound, [7])
        XCTAssertEqual(duringSwitch.awaitsWindowServer, [7])

        let hidden = try decide([7: FakeLivenessWindow((nil, .illegalArgument))], windowServer: livenessWindowServer(listed: [7, 1], shown: [7]),
            appLists: [(1, FakeLivenessWindow((1, .success)))], appHidden: true)
        XCTAssertEqual(hidden.unbound, [7], "Its app hidden")
        let shown = try decide([7: FakeLivenessWindow((nil, .illegalArgument))], windowServer: livenessWindowServer(listed: [7, 1], shown: [7]),
            appLists: [(1, FakeLivenessWindow((1, .success)))])
        XCTAssertEqual(shown.dead.count, 1, "The same, its app shown and no switch: closed")
    }

    /// A Space switch counts as under way for half a second after macOS reports it.
    func testASpaceSwitchIsUnderWayForHalfASecond() {
        let saved = lastActiveSpaceChangeUptime
        defer { lastActiveSpaceChangeUptime = saved }
        lastActiveSpaceChangeUptime = nil
        XCTAssertFalse(isActiveSpaceSwitching(now: 100))
        lastActiveSpaceChangeUptime = 100
        XCTAssertTrue(isActiveSpaceSwitching(now: 100.2))
        XCTAssertFalse(isActiveSpaceSwitching(now: 100.6))
    }

    // MARK: Looked at again

    /// Waiting on the window server: a window kept, unbound, while it lists it (off screen, or on screen with its app's
    /// list not read). Not a busy window, nor one with no list to go by, nor one let go.
    func testOnlyAWindowKeptWhileTheWindowServerListsItWaitsOnIt() throws {
        let gone = try decide([7: FakeLivenessWindow((nil, .illegalArgument)), 9: FakeLivenessWindow((nil, .noValue))],
            windowServer: livenessWindowServer(listed: [7, 1]), appLists: nil)
        XCTAssertEqual(gone.awaitsWindowServer, [7])
        XCTAssertEqual(gone.dead.count, 1)
        let onScreen = try decide([7: FakeLivenessWindow((nil, .illegalArgument))],
            windowServer: livenessWindowServer(listed: [7, 1], shown: [7]), appLists: nil)
        XCTAssertEqual(onScreen.awaitsWindowServer, [7], "On screen, its app's list not read")
        let busy = try decide([8: FakeLivenessWindow((nil, .cannotComplete))], windowServer: livenessWindowServer(listed: [8, 1]))
        XCTAssertEqual(busy.awaitsWindowServer, [])
        let noList = try decide([7: FakeLivenessWindow((nil, .illegalArgument))], windowServer: livenessWindowServer(listed: nil))
        XCTAssertEqual(noList.awaitsWindowServer, [])
    }

    /// Looked at again after half a second, then 1, 2, 4 and 8 seconds, then no more (a window hidden on close stays
    /// listed). A refresh between looks doesn't spend one. Another window waiting starts the series over; one leaving
    /// doesn't.
    func testAWindowWaitingOnTheWindowServerIsLookedAtAgainForAWhile() {
        var recheck = WindowLivenessRecheck()
        XCTAssertNil(recheck.next(awaiting: [], at: 0))
        XCTAssertEqual(recheck.next(awaiting: [7], at: 0), .milliseconds(500))
        XCTAssertNil(recheck.next(awaiting: [7], at: 0.1), "A refresh before the look is due doesn't spend one")
        XCTAssertEqual(recheck.next(awaiting: [7], at: 0.5), .seconds(1))
        XCTAssertEqual(recheck.next(awaiting: [7], at: 1.5), .seconds(2))
        XCTAssertEqual(recheck.next(awaiting: [7], at: 3.5), .seconds(4))
        XCTAssertEqual(recheck.next(awaiting: [7], at: 7.5), .seconds(8))
        XCTAssertNil(recheck.next(awaiting: [7], at: 15.5), "Done")
        XCTAssertEqual(recheck.next(awaiting: [7, 8], at: 16), .milliseconds(500), "Another window: the series starts over")
        XCTAssertEqual(recheck.next(awaiting: [8], at: 16.5), .seconds(1), "One left: the series goes on")
        XCTAssertNil(recheck.next(awaiting: [], at: 17.5))
        XCTAssertEqual(recheck.next(awaiting: [8], at: 18), .milliseconds(500), "Waiting again after none: a new series")
    }

    /// A window let go while the window server still listed it starts a series, even one that ran out for the same
    /// window, and runs it to its end with nothing left waiting: a ghost an element brought back is caught soon.
    func testAWindowLetGoWhileListedStartsASeriesRunToItsEnd() {
        var recheck = WindowLivenessRecheck()
        for (time, expected): (TimeInterval, Duration?) in [(0, .milliseconds(500)), (0.5, .seconds(1)), (1.5, .seconds(2)),
                                                            (3.5, .seconds(4)), (7.5, .seconds(8)), (15.5, nil)] {
            XCTAssertEqual(recheck.next(awaiting: [9], at: time), expected, "waiting, at \(time)")
        }
        XCTAssertEqual(recheck.next(awaiting: [9], startsSeries: true, at: 16), .milliseconds(500), "Let go: a new series")
        for (time, expected): (TimeInterval, Duration?) in [(16.5, .seconds(1)), (17.5, .seconds(2)), (19.5, .seconds(4)),
                                                            (23.5, .seconds(8)), (31.5, nil)] {
            XCTAssertEqual(recheck.next(awaiting: [], at: time), expected, "nothing waiting, at \(time)")
        }
    }
}
