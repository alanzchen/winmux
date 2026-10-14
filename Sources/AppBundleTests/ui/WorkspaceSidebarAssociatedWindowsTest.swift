import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

/// Tabs mode: a tab lists auxiliary windows one level under the window they came from.
@MainActor
final class WorkspaceSidebarAssociatedWindowsTest: XCTestCase {
    private let mail = TestApp(pid: 41, bundleId: "com.apple.mail", name: "Mail")

    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        AuxiliaryWindowRegistry.shared.removeAll()
        WorkspaceSidebarAssociatedWindowsDisclosure.shared.reset()
    }

    override func tearDown() async throws {
        AuxiliaryWindowRegistry.shared.removeAll()
        WorkspaceSidebarAssociatedWindowsDisclosure.shared.reset()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    func testATabListsItsViewerWithTheDraftOneLevelUnderAndMarksTheWindowInUse() async throws {
        let (tab, viewer) = viewerTab()
        let compose = try await open(11, from: viewer, title: "New Message")
        var model = try await viewModel(tab)
        XCTAssertEqual(model.items.map(\.id), ["window:10"], "The viewer is the tab's own row")
        XCTAssertEqual(model.associatedWindows.map(\.id), [11])
        XCTAssertEqual(model.associatedWindows.first?.parentWindowId, 10)
        XCTAssertEqual(model.associatedWindows.first?.role, .mailCompose)
        XCTAssertEqual(workspaceSidebarTabPresentation(model), .single(try XCTUnwrap(windowItem(model.items.first))),
            "A tab with a draft is still one window's tab, not a split")
        XCTAssertEqual(workspaceSidebarPinnedTabWindows(model).map(\.windowId), [10], "Never a member of a split or pin")
        XCTAssertEqual(workspaceSidebarTabWindowIds(in: model), [10, 11], "Scrolling and lookups still find it")
        XCTAssertTrue(try XCTUnwrap(windowItem(model.items.first)).isFocused)

        XCTAssertTrue(compose.focusWindow())
        model = try await viewModel(tab)
        XCTAssertEqual(model.associatedWindows.first?.window.isFocused, true, "The draft in use is the highlighted row")
        XCTAssertEqual(windowItem(model.items.first)?.isFocused, false, "The viewer's row isn't, while its tab still is")
        XCTAssertEqual(workspaceSidebarFocusedTabRowId(in: model), "window:11")
    }

    func testAFloatingWindowNotOpenedFromHereIsStillOneOfTheTabsOwn() async throws {
        let (tab, viewer) = viewerTab()
        _ = TestWindow.new(id: 12, parent: tab, app: mail, title: "Dialog")
        let model = try await viewModel(tab)
        XCTAssertEqual(model.associatedWindows, [], "Floating alone isn't auxiliary")
        XCTAssertEqual(model.items.map(\.id), ["window:10", "window:12"])
        _ = viewer
    }

    func testSearchFindsADraftByItsTitleUnderItsTab() async throws {
        let (tab, viewer) = viewerTab()
        _ = try await open(11, from: viewer, title: "Re: Quarterly numbers")
        let model = try await viewModel(tab)
        let byDraft = try XCTUnwrap(filtered(model, "quarterly"))
        XCTAssertEqual(byDraft.items.map(\.id), ["window:10"], "Shown under its viewer, for context")
        XCTAssertEqual(byDraft.associatedWindows.map(\.id), [11])
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [byDraft], query: "quarterly"), [.window(10), .window(11)],
            "The arrow keys reach it, after its tab's own rows")
        let byViewer = try XCTUnwrap(filtered(model, "inbox"))
        XCTAssertEqual(byViewer.associatedWindows, [], "A draft that doesn't match isn't shown")
    }

    func testTheTabMenuListsTheDraftAndOnlyCloseTabClosesItTooWhenAsked() async throws {
        let (tab, viewer) = viewerTab()
        _ = try await open(11, from: viewer, title: "New Message")
        let model = try await viewModel(tab)
        var sent: [WorkspaceSidebarAction] = []
        let menu = workspaceSidebarWorkspaceIdentityMenuModel(model, windowId: 10, send: { sent.append($0) })
        let opened = try XCTUnwrap(menu.entries.first { $0.title == "Opened from This Tab" })
        XCTAssertEqual(opened.children.map(\.title), ["New Message"])
        opened.children.first?.perform?()
        XCTAssertEqual(sent, [.selectWindow(11)])
        let destructive = menu.entries.filter(\.isDestructive).map(\.title)
        XCTAssertEqual(destructive, ["Close Window", "Close All Windows in Tab…"],
            "Close Window is the viewer's alone; the whole tab is its own item")
        sent = []
        menu.entries.first { $0.title == "Close Window" }?.perform?()
        XCTAssertEqual(sent, [.closeWindow(10)])
    }

    func testFoldingHidesOnlyRowsAndSaysHowManyAreFolded() async throws {
        let (tab, viewer) = viewerTab()
        let compose = try await open(11, from: viewer, title: "New Message")
        let message = try await open(12, role: .mailMessage, from: viewer, title: "Message")
        let model = try await viewModel(tab)
        let expanded = height(of: model)
        WorkspaceSidebarAssociatedWindowsDisclosure.shared.toggle(tab.name)
        let folded = height(of: model)
        XCTAssertEqual(expanded, 2 * workspaceSidebarTabRowHeight + 2, accuracy: 0.5, "One row each")
        XCTAssertEqual(folded, workspaceSidebarTabRowHeight, accuracy: 0.5, "One row for both")
        XCTAssertEqual(workspaceSidebarAssociatedWindowsCountText(model.associatedWindows.count), "2 windows")
        for window in [compose, message] {
            XCTAssertTrue(window.isBound && window.isFloating && window.nodeWorkspace === tab,
                "Folding never closes, minimizes or moves a window")
        }
        let after = try await viewModel(tab)
        XCTAssertEqual(after.associatedWindows.map(\.id), [11, 12])
        WorkspaceSidebarAssociatedWindowsDisclosure.shared.toggle(tab.name)
        XCTAssertEqual(height(of: model), expanded, accuracy: 0.5)
        XCTAssertEqual(height(of: model, isSearching: true, collapse: true), expanded, accuracy: 0.5,
            "A search shows the matching windows even in a folded tab")
    }

    func testAPinShowsOnlyACountOfItsDrafts() async throws {
        let (tab, viewer) = viewerTab()
        try setWorkspaceSidebarTabFavorite(tab, true)
        _ = try await open(11, from: viewer, title: "New Message")
        let model = try await viewModel(tab)
        XCTAssertTrue(model.appearance.isFavorite)
        XCTAssertEqual(workspaceSidebarPinnedTabWindows(model).map(\.windowId), [10], "The tile's window is the viewer alone")
        XCTAssertEqual(model.associatedWindows.map(\.id), [11])
        XCTAssertEqual(WorkspaceSidebarPinnedGridLayout(workspaces: [model], width: 160).columns, 2,
            "A draft doesn't widen the tile as a split's second window would")
    }

    func testClickingADraftsRowFocusesThatWindowWhereItIs() async throws {
        let (tab, viewer) = viewerTab()
        let compose = try await open(11, from: viewer, title: "New Message")
        XCTAssertTrue(TestWindow.new(id: 30, parent: Workspace.get(byName: "other").rootTilingContainer).focusWindow())
        XCTAssertTrue(focusWindowFromSidebar(compose, targetMonitorScopeId: nil), "What its row's click does")
        XCTAssertTrue(focus.windowOrNil === compose)
        XCTAssertTrue(focus.workspace === tab, "Its tab comes back with it")
        XCTAssertTrue(compose.isFloating && compose.nodeWorkspace === tab, "Raised as it is: never tiled in")
        XCTAssertEqual(compose.nativeFocusCount, 1)
    }

    // MARK: - A pin's own window, with a draft opened from it

    func testAPinnedViewerWithADraftIsStillAPinWithOneWindow() async throws {
        let (pin, viewer) = viewerTab()
        try setWorkspaceSidebarTabFavorite(pin, true)
        _ = try await open(11, from: viewer, title: "New Message")
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [10, 11], "The draft is the pin's to focus and close")
        XCTAssertEqual(workspaceSidebarPinSplitRole(pin), .single(viewer), "Its window is the viewer alone")
        XCTAssertTrue(workspaceSidebarTakesSplit(pin))
        let other = TestWindow.new(id: 40, parent: Workspace.get(byName: "d").rootTilingContainer)
        XCTAssertTrue(workspaceSidebarPinPolicyAllows(other, into: pin), "A window dropped on it still splits with the viewer")
        XCTAssertTrue(workspaceSidebarPinLoan(taking: viewer)?.window === viewer, "Moving the viewer out lends it")
    }

    func testSplittingAPinnedViewerLendsItAndAClickBringsItBackWhileItsDraftStays() async throws {
        let (pin, viewer) = viewerTab()
        try setWorkspaceSidebarTabFavorite(pin, true)
        let compose = try await open(11, from: viewer, title: "New Message")
        let d = Workspace.get(byName: "d")
        _ = TestWindow.new(id: 40, parent: d.rootTilingContainer)
        // As a drag of d's window onto the pin's left half does.
        await queueWorkspaceSidebarDrop(40, subject: .window, target: .workspace(pin.name), placement: .left, intent: .physical)?.value
        XCTAssertEqual(d.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [40, 10], "The split goes to d, an ordinary tab")
        XCTAssertTrue(workspaceSidebarLentWindow(of: pin) === viewer, "The pin lends its viewer, as without a draft")
        XCTAssertTrue(compose.nodeWorkspace === pin && compose.isFloating, "The draft didn't move with it")
        var model = try await viewModel(pin)
        XCTAssertEqual(model.items.map(\.id), [], "The pin shows its lent viewer, grey, not the draft as its window")
        XCTAssertEqual(model.associatedWindows.map(\.id), [11], "The draft only counted")
        XCTAssertEqual(model.lentWindow?.windowId, 10)
        XCTAssertTrue(workspaceSidebarPinRecallsWindows(pin))
        let menu = workspaceSidebarWorkspaceIdentityMenuModel(model, send: { _ in })
        XCTAssertEqual(menu.entries.filter(\.isDestructive).map(\.title), ["Close Tab and Its Windows…"],
            "Not an empty tab: it still holds the draft, which closing it would close, once agreed to")

        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(pin), .returned(viewer))
        XCTAssertTrue(viewer.nodeWorkspace === pin && viewer.parent is TilingContainer, "The same viewer, back in its pin")
        XCTAssertNil(workspaceSidebarLentWindow(of: pin))
        XCTAssertTrue(auxiliaryWindowParent(of: compose) === viewer, "Listed under it again")
        model = try await viewModel(pin)
        XCTAssertEqual(model.items.map(\.id), ["window:10"])
        XCTAssertEqual(model.associatedWindows.map(\.id), [11])
    }

    // MARK: - Search with parents and drafts both matching

    func testSearchKeepsEachMatchingDraftsParentWithTheTabsOwnMatchesInOrder() async throws {
        let tab = focus.workspace
        let inbox = TestWindow.new(id: 10, parent: tab.rootTilingContainer, app: mail, title: "Inbox")
        let notes = TestApp(pid: 43, bundleId: "com.apple.Notes", name: "Notes")
        _ = TestWindow.new(id: 20, parent: tab.rootTilingContainer, app: notes, title: "Budget")
        XCTAssertTrue(inbox.focusWindow())
        _ = try await open(11, from: inbox, title: "Re: Budget reply")
        let model = try await viewModel(tab)
        XCTAssertEqual(model.items.map(\.id), ["window:10", "window:20"])
        let found = try XCTUnwrap(filtered(model, "budget"))
        XCTAssertEqual(found.items.map(\.id), ["window:10", "window:20"],
            "The draft's parent, for context, and the window matching itself, in their order")
        XCTAssertEqual(found.associatedWindows.map(\.id), [11], "The matching draft isn't dropped")
        let selections = workspaceSidebarSearchSelections(workspaces: [found], query: "budget")
        XCTAssertEqual(selections.last, .window(11), "The arrow keys reach the draft, after the tab's own rows")
        XCTAssertTrue(selections.contains(.window(20)))
        let onlyInbox = try XCTUnwrap(filtered(model, "inbox"))
        XCTAssertEqual(onlyInbox.items.map(\.id), ["window:10"])
        XCTAssertEqual(onlyInbox.associatedWindows, [])
    }

    // MARK: - Helpers

    private func viewerTab() -> (Workspace, TestWindow) {
        let tab = focus.workspace
        let viewer = TestWindow.new(id: 10, parent: tab.rootTilingContainer, app: mail, title: "Inbox — Example")
        XCTAssertTrue(viewer.focusWindow())
        return (tab, viewer)
    }

    private func open(_ id: UInt32, role: AuxiliaryWindowRole = .mailCompose, from opener: AppBundle.Window,
                      title: String) async throws -> TestWindow {
        try await openAuxiliaryTestWindow(id, app: mail, role: role, from: opener, title: title)
    }

    private func viewModel(_ tab: Workspace) async throws -> WorkspaceSidebarWorkspaceViewModel {
        let models = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:],
            availableMonitors: monitors)
        return try XCTUnwrap(models.first { $0.name == tab.name })
    }

    private func windowItem(_ item: WorkspaceSidebarItemViewModel?) -> WorkspaceSidebarWindowViewModel? {
        guard case .window(let window)? = item?.kind else { return nil }
        return window
    }

    private func filtered(_ model: WorkspaceSidebarWorkspaceViewModel, _ query: String) -> WorkspaceSidebarWorkspaceViewModel? {
        workspaceSidebarFilteredWorkspacesByProject([model.projectId: [model]], projects: [], query: query)[model.projectId]?.first
    }

    /// The height of a tab's listed auxiliary windows, laid out offscreen.
    private func height(of model: WorkspaceSidebarWorkspaceViewModel, isSearching: Bool = false, collapse: Bool = false) -> CGFloat {
        if collapse, !WorkspaceSidebarAssociatedWindowsDisclosure.shared.isCollapsed(model.name) {
            WorkspaceSidebarAssociatedWindowsDisclosure.shared.toggle(model.name)
        }
        defer {
            if collapse, WorkspaceSidebarAssociatedWindowsDisclosure.shared.isCollapsed(model.name) {
                WorkspaceSidebarAssociatedWindowsDisclosure.shared.toggle(model.name)
            }
        }
        let view = WorkspaceSidebarAssociatedWindowsView(workspace: model, isActive: true, isSearching: isSearching,
            selectedSearchTarget: nil, dragSourceWindowId: nil, allowsDrag: false,
            activation: WorkspaceSidebarTabActivation(allowsActivation: true, isInUseOnOtherDisplay: false, requestOverride: {}),
            actions: WorkspaceSidebarActions(send: { _ in }), badgeModel: WorkspaceSidebarDockBadgeModel())
        let host = NSHostingView(rootView: view.frame(width: 280).transaction { $0.animation = nil })
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
