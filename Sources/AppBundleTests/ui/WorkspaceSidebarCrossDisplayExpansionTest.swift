import AppKit
@testable import AppBundle
import Combine
import Common
import XCTest

/// Audit F1: a sidebar drag holds back hover expansion only on the panel it started in, so
/// another display's sidebar opens for it: an auto-hidden one reveals, a compact Sidebar or Dock
/// opens, and the compact Tabs rail, which takes no drops, opens into the full list.
@MainActor
final class WorkspaceSidebarCrossDisplayExpansionTest: XCTestCase {
    private let otherDisplay = "monitor:1920.0,0.0"

    override func tearDown() async throws {
        resetWorkspaceSidebarItemDrag()
        setWorkspaceSidebarDragSourceScopeIdForTests(nil)
        workspaceSidebarIsPointerPushedAgainstDisplayEdge = { isMousePushedAgainstDisplayEdge() }
        config = defaultConfig
        try await super.tearDown()
    }

    func testOnlyTheSourcePanelHoldsBackHoverExpansion() {
        for (item, originated) in [(true, false), (false, true), (true, true)] {
            XCTAssertTrue(shouldSuppressWorkspaceSidebarHoverExpansionForDrag(isSidebarItemDragActive: item,
                isSidebarOriginatedDrag: originated, isDragSourcePanel: true))
            XCTAssertFalse(shouldSuppressWorkspaceSidebarHoverExpansionForDrag(isSidebarItemDragActive: item,
                isSidebarOriginatedDrag: originated, isDragSourcePanel: false), "Another display's panel opens")
            XCTAssertTrue(isWorkspaceSidebarIncomingDrag(isMouseWindowDragInProgress: originated,
                isSidebarItemDragActive: item, isSidebarOriginatedDrag: originated, isDragSourcePanel: false))
            XCTAssertFalse(isWorkspaceSidebarIncomingDrag(isMouseWindowDragInProgress: originated,
                isSidebarItemDragActive: item, isSidebarOriginatedDrag: originated, isDragSourcePanel: true))
        }
        XCTAssertFalse(shouldSuppressWorkspaceSidebarHoverExpansionForDrag(isSidebarItemDragActive: false,
            isSidebarOriginatedDrag: false, isDragSourcePanel: true), "No drag, nothing held back")
        XCTAssertTrue(isWorkspaceSidebarIncomingDrag(isMouseWindowDragInProgress: true, isSidebarItemDragActive: false,
            isSidebarOriginatedDrag: false, isDragSourcePanel: true), "A window dragged from the screen, as before")
    }

    func testTheDragRemembersThePanelItStartedInUntilItEnds() throws {
        let panel = try sharedPanel()
        resetWorkspaceSidebarItemDrag()
        beginWorkspaceSidebarItemDrag(sourceWindow: panel)
        XCTAssertEqual(currentWorkspaceSidebarDragSourceScopeId(), panel.monitorScopeId)
        XCTAssertTrue(isWorkspaceSidebarDragSource(panel.monitorScopeId))
        XCTAssertFalse(isWorkspaceSidebarDragSource(otherDisplay))
        beginWorkspaceSidebarItemDrag(sourceWindow: nil)
        XCTAssertEqual(currentWorkspaceSidebarDragSourceScopeId(), panel.monitorScopeId, "A nested begin keeps the source")
        endWorkspaceSidebarItemDrag()
        XCTAssertEqual(currentWorkspaceSidebarDragSourceScopeId(), panel.monitorScopeId, "One begin is still active")
        endWorkspaceSidebarItemDrag()
        XCTAssertNil(currentWorkspaceSidebarDragSourceScopeId())
        XCTAssertTrue(isWorkspaceSidebarDragSource(otherDisplay), "Without a known source every panel holds back, as before")

        beginWorkspaceSidebarItemDrag(sourceWindow: panel)
        resetWorkspaceSidebarItemDrag()
        XCTAssertNil(currentWorkspaceSidebarDragSourceScopeId(), "The mouse-up cleanup forgets it too")
    }

    /// Review follow-up: the panel whose view reports the drag is its source, whatever the event
    /// window suggested. Outside a drag, a report changes nothing.
    func testThePanelReportingTheDragIsItsSource() {
        resetWorkspaceSidebarItemDrag()
        noteWorkspaceSidebarDragReported(byPanel: otherDisplay)
        XCTAssertNil(currentWorkspaceSidebarDragSourceScopeId(), "No drag, no source")
        beginWorkspaceSidebarItemDrag(sourceWindow: nil)
        setWorkspaceSidebarDragSourceScopeIdForTests("monitor:0.0,0.0")
        noteWorkspaceSidebarDragReported(byPanel: otherDisplay)
        XCTAssertEqual(currentWorkspaceSidebarDragSourceScopeId(), otherDisplay)
        noteWorkspaceSidebarDragReported(byPanel: nil)
        XCTAssertEqual(currentWorkspaceSidebarDragSourceScopeId(), otherDisplay, "A view outside a panel reports nothing")
        resetWorkspaceSidebarItemDrag()
        XCTAssertNil(currentWorkspaceSidebarDragSourceScopeId())
    }

    func testAnotherDisplaysCompactSidebarOpensForASidebarDrag() throws {
        try withPanel(mode: .sidebar) { panel in
            dragFromAnotherDisplay()
            let probe = PublicationProbe(panel)
            recheck(panel, times: 1)
            XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 280)
            XCTAssertEqual(probe.expansions, 1)

            // The hover guard still holds: rechecks at pointer rate publish nothing more.
            probe.reset()
            recheck(panel, times: 60)
            XCTAssertEqual(probe.expansions, 0)
            XCTAssertEqual(probe.publications, 0)
        }
    }

    func testTheSourcePanelStaysAsItWas() throws {
        try withPanel(mode: .sidebar) { panel in
            resetWorkspaceSidebarItemDrag()
            beginWorkspaceSidebarItemDrag(sourceWindow: panel)
            let probe = PublicationProbe(panel)
            recheck(panel, times: 30)
            XCTAssertFalse(panel.viewModel.isWorkspaceSidebarExpanded, "The rows a drag started from stay where they are")
            XCTAssertEqual(probe.expansions + probe.publications, 0)

            // A drag whose source isn't known holds every panel back, as before.
            setWorkspaceSidebarDragSourceScopeIdForTests(nil)
            recheck(panel, times: 30)
            XCTAssertFalse(panel.viewModel.isWorkspaceSidebarExpanded)
        }
    }

    func testAnAutoHiddenSidebarRevealsItsRailAtTheEdgeThenOpens() throws {
        try withPanel(mode: .sidebar, autoHide: true) { panel in
            panel.hideSidebar(.pointerExit, animated: false)
            XCTAssertNotNil(panel.autoHideReason)
            dragFromAnotherDisplay(atEdge: true)
            recheck(panel, times: 1)
            XCTAssertNil(panel.autoHideReason, "The hidden sidebar reveals for the drag")
            XCTAssertFalse(panel.viewModel.isWorkspaceSidebarExpanded, "At the edge it shows its rail only")
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth,
                workspaceSidebarHoverActivationWidth(panel.sidebarSettings))

            workspaceSidebarIsPointerPushedAgainstDisplayEdge = { false }
            recheck(panel, times: 1)
            XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded, "Further in, it opens")
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 280)
        }
    }

    /// The compact Tabs rail has no drop targets. For a drag it opens into the full list, which does.
    func testTheCompactTabsRailOpensIntoTheListForADrag() throws {
        try withPanel(mode: .tabs) { panel in
            XCTAssertFalse(panel.viewModel.isWorkspaceSidebarExpanded)
            dragFromAnotherDisplay()
            recheck(panel, times: 1)
            XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 280)
        }
    }

    func testACompactDockOpensItsColumnsUnlessItMagnifies() throws {
        try withPanel(mode: .dock) { panel in
            dragFromAnotherDisplay()
            recheck(panel, times: 1)
            XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded, "The Dock opens its project columns")
        }
        try withPanel(mode: .dock, magnification: true) { panel in
            dragFromAnotherDisplay()
            recheck(panel, times: 1)
            XCTAssertFalse(panel.viewModel.isWorkspaceSidebarExpanded,
                "A magnifying Dock never opens on hover; its compact tiles take the drop, as for a window from the screen")
        }
    }

    // MARK: Helpers

    private func dragFromAnotherDisplay(atEdge: Bool = false) {
        resetWorkspaceSidebarItemDrag()
        beginWorkspaceSidebarItemDrag(sourceWindow: nil)
        setWorkspaceSidebarDragSourceScopeIdForTests(otherDisplay)
        workspaceSidebarIsPointerPushedAgainstDisplayEdge = { atEdge }
    }

    /// `setHovering` is what each pointer recheck calls with the hover state it computed.
    private func recheck(_ panel: WorkspaceSidebarPanel, times: Int) {
        let depth = panel.menuTrackingDepth
        panel.menuTrackingDepth = 0
        defer { panel.menuTrackingDepth = depth }
        for _ in 0 ..< times { panel.setHovering(true) }
    }

    private func sharedPanel() throws -> WorkspaceSidebarPanel {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        return WorkspaceSidebarPanel.shared
    }

    private func withPanel(mode: WorkspaceSidebarMode, autoHide: Bool = false, magnification: Bool = false,
                           _ body: (WorkspaceSidebarPanel) throws -> Void) throws {
        let panel = try sharedPanel()
        let oldConfig = config
        let wasEnabled = TrayMenuModel.shared.isEnabled
        let oldFrame = panel.frame
        let trackingDepth = panel.menuTrackingDepth
        panel.resetHiddenSidebarState()
        panel.menuTrackingDepth = 1 // Deferred rechecks must not read the real desktop pointer.
        defer {
            resetWorkspaceSidebarItemDrag()
            setWorkspaceSidebarDragSourceScopeIdForTests(nil)
            panel.pendingCollapse?.cancel()
            panel.pendingCollapse = nil
            panel.resetHiddenSidebarState()
            panel.viewModel.isWorkspaceSidebarExpanded = false
            panel.menuTrackingDepth = trackingDepth
            panel.setFrame(oldFrame, display: false)
            config = oldConfig
            TrayMenuModel.shared.isEnabled = wasEnabled
        }
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = mode
        config.workspaceSidebar.browserTabs = false
        config.workspaceSidebar.autoHide = autoHide
        config.workspaceSidebar.alwaysExpanded = false
        config.workspaceSidebar.tabsAlwaysExpanded = false
        config.workspaceSidebar.dockMagnification = magnification
        config.workspaceSidebar.width = 280
        TrayMenuModel.shared.isEnabled = true
        panel.viewModel.isWorkspaceSidebarExpanded = false
        panel.refresh(on: mainMonitor)
        panel.orderFront(nil)
        try body(panel)
    }
}

@MainActor
private final class PublicationProbe {
    private(set) var expansions = 0
    private(set) var publications = 0
    private var subscriptions: [AnyCancellable] = []

    init(_ panel: WorkspaceSidebarPanel) {
        subscriptions = [
            NotificationCenter.default.publisher(for: workspaceSidebarWillExpandNotification, object: panel)
                .sink { [unowned self] _ in expansions += 1 },
            panel.viewModel.objectWillChange.sink { [unowned self] in publications += 1 },
        ]
    }

    func reset() {
        expansions = 0
        publications = 0
    }
}
