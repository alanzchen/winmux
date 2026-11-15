@testable import AppBundle
import AppKit
import XCTest

/// Alan's lingering sidebar members (2026-11-14) were WeChat, FaceTime, Telegram and Activity Monitor windows: apps that
/// keep a window they close, ordered out, while its AX element answers for nothing. Such a window isn't closed, and
/// isn't presentable: out of its tab, its layout and the sidebar, still registered with its pin, its pinned split and its
/// auxiliary links, back where it was once it can be shown, and let go only on evidence that it closed. Synthetic: what
/// AX, the app's window list and the window server say are given.
@MainActor
final class NotPresentableWindowTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        AuxiliaryWindowRegistry.shared.removeAll()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        AuxiliaryWindowRegistry.shared.removeAll()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    // MARK: Hidden on close

    /// The window server lists it, ordered out; its element answers for nothing and its app doesn't list it. On the first
    /// refresh it leaves its tab, the layout and the sidebar, and its tab, left with no window, isn't listed. It isn't let
    /// go: still registered, and its tab is kept for it.
    func testAHideOnCloseGhostLeavesTheSidebarOnTheFirstRefresh() async throws {
        let wechat = Workspace.get(byName: "wechat")
        let ghost = TestWindow.new(id: 3269, parent: wechat.rootTilingContainer)
        let other = Workspace.get(byName: "other")
        _ = TestWindow.new(id: 1, parent: other.rootTilingContainer)
        var registry: [UInt32: FakeLivenessWindow] = [3269: .init((nil, .illegalArgument)), 1: .init((1, .success))]

        let refreshed = try await refreshPresentability(&registry, listed: [3269, 1], shown: [1], orderedOut: [3269],
            appLists: [(1, .init((1, .success)))])

        XCTAssertEqual(refreshed.dead.count, 0, "Not let go")
        XCTAssertNotNil(registry[3269], "Still registered")
        XCTAssertTrue(ghost.isNotPresentable)
        XCTAssertTrue(ghost.parent === macosNotPresentableWindowsContainer, "Out of its tab and its layout")
        XCTAssertEqual(workspaceTabMembers(wechat).count, 0, "No row in the sidebar")
        XCTAssertFalse(workspaceTabIsShown(wechat), "Its tab, left with no window, isn't listed")
        XCTAssertEqual(workspaceTabMembers(other).map(\.window.windowId), [1])
        Workspace.reconcileWorkspaceState()
        XCTAssertNotNil(Workspace.existing(byName: "wechat"), "Its tab is kept for it")
        XCTAssertTrue(Window.get(byId: 3269) === ghost)
    }

    // MARK: Controls

    /// Ordered out too, or off screen, but presentable: a minimized window (known minimized), a hidden app's window, a
    /// window on another Space and one in a full-screen Space (both ordered in), and a busy app's live window. Each
    /// stays in its tab and the sidebar.
    func testMinimizedHiddenOtherSpaceFullscreenAndBusyWindowsStayVisible() async throws {
        let tab = Workspace.get(byName: "controls")
        let minimized = TestWindow.new(id: 10, parent: tab.rootTilingContainer)
        minimized.recordObservedNativeState(fullscreen: false, minimized: true, token: minimized.nativeStateObservationToken())
        let hidden = TestWindow.new(id: 11, parent: tab.rootTilingContainer)
        let otherSpace = TestWindow.new(id: 12, parent: tab.rootTilingContainer)
        let fullscreen = TestWindow.new(id: 13, parent: tab.macOsNativeFullscreenWindowsContainer)
        fullscreen.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: tab.name)
        fullscreen.recordObservedNativeState(fullscreen: true, minimized: false, token: fullscreen.nativeStateObservationToken())
        let busy = TestWindow.new(id: 14, parent: tab.rootTilingContainer)
        let stale: (CGWindowID?, AXError) = (nil, .illegalArgument)

        // One refresh per app, as each app has its own.
        var minimizedApp: [UInt32: FakeLivenessWindow] = [10: .init(stale)]
        try await refreshPresentability(&minimizedApp, listed: [10], orderedOut: [10])
        var hiddenApp: [UInt32: FakeLivenessWindow] = [11: .init(stale)]
        try await refreshPresentability(&hiddenApp, listed: [11], orderedOut: [11], appHidden: true)
        var otherSpaceApp: [UInt32: FakeLivenessWindow] = [12: .init(stale), 13: .init(stale)]
        try await refreshPresentability(&otherSpaceApp, listed: [12, 13])
        var busyApp: [UInt32: FakeLivenessWindow] = [14: .init((nil, .cannotComplete))]
        try await refreshPresentability(&busyApp, listed: [14], orderedOut: [14])

        for window in [minimized, hidden, otherSpace, fullscreen, busy] {
            XCTAssertFalse(window.isNotPresentable, "\(window.windowId)")
        }
        XCTAssertTrue(minimized.parent === macosMinimizedWindowsContainer, "Minimized, as macOS has it")
        let members = Dictionary(uniqueKeysWithValues: workspaceTabMembers(tab).map { ($0.window.windowId, $0.state) })
        XCTAssertEqual(members.filter { $0.key != 10 }, [11: .laidOut, 12: .laidOut, 13: .nativeFullscreen, 14: .laidOut])
        XCTAssertEqual(minimizedApp.count + hiddenApp.count + otherSpaceApp.count + busyApp.count, 5, "None let go")
    }

    /// Whether it's ordered in can't be told (the private call isn't there): presentable, and never let go for it.
    func testWithoutThePrivateCallAWindowIsPresentable() async throws {
        let tab = Workspace.get(byName: "wechat")
        let window = TestWindow.new(id: 3269, parent: tab.rootTilingContainer)
        var registry: [UInt32: FakeLivenessWindow] = [3269: .init((nil, .illegalArgument))]
        let refreshed = try await refreshPresentability(&registry, listed: [3269], orderingUnknown: true)
        XCTAssertEqual(refreshed.presentable, [3269: true])
        XCTAssertEqual(refreshed.dead.count, 0)
        XCTAssertFalse(window.isNotPresentable)
        XCTAssertEqual(workspaceTabMembers(tab).map(\.window.windowId), [3269])
    }

    // MARK: Back where it was

    /// Telegram, lent by its pin into a split with Slack, with a preview opened from it: set aside, the pin still lends
    /// it, the split's record and the preview's link still name it, and a click on the pin doesn't try to bring it back.
    /// Ordered in again, it's back in the split in its place, still lent by its pin.
    func testOrderedInAgainAWindowComesBackWithItsPinSplitAndLinks() async throws {
        let pin = Workspace.get(byName: "telegram")
        let telegram = TestWindow.new(id: 3269, parent: pin.rootTilingContainer)
        let split = Workspace.get(byName: "work")
        _ = TestWindow.new(id: 11074, parent: split.rootTilingContainer)
        let preview = TestWindow.new(id: 4000, parent: split)
        AuxiliaryWindowRegistry.shared.restore(4000, pid: preview.app.pid, role: .windowRule, parentWindowId: 3269)
        try setWorkspaceSidebarTabsFavorite([pin], true)
        try splitPinnedTabWindowWithTab(pin, "work", placement: .left)
        try setWorkspaceSidebarTabFavorite(split, true)
        let members = workspaceTabMembers(split).map(\.window.windowId)
        XCTAssertEqual(members, [3269, 11074, 4000])
        var registry: [UInt32: FakeLivenessWindow] = [
            3269: .init((nil, .illegalArgument)), 11074: .init((11074, .success)), 4000: .init((4000, .success)),
        ]
        let appLists: [(UInt32, FakeLivenessWindow)] = [(11074, .init((11074, .success))), (4000, .init((4000, .success)))]

        try await refreshPresentability(&registry, listed: [3269, 11074, 4000], shown: [11074, 4000], orderedOut: [3269],
            appLists: appLists)
        syncWorkspaceSidebarPinCompositions()
        XCTAssertTrue(telegram.parent === macosNotPresentableWindowsContainer)
        XCTAssertEqual(workspaceTabMembers(split).map(\.window.windowId), [11074, 4000])
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces["telegram"]?.lentWindow?.windowId, 3269, "Still lent")
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces["work"]?.composition?.layout.contains { $0.windowId == 3269 },
            true, "Still in the split's record")
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.parentWindowId(of: preview), 3269, "Its preview's link stands")
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(pin), .nothing, "Nothing to bring back while it can't be shown")
        var models = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:], availableMonitors: monitors)
        XCTAssertNil(models.first { $0.name == "telegram" }?.lentWindow, "No row for it under its pin")
        XCTAssertFalse(sidebarWindowIds(models.first { $0.name == "work" }).contains(3269), "Nor in the split")

        // Ordered in again, its element still stale and its app's list not caught up yet.
        let back = try await refreshPresentability(&registry, listed: [3269, 11074, 4000], shown: [3269, 11074, 4000],
            appLists: appLists)
        XCTAssertEqual(back.dead.count, 0, "Not let go for a list that hasn't caught up")
        XCTAssertFalse(telegram.isNotPresentable)
        XCTAssertEqual(workspaceTabMembers(split).map(\.window.windowId), members, "Back in its place")
        XCTAssertTrue(split.rootTilingContainer.allLeafWindowsRecursive.first === telegram)
        XCTAssertTrue(workspaceSidebarLentWindow(of: pin) === telegram, "Still lent by its pin")
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.parentWindowId(of: preview), 3269)
        models = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:], availableMonitors: monitors)
        XCTAssertEqual(models.first { $0.name == "telegram" }?.lentWindow?.windowId, 3269, "Its row under its pin is back")
    }

    private func sidebarWindowIds(_ model: WorkspaceSidebarWorkspaceViewModel?) -> [UInt32] {
        guard let model else { return [] }
        func ids(_ items: [WorkspaceSidebarItemViewModel]) -> [UInt32] {
            items.flatMap { item -> [UInt32] in
                switch item.kind {
                    case .window(let window): [window.windowId]
                    default: []
                }
            }
        }
        return ids(model.items) + model.offscreenMembers.map(\.windowId) + (model.lentWindow.map { [$0.windowId] } ?? [])
    }

    /// A tab's contents moved to another tab: a window set aside goes with them, and comes back to the other tab.
    func testATabsContentsMovedTakeItsSetAsideWindowAlong() async throws {
        let from = Workspace.get(byName: "from")
        let window = TestWindow.new(id: 66, parent: from.rootTilingContainer)
        var registry: [UInt32: FakeLivenessWindow] = [66: .init((nil, .illegalArgument))]
        try await refreshPresentability(&registry, listed: [66, 1], orderedOut: [66])
        let to = Workspace.get(byName: "to")
        moveWorkspaceContents(from: from, to: to)
        XCTAssertEqual(workspaceOwnedNotPresentableWindows(to).map(\.windowId), [66])
        XCTAssertEqual(workspaceOwnedNotPresentableWindows(from).count, 0)
        try await refreshPresentability(&registry, listed: [66, 1])
        XCTAssertTrue(window.nodeWorkspace === to)
    }

    /// A fresh element for it (its app lists it again): rebound, presentable, and back in its tab.
    func testAFreshElementBringsItBack() async throws {
        let tab = Workspace.get(byName: "facetime")
        let window = TestWindow.new(id: 77, parent: tab.rootTilingContainer)
        _ = TestWindow.new(id: 78, parent: tab.rootTilingContainer)
        var registry: [UInt32: FakeLivenessWindow] = [77: .init((nil, .noValue)), 78: .init((78, .success))]
        try await refreshPresentability(&registry, listed: [77, 78], shown: [78], orderedOut: [77])
        XCTAssertTrue(window.parent === macosNotPresentableWindowsContainer)
        let fresh = FakeLivenessWindow((77, .success))
        try await refreshPresentability(&registry, listed: [77, 78], shown: [77, 78], orderedOut: [77], appLists: [(77, fresh)])
        XCTAssertTrue(registry[77] === fresh)
        XCTAssertFalse(window.isNotPresentable)
        XCTAssertEqual(tab.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [77, 78], "Back where it was")
    }

    // MARK: Let go only on evidence

    /// Set aside, it stays registered refresh after refresh while the window server lists it ordered out; once the window
    /// server no longer lists it, it closed, and goes as any closed window does.
    func testANotPresentableWindowGoesOnlyOnEvidenceItClosed() async throws {
        let tab = Workspace.get(byName: "monitor")
        let window = TestWindow.new(id: 55, parent: tab.rootTilingContainer)
        var registry: [UInt32: FakeLivenessWindow] = [55: .init((nil, .illegalArgument))]
        for _ in 0 ..< 3 {
            let refreshed = try await refreshPresentability(&registry, listed: [55, 1], orderedOut: [55], appLists: [])
            XCTAssertEqual(refreshed.dead.count, 0)
        }
        XCTAssertTrue(window.isNotPresentable)
        let closed = try await refreshPresentability(&registry, listed: [1], appLists: [])
        XCTAssertEqual(Set(closed.dead.keys), [55])
        letGoOfGoneWindow(window)
        XCTAssertFalse(window.isBound)
        XCTAssertNil(Window.get(byId: 55))
    }

    // MARK: What a refresh can tell

    /// Said for windows a refresh can tell about: shown for one AX resolves, one rebound, one ordered in, or with no
    /// ordering known; not shown for one ordered out whose element answers for nothing. Nothing said of a busy app's
    /// window, a hidden app's, one with no window list to go by, or one let go.
    func testPresentabilityIsSaidOnlyWhereARefreshCanTell() throws {
        func decide(_ registered: [UInt32: FakeLivenessWindow], _ windowServer: WindowServerWindowList,
                    appLists: [(UInt32, FakeLivenessWindow)]? = [], appHidden: Bool = false) throws -> [UInt32: Bool]
        {
            try refreshRegisteredAxWindows(registered, frontmostAppBundleId: nil, windowServer: windowServer, listed: { appLists },
                rebind: { _, fresh in fresh }, register: { _, _, _ in }, appHidden: appHidden, RunLoopJob()).presentable
        }
        let stale: (CGWindowID?, AXError) = (nil, .illegalArgument)
        XCTAssertEqual(try decide([1: .init((1, .success)), 2: .init(stale), 3: .init(stale), 4: .init(stale), 5: .init(stale)],
            livenessWindowServer(listed: [1, 2, 3, 4], orderedOut: [3]), appLists: [(4, .init((4, .success)))]),
            [1: true, 2: true, 3: false, 4: true], "Alive, ordered in, ordered out, rebound; 5 let go")
        XCTAssertEqual(try decide([3: .init(stale)], livenessWindowServer(listed: [3], orderedOut: [3]), appHidden: true), [:],
            "A hidden app's windows are all ordered out: not told")
        XCTAssertEqual(try decide([3: .init(stale)], livenessWindowServer(listed: [3], orderingUnknown: true)), [3: true])
        XCTAssertEqual(try decide([3: .init((nil, .cannotComplete))], livenessWindowServer(listed: [3], orderedOut: [3])), [:])
        XCTAssertEqual(try decide([3: .init(stale)], livenessWindowServer(listed: nil)), [:])
    }

    /// Noted: not presentable as the refresh says, unless known minimized or already minimized; presentable again as it
    /// says; a window it said nothing of keeps what it had.
    func testPresentabilityIsNotedUnlessTheWindowIsKnownMinimized() {
        let tab = Workspace.get(byName: "notes")
        let (a, b, c) = (TestWindow.new(id: 1, parent: tab.rootTilingContainer), TestWindow.new(id: 2, parent: tab.rootTilingContainer),
                         TestWindow.new(id: 3, parent: tab.rootTilingContainer))
        b.recordObservedNativeState(fullscreen: false, minimized: true, token: b.nativeStateObservationToken())
        c.isNotPresentable = true
        noteWindowPresentability([1: false, 2: false])
        XCTAssertTrue(a.isNotPresentable)
        XCTAssertFalse(b.isNotPresentable, "Known minimized")
        XCTAssertTrue(c.isNotPresentable, "Not said: as it was")
        noteWindowPresentability([1: true, 3: true])
        XCTAssertFalse(a.isNotPresentable)
        XCTAssertFalse(c.isNotPresentable)
    }
}

extension NotPresentableWindowTest {
    /// Shown again, it's back first; only from the next refresh is it judged like any window, so an app's list that
    /// still leaves it out on screen then is evidence it closed.
    func testAWindowShownAgainIsJudgedLikeAnyFromTheNextRefresh() async throws {
        let tab = Workspace.get(byName: "slack")
        let window = TestWindow.new(id: 90, parent: tab.rootTilingContainer)
        var registry: [UInt32: FakeLivenessWindow] = [90: .init((nil, .illegalArgument))]
        try await refreshPresentability(&registry, listed: [90, 1], orderedOut: [90])
        XCTAssertTrue(window.parent === macosNotPresentableWindowsContainer)
        let shown = try await refreshPresentability(&registry, listed: [90, 1], shown: [90])
        XCTAssertEqual(shown.dead.count, 0)
        XCTAssertEqual(tab.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [90], "Back")
        let next = try await refreshPresentability(&registry, listed: [90, 1], shown: [90])
        XCTAssertEqual(Set(next.dead.keys), [90], "On screen, its app's list read in full leaves it out: closed")
    }
}

// MARK: Alan's MacBook Pro, 2026-11-15T03:57Z (0.6.417)

extension NotPresentableWindowTest {
    /// Mail 18817 laid out, ChatGPT 18884 beside ChatGPT's live 18885 in another tab, Burnstate 16819 floating: each
    /// answering an illegal argument, its frame an invalid element, its app not listing it, not minimized or hidden.
    /// The window server decides. No longer listed: let go. Listed and ordered out: set aside, out of the sidebar.
    /// Listed and on screen, its app's list read in full leaving it out: let go. ChatGPT's live window stays where it is.
    func testAlansGhostsGoOrAreSetAsideBesideALiveWindowOfTheSameApp() async throws {
        let stale: (CGWindowID?, AXError) = (nil, .illegalArgument)
        for state in ["no longer listed", "listed, ordered out", "listed, on screen"] {
            setUpWorkspacesForTests()
            let (mailTab, chatTab, liveTab, burnTab) = (Workspace.get(byName: "26"), Workspace.get(byName: "12"),
                                                        Workspace.get(byName: "27"), Workspace.get(byName: "28"))
            let mail = TestWindow.new(id: 18817, parent: mailTab.rootTilingContainer)
            let chat = TestWindow.new(id: 18884, parent: chatTab.rootTilingContainer)
            let live = TestWindow.new(id: 18885, parent: liveTab.rootTilingContainer)
            let burn = TestWindow.new(id: 16819, parent: burnTab)
            let ghosts: [Window] = [mail, chat, burn]
            let ids: Set<UInt32> = [18817, 18884, 16819]
            let listed: Set<UInt32> = state == "no longer listed" ? [18885] : ids.union([18885])
            let shown: Set<UInt32> = state == "listed, on screen" ? ids.union([18885]) : [18885]
            let orderedOut: Set<UInt32> = state == "listed, ordered out" ? ids : []

            var mailApp: [UInt32: FakeLivenessWindow] = [18817: .init(stale)]
            var chatApp: [UInt32: FakeLivenessWindow] = [18884: .init(stale), 18885: .init((18885, .success))]
            var burnApp: [UInt32: FakeLivenessWindow] = [16819: .init(stale)]
            var dead: Set<UInt32> = []
            dead.formUnion(try await refreshPresentability(&mailApp, listed: listed, shown: shown, orderedOut: orderedOut,
                appLists: []).dead.keys)
            dead.formUnion(try await refreshPresentability(&chatApp, listed: listed, shown: shown, orderedOut: orderedOut,
                appLists: [(18885, .init((18885, .success)))]).dead.keys)
            dead.formUnion(try await refreshPresentability(&burnApp, listed: listed, shown: shown, orderedOut: orderedOut,
                appLists: []).dead.keys)
            for window in ghosts where dead.contains(window.windowId) { letGoOfGoneWindow(window) }

            if state == "listed, ordered out" {
                XCTAssertEqual(dead, [], state)
                for window in ghosts {
                    XCTAssertTrue(window.parent === macosNotPresentableWindowsContainer, "\(state): \(window.windowId) set aside")
                }
            } else {
                XCTAssertEqual(dead, ids, state)
                for window in ghosts { XCTAssertFalse(window.isBound, "\(state): \(window.windowId) let go") }
            }
            for tab in [mailTab, chatTab, burnTab] {
                XCTAssertEqual(workspaceTabMembers(tab).count, 0, "\(state): \(tab.name) has no row")
                XCTAssertFalse(workspaceTabIsShown(tab), "\(state): \(tab.name) isn't listed")
            }
            XCTAssertEqual(chatApp.keys.contains(18885), true, state)
            XCTAssertTrue(live.parent === liveTab.rootTilingContainer, "\(state): ChatGPT's live window stays")
            XCTAssertFalse(live.isNotPresentable, state)
        }
    }

    /// Tabs mode lists no ordinary tab without a window, however its last one went: let go (closed), set aside (not
    /// presentable), or its app quit; nor a tab waiting for windows that never came back after a restart. The panel's
    /// own report agrees (`debugSnapshotRowsInPanel`), which until now named such a tab's row as shown. An empty pin is
    /// listed.
    func testNoOrdinaryTabWithoutAWindowIsListedHoweverItsLastWindowWent() async throws {
        let closedTab = Workspace.get(byName: "9")
        let closed = TestWindow.new(id: 14550, parent: closedTab.rootTilingContainer)
        let setAsideTab = Workspace.get(byName: "14")
        _ = TestWindow.new(id: 10805, parent: setAsideTab.rootTilingContainer)
        let quitTab = Workspace.get(byName: "quit")
        let quitApp = TestApp(pid: 4242, bundleId: "com.example.quits")
        let quitWindows = [TestWindow.new(id: 31, parent: quitTab.rootTilingContainer, app: quitApp),
                           TestWindow.new(id: 32, parent: quitTab.rootTilingContainer, app: quitApp)]
        let waitingTab = Workspace.get(byName: "waiting")
        let pin = Workspace.get(byName: "23")
        try setWorkspaceSidebarTabsFavorite([pin], true)
        _ = TestWindow.new(id: 1, parent: Workspace.get(byName: "kept").rootTilingContainer)

        var closedApp: [UInt32: FakeLivenessWindow] = [14550: .init((nil, .illegalArgument))]
        let refreshed = try await refreshPresentability(&closedApp, listed: [1], appLists: [])
        XCTAssertEqual(Set(refreshed.dead.keys), [14550])
        letGoOfGoneWindow(closed)
        var setAsideApp: [UInt32: FakeLivenessWindow] = [10805: .init((nil, .illegalArgument))]
        try await refreshPresentability(&setAsideApp, listed: [10805, 1], orderedOut: [10805], appLists: [])
        // Its app quit: what refresh does for a terminated app's windows, after MacApp.destroy.
        forgetWorkspaceSidebarPinWindows { $0.pid == quitApp.pid }
        for window in quitWindows { letGoOfGoneWindow(window) }
        Workspace.reconcileWorkspaceState()

        let models = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:], availableMonitors: monitors)
        let inPanel = debugSnapshotRowsInPanel(models)
        for tab in [closedTab, setAsideTab, quitTab, waitingTab] {
            XCTAssertFalse(workspaceTabIsShown(tab), "\(tab.name)")
            if let row = models.first(where: { $0.name == tab.name }) { XCTAssertTrue(row.isLeftEmpty, "\(tab.name)") }
            XCTAssertFalse(inPanel.contains(tab.name), "\(tab.name): not reported as shown")
        }
        XCTAssertTrue(workspaceTabIsShown(pin))
        XCTAssertTrue(inPanel.contains("23"), "The empty pin is listed")
        XCTAssertTrue(inPanel.contains("kept"))
    }
}

// MARK: Re-review 3 (2026-11-15)

extension NotPresentableWindowTest {
    /// Three siblings, the first two set aside in turn (the second first), then brought back one refresh apart, the
    /// second first: each goes back between the same neighbours, in the original order.
    func testSiblingsSetAsideAndBroughtBackInAnyOrderKeepTheirOrder() async throws {
        let tab = Workspace.get(byName: "split")
        let (first, second, third) = (TestWindow.new(id: 101, parent: tab.rootTilingContainer),
                                      TestWindow.new(id: 102, parent: tab.rootTilingContainer),
                                      TestWindow.new(id: 103, parent: tab.rootTilingContainer))
        let stale: (CGWindowID?, AXError) = (nil, .illegalArgument)
        var registry: [UInt32: FakeLivenessWindow] = [101: .init(stale), 102: .init(stale), 103: .init((103, .success))]
        let listed: Set<UInt32> = [101, 102, 103]
        try await refreshPresentability(&registry, listed: listed, shown: [103], orderedOut: [102])
        try await refreshPresentability(&registry, listed: listed, shown: [103], orderedOut: [101, 102])
        XCTAssertTrue(first.parent === macosNotPresentableWindowsContainer && second.parent === macosNotPresentableWindowsContainer)
        XCTAssertEqual(tab.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [103])
        try await refreshPresentability(&registry, listed: listed, shown: [103], orderedOut: [101])
        XCTAssertEqual(tab.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [102, 103])
        try await refreshPresentability(&registry, listed: listed, shown: [103])
        XCTAssertEqual(tab.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [101, 102, 103])
        XCTAssertTrue(third.parent === tab.rootTilingContainer)
    }

    /// A reopen asked for its app (an empty pin clicked) while its window was set aside: shown again, the window goes
    /// where the reopen asked, not back to its old tab. It wasn't counted as a window the app already had.
    func testAWindowShownAgainByAReopenGoesWhereTheReopenAsked() async throws {
        let registry = NewWindowIntentRegistry.shared
        registry.resetForTests()
        defer { registry.resetForTests() }
        let old = Workspace.get(byName: "old")
        let window = TestWindow.new(id: 3269, parent: old.rootTilingContainer)
        var liveness: [UInt32: FakeLivenessWindow] = [3269: .init((nil, .illegalArgument))]
        try await refreshPresentability(&liveness, listed: [3269, 1], orderedOut: [3269])
        XCTAssertTrue(window.parent === macosNotPresentableWindowsContainer)
        let pin = Workspace.get(byName: "pin")
        let preexisting = windowIdsBeforeReopen(pid: window.app.pid, registered: [window], onScreen: { _ in [] })
        XCTAssertEqual(preexisting, [])
        XCTAssertFalse(runningAppHasWindows(pid: window.app.pid, windows: [window]))
        let bundleId = try XCTUnwrap(window.app.rawAppBundleId)
        XCTAssertNotNil(registry.register(bundleId: bundleId, pid: window.app.pid, targetWorkspace: pin,
            preexistingWindowIds: preexisting, focusGeneration: focusChangeGeneration, reopens: true))
        try await refreshPresentability(&liveness, listed: [3269, 1])
        XCTAssertTrue(window.nodeWorkspace === pin, "Where the reopen asked")
        XCTAssertFalse(registry.hasPendingIntents)
    }
}

extension NotPresentableWindowTest {
    /// A window joined the tab at its front while one was set aside: the one set aside goes back after the neighbour it
    /// had before, not at its old index.
    func testAWindowSetAsideGoesBackAfterItsNeighbourWhateverJoinedMeanwhile() async throws {
        let tab = Workspace.get(byName: "split")
        _ = TestWindow.new(id: 100, parent: tab.rootTilingContainer)
        _ = TestWindow.new(id: 101, parent: tab.rootTilingContainer)
        let setAside = TestWindow.new(id: 102, parent: tab.rootTilingContainer)
        var registry: [UInt32: FakeLivenessWindow] = [102: .init((nil, .illegalArgument))]
        try await refreshPresentability(&registry, listed: [100, 101, 102], orderedOut: [102])
        XCTAssertTrue(setAside.parent === macosNotPresentableWindowsContainer)
        TestWindow.new(id: 103, parent: tab.rootTilingContainer).bind(to: tab.rootTilingContainer, adaptiveWeight: 1, index: 0)
        try await refreshPresentability(&registry, listed: [100, 101, 102, 103])
        XCTAssertEqual(tab.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [103, 100, 101, 102])
    }

    /// The window server's list read after the app's lost the window (locked meanwhile, or the window gone): whether it
    /// can be shown isn't told on the ordering the private call gives then.
    func testAWindowTheListReadAfterItsAppsLostIsntToldAbout() throws {
        for after: [UInt32: Bool]? in [nil, [1: true]] {
            let reads = WindowServerReads([[7: true, 8: false, 1: true], after])
            let windowServer = WindowServerWindowList(orderedIn: { _ in false }, readWindows: { reads.next() })
            let refreshed = try refreshRegisteredAxWindows([7: FakeLivenessWindow((nil, .illegalArgument))], frontmostAppBundleId: nil,
                windowServer: windowServer, listed: { [(UInt32(1), FakeLivenessWindow((1, .success)))] },
                rebind: { _, fresh in fresh }, register: { _, _, _ in }, RunLoopJob())
            XCTAssertEqual(refreshed.presentable, [:], "after \(String(describing: after))")
            XCTAssertEqual(refreshed.dead.count, 0)
        }
    }
}

extension NotPresentableWindowTest {
    /// Only a tab a set-aside window left gives its display that way: a kept tab on screen with no window, none set
    /// aside, keeps it, as before.
    func testAKeptTabWithNoWindowSetAsideKeepsItsDisplay() throws {
        setSavedWorkspaceTestEnvironment()
        let other = focus.workspace
        _ = TestWindow.new(id: 1, parent: other.rootTilingContainer)
        let kept = Workspace.get(byName: "kept")
        try saveWorkspaceForSidebar(workspaceName: kept.name, displayName: "Kept")
        XCTAssertTrue(kept.focusWorkspace())
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(kept.isVisible)
        XCTAssertFalse(workspaceTabIsShown(kept))
        XCTAssertFalse(workspaceTabWasLeftEmptyBySetAside(kept))
        leaveTabsLeftEmptyOnScreen()
        XCTAssertTrue(kept.isVisible, "Kept, with nothing set aside: it stays on screen")
    }
}

// MARK: Re-review 4 (2026-11-15)

extension NotPresentableWindowTest {
    /// Carbon R4 nit 1: [X, A, B], A set aside, C joins between X and B, then B is set aside too and comes back first:
    /// B goes back after C, which joined before it, not after X.
    func testAWindowSetAsideAfterASiblingKeepsWhatJoinedInBetween() async throws {
        let tab = Workspace.get(byName: "split")
        _ = TestWindow.new(id: 1, parent: tab.rootTilingContainer)
        let a = TestWindow.new(id: 2, parent: tab.rootTilingContainer)
        let b = TestWindow.new(id: 3, parent: tab.rootTilingContainer)
        let stale: (CGWindowID?, AXError) = (nil, .illegalArgument)
        var registry: [UInt32: FakeLivenessWindow] = [2: .init(stale), 3: .init(stale)]
        try await refreshPresentability(&registry, listed: [1, 2, 3, 4], orderedOut: [2])
        XCTAssertTrue(a.parent === macosNotPresentableWindowsContainer)
        TestWindow.new(id: 4, parent: tab.rootTilingContainer).bind(to: tab.rootTilingContainer, adaptiveWeight: 1, index: 1)
        XCTAssertEqual(tab.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [1, 4, 3])
        try await refreshPresentability(&registry, listed: [1, 2, 3, 4], orderedOut: [2, 3])
        XCTAssertTrue(b.parent === macosNotPresentableWindowsContainer)
        try await refreshPresentability(&registry, listed: [1, 2, 3, 4], orderedOut: [2])
        XCTAssertEqual(tab.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [1, 4, 3])
    }

    /// Carbon R4 nit 2: a pin that took in a window of its own while the window it lent was set aside no longer lends
    /// that one once it's back.
    func testAPinHoldingAWindowOfItsOwnLendsNone() async throws {
        let pin = Workspace.get(byName: "telegram")
        let telegram = TestWindow.new(id: 3269, parent: pin.rootTilingContainer)
        let split = Workspace.get(byName: "work")
        _ = TestWindow.new(id: 11074, parent: split.rootTilingContainer)
        try setWorkspaceSidebarTabsFavorite([pin], true)
        try splitPinnedTabWindowWithTab(pin, "work", placement: .left)
        XCTAssertTrue(workspaceSidebarLentWindow(of: pin) === telegram)
        _ = TestWindow.new(id: 77, parent: pin.rootTilingContainer)
        XCTAssertNil(workspaceSidebarLentWindow(of: pin), "The pin has a window of its own")
    }
}

// MARK: Re-review 5 (2026-11-15): no cached native focus names a window set aside or brought back

extension NotPresentableWindowTest {
    /// Set aside, the window WinMux last saw macOS focus is forgotten as such, so its coming back is decided by the
    /// native focus read then, not skipped as already known.
    func testAWindowSetAsideIsForgottenAsTheLastNativeFocus() async throws {
        resetFocusCacheForTests()
        defer { resetFocusCacheForTests() }
        let tab = Workspace.get(byName: "chat")
        let window = TestWindow.new(id: 200, parent: tab.rootTilingContainer)
        _ = TestWindow.new(id: 100, parent: Workspace.get(byName: "main").rootTilingContainer)
        updateFocusCache(window)
        XCTAssertEqual(lastKnownNativeFocusedWindowIdForTests, 200)
        var registry: [UInt32: FakeLivenessWindow] = [200: .init((nil, .illegalArgument))]
        try await refreshPresentability(&registry, listed: [100, 200], orderedOut: [200])
        XCTAssertTrue(window.parent === macosNotPresentableWindowsContainer)
        XCTAssertNil(lastKnownNativeFocusedWindowIdForTests, "No cached native focus names a window set aside")
    }

    /// Brought back, it's forgotten as the last native focus too, whatever cached it meanwhile.
    func testAWindowBroughtBackIsForgottenAsTheLastNativeFocus() async throws {
        resetFocusCacheForTests()
        defer { resetFocusCacheForTests() }
        let tab = Workspace.get(byName: "chat")
        let window = TestWindow.new(id: 200, parent: tab.rootTilingContainer)
        var registry: [UInt32: FakeLivenessWindow] = [200: .init((nil, .illegalArgument))]
        try await refreshPresentability(&registry, listed: [1, 200], orderedOut: [200])
        XCTAssertTrue(window.parent === macosNotPresentableWindowsContainer)
        lastKnownNativeFocusedWindowIdForTests = 200
        try await refreshPresentability(&registry, listed: [1, 200])
        XCTAssertTrue(window.parent === tab.rootTilingContainer)
        XCTAssertNil(lastKnownNativeFocusedWindowIdForTests, "No cached native focus names a window brought back")
    }

    /// A refresh that brought back a window set aside syncs no focus back to macOS, whatever else would.
    func testARefreshThatBroughtBackAWindowSyncsNoFocusBack() {
        let window = TestWindow.new(id: 300, parent: Workspace.get(byName: "main").rootTilingContainer)
        XCTAssertTrue(shouldSyncFocusBackToMacOs(nativeFocused: window, frontmostActivationPolicy: .regular))
        XCTAssertFalse(shouldSyncFocusBackToMacOs(nativeFocused: window, frontmostActivationPolicy: .regular, broughtBackSetAside: true))
    }
}
