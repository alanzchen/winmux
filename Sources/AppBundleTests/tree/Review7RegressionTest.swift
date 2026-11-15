@testable import AppBundle
import AppKit
import Common
import XCTest

/// Round-7 review artifacts; candidate production and reviewer sources are unmodified.
@MainActor
final class Review7RegressionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetFocusCacheForTests()
        resetFrozenRestoresForTests()
        NewWindowIntentRegistry.shared.resetForTests()
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = nil
        TestApp.shared.hasActiveTransientNativeFocus = false
    }

    override func tearDown() async throws {
        setBlockingRefreshOverridesForTests()
        resetFocusCacheForTests()
        resetFrozenRestoresForTests()
        NewWindowIntentRegistry.shared.resetForTests()
        TestApp.shared.focusedWindow = nil
        TestApp.shared.hasActiveTransientNativeFocus = false
        appForTests = nil
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private func decide(_ windows: [UInt32: FakeLivenessWindow], server: WindowServerWindowList,
                        listed: [(UInt32, FakeLivenessWindow)]) throws -> RegisteredWindowsRefresh<FakeLivenessWindow> {
        try refreshRegisteredAxWindows(windows, frontmostAppBundleId: nil, windowServer: server, listed: { listed },
            rebind: { _, fresh in fresh }, register: { alive, id, element in alive[id] = element }, RunLoopJob())
    }

    /// The last observation starts with an old positive shared list. By the time this app's
    /// AXWindows returns its corpse, the window server has removed the ID. Admission must
    /// check the per-app list even when the shared list used to contain the ID.
    func testLastRecheckMustNotAdmitCorpseFromAnOlderPositiveSharedList() throws {
        var recheck = WindowLivenessRecheck()
        XCTAssertNotNil(recheck.next(awaiting: [9], startsSeries: true, at: 0))
        for time: TimeInterval in [0.5, 1.5, 3.5, 7.5] {
            XCTAssertNotNil(recheck.next(awaiting: [], at: time))
        }
        let reads = WindowServerReads([[1: true, 9: true], [1: true]])
        let server = WindowServerWindowList(readWindows: { reads.next() })
        server.take() // Another app's worker took this before this app's AXWindows read.
        let corpse = FakeLivenessWindow((9, .success))
        let result = try decide([:], server: server, listed: [(9, corpse)])
        XCTAssertNil(result.alive[9], "A fresh per-app read would reject the corpse")
        XCTAssertNil(recheck.next(awaiting: result.awaitsWindowServer, startsSeries: result.startsRecheckSeries, at: 15.5),
            "This was the last observation: admission schedules no later removal")
        XCTAssertEqual(server.readAgain()?[9], nil, "The window server no longer has it at admission")
    }

    /// Even a fresh post-AX list already obtained for row 7 is ignored for new IDs whose
    /// shared snapshot was positive. This is known current absence, not just a missing read.
    func testAdmissionUsesTheFreshAbsenceAlreadyReadForAnotherWindow() throws {
        let reads = WindowServerReads([[1: true, 7: true, 9: true], [1: true, 7: true]])
        let server = WindowServerWindowList(readWindows: { reads.next() })
        let result = try decide([7: .init((nil, .illegalArgument))], server: server,
            listed: [(9, .init((9, .success)))])
        XCTAssertEqual(reads.count, 2, "Row 7 already acquired the fresh per-app list")
        XCTAssertNotNil(result.dead[7])
        XCTAssertNil(result.alive[9], "The fresh per-app list already proves this ID absent")
    }

    private func prepareReopen(nativeAnchor: Bool) async throws -> (TestWindow, TestWindow) {
        let target = focus.workspace
        let anchor = TestWindow.new(id: 100, parent: target.rootTilingContainer)
        let returning = TestWindow.new(id: 200, parent: Workspace.get(byName: "old").rootTilingContainer)
        _ = anchor.focusWindow()
        TestApp.shared.focusedWindow = nativeAnchor ? anchor : nil
        if nativeAnchor { updateFocusCache(anchor) }
        noteWindowPresentability([200: false])
        try await normalizeLayoutReason()
        XCTAssertTrue(returning.isSetAsideAsNotPresentable)
        let registry = NewWindowIntentRegistry.shared
        XCTAssertNotNil(registry.register(bundleId: try XCTUnwrap(returning.app.rawAppBundleId), pid: returning.app.pid,
            targetWorkspace: target, preexistingWindowIds: [], focusGeneration: focusChangeGeneration, reopens: true))
        return (anchor, returning)
    }

    /// The pin launcher initially yields no managed native window. While refresh awaits AX,
    /// a native modal/panel receives focus, also represented by nil, but explicitly transient.
    /// The reread must preserve that modal focus, not interpret nil == nil as authorization.
    func testReopenDoesNotStealTransientNativeFocusWhenBothWindowIdsAreNil() async throws {
        let (anchor, returning) = try await prepareReopen(nativeAnchor: false)
        setBlockingRefreshOverridesForTests(refresh: {
            noteWindowPresentability([200: true])
            TestApp.shared.focusedWindow = nil
            TestApp.shared.hasActiveTransientNativeFocus = true
        })
        try await runHeavyCompleteRefreshSession(.globalObserverLeftMouseUp)
        XCTAssertTrue(returning.nodeWorkspace === anchor.nodeWorkspace, "Placement still succeeds")
        XCTAssertEqual(returning.nativeFocusCount, 0, "The post-restore read says a native panel has focus")
        XCTAssertNil(TestApp.shared.focusedWindow, "Do not replace modal focus with the reopened window")
    }

    /// With a frozen restore still in flight, takesFocus:false also enters the older deferred
    /// placement queue. That queue must not later undo the post-restore focus veto.
    func testFinishingOverlappingFrozenRestoreDoesNotOverrideReopenFocusVeto() async throws {
        let (anchor, returning) = try await prepareReopen(nativeAnchor: true)
        let registry = NewWindowIntentRegistry.shared
        registry.isRegistered = { $0 === anchor || $0 === returning }
        beginFrozenRestore()
        setBlockingRefreshOverridesForTests(refresh: {
            noteWindowPresentability([200: true])
            TestApp.shared.focusedWindow = nil // The user clicked the desktop while AX was awaited.
        })
        try await runHeavyCompleteRefreshSession(.globalObserverLeftMouseUp)
        XCTAssertTrue(returning.nodeWorkspace === anchor.nodeWorkspace)
        XCTAssertEqual(returning.nativeFocusCount, 0, "The reread vetoes focus correctly at first")
        XCTAssertNil(TestApp.shared.focusedWindow)
        endFrozenRestore()
        XCTAssertEqual(returning.nativeFocusCount, 0, "The deferred placement must retain takesFocus:false / the veto")
        XCTAssertNil(TestApp.shared.focusedWindow, "Finishing the old restore must not take focus back")
    }

    /// Positive controls for the two admission observations and the nil-native-focus case:
    /// a live listing, or no usable fresh list, stays admissible; an ordinary pin reopen
    /// may activate when the reread is not transient and native focus has not moved.
    func testControlsKeepLiveAdmissionsAndOrdinaryPinFocus() async throws {
        for after: [UInt32: Bool]? in [[1: true, 9: true], nil, [:]] {
            let reads = WindowServerReads([[1: true], after])
            let live = FakeLivenessWindow((9, .success))
            let result = try decide([:], server: WindowServerWindowList(readWindows: { reads.next() }), listed: [(9, live)])
            XCTAssertTrue(result.alive[9] === live)
        }
        let (_, returning) = try await prepareReopen(nativeAnchor: false)
        setBlockingRefreshOverridesForTests(refresh: { noteWindowPresentability([200: true]) })
        try await runHeavyCompleteRefreshSession(.globalObserverLeftMouseUp)
        XCTAssertEqual(returning.nativeFocusCount, 1, "No newer native or transient focus: the pin reopen can activate")
    }
}
