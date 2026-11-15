@testable import AppBundle
import AppKit
import Common
import XCTest

/// Round-6 review artifacts. Production source and the seven reviewer files are unchanged.
/// None of these tests is covered by SupersededReviewerReproducers.
@MainActor
final class Review6RegressionTest: XCTestCase {
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
                        listed: [(UInt32, FakeLivenessWindow)] = []) throws -> RegisteredWindowsRefresh<FakeLivenessWindow> {
        try refreshRegisteredAxWindows(windows, frontmostAppBundleId: nil, windowServer: server,
            listed: { listed }, rebind: { _, fresh in fresh },
            register: { alive, id, element in alive[id] = element }, RunLoopJob())
    }

    /// A global list is shared across apps. Another app took it before window 9 was
    /// created/registered; an AX-thread registry read later includes the new live window.
    /// The cached absence says "not born yet", not "closed".
    func testRow1bDoesNotDeleteAWindowBornAfterTheSharedSnapshot() throws {
        let reads = WindowServerReads([[1: true], [1: true, 9: true]])
        let server = WindowServerWindowList(readWindows: { reads.next() })
        server.take() // App A populated the shared snapshot.
        let newborn = FakeLivenessWindow((9, .success)) // Registration on app B after the snapshot.
        let result = try decide([9: newborn], server: server, listed: [(9, newborn)])
        XCTAssertNil(result.dead[9], "An older shared snapshot cannot prove that a newly registered live window closed")
        XCTAssertTrue(result.alive[9] === newborn, "Keep its identity and placement when a fresh list can confirm it")
        XCTAssertEqual(reads.count, 1, "The candidate never obtained a fresh absence observation")
        XCTAssertEqual(server.readAgain()?[9], true, "The current server list includes the live window")
    }

    /// The drop's series runs to completion, but its last callback can itself admit a
    /// corpse. Admission does not ask for a follow-up and never checks known WS absence.
    /// A usable absent list is already available, so this is not a missing-data case.
    func testACorpseFirstReadmittedOnTheLastRecheckDoesNotStayForever() throws {
        let live = FakeLivenessWindow((1, .success))
        let corpse = FakeLivenessWindow((9, .success))
        var windows: [UInt32: FakeLivenessWindow] = [1: live, 9: .init((nil, .illegalArgument))]
        var recheck = WindowLivenessRecheck()
        var pending: [TimeInterval] = []
        var last: TimeInterval = 0

        func tick(at now: TimeInterval, closing: Bool = false) throws {
            let server = livenessWindowServer(listed: closing ? [1, 9] : [1], shown: closing ? [1, 9] : [1])
            let appLists: [(UInt32, FakeLivenessWindow)] = now >= 15.5 ? [(UInt32(1), live), (UInt32(9), corpse)] : [(UInt32(1), live)]
            let result = try decide(windows, server: server, listed: appLists)
            result.commit()
            windows = result.alive
            if let delay = recheck.next(awaiting: result.awaitsWindowServer, startsSeries: result.startsRecheckSeries, at: now) {
                let parts = delay.components
                pending.append(now + Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
            }
            last = now
        }
        try tick(at: 0, closing: true)
        while !pending.isEmpty {
            pending.sort()
            try tick(at: pending.removeFirst())
        }
        XCTAssertEqual(last, 15.5)
        XCTAssertNil(windows[9],
            "The last callback registered a known-absent corpse and left no observation scheduled; the ghost can now persist without another external event")
    }

    /// Replacement for my R3 tombstone test: temporary admission is allowed; a current,
    /// usable WS absence must remove the corpse on the next observation.
    func testReplacementR3A1AdmittedCorpseIsRemovedOnCurrentServerAbsence() throws {
        let closed = try decide([9: .init((nil, .illegalArgument))],
            server: livenessWindowServer(listed: [1, 9], shown: [9]))
        XCTAssertNotNil(closed.dead[9])
        let corpse = FakeLivenessWindow((9, .success))
        let admitted = try decide([:], server: livenessWindowServer(listed: [1, 9], shown: [9]),
            listed: [(9, corpse)])
        XCTAssertTrue(admitted.alive[9] === corpse)
        let removed = try decide(admitted.alive, server: livenessWindowServer(listed: [1], shown: [1]))
        XCTAssertNotNil(removed.dead[9])
        XCTAssertNil(removed.alive[9])
    }

    /// Replacement for my R5 scheduler test: explicit virtual time and startsSeries,
    /// with no obsolete tombstone/attempt-count assumptions.
    func testReplacementR5DropRestartsObservationWithoutDelayingReadmission() throws {
        var recheck = WindowLivenessRecheck()
        for time: TimeInterval in [0, 0.5, 1.5, 3.5, 7.5, 15.5] {
            _ = recheck.next(awaiting: [9], at: time)
        }
        let server = livenessWindowServer(listed: [1, 9], shown: [9])
        let dropped = try decide([9: .init((nil, .illegalArgument))], server: server)
        XCTAssertTrue(dropped.startsRecheckSeries)
        XCTAssertEqual(recheck.next(awaiting: dropped.awaitsWindowServer, startsSeries: dropped.startsRecheckSeries, at: 20),
            .milliseconds(500))
        XCTAssertNil(recheck.next(awaiting: [], at: 20.1), "An intervening refresh spends no timer")
        XCTAssertEqual(recheck.next(awaiting: [], at: 20.5), .seconds(1))
        let liveAgain = FakeLivenessWindow((9, .success))
        let admitted = try decide([:], server: server, listed: [(9, liveAgain)])
        XCTAssertTrue(admitted.alive[9] === liveAgain, "No timer or elapsed-time gate delays a live return")
    }

    /// Replacement for the R5 characterization: its old final assertion is inverted.
    func testReplacementR5LongLivedCorpseIsDroppedEvenWhileAxStillResolves() throws {
        let corpse = FakeLivenessWindow((9, .success))
        let removed = try decide([9: corpse], server: livenessWindowServer(listed: [1], shown: [1]),
            listed: [(9, corpse)])
        XCTAssertNotNil(removed.dead[9])
        XCTAssertNil(removed.alive[9])
    }

    /// New focus is read after restoration, not taken from the observation at entry.
    func testRestorationUsesTheLaterNativeFocusAndDoesNotSyncBack() async throws {
        let main = focus.workspace
        let old = TestWindow.new(id: 100, parent: main.rootTilingContainer)
        let chat = Workspace.get(byName: "chat")
        let returning = TestWindow.new(id: 200, parent: chat.rootTilingContainer)
        let laterTab = Workspace.get(byName: "later")
        let later = TestWindow.new(id: 300, parent: laterTab.rootTilingContainer)
        _ = old.focusWindow()
        TestApp.shared.focusedWindow = old
        updateFocusCache(old)
        noteWindowPresentability([200: false])
        try await normalizeLayoutReason()
        XCTAssertTrue(returning.isSetAsideAsNotPresentable)
        TestApp.shared.focusedWindow = returning
        setBlockingRefreshOverridesForTests(refresh: {
            noteWindowPresentability([200: true])
            TestApp.shared.focusedWindow = later // Native focus changes during the refresh.
        })
        try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String))
        XCTAssertEqual(focus.windowOrNil?.windowId, 300)
        XCTAssertTrue(laterTab.isVisible)
        XCTAssertEqual(old.nativeFocusCount, 0)
        XCTAssertEqual(returning.nativeFocusCount, 0)
    }

    /// Characterize recovery cost: the closed-world cache can restore tree placement,
    /// but GC has already erased the pin's lending record.
    func testCharacterizeNewIdentityRestoresCachedPlacementButNotTheLendingRecord() async throws {
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        defer { replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: [])) }
        let pin = Workspace.get(byName: "telegram")
        let old = TestWindow.new(id: 9, parent: pin.rootTilingContainer)
        let split = Workspace.get(byName: "work")
        _ = TestWindow.new(id: 1, parent: split.rootTilingContainer)
        try setWorkspaceSidebarTabsFavorite([pin], true)
        try splitPinnedTabWindowWithTab(pin, "work", placement: .left)
        try setWorkspaceSidebarTabFavorite(split, true)
        XCTAssertTrue(workspaceSidebarLentWindow(of: pin) === old)
        let order = split.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)
        syncWorkspaceSidebarPinCompositions()
        replaceClosedWindowsCache(snapshotCurrentFrozenWorld()) // Give recovery its best case: a current cache.
        old.forgetClosedWindow(skipClosedWindowsCache: false)
        XCTAssertNil(workspaceSidebarOrganizationStore.state.workspaces[pin.name]?.lentWindow)
        let returned = TestWindow.new(id: 9, parent: Workspace.get(byName: "new-detection").rootTilingContainer)
        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: returned)
        XCTAssertTrue(restored)
        XCTAssertEqual(returned.nodeWorkspace?.name, split.name)
        XCTAssertEqual(split.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), order)
        XCTAssertTrue(workspaceSidebarIsPinned(pin))
        XCTAssertTrue(workspaceSidebarIsPinned(split))
        XCTAssertNil(workspaceSidebarOrganizationStore.state.workspaces[pin.name]?.lentWindow,
            "New identity and tree restoration do not reconstruct the erased home-pin link")
    }

    /// Reopen placement runs during restoration, before the new native-focus reread.
    /// A later native selection must not be overwritten by the pending intent first.
    func testPendingReopenDoesNotStealFocusBeforeThePostRestoreReread() async throws {
        let registry = NewWindowIntentRegistry.shared
        registry.resetForTests()
        defer { registry.resetForTests() }
        let target = focus.workspace
        let anchor = TestWindow.new(id: 100, parent: target.rootTilingContainer)
        let returning = TestWindow.new(id: 200, parent: Workspace.get(byName: "old").rootTilingContainer)
        let later = TestWindow.new(id: 300, parent: Workspace.get(byName: "later").rootTilingContainer)
        _ = anchor.focusWindow()
        TestApp.shared.focusedWindow = anchor
        updateFocusCache(anchor)
        noteWindowPresentability([200: false])
        try await normalizeLayoutReason()
        XCTAssertTrue(returning.isSetAsideAsNotPresentable)
        XCTAssertNotNil(registry.register(bundleId: try XCTUnwrap(returning.app.rawAppBundleId),
            pid: returning.app.pid, targetWorkspace: target, preexistingWindowIds: [],
            focusGeneration: focusChangeGeneration, reopens: true))
        TestApp.shared.focusedWindow = returning
        setBlockingRefreshOverridesForTests(refresh: {
            noteWindowPresentability([200: true])
            TestApp.shared.focusedWindow = later
        })
        try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String))
        XCTAssertTrue(returning.nodeWorkspace === target, "Keep the requested placement")
        XCTAssertFalse(registry.hasPendingIntents)
        XCTAssertEqual(returning.nativeFocusCount, 0, "Restoration must not steal focus before the reread can observe the newer native selection")
        XCTAssertTrue(TestApp.shared.focusedWindow === later, "The newer macOS focus must survive the restoration")
        XCTAssertEqual(focus.windowOrNil?.windowId, 300)
    }

    /// Ordinary controls: listed off-screen windows stay; unusable session/list evidence
    /// never lets a resolving ID go. No native UI is queried.
    func testRow1bControlsForListedAndUnusableSnapshots() throws {
        let live = FakeLivenessWindow((9, .success))
        let servers = [
            livenessWindowServer(listed: [1, 9], shown: []),
            WindowServerWindowList(sessionSuspended: true, readWindows: { [1: true] }),
            WindowServerWindowList(spaceSwitching: true, readWindows: { [1: true, 9: false] }),
            livenessWindowServer(listed: nil),
            livenessWindowServer(listed: []),
            WindowServerWindowList(readWindows: {
                windowServerWindowsForLiveness(session: [kCGSessionOnConsoleKey as String: false], windows: [[kCGWindowNumber as String: UInt32(1)]])
            }),
            WindowServerWindowList(readWindows: {
                windowServerWindowsForLiveness(session: [kCGSessionOnConsoleKey as String: true, "CGSSessionScreenIsLocked": true],
                    windows: [[kCGWindowNumber as String: UInt32(1)]])
            }),
        ]
        for server in servers {
            let result = try decide([9: live], server: server, listed: [(9, live)])
            XCTAssertTrue(result.alive[9] === live)
            XCTAssertNil(result.dead[9])
        }
    }
}

