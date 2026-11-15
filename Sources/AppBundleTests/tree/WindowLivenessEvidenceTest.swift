@testable import AppBundle
import AppKit
import XCTest

/// A registered window is let go only on positive evidence that it closed; failing to observe it is never evidence
/// (Carbon's review, 2026-11-14). `windowLivenessVerdict`'s table row by row, then how a refresh gathers that evidence:
/// once per app, a busy app asked once, the window server asked before and after the app's list, nothing committed on a
/// cancelled refresh. Synthetic throughout.
@MainActor
final class WindowLivenessEvidenceTest: XCTestCase {
    private let answers: [RegisteredAxWindowAnswer] = [.alive, .busy, .gone]
    private let apps: [AppListingEvidence] = [.unread, .omits, .names]
    private let servers: [WindowServerEvidence] = [.unusable, .absent, .listed(onShownSpace: false), .listed(onShownSpace: true)]

    // MARK: The table

    /// The one rule over every combination: dropped exactly when the window server no longer lists it (a busy app's
    /// window: twice in a row; one AX resolves: whatever its app lists), or when it's on screen and its app, read in
    /// full, leaves it out.
    func testOnlyPositiveEvidenceDropsAWindow() {
        for ax in answers {
            for app in apps {
                for server in servers {
                    for absences in 0 ... 2 {
                        let closed = ax == .alive ? server == .absent : app != .names && (
                            ax == .gone && server == .absent
                                || ax == .busy && server == .absent && absences + 1 >= windowServerAbsencesToLetGo
                                || ax == .gone && app == .omits && server == .listed(onShownSpace: true))
                        let verdict = windowLivenessVerdict(ax: ax, app: app, windowServer: server, absences: absences).verdict
                        XCTAssertEqual(verdict == .drop, closed, "\(ax), \(app), \(server), \(absences) absences: \(verdict)")
                    }
                }
            }
        }
    }

    /// Row 1a: AX resolves it, and the window server has it (or there's no list to go by): kept, the busy count starting
    /// over.
    func testRow1aAWindowAxResolvesIsKeptWhileTheWindowServerHasIt() {
        for app in apps {
            for server: WindowServerEvidence in [.unusable, .listed(onShownSpace: false), .listed(onShownSpace: true)] {
                assertVerdict(.alive, app, server, absences: 1, is: .keep, absences: 0)
            }
        }
    }

    /// Row 1b: AX resolves it, but the window server no longer lists it: closed, whatever element AX hands out for it.
    func testRow1bAWindowTheWindowServerNoLongerHasIsDroppedWhateverAxAnswers() {
        for app in apps {
            assertVerdict(.alive, app, .absent, absences: 1, is: .drop, absences: 0, asksTheWindowServer: true)
        }
    }

    /// Row 2a: a busy app that lists it. Kept as it is: its element isn't shown to be stale.
    func testRow2aABusyWindowItsAppListsIsKept() {
        assertVerdict(.busy, .names, .absent, absences: 1, is: .keep, absences: 0, asksTheWindowServer: false)
    }

    /// Row 2b: an element that answers for nothing, and its app lists the window: rebound.
    func testRow2bAGoneElementWhoseAppListsTheWindowIsRebound() {
        assertVerdict(.gone, .names, .absent, absences: 1, is: .rebind, absences: 0, asksTheWindowServer: false)
    }

    /// Row 3: no window list to go by. A busy window is kept as it is, a gone one unbound; the busy count stays.
    func testRow3NoWindowListKeepsAWindowAndItsCount() {
        for app: AppListingEvidence in [.unread, .omits] {
            assertVerdict(.busy, app, .unusable, absences: 1, is: .keep, absences: 1)
            assertVerdict(.gone, app, .unusable, absences: 1, is: .keepUnbound, absences: 1)
        }
    }

    /// Row 4: the window server no longer lists it: closed.
    func testRow4AGoneWindowTheWindowServerNoLongerListsIsDropped() {
        for app: AppListingEvidence in [.unread, .omits] {
            assertVerdict(.gone, app, .absent, absences: 0, is: .drop, absences: 0)
        }
    }

    /// Row 5: a busy app's window the window server no longer lists: dropped at the second absence in a row.
    func testRow5ABusyWindowIsDroppedAtItsSecondAbsenceInARow() {
        for app: AppListingEvidence in [.unread, .omits] {
            assertVerdict(.busy, app, .absent, absences: 0, is: .keep, absences: 1)
            assertVerdict(.busy, app, .absent, absences: 1, is: .drop, absences: 2)
        }
    }

    /// Row 6: a busy app's window the window server lists, on screen or not: kept, and the count starts over.
    func testRow6ABusyWindowTheWindowServerListsIsKept() {
        for app: AppListingEvidence in [.unread, .omits] {
            for shown in [false, true] {
                assertVerdict(.busy, app, .listed(onShownSpace: shown), absences: 1, is: .keep, absences: 0)
            }
        }
    }

    /// Row 7: on screen, and its app's list, read in full, leaves it out: closed.
    func testRow7AGoneWindowOnScreenThatItsAppLeavesOutIsDropped() {
        assertVerdict(.gone, .omits, .listed(onShownSpace: true), absences: 0, is: .drop, absences: 0)
    }

    /// Row 8: on screen, and its app's list couldn't be read: kept, unbound.
    func testRow8AGoneWindowOnScreenWhoseAppsListWasntReadIsKeptUnbound() {
        assertVerdict(.gone, .unread, .listed(onShownSpace: true), absences: 0, is: .keepUnbound, absences: 0)
    }

    /// Row 9: off screen, or not known to be on screen (another Space, full screen, minimized, ordered out), where the
    /// app's list doesn't look: kept, unbound.
    func testRow9AGoneWindowOffScreenIsKeptUnbound() {
        for app: AppListingEvidence in [.unread, .omits] {
            assertVerdict(.gone, app, .listed(onShownSpace: false), absences: 0, is: .keepUnbound, absences: 0)
        }
    }

    private func assertVerdict(_ ax: RegisteredAxWindowAnswer, _ app: AppListingEvidence, _ server: WindowServerEvidence,
                               absences: Int, is verdict: WindowLivenessVerdict, absences committed: Int,
                               asksTheWindowServer: Bool? = nil, file: StaticString = #filePath, line: UInt = #line) {
        var asked = false
        func windowServer() -> WindowServerEvidence {
            asked = true
            return server
        }
        let decided = windowLivenessVerdict(ax: ax, app: app, windowServer: windowServer(), absences: absences)
        XCTAssertEqual(decided.verdict, verdict, "\(ax), \(app), \(server)", file: file, line: line)
        XCTAssertEqual(decided.absences, committed, "\(ax), \(app), \(server): absences", file: file, line: line)
        if let asksTheWindowServer {
            XCTAssertEqual(asked, asksTheWindowServer, "\(ax), \(app): window server asked", file: file, line: line)
        }
    }

    // MARK: Gathering it

    /// A busy app (Carbon's finding 5): once one window's query times out, no other is asked and its AXWindows isn't
    /// read, so a refresh costs one timeout, not one per window, and stays inside the app's deadline. Its windows go by
    /// the window server: closed ones go at the second refresh.
    func testABusyAppIsAskedOnceAndItsWindowListIsntRead() throws {
        let windows: [UInt32: FakeLivenessWindow] = [
            1: .init((nil, .cannotComplete)), 2: .init((nil, .cannotComplete)), 3: .init((nil, .cannotComplete)),
        ]
        var listRead = false
        func refresh(_ registered: [UInt32: FakeLivenessWindow]) throws -> [UInt32: FakeLivenessWindow] {
            let refreshed = try refreshRegisteredAxWindows(registered, frontmostAppBundleId: nil,
                windowServer: livenessWindowServer(listed: [9]),
                listed: { () -> [(UInt32, FakeLivenessWindow)]? in
                    listRead = true
                    return []
                },
                rebind: { _, fresh in fresh }, register: { _, _, _ in }, RunLoopJob())
            refreshed.commit()
            return refreshed.alive
        }
        let first = try refresh(windows)
        XCTAssertEqual(windows.values.map(\.probes).reduce(0, +), 1, "One query timed out: no other asked")
        XCTAssertFalse(listRead, "A busy app's AXWindows isn't read")
        XCTAssertEqual(Set(first.keys), [1, 2, 3], "Missing once")
        XCTAssertEqual(try refresh(first).count, 0, "Missing twice in a row")
        XCTAssertEqual(windows.values.map(\.probes).reduce(0, +), 2)
    }

    /// The window server is asked whether a window is on screen before its app's AXWindows is read and again after:
    /// a Space switch or a lock in between doesn't make the list look like it left the window out.
    func testAGoneWindowIsDroppedForLeavingTheListOnlyIfOnScreenBeforeAndAfterTheListWasRead() throws {
        let cases: [(before: [UInt32: Bool]?, after: [UInt32: Bool]?, dropped: Bool, label: String)] = [
            ([7: true, 1: true], [7: true, 1: true], true, "On screen throughout"),
            ([7: true, 1: true], [7: false, 1: true], false, "Its Space switched away while the list was read"),
            ([7: false, 1: true], [7: true, 1: true], false, "Its Space came into view while the list was read"),
            ([7: true, 1: true], nil, false, "The screen locked while the list was read"),
            ([7: true, 1: true], [1: true], false, "Gone from the window server only after"),
        ]
        for (before, after, dropped, label) in cases {
            let reads = WindowServerReads([before, after])
            let windowServer = WindowServerWindowList(readWindows: { reads.next() })
            var readsBeforeTheList = -1
            let refreshed = try refreshRegisteredAxWindows([7: FakeLivenessWindow((nil, .illegalArgument))],
                frontmostAppBundleId: nil, windowServer: windowServer,
                listed: { () -> [(UInt32, FakeLivenessWindow)]? in
                    readsBeforeTheList = reads.count
                    return [(1, FakeLivenessWindow((1, .success)))]
                },
                rebind: { _, fresh in fresh }, register: { _, _, _ in }, RunLoopJob())
            XCTAssertEqual(readsBeforeTheList, 1, "\(label): the refresh's list taken before the app's")
            XCTAssertEqual(refreshed.dead.keys.contains(7), dropped, label)
            XCTAssertEqual(refreshed.alive[7] == nil, dropped, label)
            if !dropped { XCTAssertEqual(refreshed.unbound, [7], label) }
        }
    }

    /// Asked again only when it can tell: a window off screen in the refresh's list, or one its app's list couldn't
    /// cover, isn't.
    func testTheWindowServerIsAskedAgainOnlyForAWindowThatMayHaveClosedOnScreen() throws {
        for (shown, appLists): (Bool, [(UInt32, FakeLivenessWindow)]?) in [(false, []), (true, nil)] {
            let reads = WindowServerReads([[7: shown, 1: true]])
            _ = try refreshRegisteredAxWindows([7: FakeLivenessWindow((nil, .illegalArgument))], frontmostAppBundleId: nil,
                windowServer: WindowServerWindowList(readWindows: { reads.next() }), listed: { appLists },
                rebind: { _, fresh in fresh }, register: { _, _, _ in }, RunLoopJob())
            XCTAssertEqual(reads.count, 1, "on screen \(shown), app list read \(appLists != nil)")
        }
    }

    /// Cancelled once every window is decided (the app's deadline), the refresh throws: no absence is counted (Carbon's
    /// finding 5). The next completed miss is the first.
    func testACancelledRefreshCommitsNothing() {
        let job = RunLoopJob()
        let window = FakeLivenessWindow((nil, .cannotComplete))
        let windowServer = WindowServerWindowList(readWindows: {
            job.cancel()
            return [1: true]
        })
        XCTAssertThrowsError(try refreshRegisteredAxWindows([7: window], frontmostAppBundleId: nil, windowServer: windowServer,
            listed: { nil as [(UInt32, FakeLivenessWindow)]? }, rebind: { _, fresh in fresh }, register: { _, _, _ in }, job))
        XCTAssertEqual(window.windowServerAbsences, 0)
        var registry: [UInt32: FakeLivenessWindow] = [7: window]
        XCTAssertEqual(refreshWindowLiveness(&registry, listed: [1]).kept, [7], "One completed miss")
    }

    /// Cancelled while a new window is registered, after every registered one is decided: throws, so the window it
    /// found closed isn't let go on a cancelled refresh.
    func testARefreshCancelledWhileRegisteringThrows() {
        let job = RunLoopJob()
        let window = FakeLivenessWindow((nil, .noValue))
        XCTAssertThrowsError(try refreshRegisteredAxWindows([7: window], frontmostAppBundleId: nil,
            windowServer: livenessWindowServer(listed: [1]),
            listed: { [(UInt32(1), FakeLivenessWindow((1, .success)))] }, rebind: { _, fresh in fresh },
            register: { _, _, _ in job.cancel() }, job))
    }

    /// Every fresh element its app lists with its id is refused (sheets, proxies, failed subscriptions): kept, unbound,
    /// not dead.
    func testAWindowWhoseFreshElementsAreAllRefusedIsKeptUnbound() throws {
        let stale = FakeLivenessWindow((nil, .illegalArgument))
        let refreshed = try refreshRegisteredAxWindows([3269: stale], frontmostAppBundleId: nil,
            windowServer: livenessWindowServer(listed: [3269], shown: [3269]),
            listed: { () -> [(UInt32, FakeLivenessWindow)]? in
                [(3269, FakeLivenessWindow((3269, .success))), (3269, FakeLivenessWindow((3269, .success)))]
            },
            rebind: { _, _ in nil }, register: { alive, id, element in alive[id] = element }, RunLoopJob())
        XCTAssertTrue(refreshed.alive[3269] === stale)
        XCTAssertEqual(refreshed.dead.count, 0)
        XCTAssertEqual(refreshed.unbound, [3269])
    }

    // MARK: What it goes by

    /// The window server's list, with whether each window is on screen; nothing off the console or with the screen locked.
    func testTheWindowServerListSaysWhichWindowsAreOnScreen() {
        let windows: [[String: Any]] = [
            [kCGWindowNumber as String: UInt32(5), kCGWindowIsOnscreen as String: true],
            [kCGWindowNumber as String: UInt32(6), kCGWindowIsOnscreen as String: false],
            [kCGWindowNumber as String: UInt32(7)],
        ]
        let console: [String: Any] = [kCGSessionOnConsoleKey as String: true]
        XCTAssertEqual(windowServerWindowsForLiveness(session: console, windows: windows), [5: true, 6: false, 7: false])
        XCTAssertNil(windowServerWindowsForLiveness(session: [kCGSessionOnConsoleKey as String: false], windows: windows))
        XCTAssertNil(windowServerWindowsForLiveness(session: [kCGSessionOnConsoleKey as String: true, "CGSSessionScreenIsLocked": true],
            windows: windows))
        let listed = windowServerWindowsForLiveness(session: console, windows: windows)
        let list = WindowServerWindowList(readWindows: { listed })
        XCTAssertEqual(list.evidence(for: 5), .listed(onShownSpace: true))
        XCTAssertEqual(list.evidence(for: 6), .listed(onShownSpace: false))
        XCTAssertEqual(list.evidence(for: 8), .absent)
        XCTAssertEqual(WindowServerWindowList(readWindows: { [:] }).evidence(for: 5), .unusable, "An empty list says nothing")
        XCTAssertEqual(WindowServerWindowList(read: { [5] }).evidence(for: 5), .listed(onShownSpace: false),
            "Ids alone: not known to be on screen")
    }

    /// An app's AXWindows read in full: not read when an element's window id doesn't come in time (Carbon's finding 2),
    /// or when the answer isn't a list; elements that aren't windows are left out.
    func testAnAppsWindowListIsReadInFullOrNotAtAll() {
        let elements = (0 ..< 3).map { _ in AXUIElementCreateApplication(getpid()) }
        let raw = elements as NSArray
        func answering(_ answers: [(CGWindowID?, AXError)]) -> (AXUIElement) -> (windowId: CGWindowID?, error: AXError) {
            { element in answers[elements.firstIndex { $0 === element }!] }
        }
        XCTAssertEqual(windowsInFull(raw, windowId: answering([(4, .success), (nil, .success), (6, .success)]))?.map(\.windowId),
            [4, 6], "A zero id (not a window) is left out")
        XCTAssertNil(windowsInFull(raw, windowId: answering([(4, .success), (nil, .cannotComplete), (6, .success)])),
            "One element timed out: the list isn't read in full")
        XCTAssertNil(windowsInFull("windows" as NSString, windowId: answering([])))
        XCTAssertEqual(windowsInFull(NSArray(), windowId: answering([]))?.count, 0, "Read, and no windows")
    }
}

/// Window server lists that change from one read to the next; the last one repeats.
final class WindowServerReads: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [[UInt32: Bool]?]
    private var reads = 0
    init(_ lists: [[UInt32: Bool]?]) { self.lists = lists }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func next() -> [UInt32: Bool]? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return lists.count > 1 ? lists.removeFirst() : lists.first ?? nil
    }
}
