@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class ReviewBlockReproTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        AuxiliaryWindowRegistry.shared.removeAll()
    }

    override func tearDown() async throws {
        AuxiliaryWindowRegistry.shared.removeAll()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    /// BLOCK 1: A live window whose cached AXUIElement went stale (`.illegalArgument`, as observed on Telegram 3269 and
    /// Slack 11074) while on an inactive macOS Space or behind/in a native-fullscreen Space (`AXWindows` omits windows
    /// off the active Space, `accessibility.swift:255-256`, while `CGWindowList` `.optionAll` still lists 3269).
    func testBlock1_LiveWindowWithStaleElementOnInactiveOrFullscreenSpaceIsNotDropped() throws {
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()

        let pin = Workspace.get(byName: "telegram")
        let telegram = TestWindow.new(id: 3269, parent: pin.rootTilingContainer)
        let split = Workspace.get(byName: "work")
        let slack = TestWindow.new(id: 11074, parent: split.rootTilingContainer)
        let preview = TestWindow.new(id: 4000, parent: split)
        AuxiliaryWindowRegistry.shared.restore(4000, pid: preview.app.pid, role: .windowRule, parentWindowId: 3269)

        try setWorkspaceSidebarTabsFavorite([pin], true)
        try splitPinnedTabWindowWithTab(pin, "work", placement: .left)
        try setWorkspaceSidebarTabFavorite(split, true)

        var registry: [UInt32: FakeLivenessWindow] = [
            3269: .init((nil, .illegalArgument)),
            11074: .init((11074, .success)),
            4000: .init((4000, .success)),
        ]
        // Inactive Space / native-fullscreen Space active on the display: AXWindows omits Desktop-Space windows (`appLists: []`),
        // while CGWindowList([.optionAll]) still lists all three live window IDs.
        let result = refreshAppWindowRegistry(&registry, listed: [3269, 11074, 4000], appLists: [])
        for window in [telegram, slack, preview] where result.kept[window.windowId] == nil {
            letGoOfGoneWindow(window)
        }

        XCTAssertNotNil(result.kept[3269], "Live window on an inactive/fullscreen Space must not be dropped")
        XCTAssertEqual(result.dead, [], "Live window's pending frame job must not be cancelled as dead")
        XCTAssertTrue(telegram.isBound, "Live window must stay in the tree")
        XCTAssertTrue(workspaceSidebarLentWindow(of: pin) === telegram, "Pin lending must survive")
        XCTAssertEqual(workspaceTabMembers(split).map(\.window.windowId), [3269, 11074, 4000])
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.parentWindowId(of: preview), 3269, "Auxiliary link must survive")
    }

    /// BLOCK 2A: On the active Space, `MacApp.swift:797` (`axApp.threadGuarded.get(Ax.windowsAttr) ?? []`) collapses a
    /// failed/timed-out `kAXWindowsAttribute` read (`nil`) into `[]`, falsely dropping a live window with a stale element.
    func testBlock2A_LiveWindowWithStaleElementSurvivesTimedOutAxWindowsRead() {
        let stale = FakeLivenessWindow((nil, .illegalArgument))
        let registered: [UInt32: FakeLivenessWindow] = [11074: stale]
        let windowServer = WindowServerWindowList(read: { [11074] })
        let timedOutAxWindows: [(UInt32, FakeLivenessWindow)]? = nil

        let refreshed = try? refreshRegisteredAxWindows(
            registered,
            frontmostAppBundleId: nil,
            windowServer: windowServer,
            listed: { timedOutAxWindows ?? [] }, // Exact `?? []` coercion from MacApp.swift:797
            rebind: { _, fresh in fresh },
            register: { alive, id, element in if alive[id] == nil { alive[id] = element } },
            RunLoopJob()
        )

        XCTAssertNotNil(refreshed?.alive[11074], "Timed-out kAXWindowsAttribute (nil) is unknown, not proof 11074 is absent")
        XCTAssertEqual(refreshed.map { Set($0.dead.keys) }, [])
    }

    /// BLOCK 2B: `WindowLiveness.swift:116-124` checks `job.checkCancellation()` only inside `for ... in listed()`, so when
    /// `singleAppRefreshDeadline` (`MacApp.swift:708, 723`) cancels `job` during `listed()` and `listed()` returns `[]`,
    /// `refreshRegisteredAxWindows` returns `(alive: [:], dead: [11074])` instead of throwing `CancellationError`.
    func testBlock2B_DeadlineCancellationDuringAxWindowsReadThrowsInsteadOfCommittingDeadState() {
        let stale = FakeLivenessWindow((nil, .illegalArgument))
        let registered: [UInt32: FakeLivenessWindow] = [11074: stale]
        let windowServer = WindowServerWindowList(read: { [11074] })
        let job = RunLoopJob()

        XCTAssertThrowsError(try refreshRegisteredAxWindows(
            registered,
            frontmostAppBundleId: nil,
            windowServer: windowServer,
            listed: {
                // Models singleAppRefreshDeadline firing while kAXWindowsAttribute / windowOrNil times out and yields [].
                job.cancel()
                return []
            },
            rebind: { _, fresh in fresh },
            register: { alive, id, element in if alive[id] == nil { alive[id] = element } },
            job
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// BLOCK 3: Behind a locked screen (`CGSSessionScreenIsLocked: true`) or off-console Fast User Switching session
    /// (`kCGSessionOnConsoleKey: false`) where `frontmostAppBundleId` is still the user's app (not `com.apple.loginwindow`),
    /// AX becomes unobservable (`closedWindowsCache.swift:5-6`: `.noValue` and empty `AXWindows`). `reconcileRegisteredWindows`
    /// drops the live window on the first refresh and permanently wipes its pin, pinned split, and auxiliary links.
    func testBlock3_LockedOrOffConsoleSessionWithoutLoginWindowFrontmostKeepsWindowsAndPinState() throws {
        let sessions: [(String, [String: Any])] = [
            ("screenLocked", [kCGSessionOnConsoleKey as String: true, "CGSSessionScreenIsLocked": true]),
            ("offConsole", [kCGSessionOnConsoleKey as String: false]),
        ]
        for (label, session) in sessions {
            setUpWorkspacesForTests()
            AuxiliaryWindowRegistry.shared.removeAll()
            config.workspaceSidebar.enabled = true
            config.workspaceSidebar.mode = .tabs
            workspaceSidebarOrganizationStore = .init()

            let pin = Workspace.get(byName: "mail")
            let viewer = TestWindow.new(id: 500, parent: pin.rootTilingContainer)
            let split = Workspace.get(byName: "triage")
            let notes = TestWindow.new(id: 501, parent: split.rootTilingContainer)
            let draft = TestWindow.new(id: 502, parent: split)
            AuxiliaryWindowRegistry.shared.restore(502, pid: draft.app.pid, role: .mailCompose, parentWindowId: 500)

            try setWorkspaceSidebarTabsFavorite([pin], true)
            try splitPinnedTabWindowWithTab(pin, "triage", placement: .left)
            try setWorkspaceSidebarTabFavorite(split, true)

            let cgWindows: [[String: Any]] = [
                [kCGWindowNumber as String: UInt32(500)],
                [kCGWindowNumber as String: UInt32(501)],
                [kCGWindowNumber as String: UInt32(502)],
            ]
            let listed = livenessWindowList(session: session, windows: cgWindows)
            let windowServer = WindowServerWindowList(read: { listed })
            let registered: [UInt32: FakeLivenessWindow] = [
                500: .init((nil, .noValue)),
                501: .init((nil, .noValue)),
                502: .init((nil, .noValue)),
            ]
            let refreshed = try refreshRegisteredAxWindows(
                registered,
                frontmostAppBundleId: "com.apple.mail", // Not com.apple.loginwindow
                windowServer: windowServer,
                listed: { [] },
                rebind: { _, fresh in fresh },
                register: { _, _, _ in },
                RunLoopJob()
            )
            for window in [viewer, notes, draft] where refreshed.alive[window.windowId] == nil {
                letGoOfGoneWindow(window)
            }

            XCTAssertEqual(Set(refreshed.alive.keys), [500, 501, 502], "\(label): locked/off-console session must not drop windows")
            XCTAssertTrue(workspaceSidebarLentWindow(of: pin) === viewer, "\(label): pin lentWindow wiped")
            XCTAssertEqual(AuxiliaryWindowRegistry.shared.parentWindowId(of: draft), 500, "\(label): auxiliary link wiped")
        }
    }

    /// BLOCK 4: `WindowLiveness.swift:118-119` removes `windowId` from `dead` on the first matching entry in `listed()`
    /// even when `rebind` rejects it (returns `nil`, e.g. failed subscription or transient sheet/proxy sharing the owner's
    /// `windowId`), stranding `alive[windowId]` on `stale` and ignoring the canonical window entry that follows.
    func testBlock4_StaleWindowRebindsToCanonicalEntryAfterRejectedDuplicateEntry() throws {
        let stale = FakeLivenessWindow((nil, .illegalArgument))
        let rejectedProxy = FakeLivenessWindow((3269, .success))
        let canonicalFresh = FakeLivenessWindow((3269, .success))
        let registered: [UInt32: FakeLivenessWindow] = [3269: stale]

        let refreshed = try refreshRegisteredAxWindows(
            registered,
            frontmostAppBundleId: nil,
            windowServer: WindowServerWindowList(read: { [3269] }),
            listed: { [(UInt32(3269), rejectedProxy), (UInt32(3269), canonicalFresh)] },
            rebind: { _, candidate in candidate === rejectedProxy ? nil : candidate },
            register: { alive, id, element in if alive[id] == nil { alive[id] = element } },
            RunLoopJob()
        )

        XCTAssertTrue(refreshed.alive[3269] === canonicalFresh, "Must rebind to the canonical fresh entry, not stay stuck on stale")
        XCTAssertTrue(refreshed.dead.isEmpty)
    }

    /// BLOCK 5: `reconcileRegisteredWindows` (`WindowLiveness.swift:75-100`) mutates `window.windowServerAbsences` in-place
    /// on reference-type `AxWindow` instances before a later entry throws `CancellationError` on `singleAppRefreshDeadline`
    /// (`MacApp.swift:708` = 1.5s vs 1.0s per `.cannotComplete` query):
    /// 1) A cancelled refresh leaks `windowServerAbsences = 1`, so one later miss drops a live window without two consecutive
    ///    completed refreshes; and
    /// 2) A busy app with >= 3 windows cancels after 2 x 1.0s timeouts on every refresh and never drops a closed window.
    func testBlock5_CancelledRefreshDoesNotLeakWindowServerAbsenceCountOntoSurvivingWindow() {
        final class ProbeHookWindow: RegisteredWindowLiveness {
            let id: UInt32
            let inner: FakeLivenessWindow
            let onAfterProbe: (UInt32) -> Void
            var windowServerAbsences: Int {
                get { inner.windowServerAbsences }
                set { inner.windowServerAbsences = newValue }
            }
            init(id: UInt32, _ inner: FakeLivenessWindow, onAfterProbe: @escaping (UInt32) -> Void) {
                self.id = id
                self.inner = inner
                self.onAfterProbe = onAfterProbe
            }
            func containingWindowIdWithError() -> (windowId: CGWindowID?, error: AXError) {
                defer { onAfterProbe(id) }
                return inner.containingWindowIdWithError()
            }
        }

        let backing: [UInt32: FakeLivenessWindow] = [
            7: .init((nil, .cannotComplete)),
            8: .init((nil, .cannotComplete)),
        ]
        let job = RunLoopJob()
        var firstProbedId: UInt32?
        let wrapped: [UInt32: ProbeHookWindow] = backing.reduce(into: [:]) { dict, entry in
            dict[entry.key] = ProbeHookWindow(id: entry.key, entry.value) { id in
                if firstProbedId == nil {
                    firstProbedId = id
                    job.cancel() // Deadline fires before the 2nd window is probed
                }
            }
        }

        let windowServer = WindowServerWindowList(read: { [100] })
        XCTAssertThrowsError(try reconcileRegisteredWindows(wrapped, frontmostAppBundleId: nil, windowServer: windowServer, job))
        guard let victimId = firstProbedId, let victim = backing[victimId] else {
            return XCTFail("Expected first window probe before cancellation")
        }

        // Refresh 1 threw CancellationError ("nothing changed" fallback in MacApp.swift:729-733), so `victim` must still have
        // 0 committed absences; a single miss on the next completed refresh must NOT drop `victim`!
        var surviving: [UInt32: FakeLivenessWindow] = [victimId: victim]
        let nextRefresh = refreshWindowLiveness(&surviving, listed: [100])
        XCTAssertEqual(nextRefresh.kept, [victimId], "A single completed miss after a cancelled refresh must not drop window \(victimId)")
    }
}
