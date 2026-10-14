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

    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        savedConfirm = workspaceTabCloseConfirm
        savedNotice = workspaceSidebarPinRecallNotice
        workspaceTabCloseConfirm = { [unowned self] message, informative in
            asked.append((message, informative))
            return answer
        }
        workspaceSidebarPinRecallNotice = { [unowned self] title, body in notices.append("\(title): \(body)") }
    }

    override func tearDown() async throws {
        workspaceTabCloseConfirm = savedConfirm
        workspaceSidebarPinRecallNotice = savedNotice
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
        try await super.tearDown()
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
}
