@testable import AppBundle
import AppKit
import XCTest

/// The contracts that replace reviewers' superseded tombstone assertions (Astra REVIEW-6, Carbon REVIEW-6), as ordinary
/// tests, with the round-6 fixes: a registration is stamped against the window server's list; a window an app lists
/// that the window server doesn't have isn't admitted; a reopen's focus waits for macOS's focus read after a restore.
@MainActor
final class SupersededReviewerReplacementTest: XCTestCase {
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
        appForTests = nil
        TestApp.shared.focusedWindow = nil
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private func decide(_ windows: [UInt32: FakeLivenessWindow], server: WindowServerWindowList,
                        listed: [(UInt32, FakeLivenessWindow)]? = []) throws -> RegisteredWindowsRefresh<FakeLivenessWindow> {
        try refreshRegisteredAxWindows(windows, frontmostAppBundleId: nil, windowServer: server, listed: { listed },
            rebind: { _, fresh in fresh }, register: { alive, id, element in alive[id] = element }, RunLoopJob())
    }

    // MARK: Astra's replacements for her superseded tests

    /// For Astra R3 A1: a row-7 drop may be followed by a temporary admission while the window server lists the id;
    /// its current, usable absence removes the corpse.
    func testAnAdmittedCorpseGoesOnTheWindowServersCurrentAbsence() throws {
        let closed = try decide([9: .init((nil, .illegalArgument))], server: livenessWindowServer(listed: [1, 9], shown: [9]))
        XCTAssertNotNil(closed.dead[9])
        let corpse = FakeLivenessWindow((9, .success))
        let admitted = try decide([:], server: livenessWindowServer(listed: [1, 9], shown: [9]), listed: [(9, corpse)])
        XCTAssertTrue(admitted.alive[9] === corpse)
        let removed = try decide(admitted.alive, server: livenessWindowServer(listed: [1], shown: [1]))
        XCTAssertNotNil(removed.dead[9])
        XCTAssertNil(removed.alive[9])
    }

    /// For Astra R5 (a): with explicit times and `startsSeries`, a drop restarts the looks again, a refresh between them
    /// spends none, and a live window comes back at once, whatever the looks.
    func testADropRestartsLooksAgainWithoutDelayingAReturn() throws {
        var recheck = WindowLivenessRecheck()
        for time: TimeInterval in [0, 0.5, 1.5, 3.5, 7.5, 15.5] { _ = recheck.next(awaiting: [9], at: time) }
        let server = livenessWindowServer(listed: [1, 9], shown: [9])
        let dropped = try decide([9: .init((nil, .illegalArgument))], server: server)
        XCTAssertTrue(dropped.startsRecheckSeries)
        XCTAssertEqual(recheck.next(awaiting: dropped.awaitsWindowServer, startsSeries: dropped.startsRecheckSeries, at: 20),
            .milliseconds(500))
        XCTAssertNil(recheck.next(awaiting: [], at: 20.1), "A refresh between looks spends none")
        XCTAssertEqual(recheck.next(awaiting: [], at: 20.5), .seconds(1))
        let liveAgain = FakeLivenessWindow((9, .success))
        XCTAssertTrue(try decide([:], server: server, listed: [(9, liveAgain)]).alive[9] === liveAgain, "Back at once")
    }

    /// For Astra's R5 characterization, inverted: once the window server no longer lists it, a corpse goes, even while
    /// AX resolves it and its app lists it.
    func testALongLivedCorpseGoesWhileAxStillResolvesIt() throws {
        let corpse = FakeLivenessWindow((9, .success))
        let removed = try decide([9: corpse], server: livenessWindowServer(listed: [1], shown: [1]), listed: [(9, corpse)])
        XCTAssertNotNil(removed.dead[9])
        XCTAssertNil(removed.alive[9])
    }

    // MARK: Carbon's replacements (REVIEW-6, Option B), as our own

    /// For Carbon R3 C2: a drop while listed starts looks; a corpse admitted during the lag is short-lived, gone on the
    /// window server's drop, whether its app still lists it or not.
    func testACorpseAdmittedDuringTheLagGoesWithTheWindowServersDrop() throws {
        let live = FakeLivenessWindow((1, .success))
        let lag = livenessWindowServer(listed: [1, 9], shown: [1, 9])
        let closed = try decide([1: live, 9: .init((nil, .illegalArgument))], server: lag, listed: [(1, live)])
        XCTAssertEqual(Set(closed.dead.keys), [9])
        XCTAssertTrue(closed.startsRecheckSeries)
        XCTAssertEqual(closed.awaitsWindowServer, [9])
        let corpse = FakeLivenessWindow((9, .success))
        let ghost = try decide([1: live], server: livenessWindowServer(listed: [1, 9], shown: [1, 9]), listed: [(1, live), (9, corpse)])
        XCTAssertTrue(ghost.alive[9] === corpse, "At most a short-lived ghost")
        let appListings: [[(UInt32, FakeLivenessWindow)]] = [[(1, live), (9, corpse)], [(1, live)]]
        for appLists in appListings {
            let settled = try decide(ghost.alive, server: livenessWindowServer(listed: [1], shown: [1]), listed: appLists)
            XCTAssertEqual(Set(settled.dead.keys), [9])
            XCTAssertNil(settled.alive[9])
        }
    }

    /// For Carbon R4-1: a drop while listed asks for a follow-up, and the window reopened is re-admitted.
    func testADropWhileListedAsksForAFollowUpAndTheReopenedWindowIsReadmitted() throws {
        let live = FakeLivenessWindow((1, .success))
        let closing = try decide([1: live, 9: .init((nil, .illegalArgument))], server: livenessWindowServer(listed: [1, 9], shown: [1, 9]),
            listed: [(1, live)])
        XCTAssertEqual(Set(closing.dead.keys), [9])
        var recheck = WindowLivenessRecheck()
        XCTAssertTrue(closing.asksForConfirmation
            || recheck.next(awaiting: closing.awaitsWindowServer, startsSeries: closing.startsRecheckSeries) != nil)
        let reopened = FakeLivenessWindow((9, .success))
        let reopen = try decide([1: live], server: livenessWindowServer(listed: [1, 9], shown: [1, 9]), listed: [(1, live), (9, reopened)])
        XCTAssertTrue(reopen.alive[9] === reopened)
    }

    // MARK: Round 6

    /// R6-1: a window-server list taken before a window was registered says nothing of its absence, by any row: kept,
    /// not dropped (1b), nor counted or let go when gone (4) or busy (5). One taken after does.
    func testAListOlderThanAWindowsRegistrationSaysNothingOfItsAbsence() throws {
        for answer: (CGWindowID?, AXError) in [(9, .success), (nil, .illegalArgument), (nil, .cannotComplete)] {
            let older = livenessWindowServer(listed: [1], shown: [1])
            older.take()
            let window = FakeLivenessWindow(answer)
            window.windowServerAbsences = 1
            let result = try decide([9: window], server: older, listed: nil)
            XCTAssertNil(result.dead[9], "\(answer): registered after the list")
            XCTAssertTrue(result.alive[9] === window)
            let newer = try decide([9: window], server: livenessWindowServer(listed: [1], shown: [1]), listed: nil)
            XCTAssertNotNil(newer.dead[9], "\(answer): the list taken after its registration speaks for it")
        }
    }

    /// R6-2: an app's AXWindows names an id the window server doesn't have: not admitted, when a list read now confirms
    /// it (a corpse, on any look, the last one too). The refresh's list may predate a window just opened: a list read
    /// now that has it admits it at once; with no list read now to go by, it's admitted.
    func testAWindowTheWindowServerDoesntHaveIsntAdmitted() throws {
        let corpse = FakeLivenessWindow((9, .success))
        XCTAssertNil(try decide([:], server: livenessWindowServer(listed: [1], shown: [1]), listed: [(9, corpse)]).alive[9])
        let reads = WindowServerReads([[1: true], [1: true, 9: true]])
        let newborn = FakeLivenessWindow((9, .success))
        let opened = try decide([:], server: WindowServerWindowList(readWindows: { reads.next() }), listed: [(9, newborn)])
        XCTAssertTrue(opened.alive[9] === newborn, "Opened after the refresh's list: a list read now has it")
        let unreadable = WindowServerReads([[1: true], nil])
        let noList = try decide([:], server: WindowServerWindowList(readWindows: { unreadable.next() }), listed: [(9, newborn)])
        XCTAssertTrue(noList.alive[9] === newborn, "No list read now to go by: admitted")
    }

    /// R6-3, the other side: a reopen asked for a window set aside, and macOS's focus didn't move on during the refresh
    /// (the app shows it without activating, as an empty pin's reopen does): it takes focus after the read, as before.
    func testAReopenedWindowTakesFocusWhenMacOSFocusDidntMoveOn() async throws {
        let registry = NewWindowIntentRegistry.shared
        registry.resetForTests()
        defer { registry.resetForTests() }
        let target = focus.workspace
        let anchor = TestWindow.new(id: 100, parent: target.rootTilingContainer)
        let returning = TestWindow.new(id: 200, parent: Workspace.get(byName: "old").rootTilingContainer)
        _ = anchor.focusWindow()
        TestApp.shared.focusedWindow = anchor
        updateFocusCache(anchor)
        noteWindowPresentability([200: false])
        try await normalizeLayoutReason()
        XCTAssertTrue(returning.isSetAsideAsNotPresentable)
        XCTAssertNotNil(registry.register(bundleId: try XCTUnwrap(returning.app.rawAppBundleId), pid: returning.app.pid,
            targetWorkspace: target, preexistingWindowIds: [], focusGeneration: focusChangeGeneration, reopens: true))
        setBlockingRefreshOverridesForTests(refresh: { noteWindowPresentability([200: true]) })
        try await runRefreshSessionBlocking(.globalObserverLeftMouseUp) // The pin click's refresh
        XCTAssertTrue(returning.nodeWorkspace === target)
        XCTAssertEqual(returning.nativeFocusCount, 1, "Focused after the read, once")
        XCTAssertEqual(focus.windowOrNil?.windowId, 200)
    }

    /// R6-3, the third side: a reopen asked for a window set aside, and its app showed and focused it: macOS's focus,
    /// read after the restore, makes it the focus; it isn't focused again.
    func testAReopenedWindowMacOSFocusedIsntFocusedAgain() async throws {
        let registry = NewWindowIntentRegistry.shared
        registry.resetForTests()
        defer { registry.resetForTests() }
        let target = focus.workspace
        let anchor = TestWindow.new(id: 100, parent: target.rootTilingContainer)
        let returning = TestWindow.new(id: 200, parent: Workspace.get(byName: "old").rootTilingContainer)
        _ = anchor.focusWindow()
        TestApp.shared.focusedWindow = anchor
        updateFocusCache(anchor)
        noteWindowPresentability([200: false])
        try await normalizeLayoutReason()
        XCTAssertNotNil(registry.register(bundleId: try XCTUnwrap(returning.app.rawAppBundleId), pid: returning.app.pid,
            targetWorkspace: target, preexistingWindowIds: [], focusGeneration: focusChangeGeneration, reopens: true))
        TestApp.shared.focusedWindow = returning
        setBlockingRefreshOverridesForTests(refresh: { noteWindowPresentability([200: true]) })
        try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String))
        XCTAssertTrue(returning.nodeWorkspace === target)
        XCTAssertEqual(focus.windowOrNil?.windowId, 200)
        XCTAssertEqual(returning.nativeFocusCount, 0, "macOS focused it already")
        XCTAssertEqual(anchor.nativeFocusCount, 0)
    }

    /// R6-3: an empty pin clicked (its tab on screen, with no window), and its app showed and focused the window: macOS's
    /// focus, read after the restore, makes it the focus, and though the user is still where they asked from, it isn't
    /// focused again.
    func testAWindowReopenedFromAnEmptyTabThatMacOSFocusedIsntFocusedAgain() async throws {
        let registry = NewWindowIntentRegistry.shared
        registry.resetForTests()
        defer { registry.resetForTests() }
        let target = focus.workspace
        let returning = TestWindow.new(id: 200, parent: Workspace.get(byName: "old").rootTilingContainer)
        noteWindowPresentability([200: false])
        try await normalizeLayoutReason()
        XCTAssertNil(focus.windowOrNil)
        let intent = try XCTUnwrap(registry.register(bundleId: try XCTUnwrap(returning.app.rawAppBundleId),
            pid: returning.app.pid, targetWorkspace: target, preexistingWindowIds: [], focusGeneration: focusChangeGeneration,
            reopens: true))
        registry.recordFocusWhenSent(forIntent: intent.id, .init(generation: focusChangeGeneration, workspace: target, window: nil))
        TestApp.shared.focusedWindow = returning
        setBlockingRefreshOverridesForTests(refresh: { noteWindowPresentability([200: true]) })
        try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String))
        XCTAssertTrue(returning.nodeWorkspace === target)
        XCTAssertEqual(focus.windowOrNil?.windowId, 200)
        XCTAssertEqual(returning.nativeFocusCount, 0, "macOS focused it already")
    }

    /// R6-3: macOS's focus moved on during the refresh to no window WinMux places (the desktop clicked, a panel): the
    /// reopened window doesn't take it back, though WinMux's own focus didn't change.
    func testAReopenedWindowDoesntTakeFocusMacOSGaveToNoWindow() async throws {
        let registry = NewWindowIntentRegistry.shared
        registry.resetForTests()
        defer { registry.resetForTests() }
        let target = focus.workspace
        let anchor = TestWindow.new(id: 100, parent: target.rootTilingContainer)
        let returning = TestWindow.new(id: 200, parent: Workspace.get(byName: "old").rootTilingContainer)
        _ = anchor.focusWindow()
        TestApp.shared.focusedWindow = anchor
        updateFocusCache(anchor)
        noteWindowPresentability([200: false])
        try await normalizeLayoutReason()
        XCTAssertNotNil(registry.register(bundleId: try XCTUnwrap(returning.app.rawAppBundleId), pid: returning.app.pid,
            targetWorkspace: target, preexistingWindowIds: [], focusGeneration: focusChangeGeneration, reopens: true))
        setBlockingRefreshOverridesForTests(refresh: {
            noteWindowPresentability([200: true])
            TestApp.shared.focusedWindow = nil
        })
        try await runRefreshSessionBlocking(.globalObserverLeftMouseUp)
        XCTAssertTrue(returning.nodeWorkspace === target, "Placed where asked")
        XCTAssertEqual(returning.nativeFocusCount, 0, "macOS's newer focus stands")
    }

    /// R6-3: a reopen's focus is its refresh's alone. One a restore left with no read of macOS's focus after it (a refresh
    /// cut short; here, outside one) isn't applied by a later refresh that brings back another window.
    func testAReopenFocusLeftBehindIsntAppliedByALaterRefresh() async throws {
        let registry = NewWindowIntentRegistry.shared
        registry.resetForTests()
        defer { registry.resetForTests() }
        let target = focus.workspace
        let anchor = TestWindow.new(id: 100, parent: target.rootTilingContainer)
        let returning = TestWindow.new(id: 200, parent: Workspace.get(byName: "old").rootTilingContainer)
        let other = TestWindow.new(id: 300, parent: target.rootTilingContainer)
        _ = anchor.focusWindow()
        TestApp.shared.focusedWindow = anchor
        updateFocusCache(anchor)
        noteWindowPresentability([200: false, 300: false])
        try await normalizeLayoutReason()
        XCTAssertTrue(returning.isSetAsideAsNotPresentable && other.isSetAsideAsNotPresentable)
        XCTAssertNotNil(registry.register(bundleId: try XCTUnwrap(returning.app.rawAppBundleId), pid: returning.app.pid,
            targetWorkspace: target, preexistingWindowIds: [], focusGeneration: focusChangeGeneration, reopens: true))
        noteWindowPresentability([200: true, 300: false])
        try await normalizeLayoutReason()
        XCTAssertTrue(returning.nodeWorkspace === target)
        XCTAssertFalse(registry.hasPendingIntents)
        setBlockingRefreshOverridesForTests(refresh: { noteWindowPresentability([200: true, 300: true]) })
        try await runRefreshSessionBlocking(.globalObserverLeftMouseUp)
        XCTAssertFalse(other.isSetAsideAsNotPresentable)
        XCTAssertEqual(returning.nativeFocusCount, 0, "Left behind: not applied later")
    }

    /// Carbon REVIEW-6 nit 2: a window let go is forgotten as the last native focus too.
    func testAWindowLetGoIsForgottenAsTheLastNativeFocus() {
        let window = TestWindow.new(id: 200, parent: Workspace.get(byName: "chat").rootTilingContainer)
        updateFocusCache(window)
        XCTAssertEqual(lastKnownNativeFocusedWindowIdForTests, 200)
        window.forgetClosedWindow(skipClosedWindowsCache: true)
        XCTAssertNil(lastKnownNativeFocusedWindowIdForTests)
    }
}
