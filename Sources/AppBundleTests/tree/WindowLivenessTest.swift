@testable import AppBundle
import AppKit
import XCTest

/// Windows closed long ago stayed in the sidebar (2026-11-14). Since 830c9668 a registered window was let go only when its
/// AX element was reported invalid; a closed window whose stale element answered anything else (no value, an unsupported
/// attribute, a failure, a zero id) stayed forever. Now a registered window AX can't resolve is let go on positive
/// evidence that it closed (`windowLivenessVerdict`): the window server no longer lists it, or it's on screen and its app,
/// read in full, doesn't list it. A busy app's window (a timeout) is let go once the window server misses it twice in a
/// row. Synthetic: what each window's own AX query answers, what its app lists and what the window server lists are given.
@MainActor
final class WindowLivenessTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        AuxiliaryWindowRegistry.shared.removeAll()
    }

    override func tearDown() async throws {
        AuxiliaryWindowRegistry.shared.removeAll()
    }

    /// `times` refreshes in a row with the same answers: the ids the last one kept.
    private func refresh(_ registry: inout [UInt32: FakeLivenessWindow], listed: Set<UInt32>?, shown: Set<UInt32> = [],
                         frontmost: String? = nil, appLists: [UInt32]? = [], times: Int = 1) -> Set<UInt32> {
        var kept: Set<UInt32> = []
        for _ in 0 ..< times {
            kept = refreshWindowLiveness(&registry, listed: listed, shown: shown, frontmost: frontmost, appLists: appLists).kept
        }
        return kept
    }

    // MARK: Closed windows go

    func testAClosedWindowAnsweringNoValueIsLetGoOnTheFirstRefresh() {
        assertLetGoOnTheFirstRefresh((nil, .noValue))
    }

    func testAClosedWindowAnsweringAnUnsupportedAttributeIsLetGoOnTheFirstRefresh() {
        assertLetGoOnTheFirstRefresh((nil, .attributeUnsupported))
    }

    func testAClosedWindowAnsweringAZeroIdIsLetGoOnTheFirstRefresh() {
        assertLetGoOnTheFirstRefresh((nil, .success))
    }

    func testAClosedWindowAnsweringAFailureIsLetGoOnTheFirstRefresh() {
        assertLetGoOnTheFirstRefresh((nil, .failure))
    }

    func testAClosedWindowAnsweringAnIllegalArgumentIsLetGoOnTheFirstRefresh() {
        assertLetGoOnTheFirstRefresh((nil, .illegalArgument))
    }

    /// On either evidence of a close: the window server no longer lists it (whatever its app lists, or if its list
    /// couldn't be read), or it's on screen and its app, read in full, lists other windows or none, and not this one.
    private func assertLetGoOnTheFirstRefresh(_ answer: (windowId: CGWindowID?, error: AXError), file: StaticString = #filePath,
                                              line: UInt = #line) {
        let cases: [(listed: Set<UInt32>, shown: Set<UInt32>, appLists: [UInt32]?)] = [
            ([1, 2], [], []), ([1, 2], [], [1]), ([1, 2], [], nil), ([1, 7], [7], [1]), ([1, 7], [7], []),
        ]
        for (listed, shown, appLists) in cases {
            var registry: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow(answer)]
            XCTAssertEqual(refresh(&registry, listed: listed, shown: shown, appLists: appLists), [],
                "listed \(listed), shown \(shown), app lists \(String(describing: appLists))", file: file, line: line)
            XCTAssertNil(registry[7], "No longer registered", file: file, line: line)
        }
    }

    /// A busy app's window that closed: its query times out, and the window server no longer lists it, twice in a row.
    func testAClosedWindowOfABusyAppIsLetGoOnceTheWindowServerMissesItTwice() {
        var registry: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow((nil, .cannotComplete))]
        XCTAssertEqual(refresh(&registry, listed: [1, 2]), [7], "Missing once")
        XCTAssertEqual(refresh(&registry, listed: [1, 2]), [], "Missing twice in a row")
        XCTAssertNil(registry[7])
    }

    /// Through what refresh does with a window that's gone: out of its tab, so out of the sidebar, and a draft opened
    /// from it is a window of its own.
    func testAClosedWindowLeavesItsTabTheSidebarAndItsDrafts() {
        let tab = Workspace.get(byName: "mail")
        let live = TestWindow.new(id: 1, parent: tab.rootTilingContainer)
        let closed = TestWindow.new(id: 2, parent: tab.rootTilingContainer)
        let draft = TestWindow.new(id: 3, parent: tab)
        AuxiliaryWindowRegistry.shared.restore(3, pid: draft.app.pid, role: .mailCompose, parentWindowId: 2)
        var registry: [UInt32: FakeLivenessWindow] = [1: .init((1, .success)), 2: .init((nil, .noValue)), 3: .init((3, .success))]

        let kept = refresh(&registry, listed: [1, 3])
        for window in [live, closed, draft] where !kept.contains(window.windowId) { letGoOfGoneWindow(window) }
        XCTAssertFalse(closed.isBound)
        XCTAssertEqual(workspaceTabMembers(tab).map(\.window.windowId).sorted(), [1, 3])
        XCTAssertNil(AuxiliaryWindowRegistry.shared.parentWindowId(of: draft), "Its draft stays, as a window of its own")
        XCTAssertTrue(live.isBound)
    }

    /// A window a pin lends into a pinned split, and the split's other window, both closed (one on screen that its app no
    /// longer lists, one the window server no longer lists): no pin lends either any more, and the split doesn't bring
    /// either back. The split is still pinned, with none.
    func testAClosedWindowLentByAPinOrInAPinnedSplitLeavesBoth() throws {
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        defer { workspaceSidebarOrganizationStore = .init(); config = defaultConfig }
        let pin = Workspace.get(byName: "telegram")
        let telegram = TestWindow.new(id: 3269, parent: pin.rootTilingContainer)
        let split = Workspace.get(byName: "work")
        let slack = TestWindow.new(id: 11074, parent: split.rootTilingContainer)
        try setWorkspaceSidebarTabsFavorite([pin], true)
        try splitPinnedTabWindowWithTab(pin, "work", placement: .left)
        try setWorkspaceSidebarTabFavorite(split, true)
        XCTAssertTrue(workspaceSidebarLentWindow(of: pin) === telegram)
        XCTAssertTrue(pinMentions("telegram", 3269) && pinMentions("work", 3269) && pinMentions("work", 11074))

        var registry: [UInt32: FakeLivenessWindow] = [3269: .init((nil, .illegalArgument)), 11074: .init((nil, .noValue))]
        let kept = refresh(&registry, listed: [3269, 1], shown: [3269], appLists: [1])
        XCTAssertEqual(kept, [])
        for window in [telegram, slack] { letGoOfGoneWindow(window) }

        XCTAssertNil(workspaceSidebarLentWindow(of: pin))
        XCTAssertNil(workspaceSidebarOrganizationStore.state.workspaces["telegram"]?.lentWindow, "Not lent any more")
        for (name, windowId) in [("telegram", UInt32(3269)), ("work", 3269), ("work", 11074)] {
            XCTAssertFalse(pinMentions(name, windowId), "\(name) no longer mentions \(windowId)")
        }
        XCTAssertTrue(workspaceSidebarIsPinned(split), "Still a pinned split")
    }

    private func pinMentions(_ name: String, _ windowId: UInt32) -> Bool {
        guard let appearance = workspaceSidebarOrganizationStore.state.workspaces[name] else { return false }
        return appearance.lentWindow?.windowId == windowId
            || appearance.composition?.layout.contains { $0.windowId == windowId } == true
            || appearance.composition?.away.contains { $0.window.windowId == windowId } == true
    }

    // MARK: Live windows stay

    /// The 0.6.408 protection: a busy app answers nothing in time, and its window is still there.
    func testABusyAppsLiveWindowStaysWhileTheWindowServerListsIt() {
        var registry: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow((nil, .cannotComplete))]
        XCTAssertEqual(refresh(&registry, listed: [7], times: 5), [7])
    }

    /// Windows that aren't on screen (minimized, a hidden app's, on another Space or in a full-screen Space) still
    /// resolve to their ids over AX, as upstream AeroSpace has relied on; a busy app's may time out, and `.optionAll`
    /// lists them. Either way they stay.
    func testMinimizedHiddenAndOtherSpaceWindowsStay() {
        var registry: [UInt32: FakeLivenessWindow] = [10: .init((10, .success)), 11: .init((nil, .cannotComplete))]
        XCTAssertEqual(refresh(&registry, listed: [10, 11], times: 5), [10, 11])
    }

    /// Behind the lock screen nothing is let go, whatever windows answer.
    func testALockScreenInFrontKeepsWindowsWhateverTheyAnswer() {
        var registry: [UInt32: FakeLivenessWindow] = [7: .init((nil, .noValue)), 8: .init((nil, .cannotComplete))]
        XCTAssertEqual(refresh(&registry, listed: [1], frontmost: lockScreenAppBundleId, times: 5), [7, 8])
    }

    /// AX vouches for it, and the window server has it (on screen or not), or there's no list: it stays. (Missing from
    /// the window server's list, it closed, whatever AX vouches: `testAGhostAnElementBringsBackGoesOnceTheWindowServerLetsItGo`.)
    func testAWindowAxVouchesForStaysWhileTheWindowServerHasIt() {
        for listed: Set<UInt32>? in [[7, 1], nil] {
            var registry: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow((7, .success))]
            XCTAssertEqual(refresh(&registry, listed: listed, times: 5), [7], "listed \(String(describing: listed))")
        }
    }

    func testAnInvalidElementIsLetGoAtOnce() {
        var registry: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow((nil, .invalidUIElement))]
        XCTAssertEqual(refresh(&registry, listed: [1]), [])
    }

    // MARK: Only on evidence this session gives (Astra's and Carbon's reviews, 2026-11-14)

    /// No window list to go by (the screen locked after the refresh looked at the frontmost app, another user's session):
    /// nothing is let go, whatever windows answer.
    func testWithoutAWindowListNothingIsLetGo() {
        for error: AXError in [.success, .noValue, .illegalArgument, .attributeUnsupported, .invalidUIElement] {
            var registry: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow((nil, error))]
            XCTAssertEqual(refresh(&registry, listed: nil, appLists: [1]), [7], "\(error)")
        }
    }

    /// The window server still lists it, off screen (another Space, a full-screen Space not shown, minimized, ordered out:
    /// where the app's AXWindows doesn't look), or on screen while its app's list couldn't be read: not proof of a close,
    /// so it's kept, unbound, for the next refresh. On screen and left out of a list read in full, it's gone.
    func testAWindowTheWindowServerListsIsKeptUnlessItsOnScreenAndItsAppLeavesItOut() {
        for appLists: [UInt32]? in [[], [1], nil] {
            var offScreen: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow((nil, .illegalArgument))]
            let kept = refreshWindowLiveness(&offScreen, listed: [7, 1], appLists: appLists)
            XCTAssertEqual(kept.kept, [7], "Off screen, app lists \(String(describing: appLists))")
            XCTAssertEqual(kept.unbound, [7])
        }
        var unread: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow((nil, .illegalArgument))]
        XCTAssertEqual(refreshWindowLiveness(&unread, listed: [7, 1], shown: [7], appLists: nil).unbound, [7],
            "On screen, its app's list not read")
        var onScreen: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow((nil, .illegalArgument))]
        XCTAssertEqual(refresh(&onScreen, listed: [7, 1], shown: [7], appLists: [1]), [], "On screen, its app leaves it out")
    }

    // MARK: Guards on a busy app's window

    func testOneAbsenceIsntEnoughTwoInARowAre() {
        var registry: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow((nil, .cannotComplete))]
        XCTAssertEqual(refresh(&registry, listed: [1]), [7], "Missing once")
        XCTAssertEqual(refresh(&registry, listed: [7]), [7], "Listed again: the count starts over")
        XCTAssertEqual(refresh(&registry, listed: [1]), [7])
        XCTAssertEqual(refresh(&registry, listed: [1]), [], "Missing twice in a row")
    }

    func testNoListOrAnEmptyOneSaysNothing() {
        var registry: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow((nil, .cannotComplete))]
        XCTAssertEqual(refresh(&registry, listed: nil, times: 5), [7])
        XCTAssertEqual(refresh(&registry, listed: [], times: 5), [7])
        XCTAssertEqual(refresh(&registry, listed: [1], times: 2), [], "A real list, missing twice")
    }

    func testAbsencesBehindTheLockScreenDontCount() {
        var registry: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow((nil, .cannotComplete))]
        XCTAssertEqual(refresh(&registry, listed: [1]), [7])
        XCTAssertEqual(refresh(&registry, listed: [1], frontmost: lockScreenAppBundleId, times: 3), [7])
        XCTAssertEqual(refresh(&registry, listed: [1]), [], "The lock screen neither counted nor reset it")
    }

    /// The second look isn't left to whatever event comes next: the first absence asks for a refresh of its own.
    func testAFirstAbsenceAsksForAConfirmingRefresh() {
        var registry: [UInt32: FakeLivenessWindow] = [7: .init((nil, .cannotComplete)), 8: .init((8, .success))]
        XCTAssertTrue(refreshWindowLiveness(&registry, listed: [8]).confirming)
        let second = refreshWindowLiveness(&registry, listed: [8])
        XCTAssertEqual(second.kept, [8])
        XCTAssertFalse(second.confirming, "Nothing left to confirm")
        var unlisted: [UInt32: FakeLivenessWindow] = [7: FakeLivenessWindow((nil, .cannotComplete))]
        XCTAssertFalse(refreshWindowLiveness(&unlisted, listed: nil).confirming, "No list: nothing to confirm, no refresh loop")
    }

    /// A list from a session that isn't on the console, or whose screen is locked, isn't this user's windows to go by.
    func testTheWindowServerListSaysNothingOffTheConsoleOrWithTheScreenLocked() {
        let windows: [[String: Any]] = [[kCGWindowNumber as String: UInt32(5)], [kCGWindowNumber as String: UInt32(6)]]
        XCTAssertEqual(livenessWindowList(session: [kCGSessionOnConsoleKey as String: true], windows: windows), [5, 6])
        XCTAssertNil(livenessWindowList(session: [kCGSessionOnConsoleKey as String: false], windows: windows))
        XCTAssertNil(livenessWindowList(session: [kCGSessionOnConsoleKey as String: true, "CGSSessionScreenIsLocked": true],
            windows: windows))
        XCTAssertNil(livenessWindowList(session: nil, windows: windows))
        XCTAssertNil(livenessWindowList(session: [kCGSessionOnConsoleKey as String: true], windows: nil))
    }
}
