@testable import AppBundle
import AppKit
import XCTest

/// Review-only, synthetic cases for candidate 6d38e167. No native apps or windows.
@MainActor
final class Review3RegressionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    func testTwoSetAsideSiblingsReturnInTheirOriginalOrder() async throws {
        let split = Workspace.get(byName: "split")
        let first = TestWindow.new(id: 101, parent: split.rootTilingContainer)
        let second = TestWindow.new(id: 102, parent: split.rootTilingContainer)
        let third = TestWindow.new(id: 103, parent: split.rootTilingContainer)
        try setWorkspaceSidebarTabFavorite(split, true)
        let original = workspaceTabMembers(split).map(\.window.windowId)
        XCTAssertEqual(original, [101, 102, 103])
        var registry: [UInt32: FakeLivenessWindow] = [
            101: .init((nil, .illegalArgument)),
            102: .init((nil, .illegalArgument)),
            103: .init((103, .success)),
        ]
        let listed: Set<UInt32> = [101, 102, 103]
        let liveThird = FakeLivenessWindow((103, .success))
        try await refreshPresentability(&registry, listed: listed, shown: [103], orderedOut: [101, 102],
            appLists: [(103, liveThird)])
        XCTAssertTrue(first.parent === macosNotPresentableWindowsContainer)
        XCTAssertTrue(second.parent === macosNotPresentableWindowsContainer)
        XCTAssertTrue(third.parent === split.rootTilingContainer)
        syncWorkspaceSidebarPinCompositions()

        // They are both ordered in again in the same refresh. Their AX tree is
        // still being rebuilt, the same supported restore path as the author's test.
        try await refreshPresentability(&registry, listed: listed, shown: listed, appLists: [(103, liveThird)])
        XCTAssertFalse(first.isNotPresentable)
        XCTAssertFalse(second.isNotPresentable)
        XCTAssertTrue(workspaceSidebarIsPinned(split))
        XCTAssertEqual(workspaceTabMembers(split).map(\.window.windowId), original,
            "Two hidden siblings must keep their original split positions")
    }

    func testTombstoneRejectsCorpseWhileTheSameOnscreenSurfaceStillLingers() throws {
        let closed = FakeLivenessWindow((nil, .illegalArgument))
        var ledger = WindowLivenessLedger<FakeLivenessWindow>()
        let first = livenessWindowServer(listed: [1, 9], shown: [9])
        let decided = try refreshRegisteredAxWindows([9: closed], frontmostAppBundleId: nil,
            windowServer: first, listed: { [] as [(UInt32, FakeLivenessWindow)] },
            rebind: { _, fresh in fresh }, register: { alive, id, element in alive[id] = element }, RunLoopJob())
        XCTAssertEqual(Set(decided.dead.keys), [9], "Evidence table row 7 closes an ID that WindowServer still lists on screen")
        ledger.hold(decided, of: first)
        _ = ledger.commit(first)
        XCTAssertEqual(ledger.confirmedClosed, [9])

        // No out/in transition or absence has occurred. WindowServer is still
        // lagging the close; the app now vends a live-looking element for that ID.
        let stillLingering = livenessWindowServer(listed: [1, 9], shown: [9])
        let corpse = FakeLivenessWindow((9, .success))
        let next = try refreshRegisteredAxWindows([:], frontmostAppBundleId: nil,
            windowServer: stillLingering, listed: { [(UInt32(9), corpse)] },
            rebind: { _, fresh in fresh }, register: { alive, id, element in alive[id] = element },
            confirmedClosed: ledger.confirmedClosed, RunLoopJob())
        XCTAssertNil(next.alive[9], "Still on screen is not evidence of being shown AGAIN after a confirmed close")
        XCTAssertFalse(ledger.mayRegister(9, windowServer: stillLingering), "The focus path must keep the same tombstone")
    }
}
