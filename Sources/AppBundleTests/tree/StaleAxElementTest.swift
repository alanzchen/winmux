@testable import AppBundle
import AppKit
import XCTest

/// Alan's MacBook Pro (2026-11-14, the 0.6.414 debug snapshot): 11 sidebar members answered `illegalArgument` for their
/// window id, and their frame read `invalidUIElement`. 9 were windows their apps no longer listed: ghosts. 2 were live
/// windows the app still listed in AXWindows under a fresh element (Telegram 3269, focused; Slack 11074): their cached
/// element had gone stale. A ghost goes on the first refresh. A live window goes on under its fresh element: the same
/// Window, in the same place, with its pending frame job left alone, whatever the mouse is doing. Until a fresh element
/// can be taken, it's kept unbound.
@MainActor
final class StaleAxElementTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        AuxiliaryWindowRegistry.shared.removeAll()
    }

    override func tearDown() async throws {
        AuxiliaryWindowRegistry.shared.removeAll()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    /// On screen, and its app names its other windows, not this one; or the window server no longer lists it.
    func testAGhostAnsweringIllegalArgumentGoesOnTheFirstRefresh() {
        for (listed, appLists): (Set<UInt32>, [(UInt32, FakeLivenessWindow)]) in [([100, 1], [(1, .init((1, .success)))]), ([1], [])] {
            var registry: [UInt32: FakeLivenessWindow] = [100: .init((nil, .illegalArgument))]
            let result = refreshAppWindowRegistry(&registry, listed: listed, shown: [100], appLists: appLists)
            XCTAssertNil(result.kept[100], "listed \(listed)")
            XCTAssertEqual(result.dead, [100], "listed \(listed)")
        }
    }

    /// Kept, unbound, through a refresh whose AXWindows couldn't be read (on screen, so only the list could tell), then
    /// rebound once it could.
    func testAStaleLiveWindowKeptThroughAnUnreadableListIsReboundOnceTheListIsRead() {
        let stale = FakeLivenessWindow((nil, .illegalArgument))
        let fresh = FakeLivenessWindow((3269, .success))
        var registry: [UInt32: FakeLivenessWindow] = [3269: stale]
        let first = refreshAppWindowRegistry(&registry, listed: [3269], shown: [3269], appLists: nil)
        XCTAssertTrue(first.kept[3269] === stale)
        XCTAssertEqual(first.dead, [])
        XCTAssertEqual(first.unbound, [3269])
        let second = refreshAppWindowRegistry(&registry, listed: [3269], shown: [3269], appLists: [(3269, fresh)])
        XCTAssertTrue(second.kept[3269] === fresh)
        XCTAssertEqual(second.dead, [])
        XCTAssertEqual(second.unbound, [])
    }

    /// The app still lists the window, under a fresh element: kept under that element, and not reported dead, so its
    /// pending frame job isn't cancelled. Also while the mouse button is down, when no new window is registered.
    func testALiveWindowWhoseElementWentStaleGoesOnUnderItsFreshElement() {
        for mouseDown in [false, true] {
            let stale = FakeLivenessWindow((nil, .illegalArgument))
            let fresh = FakeLivenessWindow((3269, .success))
            var registry: [UInt32: FakeLivenessWindow] = [3269: stale, 100: .init((nil, .illegalArgument))]
            let result = refreshAppWindowRegistry(&registry, listed: [3269], shown: [3269], appLists: [(3269, fresh)],
                mouseDown: mouseDown)
            XCTAssertTrue(result.kept[3269] === fresh, "mouse down \(mouseDown): under its fresh element")
            XCTAssertEqual(result.dead, [100], "mouse down \(mouseDown): only the ghost is dead; the live window's frame job stays")
        }
    }

    /// A fresh element that can't be taken (its subscriptions fail, or it's a sheet or proxy with the window's id): the
    /// window is kept as it was, unbound, not reported dead, and the next refresh tries again.
    func testALiveWindowWhoseFreshElementCantBeTakenIsKeptUnboundForTheNextRefresh() {
        let stale = FakeLivenessWindow((nil, .illegalArgument))
        let fresh = FakeLivenessWindow((3269, .success))
        var registry: [UInt32: FakeLivenessWindow] = [3269: stale]
        let result = refreshAppWindowRegistry(&registry, listed: [3269], shown: [3269], appLists: [(3269, fresh)],
            freshElementTaken: false)
        XCTAssertTrue(result.kept[3269] === stale)
        XCTAssertEqual(result.dead, [])
        XCTAssertEqual(result.unbound, [3269])
        let next = refreshAppWindowRegistry(&registry, listed: [3269], shown: [3269], appLists: [(3269, fresh)])
        XCTAssertTrue(next.kept[3269] === fresh, "Tried again, and taken")
        XCTAssertEqual(next.unbound, [])
    }

    /// Through the tree: Telegram lent by a pin into a split with Slack, both with stale elements the app lists afresh,
    /// mid-drag, and a ghost in another tab. After the refresh and its garbage collection, the same two windows are in
    /// the split in the same order, still lent by the pin; the ghost is gone.
    func testALiveWindowWithAStaleElementKeepsItsTabRowPinAndSplitOnTheSameRefresh() throws {
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        let pin = Workspace.get(byName: "telegram")
        let telegram = TestWindow.new(id: 3269, parent: pin.rootTilingContainer)
        let split = Workspace.get(byName: "work")
        let slack = TestWindow.new(id: 11074, parent: split.rootTilingContainer)
        let other = Workspace.get(byName: "other")
        let ghost = TestWindow.new(id: 100, parent: other.rootTilingContainer)
        try setWorkspaceSidebarTabsFavorite([pin], true)
        try splitPinnedTabWindowWithTab(pin, "work", placement: .left)
        try setWorkspaceSidebarTabFavorite(split, true)
        let members = split.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)
        XCTAssertEqual(members, [3269, 11074])
        XCTAssertTrue(workspaceSidebarLentWindow(of: pin) === telegram)

        var registry: [UInt32: FakeLivenessWindow] = [
            3269: .init((nil, .illegalArgument)), 11074: .init((nil, .illegalArgument)), 100: .init((nil, .illegalArgument)),
        ]
        let result = refreshAppWindowRegistry(&registry, listed: [3269, 11074], shown: [3269, 11074],
            appLists: [(3269, .init((3269, .success))), (11074, .init((11074, .success)))], mouseDown: true)
        for window in [telegram, slack, ghost] where result.kept[window.windowId] == nil { letGoOfGoneWindow(window) }

        XCTAssertTrue(telegram.isBound && slack.isBound)
        XCTAssertEqual(split.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), members, "Same place in the split")
        XCTAssertTrue(split.rootTilingContainer.allLeafWindowsRecursive.first === telegram, "The same Window, not a new one")
        XCTAssertTrue(workspaceSidebarLentWindow(of: pin) === telegram, "Still lent by its pin")
        XCTAssertTrue(workspaceSidebarIsPinned(split))
        XCTAssertEqual(workspaceTabMembers(split).map(\.window.windowId), members, "Its sidebar row lists both")
        XCTAssertFalse(ghost.isBound)
    }
}
