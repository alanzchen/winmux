@testable import AppBundle
import AppKit
import XCTest

/// Review-only reproductions. All AX answers and session state are synthetic;
/// these tests never enumerate, launch, or change a native application.
@MainActor
final class ReviewLivenessRegressionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        AuxiliaryWindowRegistry.shared.removeAll()
        workspaceSidebarOrganizationStore = .init()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
    }

    override func tearDown() async throws {
        AuxiliaryWindowRegistry.shared.removeAll()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    func testStaleLiveWindowIsNotRemovedWhenAXWindowsReadTimesOut() throws {
        // Same stale cached answer as the supplied live Telegram observation.
        let stale = FakeLivenessWindow((nil, .illegalArgument))
        let pin = Workspace.get(byName: "telegram")
        let telegram = TestWindow.new(id: 3269, parent: pin.rootTilingContainer)
        let split = Workspace.get(byName: "work")
        let slack = TestWindow.new(id: 11074, parent: split.rootTilingContainer)
        try setWorkspaceSidebarTabsFavorite([pin], true)
        try splitPinnedTabWindowWithTab(pin, "work", placement: .left)
        try setWorkspaceSidebarTabFavorite(split, true)
        let originalMembers = workspaceTabMembers(split).map(\.window.windowId)
        let pendingFrameJob = RunLoopJob()

        // AXUIElement.get returns nil when AXWindows returns cannotComplete
        // (accessibility.swift:348-354). MacApp.swift:797 turns that nil into [].
        // The stale ID query can fail immediately and this read can time out in
        // 1 second, before the app's 1.5-second cancellation deadline.
        let failedAXWindowsRead: [(UInt32, FakeLivenessWindow)]? = nil
        let result = try refreshRegisteredAxWindows([3269: stale], frontmostAppBundleId: "org.telegram.desktop",
            windowServer: WindowServerWindowList(read: { [3269, 11074] }),
            listed: { failedAXWindowsRead ?? [] },
            rebind: { _, fresh in fresh },
            register: { alive, id, element in alive[id] = element }, RunLoopJob())

        // The downstream production decisions in MacApp.swift:806-807 and
        // refresh.swift:469-471, applied to test-only frame jobs and windows.
        if result.dead[3269] != nil { pendingFrameJob.cancel() }
        if result.alive[3269] == nil { letGoOfGoneWindow(telegram) }

        XCTAssertTrue(result.alive[3269] === stale, "An unreadable enumeration must not prove that this live window closed")
        XCTAssertTrue(result.dead.isEmpty, "Do not cancel a live window's queued frame work")
        XCTAssertFalse(pendingFrameJob.isCancelled)
        XCTAssertTrue(telegram.isBound)
        XCTAssertTrue(workspaceSidebarLentWindow(of: pin) === telegram)
        XCTAssertEqual(workspaceTabMembers(split).map(\.window.windowId), originalMembers)
        XCTAssertTrue(slack.isBound)
    }

    func testLockAfterFrontmostSampleKeepsLiveWindowsWithEmptyAXAnswers() throws {
        // refresh.swift:465 samples frontmost before awaiting the AX workers.
        // The screen can lock while the refresh waits in an app's queue. The
        // known lock behavior is documented in frozen/closedWindowsCache.swift:3-7.
        // The list's session guard already knows this session is locked.
        for error: AXError in [.success, .noValue, .illegalArgument] {
            let live = FakeLivenessWindow((nil, error))
            let windowServer = WindowServerWindowList(read: {
                windowServerWindowIdsForLiveness(
                    session: [kCGSessionOnConsoleKey as String: true, "CGSSessionScreenIsLocked": true],
                    windows: [[kCGWindowNumber as String: UInt32(3269)]])
            })
            XCTAssertNil(windowServer.lists(3269), "The current session says AX absence is not reliable")
            let result = try refreshRegisteredAxWindows([3269: live], frontmostAppBundleId: "org.telegram.desktop",
                windowServer: windowServer,
                listed: { [] as [(UInt32, FakeLivenessWindow)] },
                rebind: { _, fresh in fresh },
                register: { alive, id, element in alive[id] = element }, RunLoopJob())
            XCTAssertTrue(result.alive[3269] === live, "Lock after the frontmost sample: \(error)")
            XCTAssertTrue(result.dead.isEmpty, "Lock is not a window close: \(error)")
        }
    }
}
