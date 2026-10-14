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

    /// The viewer's own row heads the card its windows are listed in, one level in. Folding a tab
    /// not in use hides only their rows; one in use, or a search, always lists them.
    func testTheViewersRowHeadsItsDraftsAndFoldingHidesOnlyTheirRows() async throws {
        let (tab, viewer) = viewerTab()
        let compose = try await open(11, from: viewer, title: "New Message")
        let message = try await open(12, role: .mailMessage, from: viewer, title: "Message")
        let model = try await viewModel(tab)
        let row = workspaceSidebarTabRowHeight, inset = workspaceSidebarTabGroupInset
        let expanded = height(of: model, isActive: false)
        XCTAssertEqual(expanded, 2 * inset + 3 * row + 2 * 2, accuracy: 0.5, "The viewer's row, then one row each, in one card")
        WorkspaceSidebarAssociatedWindowsDisclosure.shared.toggle(tab.name)
        XCTAssertEqual(height(of: model, isActive: false), 2 * inset + row, accuracy: 0.5, "Folded: the viewer's row alone")
        XCTAssertEqual(workspaceSidebarAssociatedWindowsCountText(model.associatedWindows.count), "2 windows")
        for window in [compose, message] {
            XCTAssertTrue(window.isBound && window.isFloating && window.nodeWorkspace === tab,
                "Folding never closes, minimizes or moves a window")
        }
        XCTAssertEqual(height(of: model, isActive: true), expanded, accuracy: 0.5,
            "The tab in use always lists them, so the window in use is never folded away")
        XCTAssertEqual(height(of: model, isActive: false, isSearching: true), expanded, accuracy: 0.5,
            "A search shows the matching windows even in a folded tab")
        XCTAssertFalse(workspaceSidebarAssociatedWindowsCanFold(isActive: true, isSearching: false))
        XCTAssertFalse(workspaceSidebarAssociatedWindowsCanFold(isActive: false, isSearching: true))
        XCTAssertTrue(workspaceSidebarAssociatedWindowsCanFold(isActive: false, isSearching: false))
        WorkspaceSidebarAssociatedWindowsDisclosure.shared.toggle(tab.name)
        XCTAssertEqual(height(of: model, isActive: false), expanded, accuracy: 0.5)
        let after = try await viewModel(tab)
        XCTAssertEqual(after.associatedWindows.map(\.id), [11, 12])
    }

    /// The disclosure is the viewer's row's, on its icon column; a draft's row, a leaf, only selects it.
    func testTheDisclosureIsOnTheViewersRowAndADraftsRowOnlySelectsIt() async throws {
        let (tab, viewer) = viewerTab()
        _ = try await open(11, from: viewer, title: "New Message")
        let model = try await viewModel(tab)
        let row = workspaceSidebarTabRowHeight, inset = workspaceSidebarTabGroupInset
        var sent: [WorkspaceSidebarAction] = []
        let width: CGFloat = 280
        let card = WorkspaceSidebarTabCardView(workspace: model, presentation: workspaceSidebarTabPresentation(model),
            isActive: false, isDropTarget: false, dragSourceWindowId: nil, selectedSearchTarget: nil,
            activation: .init(allowsActivation: true, isInUseOnOtherDisplay: false, requestOverride: {}),
            isShowingOverride: false, overrideMinHeight: row, actions: .init(send: { sent.append($0) }),
            badgeModel: WorkspaceSidebarDockBadgeModel(), onBeginRename: {}, onCommitOverride: {}, onCancelOverride: {})
        let viewerRowY = inset + row / 2, draftRowY = inset + row + 2 + row / 2
        try click(card, size: CGSize(width: width, height: 2 * inset + 2 * row + 2), points: [
            // Where a disclosure would be on the draft's row: it selects the draft.
            CGPoint(x: 14, y: draftRowY),
            CGPoint(x: width / 2, y: viewerRowY),
            // The viewer's row's own disclosure.
            CGPoint(x: 14, y: viewerRowY),
        ])
        XCTAssertEqual(sent, [.selectWindow(11), .selectWindow(10)], "Rows select their own window; the disclosure selects nothing")
        XCTAssertTrue(WorkspaceSidebarAssociatedWindowsDisclosure.shared.isCollapsed(tab.name), "The viewer's row folds them")
    }

    /// Under a split, windows opened from one of its windows are listed under a header naming that one.
    func testInASplitWindowsOpenedFromOneAreGroupedUnderIt() async throws {
        let (tab, viewer) = viewerTab()
        let notes = TestWindow.new(id: 20, parent: tab.rootTilingContainer, title: "Notes")
        _ = try await open(11, from: viewer, title: "New Message")
        let model = try await viewModel(tab)
        guard case .split = workspaceSidebarTabPresentation(model) else { return XCTFail("A split tab") }
        let groups = workspaceSidebarAssociatedWindowGroups(model)
        XCTAssertEqual(groups.map { $0.parent?.windowId }, [10], "Under the viewer it was opened from, not the split's other window")
        XCTAssertEqual(groups.first?.windows.map(\.id), [11])
        _ = notes
    }

    /// Two windows of a split with drafts of their own: the arrow keys go through the drafts in the
    /// order they're listed, under their own window each, whatever order they were opened in.
    func testInASplitTheArrowKeysGoThroughDraftsInTheOrderTheyreListed() async throws {
        let (tab, first) = viewerTab()
        let second = TestWindow.new(id: 20, parent: tab.rootTilingContainer, app: mail, title: "Archive — Example")
        _ = try await open(21, from: second, title: "Draft to second")
        _ = try await open(11, from: first, title: "Draft to first")
        let model = try await viewModel(tab)
        XCTAssertEqual(model.associatedWindows.map(\.id), [21, 11], "Opened from the second window first")
        XCTAssertEqual(workspaceSidebarListedAssociatedWindows(model).map(\.id), [11, 21], "Listed under the first window, then the second")
        let found = try XCTUnwrap(filtered(model, "draft"))
        let selections = workspaceSidebarSearchSelections(workspaces: [found], query: "draft")
        XCTAssertEqual(Array(selections.suffix(2)), [.window(11), .window(21)], "Down goes from one to the next as they're listed")
        XCTAssertEqual(workspaceSidebarListedAssociatedWindows(found).map(\.id), [11, 21])
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
        let compose = try await open(11, from: viewer, title: "Re: Quarterly plan")
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

        // Searched by its own title while the viewer is lent: the draft is found, under the lent viewer as context.
        let found = try XCTUnwrap(filtered(model, "quarterly"))
        XCTAssertEqual(found.items.map(\.id), [], "The lent viewer isn't made one of the pin's own rows")
        XCTAssertEqual(found.associatedWindows.map(\.id), [11], "The matching draft is kept")
        XCTAssertEqual(found.lentWindow?.windowId, 10, "Its context: the pin's window, in another tab")
        XCTAssertEqual(workspaceSidebarTabPresentation(found), .empty, "Drawn as that context, not as an empty tab")
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [found], query: "quarterly"), [.window(11)],
            "The arrow keys reach the draft alone")
        XCTAssertEqual(WorkspaceTabClosePlan([pin]).tabs.first?.members.map(\.window.windowId), [11],
            "Closing the pin still closes only what is in it")
        // Enter on it, as search sends it: the draft itself is focused, and the lent viewer stays where it is.
        XCTAssertTrue(TestWindow.new(id: 50, parent: Workspace.get(byName: "other").rootTilingContainer).focusWindow())
        handleWorkspaceSidebarAction(.selectWindow(11))
        for _ in 0 ..< 200 where focus.windowOrNil !== compose { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(focus.windowOrNil === compose, "The actual draft")
        XCTAssertTrue(focus.workspace === pin && compose.isFloating, "In its pin, still floating")
        XCTAssertTrue(viewer.nodeWorkspace === d && workspaceSidebarLentWindow(of: pin) === viewer,
            "The viewer isn't recalled, moved or copied")
        XCTAssertEqual(d.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [40, 10])

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

    /// The height of a tab's card, laid out offscreen as the sidebar lays it out.
    private func height(of model: WorkspaceSidebarWorkspaceViewModel, isActive: Bool, isSearching: Bool = false) -> CGFloat {
        let view = WorkspaceSidebarTabCardView(workspace: model, presentation: workspaceSidebarTabPresentation(model),
            isActive: isActive, isDropTarget: false, dragSourceWindowId: nil, selectedSearchTarget: nil,
            activation: .init(allowsActivation: true, isInUseOnOtherDisplay: false, requestOverride: {}),
            isShowingOverride: false, overrideMinHeight: workspaceSidebarTabRowHeight, actions: .init(send: { _ in }),
            badgeModel: WorkspaceSidebarDockBadgeModel(), isSearching: isSearching,
            onBeginRename: {}, onCommitOverride: {}, onCancelOverride: {})
        let host = NSHostingView(rootView: view.frame(width: 280).transaction { $0.animation = nil })
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Clicks `points` in a native window holding `view`, as the row tests do.
    private func click(_ view: some View, size: CGSize, points: [CGPoint]) throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).transaction { $0.animation = nil })
        let native = NSWindow(contentRect: CGRect(origin: CGPoint(x: 300, y: 200), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.contentView = host
        native.orderFrontRegardless()
        defer { native.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        native.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for point in points {
            let location = host.convert(CGPoint(x: point.x, y: host.isFlipped ? point.y : size.height - point.y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: native.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)), atStart: false)
            }
            let deadline = Date().addingTimeInterval(0.2)
            while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: deadline,
                inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }
    }
}
