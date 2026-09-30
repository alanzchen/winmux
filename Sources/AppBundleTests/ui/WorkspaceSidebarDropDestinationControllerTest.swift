import AppKit
@testable import AppBundle
import Combine
import Common
import XCTest

/// A sidebar drag with two displays offers the other one's hint beside the sidebar; pausing on it
/// opens that display's list there. One display does nothing. A display change, Escape or the
/// release tears it all down, and frames where nothing changed do nothing.
@MainActor
final class WorkspaceSidebarDropDestinationControllerTest: XCTestCase {
    private let controller = WorkspaceSidebarDropDestinationController.shared
    private let sessions = WorkspaceSidebarDragSessions.shared
    private var wasEnabled = false

    override func setUp() async throws {
        setUpWorkspacesForTests()
        workspaceSidebarOrganizationStore = .init()
        wasEnabled = TrayMenuModel.shared.isEnabled
        controller.resetForTests()
        sessions.resetForTests()
    }

    override func tearDown() async throws {
        controller.resetForTests()
        sessions.resetForTests()
        cancelActiveSidebarPinnedTabDrag()
        WorkspaceSidebarTemporaryDropSurfaces.shared.removeAll()
        setWorkspaceSidebarDragSourceScopeIdForTests(nil)
        clearWorkspaceSidebarDropPreview()
        MousePointerTracker.shared.reset()
        TrayMenuModel.shared.isEnabled = wasEnabled
        workspaceSidebarOrganizationStore = .init()
        for panel in WorkspaceSidebarPanel.visiblePanels { panel.visibleSurfaceFrame = nil }
        setMonitorsForTests(nil)
        config = defaultConfig
        WorkspaceSidebarPanel.refreshAll()
        try await super.tearDown()
    }

    func testOneDisplayDoesNothing() throws {
        let tab = try fixture(displays: 1)
        beginDrag(tab)
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(WorkspaceSidebarTemporaryDropSurfaces.shared.isEmpty, "Nothing is made")
    }

    func testAPauseOnTheOtherDisplaysHintOpensItsListBesideTheSidebar() throws {
        let tab = try fixture(displays: 2)
        beginDrag(tab)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.hints.map(\.id), [right])
        let hint = try XCTUnwrap(controller.layout?.hints.first)
        XCTAssertEqual(workspaceSidebarSurface(at: normalizeAppKitScreenPoint(hint.center))?.surface.isTemporary, true)
        XCTAssertNil(workspaceSidebarSurfaceHit(at: normalizeAppKitScreenPoint(hint.center)).target, "Hints take no drop")

        controller.tick(pointer: hint.center, now: 10, elapsed: 0)
        XCTAssertNil(controller.openId, "Passing over it opens nothing yet")
        controller.tick(pointer: hint.center, now: 10 + workspaceSidebarDropDestinationDwell, elapsed: 0.22)
        XCTAssertEqual(controller.openId, right)
        let column = try XCTUnwrap(controller.layout?.column)
        XCTAssertEqual(controller.columnPanel.dropDestination?.monitorScopeId, right)
        XCTAssertTrue(controller.columnPanel.isVisible)
        XCTAssertFalse(controller.columnPanel.canBecomeKey, "Opening it takes no focus")
        XCTAssertTrue(controller.columnPanel.ignoresMouseEvents)
        let snapshot = try XCTUnwrap(controller.columnPanel.model.snapshot)
        XCTAssertEqual(snapshot.projection.selectedMonitorScopeId, right, "It lists the other display")
        XCTAssertEqual(snapshot.projection.targetMonitorScopeId, right)
        let onColumn = workspaceSidebarSurface(at: normalizeAppKitScreenPoint(CGPoint(x: column.midX, y: column.midY)))
        XCTAssertEqual(onColumn?.surface, controller.columnPanel.surfaceRef)
        XCTAssertEqual(WorkspaceSidebarTemporaryDropSurfaces.shared.destination(for: controller.columnPanel.surfaceRef)?
            .monitorScopeId, right)
    }

    func testAFrameWhereNothingChangedDoesNothing() throws {
        let tab = try fixture(displays: 2)
        beginDrag(tab)
        let away = CGPoint(x: 5000, y: 5000)
        let before = controller.processedFrames
        for index in 0 ..< 5 { controller.tick(pointer: away, now: 20 + Double(index) * 0.016, elapsed: 0.016) }
        XCTAssertEqual(controller.processedFrames, before + 1, "Only the first frame at a new place")
        controller.tick(pointer: CGPoint(x: 5001, y: 5000), now: 21, elapsed: 0.016)
        XCTAssertEqual(controller.processedFrames, before + 2)

        // Resting on a hint, the frames wait for the pause, then open it with the pointer still.
        let hint = try XCTUnwrap(controller.layout?.hints.first)
        controller.tick(pointer: hint.center, now: 30, elapsed: 0.016)
        let armed = controller.processedFrames
        controller.tick(pointer: hint.center, now: 30.05, elapsed: 0.016)
        XCTAssertEqual(controller.processedFrames, armed, "Before its deadline a still pointer does nothing")
        controller.tick(pointer: hint.center, now: 30 + workspaceSidebarDropDestinationDwell, elapsed: 0.016)
        XCTAssertEqual(controller.openId, right)
    }

    func testTheHintsPublishOnlyWhenTheyLookDifferent() throws {
        let tab = try fixture(displays: 2)
        beginDrag(tab)
        var publications = 0
        let subscription = controller.hintPanel.model.$content.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        for x in stride(from: 4000.0, to: 4100, by: 5) {
            controller.tick(pointer: CGPoint(x: x, y: 4000), now: 40 + x / 1000, elapsed: 0.016)
        }
        XCTAssertEqual(publications, 0, "Moving about elsewhere changes nothing on them")
        let hint = try XCTUnwrap(controller.layout?.hints.first)
        controller.tick(pointer: hint.center, now: 50, elapsed: 0.016)
        XCTAssertEqual(publications, 1, "Arming")
        controller.tick(pointer: hint.center, now: 50 + workspaceSidebarDropDestinationDwell, elapsed: 0.016)
        XCTAssertGreaterThanOrEqual(publications, 2, "Open")
        let opened = publications
        let column = try XCTUnwrap(controller.layout?.column)
        for y in stride(from: column.midY - 40, to: column.midY + 40, by: 4) {
            controller.tick(pointer: CGPoint(x: column.midX, y: y), now: 51 + y / 10000, elapsed: 0.016)
        }
        XCTAssertEqual(publications, opened, "Moving in the list doesn't touch the hints")
    }

    func testADisplayChangeEndsTheListForTheRestOfTheDrag() throws {
        let tab = try fixture(displays: 2)
        beginDrag(tab)
        try open()
        MonitorConfigurationObserver.shared.noteDisplayChangeForTests()
        controller.tick(pointer: CGPoint(x: 5000, y: 5000), now: 60, elapsed: 0.016)
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(WorkspaceSidebarTemporaryDropSurfaces.shared.isEmpty)
        XCTAssertFalse(controller.columnPanel.isVisible)
        updateSidebarPinnedTabDrag(tab.name, pointer: .zero)
        XCTAssertFalse(controller.isActive, "The same gesture can't bring it back")

        // The next drag can.
        finishSidebarPinnedTabDrag(tab.name, pointer: .zero)
        beginDrag(tab)
        XCTAssertTrue(controller.isActive)
    }

    func testEscapeTakesTheListAwayAndDropsNothing() throws {
        let tab = try fixture(displays: 2)
        beginDrag(tab)
        try open()
        XCTAssertTrue(workspaceSidebarHandleEscapeDuringDrag(keyCode: 53))
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(WorkspaceSidebarTemporaryDropSurfaces.shared.isEmpty)
        XCTAssertFalse(controller.columnPanel.isVisible)
        XCTAssertFalse(controller.hintPanel.isVisible)
        XCTAssertNil(controller.columnPanel.model.snapshot, "Its content goes too")
    }

    func testTheReleaseTakesTheListAway() throws {
        let tab = try fixture(displays: 2)
        beginDrag(tab)
        try open()
        finishSidebarPinnedTabDrag(tab.name, pointer: CGPoint(x: -9000, y: -9000))
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(WorkspaceSidebarTemporaryDropSurfaces.shared.isEmpty)
        XCTAssertTrue(workspacePinnedTabs(in: tab.projectId).contains(tab), "Released away from everything: nothing moved")
    }

    /// The list's blank space over the source sidebar is the list's: a release there drops nothing,
    /// and the sidebar underneath takes nothing.
    func testTheListCoversTheSidebarUnderIt() throws {
        let tab = try fixture(displays: 2)
        beginDrag(tab)
        try open()
        let source = try XCTUnwrap(WorkspaceSidebarPanel.panel(for: left))
        let column = controller.columnPanel.frame
        // Over both, whatever the list's placement: put the list on the sidebar.
        controller.columnPanel.setFrame(source.visibleSurfaceFrameOnScreen.insetBy(dx: 20, dy: 20), display: false)
        defer { controller.columnPanel.setFrame(column, display: false) }
        let point = normalizeAppKitScreenPoint(CGPoint(x: controller.columnPanel.frame.midX, y: controller.columnPanel.frame.midY))
        let hit = workspaceSidebarSurfaceHit(at: point)
        XCTAssertEqual(hit.surface, controller.columnPanel.surfaceRef)
        XCTAssertNil(hit.target)
    }

    /// Through the list: a pin dropped between the other display's tabs goes to that display, as
    /// on its own sidebar, and the list goes as the release is taken.
    func testAPinDroppedBetweenTheListsTabsMovesToThatDisplay() async throws {
        let tab = try fixture(displays: 2)
        let other = Workspace.get(byName: "r")
        _ = TestWindow.new(id: 5, parent: other.rootTilingContainer)
        let rightMonitor = try XCTUnwrap(sortedMonitors.first { workspaceSidebarMonitorScopeId(for: $0) == right })
        other.preferredMonitorPoint = rightMonitor.rect.topLeftCorner
        XCTAssertTrue(rightMonitor.setActiveWorkspace(other))
        beginDrag(tab)
        try open()
        // The gap after "r", where the list would report it.
        let gap = CGRect(x: 8, y: 80, width: 200, height: 14)
        controller.columnPanel.setTargetsForTests([.init(kind: .tabGap(projectId: tab.projectId, monitorScopeId: right,
            gap: .init(workspaceName: other.name, isAfter: true)), frame: gap)])
        let panel = controller.columnPanel
        let point = normalizeAppKitScreenPoint(CGPoint(x: panel.frame.minX + gap.midX,
            y: panel.frame.minY + panel.hostingView.bounds.height - gap.midY))
        XCTAssertEqual(workspaceSidebarSurfaceHit(at: point).target?.surface, panel.surfaceRef)

        updateSidebarPinnedTabDrag(tab.name, pointer: point)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetMonitorScopeId, right)
        XCTAssertEqual(currentWorkspaceSidebarDropPreviewOwnerScopeId(), panel.surfaceRef.ownerId, "The list shows it")
        finishSidebarPinnedTabDrag(tab.name, pointer: point)
        XCTAssertFalse(controller.isActive, "Gone with the release")
        try await waitUntil { tab.workspaceMonitor.rect == rightMonitor.rect }
        XCTAssertFalse(workspacePinnedTabs(in: tab.projectId).contains(tab), "Between tabs, it's unpinned")
    }

    /// Sidebar mode: a window row dropped on a workspace in the list goes into it on the other
    /// display, and the release refocuses nothing on the display under the pointer. (The release
    /// resolves its target where it lands; Tabs mode's preview reads the real pointer.)
    func testAWindowDroppedOnTheListsWorkspaceGoesThere() async throws {
        _ = try fixture(displays: 2)
        config.workspaceSidebar.mode = .sidebar
        let source = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 7, parent: source.rootTilingContainer)
        let leftMonitor = sortedMonitors[0]
        source.preferredMonitorPoint = leftMonitor.rect.topLeftCorner
        XCTAssertTrue(leftMonitor.setActiveWorkspace(source))
        let other = Workspace.get(byName: "r")
        _ = TestWindow.new(id: 5, parent: other.rootTilingContainer)
        let rightMonitor = try XCTUnwrap(sortedMonitors.first { workspaceSidebarMonitorScopeId(for: $0) == right })
        other.preferredMonitorPoint = rightMonitor.rect.topLeftCorner
        XCTAssertTrue(rightMonitor.setActiveWorkspace(other))
        defer {
            clearActiveWorkspaceSidebarDrag()
            clearPendingWindowDragIntent()
            cancelManipulatedWithMouseState()
        }
        sessions.noteLeftMouseDown()
        setWorkspaceSidebarDragSourceScopeIdForTests(left)
        updateSidebarWindowDrag(window.windowId, subject: .window, pointer: CGPoint(x: -9000, y: -9000))
        XCTAssertTrue(controller.isActive)
        try open()
        let row = CGRect(x: 8, y: 60, width: 200, height: 36)
        controller.columnPanel.setTargetsForTests([.init(kind: .workspace(other.name), frame: row)])
        let panel = controller.columnPanel
        let point = normalizeAppKitScreenPoint(CGPoint(x: panel.frame.minX + row.midX,
            y: panel.frame.minY + panel.hostingView.bounds.height - row.midY))

        XCTAssertEqual(workspaceSidebarSurfaceHit(at: point).target?.kind, .workspace(other.name))
        finishSidebarWindowDrag(pointer: point)
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(takeWorkspaceSidebarConsumedRelease(), "The desktop click doesn't refocus the display under it")
        try await waitUntil { window.nodeWorkspace === other }
        XCTAssertEqual(window.nodeWorkspace?.workspaceMonitor.rect, rightMonitor.rect)
    }

    /// Review round 1: going straight from one display's list to another's, the last list's targets
    /// don't count for the new one, even reported late.
    func testSwitchingListsDropsTheLastListsTargets() throws {
        let tab = try fixture(displays: 3)
        beginDrag(tab)
        try open()
        let first = controller.columnPanel.surfaceRef
        let row = CGRect(x: 8, y: 60, width: 200, height: 36)
        controller.columnPanel.setTargetsForTests([.init(kind: .tabGap(projectId: tab.projectId, monitorScopeId: right,
            gap: .init(workspaceName: "r", isAfter: true)), frame: row)])
        XCTAssertFalse(controller.columnPanel.targets.isEmpty)

        let farHint = try XCTUnwrap(controller.layout?.hints.last)
        XCTAssertEqual(controller.hints.last?.id, far)
        controller.tick(pointer: farHint.center, now: 200, elapsed: 0.016)
        controller.tick(pointer: farHint.center, now: 200 + workspaceSidebarDropDestinationDwell, elapsed: 0.22)
        XCTAssertEqual(controller.openId, far)
        XCTAssertNotEqual(controller.columnPanel.surfaceRef, first, "A new list, a new surface")
        XCTAssertTrue(controller.columnPanel.targets.isEmpty, "None until its own are laid out")
        controller.columnPanel.setTargets([.init(kind: .workspace("r"), frame: row)], reportedFor: first)
        XCTAssertTrue(controller.columnPanel.targets.isEmpty, "The last list's layout, reported late")

        // Even a target naming the last display, found on the new list, takes nothing.
        let stale = WorkspaceSidebarDropTarget(kind: .tabGap(projectId: tab.projectId, monitorScopeId: right,
            gap: .init(workspaceName: "r", isAfter: true)), rect: Rect(topLeftX: 0, topLeftY: 0, width: 10, height: 10),
            surface: controller.columnPanel.surfaceRef)
        XCTAssertNil(WorkspaceSidebarDropIntent.captured(for: stale))
    }

    /// Review round 1: with the pointer still, a frame looks again once any surface's targets change.
    func testAStillPointerLooksAgainWhenTargetsChange() throws {
        let tab = try fixture(displays: 2)
        beginDrag(tab)
        let still = CGPoint(x: 5000, y: 5000)
        controller.tick(pointer: still, now: 300, elapsed: 0.016)
        let before = controller.processedFrames
        controller.tick(pointer: still, now: 300.02, elapsed: 0.016)
        XCTAssertEqual(controller.processedFrames, before)
        WorkspaceSidebarDropTargetsRevision.bump()
        controller.tick(pointer: still, now: 300.04, elapsed: 0.016)
        XCTAssertEqual(controller.processedFrames, before + 1)
        controller.syncFromShared()
        controller.tick(pointer: still, now: 300.06, elapsed: 0.016)
        XCTAssertEqual(controller.processedFrames, before + 2, "A model change too")
    }

    /// Review round 1: a preview another display's sidebar made goes once the pointer leaves it,
    /// with no gesture events to clear it.
    func testAPreviewLeftByAnotherSidebarGoesWhenThePointerLeaves() throws {
        let tab = try fixture(displays: 2)
        beginDrag(tab)
        let preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 1, label: "pin", appName: "Notes",
            targetWorkspaceName: nil, targetsNewWorkspace: false, targetProjectId: tab.projectId,
            targetMonitorScopeId: right, isTabGroup: false, windowCount: 1)
        setWorkspaceSidebarDropPreviewIfChanged(preview, owner: .panel(monitorScopeId: right))
        controller.tick(pointer: CGPoint(x: 7000, y: 7000), now: 400, elapsed: 0.016)
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
    }

    func testADocksRowOfHintsScrollsAlongIt() {
        let area = CGRect(x: 100, y: 100, width: 500, height: 36)
        XCTAssertGreaterThan(workspaceSidebarDropDestinationHintAutoscrollVelocity(pointer: CGPoint(x: 595, y: 118),
            area: area, isRow: true), 0, "On, near its trailing end")
        XCTAssertLessThan(workspaceSidebarDropDestinationHintAutoscrollVelocity(pointer: CGPoint(x: 105, y: 118),
            area: area, isRow: true), 0, "Back, near its leading end")
        XCTAssertEqual(workspaceSidebarDropDestinationHintAutoscrollVelocity(pointer: CGPoint(x: 350, y: 118),
            area: area, isRow: true), 0)
        XCTAssertEqual(workspaceSidebarDropDestinationHintAutoscrollVelocity(pointer: CGPoint(x: 595, y: 300),
            area: area, isRow: true), 0, "Off the row")
    }

    /// §7.2: with shared pins, a pin rearranged on another display's list stays on its display, and
    /// Undo puts the order back. The list shows the drop; no physical panel does.
    func testASharedPinRearrangedOnTheListStaysWhereItIs() async throws {
        let (tab, other, rightMonitor) = try sharedPinsFixture()
        let point = try openListWithPinTarget(after: other)
        updateSidebarPinnedTabDrag(tab.name, pointer: point)
        XCTAssertEqual(currentWorkspaceSidebarDropPreviewOwnerScopeId(), controller.columnPanel.surfaceRef.ownerId)
        XCTAssertEqual(workspaceSidebarPanelDropPreview(TrayMenuModel.shared.workspaceSidebarDropPreview, panelScopeId: right,
            ownerId: currentWorkspaceSidebarDropPreviewOwnerScopeId(), sharesPinnedTabs: true)?.targetsPinned, false,
            "Only the list lights it")
        finishSidebarPinnedTabDrag(tab.name, pointer: point)
        try await waitUntil { workspacePinnedTabs(in: tab.projectId).map(\.name) == [other.name, tab.name] }
        XCTAssertNotEqual(tab.workspaceMonitor.rect, rightMonitor.rect, "Rearranged, not moved")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(workspacePinnedTabs(in: tab.projectId).map(\.name), [tab.name, other.name])
    }

    /// §7.2: a drop on the pins shown with shared pins isn't made once the setting changed.
    func testAPinRuleChangedAfterThePreviewDropsNothing() async throws {
        let (tab, other, _) = try sharedPinsFixture()
        let point = try openListWithPinTarget(after: other)
        updateSidebarPinnedTabDrag(tab.name, pointer: point)
        XCTAssertNotNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
        config.workspaceSidebar.sharePinnedTabs = false
        finishSidebarPinnedTabDrag(tab.name, pointer: point)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(workspacePinnedTabs(in: tab.projectId).map(\.name), [tab.name, other.name], "Nothing was dropped")
        XCTAssertEqual(tab.workspaceMonitor.rect, sortedMonitors[0].rect)
    }

    /// §7.2: the drop keeps the rule it was shown with, even if the setting changes before its
    /// session runs.
    func testAPinRuleChangedAfterTheReleaseKeepsTheRuleShown() async throws {
        let (tab, other, _) = try sharedPinsFixture()
        let point = try openListWithPinTarget(after: other)
        updateSidebarPinnedTabDrag(tab.name, pointer: point)
        finishSidebarPinnedTabDrag(tab.name, pointer: point)
        config.workspaceSidebar.sharePinnedTabs = false
        try await waitUntil { workspacePinnedTabs(in: tab.projectId).map(\.name) == [other.name, tab.name] }
        XCTAssertEqual(tab.workspaceMonitor.rect, sortedMonitors[0].rect, "Shown as shared pins: it stays")
    }

    /// A pinned tile's release makes the drop its preview showed, or none: one the pointer only
    /// found at the release, with no preview of it, isn't made.
    func testAPinnedTileReleaseMakesOnlyTheDropShown() async throws {
        let (tab, other, rightMonitor) = try sharedPinsFixture()
        let point = try openListWithPinTarget(after: other)
        updateSidebarPinnedTabDrag(tab.name, pointer: point)
        // The list's layout changes under a still pointer: its place is now between the list's tabs.
        let gap = CGRect(x: 8, y: 60, width: 60, height: 54)
        controller.columnPanel.setTargetsForTests([.init(kind: .tabGap(projectId: tab.projectId, monitorScopeId: right,
            gap: .init(workspaceName: other.name, isAfter: true)), frame: gap)])
        finishSidebarPinnedTabDrag(tab.name, pointer: point)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(workspacePinnedTabs(in: tab.projectId).map(\.name), [tab.name, other.name])
        XCTAssertNotEqual(tab.workspaceMonitor.rect, rightMonitor.rect, "Nothing was dropped")
    }

    func testTheSplitHoverRemembersThePinRuleShown() {
        let hover = WorkspaceSidebarTabSplitHoverController.shared
        defer { hover.reset() }
        let target = WorkspaceSidebarDropTarget(kind: .pinnedTabs(projectId: workspaceProjectDefaultId, monitorScopeId: right),
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 10, height: 10))
        hover.noteDisplayed(source: 3, hitKind: target.kind, target: target, placement: nil, pinGridIsShared: true)
        XCTAssertEqual(hover.displayedPinGridIsShared(source: 3), true)
        XCTAssertNil(hover.displayedPinGridIsShared(source: 4), "Another drag's")
        hover.clearDisplayed()
        XCTAssertNil(hover.displayedPinGridIsShared(source: 3))
    }

    func testAnEdgeScrollsTheListFasterNearerIt() {
        XCTAssertEqual(workspaceSidebarDropDestinationAutoscrollVelocity(pointY: 500, top: 1000, bottom: 0), 0)
        let nearTop = workspaceSidebarDropDestinationAutoscrollVelocity(pointY: 990, top: 1000, bottom: 0)
        let atTop = workspaceSidebarDropDestinationAutoscrollVelocity(pointY: 1000, top: 1000, bottom: 0)
        XCTAssertLessThan(nearTop, 0, "Towards the top")
        XCTAssertLessThan(atTop, nearTop)
        XCTAssertEqual(atTop, -workspaceSidebarDropDestinationAutoscrollSpeed, accuracy: 0.01)
        XCTAssertGreaterThan(workspaceSidebarDropDestinationAutoscrollVelocity(pointY: 10, top: 1000, bottom: 0), 0)
        XCTAssertEqual(workspaceSidebarDropDestinationAutoscrollVelocity(pointY: 1100, top: 1000, bottom: 0), 0, "Outside")
    }

    // MARK: Helpers

    private let left = "monitor:0.0,0.0"
    private let right = "monitor:1920.0,0.0"
    private let far = "monitor:3840.0,0.0"

    /// Tabs mode with a pinned tab "pin" on the left display, and the sidebar panels.
    private func fixture(displays: Int) throws -> Workspace {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        config.workspaceSidebar.tabsAlwaysExpanded = true
        let leftMonitor = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Left",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true)
        let rightMonitor = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Right",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        let farMonitor = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 3, name: "Far",
            rect: Rect(topLeftX: 3840, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 3840, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        setMonitorsForTests(Array([leftMonitor, rightMonitor, farMonitor].prefix(displays)))
        Workspace.reconcileWorkspaceState()
        let tab = Workspace.get(byName: "pin")
        _ = TestWindow.new(id: 1, parent: tab.rootTilingContainer)
        try setWorkspaceSidebarTabFavorite(tab, true)
        WorkspaceSidebarPanel.refreshAll()
        let panel = try XCTUnwrap(WorkspaceSidebarPanel.panel(for: left))
        panel.orderFront(nil)
        // The surface SwiftUI would report after its first layout.
        panel.visibleSurfaceFrame = CGRect(x: 0, y: 0, width: 280, height: 600)
        return tab
    }

    private func beginDrag(_ tab: Workspace) {
        sessions.noteLeftMouseDown()
        setWorkspaceSidebarDragSourceScopeIdForTests(left)
        updateSidebarPinnedTabDrag(tab.name, pointer: CGPoint(x: -9000, y: -9000))
    }

    /// Shared pins "pin" (left, first) and "r" (right), with the drag of "pin" begun.
    private func sharedPinsFixture() throws -> (tab: Workspace, other: Workspace, right: Monitor) {
        let tab = try fixture(displays: 2)
        config.workspaceSidebar.sharePinnedTabs = true
        let other = Workspace.get(byName: "r")
        _ = TestWindow.new(id: 5, parent: other.rootTilingContainer)
        let rightMonitor = try XCTUnwrap(sortedMonitors.first { workspaceSidebarMonitorScopeId(for: $0) == right })
        other.preferredMonitorPoint = rightMonitor.rect.topLeftCorner
        XCTAssertTrue(rightMonitor.setActiveWorkspace(other))
        try setWorkspaceSidebarTabFavorite(other, true)
        XCTAssertEqual(workspacePinnedTabs(in: tab.projectId).map(\.name), [tab.name, other.name])
        beginDrag(tab)
        return (tab, other, rightMonitor)
    }

    /// Opens the right display's list and puts the place after `pin` among its pins under the
    /// returned normalized point.
    private func openListWithPinTarget(after pin: Workspace) throws -> CGPoint {
        try open()
        let gap = CGRect(x: 8, y: 60, width: 60, height: 54)
        controller.columnPanel.setTargetsForTests([.init(kind: .pinnedTabs(projectId: pin.projectId,
            gap: .init(workspaceName: pin.name, isAfter: true), monitorScopeId: right), frame: gap)])
        let panel = controller.columnPanel
        return normalizeAppKitScreenPoint(CGPoint(x: panel.frame.minX + gap.midX,
            y: panel.frame.minY + panel.hostingView.bounds.height - gap.midY))
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func open() throws {
        let hint = try XCTUnwrap(controller.layout?.hints.first)
        controller.tick(pointer: hint.center, now: 100, elapsed: 0)
        controller.tick(pointer: hint.center, now: 100 + workspaceSidebarDropDestinationDwell, elapsed: 0.22)
        XCTAssertEqual(controller.openId, right)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
