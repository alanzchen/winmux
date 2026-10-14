import AppKit
@testable import AppBundle
import Common
import XCTest

/// A tab whose windows all belong to it but none is on screen (hidden with their app, in native
/// full screen, or minimized from it) is listed as those windows, never as an empty tab, and closing
/// it closes them only once the user has agreed, knowing they're there.
@MainActor
final class WorkspaceSidebarTabMembersTest: XCTestCase {
    private var asked: [(message: String, informative: String)] = []
    private var answer = true
    private var notices: [String] = []
    private var savedConfirm: (@MainActor (String, String) -> Bool)!
    private var savedNotice: (@MainActor (String, String) -> Void)!
    private var savedCloseIO: (@MainActor (Window) -> WindowCloseIO?)!
    private var savedRestore: (@MainActor (Window) async -> Bool)!
    private var savedUnhide: (@MainActor (Window) async -> Bool)!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        savedConfirm = workspaceTabCloseConfirm
        savedNotice = workspaceSidebarPinRecallNotice
        savedCloseIO = workspaceTabCloseIO
        savedRestore = workspaceSidebarRestoreMinimizedWindow
        savedUnhide = workspaceSidebarUnhideWindow
        workspaceTabCloseConfirm = { [unowned self] message, informative in
            asked.append((message, informative))
            return answer
        }
        workspaceSidebarPinRecallNotice = { [unowned self] title, body in notices.append("\(title): \(body)") }
    }

    override func tearDown() async throws {
        workspaceTabCloseConfirm = savedConfirm
        workspaceSidebarPinRecallNotice = savedNotice
        workspaceTabCloseIO = savedCloseIO
        workspaceSidebarRestoreMinimizedWindow = savedRestore
        workspaceSidebarUnhideWindow = savedUnhide
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
        try await super.tearDown()
    }

    /// A fresh world for one case of a loop, in Tabs mode again.
    private func resetWorld() {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        notices = []
    }

    private func minimized(_ id: UInt32, from tab: Workspace) -> Window {
        let window = TestWindow.new(id: id, parent: macosMinimizedWindowsContainer)
        window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: tab.name)
        return window
    }

    private func viewModel(_ tab: Workspace) async -> WorkspaceSidebarWorkspaceViewModel? {
        await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:], availableMonitors: sortedMonitors)
            .first { $0.name == tab.name }
    }

    // MARK: - Membership and how the tab shows

    func testEveryWindowThatBelongsToATabIsItsMemberOnceInAStableOrder() {
        let tab = Workspace.get(byName: "members")
        let laidOut = TestWindow.new(id: 10, parent: tab.rootTilingContainer)
        let hidden = TestWindow.new(id: 11, parent: tab.macOsNativeHiddenAppsWindowsContainer)
        let full = TestWindow.new(id: 12, parent: tab.macOsNativeFullscreenWindowsContainer)
        let mini = minimized(13, from: tab)
        _ = minimized(14, from: Workspace.get(byName: "elsewhere"))

        let members = workspaceTabMembers(tab)
        XCTAssertEqual(members.map(\.window.windowId), [10, 11, 12, 13])
        XCTAssertEqual(members.map(\.state), [.laidOut, .hiddenWithApp, .nativeFullscreen, .minimized])
        XCTAssertTrue(workspaceTabOwns(tab, mini) && workspaceTabOwns(tab, hidden) && workspaceTabOwns(tab, full)
            && workspaceTabOwns(tab, laidOut))
        XCTAssertEqual(workspaceHasLifecycleWindows(tab), !members.isEmpty, "Listed exactly while it has members")
    }

    func testATabWithOnlyAWindowHiddenWithItsAppShowsThatWindowNotAnEmptyTab() async {
        let tab = Workspace.get(byName: "discord")
        _ = TestWindow.new(id: 151804, parent: tab.macOsNativeHiddenAppsWindowsContainer)
        XCTAssertTrue(workspaceTabIsShown(tab), "Still listed, as before")

        guard let model = await viewModel(tab) else { return XCTFail("The tab has a row") }
        XCTAssertEqual(model.items.count, 0, "Nothing of it is laid out")
        XCTAssertEqual(model.offscreenMembers.map(\.windowId), [151804])
        XCTAssertEqual(model.offscreenMembers.first?.state, .hiddenWithApp)
        guard case .offscreen(let members) = workspaceSidebarTabPresentation(model) else {
            return XCTFail("Shown as its window, not as an empty tab")
        }
        XCTAssertEqual(members.map(\.windowId), [151804])
    }

    func testMinimizedAndFullScreenOnlyTabsAreNotEmptyEither() async {
        let mini = Workspace.get(byName: "mini")
        _ = minimized(20, from: mini)
        let full = Workspace.get(byName: "full")
        _ = TestWindow.new(id: 21, parent: full.macOsNativeFullscreenWindowsContainer)
        for (tab, state) in [(mini, WorkspaceTabMemberState.minimized), (full, .nativeFullscreen)] {
            guard let model = await viewModel(tab) else { XCTFail("\(tab.name) has a row"); continue }
            guard case .offscreen(let members) = workspaceSidebarTabPresentation(model) else {
                XCTFail("\(tab.name) isn't an empty tab"); continue
            }
            XCTAssertEqual(members.map(\.state), [state])
        }
    }

    func testATabWithAWindowOnScreenKeepsItsPresentationAndAnEmptyTabStaysEmpty() async {
        let split = Workspace.get(byName: "split")
        _ = TestWindow.new(id: 30, parent: split.rootTilingContainer)
        _ = TestWindow.new(id: 31, parent: split.rootTilingContainer)
        _ = TestWindow.new(id: 32, parent: split.macOsNativeHiddenAppsWindowsContainer)
        guard let model = await viewModel(split) else { return XCTFail("The split has a row") }
        guard case .split = workspaceSidebarTabPresentation(model) else { return XCTFail("Its split stays as it was") }
        XCTAssertEqual(model.offscreenMembers.map(\.windowId), [32], "Known, not shown as a row of its own")

        let empty = Workspace.get(byName: "empty")
        XCTAssertFalse(workspaceTabIsShown(empty), "A really empty ordinary tab stays unlisted")
        XCTAssertTrue(workspaceTabMembers(empty).isEmpty)
    }

    func testItsMenuOffersClosingTheTabWithItsWindowsNotCloseEmptyTab() async {
        let tab = Workspace.get(byName: "discord")
        _ = TestWindow.new(id: 40, parent: tab.macOsNativeHiddenAppsWindowsContainer)
        guard let model = await viewModel(tab) else { return XCTFail("The tab has a row") }
        var sent: [WorkspaceSidebarAction] = []
        let menu = workspaceSidebarWorkspaceIdentityMenuModel(model) { sent.append($0) }
        let titles = (menu.entries + menu.trailingEntries).map(\.title)
        XCTAssertFalse(titles.contains("Close Empty Tab"))
        guard let close = menu.trailingEntries.first(where: { $0.title == "Close Tab and Its Windows…" }) else {
            return XCTFail("Its Close closes its windows")
        }
        close.perform?()
        XCTAssertEqual(sent, [.closeTabs([tab.name])])
    }

    // MARK: - Closing it closes all its windows, once agreed to

    func testClosingAskFirstSayingWhichWindowsArentOnScreenAndCancelClosesNothing() async {
        let tab = Workspace.get(byName: "discord")
        _ = TestWindow.new(id: 50, parent: tab.macOsNativeHiddenAppsWindowsContainer)
        var closed: [UInt32] = []
        answer = false
        await closeWorkspaceSidebarTabs([tab.name]) { closed.append($0.windowId); return true }?.value
        XCTAssertEqual(asked.count, 1, "One window, one tab, and still asked: it isn't on screen")
        XCTAssertTrue(asked[0].informative.contains("hidden with its app"))
        XCTAssertFalse(asked[0].informative.contains("150"), "Says the app and state, never a window's title")
        XCTAssertEqual(closed, [], "Cancel closes nothing")
        XCTAssertTrue(Workspace.existing(byName: tab.name) === tab)

        answer = true
        await closeWorkspaceSidebarTabs([tab.name]) { closed.append($0.windowId); return true }?.value
        XCTAssertEqual(closed, [50], "Agreed to, the hidden window is closed like any other")
    }

    func testClosingAMinimizedOnlyTabClosesItsWindowAndMentionsFullScreenSpaces() async {
        let mini = Workspace.get(byName: "mini")
        _ = minimized(60, from: mini)
        let full = Workspace.get(byName: "full")
        _ = TestWindow.new(id: 61, parent: full.macOsNativeFullscreenWindowsContainer)
        var closed: [UInt32] = []
        await closeWorkspaceSidebarTabs([mini.name, full.name]) { closed.append($0.windowId); return true }?.value
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].informative.contains("minimized"))
        XCTAssertTrue(asked[0].informative.contains("full-screen space"), "Closing it also ends its Space")
        XCTAssertEqual(closed, [60, 61], "A minimized window is the tab's too; before, its close skipped it")
    }

    func testAWindowThatJoinsTheTabAfterTheUserAgreedIsNotClosed() async {
        let tab = Workspace.get(byName: "discord")
        _ = TestWindow.new(id: 70, parent: tab.macOsNativeHiddenAppsWindowsContainer)
        var closed: [UInt32] = []
        workspaceTabCloseConfirm = { [unowned self] message, informative in
            asked.append((message, informative))
            // While the question is up, another window comes to the tab.
            _ = TestWindow.new(id: 71, parent: tab.rootTilingContainer)
            return true
        }
        await closeWorkspaceSidebarTabs([tab.name]) { closed.append($0.windowId); return true }?.value
        XCTAssertEqual(closed, [70], "Only the windows the user agreed to close")
        XCTAssertTrue(Workspace.existing(byName: tab.name) === tab, "The new window keeps its tab")
    }

    func testAWindowThatLeftTheScreenWithoutBeingAgreedToStaysOpen() async {
        let tab = Workspace.get(byName: "one")
        let window = TestWindow.new(id: 80, parent: tab.rootTilingContainer)
        var closed: [UInt32] = []
        let task = closeWorkspaceSidebarTabs([tab.name]) { closed.append($0.windowId); return true }
        XCTAssertEqual(asked.count, 0, "One window on screen in one tab: nothing to ask, as before")
        // Before the close runs, its app hides it.
        window.bind(to: tab.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        await task?.value
        XCTAssertEqual(closed, [], "Not closed out of sight without having asked")
        XCTAssertEqual(notices.count, 1)
    }

    func testCloseAllWindowsInASplitIncludesItsHiddenWindowAndAsks() async {
        let tab = Workspace.get(byName: "split")
        _ = TestWindow.new(id: 90, parent: tab.rootTilingContainer)
        _ = TestWindow.new(id: 91, parent: tab.rootTilingContainer)
        _ = TestWindow.new(id: 92, parent: tab.macOsNativeHiddenAppsWindowsContainer)
        answer = false
        closeWorkspaceSidebarTabWindows(tab.name)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].message.contains("3 windows"), "All three are the tab's")
        XCTAssertTrue(asked[0].informative.contains("hidden with its app"))
    }

    // MARK: - F1: each window closes only in the state the user agreed to close it in

    func testAWindowThatGoesFullScreenWhileTheQuestionIsUpIsLeftOpen() async {
        let tab = Workspace.get(byName: "mixed")
        _ = TestWindow.new(id: 100, parent: tab.macOsNativeHiddenAppsWindowsContainer)
        let normal = TestWindow.new(id: 101, parent: tab.rootTilingContainer)
        var closed: [UInt32] = []
        workspaceTabCloseConfirm = { [unowned self] message, informative in
            asked.append((message, informative))
            normal.bind(to: tab.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
            return true
        }
        await closeWorkspaceSidebarTabs([tab.name]) { closed.append($0.windowId); return true }?.value
        XCTAssertFalse(asked[0].informative.contains("full screen"), "Asked about a hidden window only")
        XCTAssertEqual(closed, [100], "The window now in full screen wasn't agreed to in full screen")
        XCTAssertEqual(notices.count, 1)
    }

    func testAWindowThatChangesStateBetweenClosesIsLeftOpen() async {
        let tab = Workspace.get(byName: "mixed")
        _ = TestWindow.new(id: 110, parent: tab.macOsNativeHiddenAppsWindowsContainer)
        let normal = TestWindow.new(id: 111, parent: tab.rootTilingContainer)
        let minimizedOne = minimized(112, from: tab)
        var closed: [UInt32] = []
        await closeWorkspaceSidebarTabs([tab.name]) { window in
            closed.append(window.windowId)
            if window.windowId == 111 {
                // While the first close waits, another window goes to full screen.
                minimizedOne.bind(to: tab.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER,
                    index: INDEX_BIND_LAST)
            }
            return true
        }?.value
        XCTAssertEqual(closed, [111, 110], "Laid out, then hidden; the minimized one went full screen meanwhile")
        XCTAssertTrue(normal.isBound)
    }

    func testAConfirmedHiddenWindowThatGoesFullScreenIsLeftOpen() async {
        let tab = Workspace.get(byName: "discord")
        let hidden = TestWindow.new(id: 120, parent: tab.macOsNativeHiddenAppsWindowsContainer)
        var closed: [UInt32] = []
        workspaceTabCloseConfirm = { [unowned self] message, informative in
            asked.append((message, informative))
            hidden.bind(to: tab.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
            return true
        }
        await closeWorkspaceSidebarTabs([tab.name]) { closed.append($0.windowId); return true }?.value
        XCTAssertEqual(closed, [])
        XCTAssertEqual(notices.count, 1)
    }

    func testTheFullScreenWarningIsGivenEvenBeyondTheWindowsListedByName() async {
        let tab = Workspace.get(byName: "many")
        for id in UInt32(130) ..< 138 { _ = TestWindow.new(id: id, parent: tab.macOsNativeHiddenAppsWindowsContainer) }
        _ = TestWindow.new(id: 138, parent: tab.macOsNativeFullscreenWindowsContainer)
        answer = false
        await closeWorkspaceSidebarTabs([tab.name]) { _ in true }?.value
        let text = asked[0].informative
        XCTAssertTrue(text.contains("8 hidden with their app, 1 in full screen"), text)
        XCTAssertTrue(text.contains("and 1 more"), "The ninth isn't listed by name")
        XCTAssertTrue(text.contains("Closing a window in full screen also ends its full-screen space."), text)
    }

    // MARK: - F2: only a window proven gone counts as closed

    private func io(presence: [WindowPresence], windowServer: Bool? = true, press: WindowClosePress = .pressed,
                    pressed: @escaping @MainActor (UInt32) -> Void, forgot: @escaping @MainActor (UInt32) -> Void)
        -> @MainActor (Window) -> WindowCloseIO?
    {
        { window in
            var answers = presence
            return WindowCloseIO(
                press: { isStillValid in
                    guard isStillValid() else { return .invalidated }
                    pressed(window.windowId)
                    return press
                },
                presence: { answers.count > 1 ? answers.removeFirst() : answers.first ?? .unknown },
                windowServerHasWindow: { windowServer },
                forget: { forgot(window.windowId) },
                timeout: 0.2, pause: {})
        }
    }

    func testAnUnreadableWindowListIsNotAClosedWindowAndStopsTheRest() async {
        let tab = Workspace.get(byName: "two")
        let first = TestWindow.new(id: 140, parent: tab.rootTilingContainer)
        _ = TestWindow.new(id: 141, parent: tab.rootTilingContainer)
        var pressed: [UInt32] = []
        var forgot: [UInt32] = []
        workspaceTabCloseIO = io(presence: [.unknown], pressed: { pressed.append($0) }, forgot: { forgot.append($0) })
        await closeWorkspaceSidebarTabs([tab.name])?.value
        XCTAssertEqual(pressed, [140], "The first close couldn't be told: nothing after it")
        XCTAssertEqual(forgot, [], "Not forgotten: it may be showing a save sheet")
        XCTAssertTrue(Window.get(byId: 140) === first)
        XCTAssertTrue(notices.last?.contains("couldn't tell") == true, "\(notices)")
    }

    func testEveryCloseOutcomeIsTakenForWhatItIs() async {
        let cases: [(String, [WindowPresence], Bool?, WindowClosePress, pressed: [UInt32], forgot: [UInt32])] = [
            ("a save sheet keeps it open", [.present], true, .pressed, [150], []),
            ("no close button", [.present], true, .notPressed, [150], []),
            ("gone from the app's list", [.present, .absent], true, .pressed, [150, 151], [150, 151]),
            ("app can't say, window server has no such window", [.unknown], false, .pressed, [150, 151], [150, 151]),
        ]
        for (label, presence, server, press, wantPressed, wantForgot) in cases {
            resetWorld()
            let tab = Workspace.get(byName: "two")
            _ = TestWindow.new(id: 150, parent: tab.rootTilingContainer)
            _ = TestWindow.new(id: 151, parent: tab.rootTilingContainer)
            var pressed: [UInt32] = []
            var forgot: [UInt32] = []
            workspaceTabCloseIO = io(presence: presence, windowServer: server, press: press,
                pressed: { pressed.append($0) }, forgot: { forgot.append($0) })
            await closeWorkspaceSidebarTabs([tab.name])?.value
            XCTAssertEqual(pressed, wantPressed, label)
            XCTAssertEqual(forgot, wantForgot, label)
        }
    }

    func testAMinimizedWindowThatWontCloseStopsItAndSaysSoWithoutShowingAnything() async {
        let tab = Workspace.get(byName: "mini")
        _ = minimized(160, from: tab)
        _ = minimized(161, from: tab)
        var pressed: [UInt32] = []
        workspaceTabCloseIO = io(presence: [.present], pressed: { pressed.append($0) }, forgot: { _ in })
        await closeWorkspaceSidebarTabs([tab.name])?.value
        XCTAssertEqual(pressed, [160])
        XCTAssertTrue(notices.last?.contains("minimized") == true && notices.last?.contains("didn't close") == true, "\(notices)")
    }

    // MARK: - F3: the agreement is checked again right before the press

    func testAPressWaitingForItsAppDoesntCloseAWindowThatMovedChangedOrWasReplaced() async throws {
        for change in ["moved to another tab", "went full screen", "replaced"] {
            resetWorld()
            let tab = Workspace.get(byName: "mixed")
            let waiting = TestWindow.new(id: 170, parent: tab.rootTilingContainer)
            _ = TestWindow.new(id: 171, parent: tab.rootTilingContainer)
            var gate: CheckedContinuation<Void, Never>?
            var pressed: [UInt32] = []
            var forgot: [UInt32] = []
            workspaceTabCloseIO = { window in
                WindowCloseIO(
                    press: { isStillValid in
                        if window.windowId == 170 { await withCheckedContinuation { gate = $0 } }
                        // The app's thread checks right before it presses.
                        guard isStillValid() else { return .invalidated }
                        pressed.append(window.windowId)
                        return .pressed
                    },
                    presence: { .absent }, windowServerHasWindow: { false },
                    forget: { forgot.append(window.windowId) }, timeout: 0.2, pause: {})
            }
            let task = closeWorkspaceSidebarTabs([tab.name])
            for _ in 0 ..< 200 where gate == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNotNil(gate, change)
            switch change {
                case "moved to another tab":
                    waiting.bind(to: Workspace.get(byName: "elsewhere").rootTilingContainer, adaptiveWeight: WEIGHT_AUTO,
                        index: INDEX_BIND_LAST)
                case "went full screen":
                    waiting.bind(to: tab.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER,
                        index: INDEX_BIND_LAST)
                default:
                    waiting.unbindFromParent()
            }
            gate?.resume()
            await task?.value
            XCTAssertEqual(pressed, [171], "\(change): never pressed; the other window still closes")
            XCTAssertEqual(forgot, [171], change)
            XCTAssertEqual(notices.last, "Some windows stayed open: A window moved or changed while the tab was closing, so it wasn't closed.",
                change)
        }
    }

    // MARK: - F5: bringing a window back doesn't override what changed meanwhile

    private func gatedRestore() -> (seam: @MainActor (Window) async -> Bool, release: () -> Void, reached: () -> Bool) {
        var gate: CheckedContinuation<Void, Never>?
        var reached = false
        return ({ _ in
            reached = true
            await withCheckedContinuation { gate = $0 }
            return true
        }, { gate?.resume() }, { reached })
    }

    func testRestoringAMinimizedOnlyTabShowsItUnlessItMovedOrTheUserChoseAnotherTab() async throws {
        for change in ["nothing", "moved to another tab", "another tab chosen"] {
            resetWorld()
            let tab = Workspace.get(byName: "mini")
            let window = minimized(180, from: tab)
            let start = Workspace.get(byName: "start")
            XCTAssertTrue(start.focusWorkspace())
            let restore = gatedRestore()
            workspaceSidebarRestoreMinimizedWindow = restore.seam
            let task = showWorkspaceSidebarOffscreenTab(tab.name, targetMonitorScopeId: nil)
            for _ in 0 ..< 200 where !restore.reached() { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(restore.reached(), change)
            let other = Workspace.get(byName: "chosen")
            switch change {
                case "moved to another tab":
                    window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: "elsewhere")
                case "another tab chosen":
                    XCTAssertTrue(other.focusWorkspace())
                default: break
            }
            restore.release()
            await task?.value
            switch change {
                case "nothing": XCTAssertTrue(focus.workspace === tab, "Shown, as clicked")
                case "moved to another tab":
                    XCTAssertTrue(focus.workspace === start, "Not shown: its window isn't in it any more")
                    XCTAssertEqual(notices.count, 1)
                default: XCTAssertTrue(focus.workspace === other, "The newer choice stands")
            }
        }
    }

    func testShowingAHiddenOnlyTabDoesntOverrideANewerChoice() async throws {
        let tab = Workspace.get(byName: "discord")
        _ = TestWindow.new(id: 190, parent: tab.macOsNativeHiddenAppsWindowsContainer)
        XCTAssertTrue(Workspace.get(byName: "start").focusWorkspace())
        let unhide = gatedRestore()
        workspaceSidebarUnhideWindow = unhide.seam
        let task = showWorkspaceSidebarOffscreenTab(tab.name, targetMonitorScopeId: nil)
        for _ in 0 ..< 200 where !unhide.reached() { try await Task.sleep(for: .milliseconds(5)) }
        let other = Workspace.get(byName: "chosen")
        XCTAssertTrue(other.focusWorkspace())
        unhide.release()
        await task?.value
        XCTAssertTrue(focus.workspace === other)
    }
}
