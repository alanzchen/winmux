import AppKit
@testable import AppBundle
import Common
import XCTest

/// A release captures where it dropped; the drop's session, which runs later, checks it again.
/// A list of another display drops only onto that same display, a display that's gone takes
/// nothing, and a drop that stops partway undoes what it did.
@MainActor
final class WorkspaceSidebarDropIntentTest: XCTestCase {
    private var wasEnabled = false

    override func setUp() async throws {
        setUpWorkspacesForTests()
        workspaceSidebarOrganizationStore = .init()
        wasEnabled = TrayMenuModel.shared.isEnabled
    }

    override func tearDown() async throws {
        TrayMenuModel.shared.isEnabled = wasEnabled
        WorkspaceSidebarTemporaryDropSurfaces.shared.removeAll()
        WorkspaceSidebarTabUndo.shared.clear()
        clearWorkspaceSidebarDropPreview()
        MessageModel.shared.message = nil
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
        try await super.tearDown()
    }

    func testAListsDisplayResolvesOnlyWhileItsTheSameDisplay() {
        let (left, right) = twoDisplays(rightIdentity: "B")
        let rightScope = workspaceSidebarMonitorScopeId(for: right)
        let destination = WorkspaceSidebarDropDestinationIdentity(monitorScopeId: rightScope)
        XCTAssertEqual(destination?.resolve()?.rect, right.rect)
        XCTAssertNil(WorkspaceSidebarDropDestinationIdentity(monitorScopeId: workspaceSidebarDefaultScopeId),
            "Only a display's list has a destination")

        // Another display now where it was.
        setMonitorsForTests([left, IdentifiedMonitor(id: 2, rect: right.rect, identity: "C")])
        XCTAssertNil(destination?.resolve(), "A different display at the same place")
        setMonitorsForTests([left, right])
        XCTAssertEqual(destination?.resolve()?.rect, right.rect)

        setMonitorsForTests([left])
        XCTAssertNil(destination?.resolve(), "Unplugged")
        setMonitorsForTests([left, right])
        MonitorConfigurationObserver.shared.noteDisplayChangeForTests()
        XCTAssertNil(destination?.resolve(), "Any display change since the list opened")
    }

    func testAReleaseOnAListThatClosedTakesNothing() {
        let (_, right) = twoDisplays(rightIdentity: "B")
        let rightScope = workspaceSidebarMonitorScopeId(for: right)
        let target = WorkspaceSidebarDropTarget(kind: .workspace("r"), rect: Rect(topLeftX: 0, topLeftY: 0, width: 10, height: 10),
            surface: .dropDestination(generation: 5))
        XCTAssertNil(WorkspaceSidebarDropIntent.captured(for: target), "No list is registered for that surface")

        let list = IntentTestSurface(generation: 5, destination: .init(monitorScopeId: rightScope))
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(list)
        XCTAssertEqual(WorkspaceSidebarDropIntent.captured(for: target)?.destination?.monitorScopeId, rightScope)

        var reopened = target
        reopened.surface = .dropDestination(generation: 6)
        XCTAssertNil(WorkspaceSidebarDropIntent.captured(for: reopened), "A list opened after this one isn't it")

        var physical = target
        physical.surface = .panel(monitorScopeId: rightScope)
        let intent = WorkspaceSidebarDropIntent.captured(for: physical)
        XCTAssertNotNil(intent)
        XCTAssertNil(intent?.destination, "A display's own panel checks its drops as it always has")
    }

    func testADropNamingAGoneDisplayResolvesNowhere() {
        let (left, _) = twoDisplays(rightIdentity: "B")
        XCTAssertNil(workspaceSidebarDropTargetMonitor(scopeId: "monitor:5000.0,0.0"))
        XCTAssertEqual(workspaceSidebarDropTargetMonitor(scopeId: workspaceSidebarMonitorScopeId(for: left))?.rect, left.rect)
        XCTAssertNotNil(workspaceSidebarDropTargetMonitor(scopeId: workspaceSidebarDefaultScopeId),
            "A scope naming no display keeps its meaning")
    }

    /// The list showed tab "r" on the right display; by the time the session runs, "r" is on the left.
    func testATabThatChangedDisplaysTakesNoDropFromTheList() async throws {
        let (left, right, window) = try twoDisplaysWithTabs()
        let intent = try listIntent(for: right)
        let r = Workspace.get(byName: "r")
        XCTAssertTrue(right.setActiveWorkspace(Workspace.get(byName: "s")))
        XCTAssertTrue(left.setActiveWorkspace(r))
        XCTAssertEqual(r.workspaceMonitor.rect, left.rect)
        let task = try XCTUnwrap(queueWorkspaceSidebarDrop(window.windowId, subject: .window, target: .workspace("r"),
            placement: nil, intent: intent))
        await task.value
        XCTAssertEqual(window.nodeWorkspace?.name, "a", "Nothing moved")
    }

    func testAWindowDroppedOnTheListsTabGoesThere() async throws {
        let (_, right, window) = try twoDisplaysWithTabs()
        let intent = try listIntent(for: right)
        let task = try XCTUnwrap(queueWorkspaceSidebarDrop(window.windowId, subject: .window, target: .workspace("r"),
            placement: nil, intent: intent))
        await task.value
        XCTAssertEqual(window.nodeWorkspace?.name, "r")
        XCTAssertEqual(window.nodeWorkspace?.workspaceMonitor.rect, right.rect)
    }

    /// With shared pins, B's list shows a pin that lives on C. A window joined to it goes to C,
    /// where the pin's tab is; without shared pins the list never showed it and takes nothing.
    func testAListJoinsASharedPinOnAThirdDisplayWhereverItIs() async throws {
        for shares in [true, false] {
            setUpWorkspacesForTests()
            workspaceSidebarOrganizationStore = .init()
            let (_, right, window) = try twoDisplaysWithTabs()
            let third = IdentifiedMonitor(id: 3, rect: Rect(topLeftX: 3840, topLeftY: 0, width: 1920, height: 1080),
                identity: "C")
            setMonitorsForTests(monitors + [third])
            let pin = Workspace.get(byName: "p")
            _ = TestWindow.new(id: 9, parent: pin.rootTilingContainer)
            pin.preferredMonitorPoint = third.rect.topLeftCorner
            XCTAssertTrue(third.setActiveWorkspace(pin))
            try setWorkspaceSidebarTabFavorite(pin, true)
            config.workspaceSidebar.sharePinnedTabs = shares
            let intent = try listIntent(for: right)
            config.workspaceSidebar.sharePinnedTabs = !shares // Captured at the release; the session doesn't reread it.

            let task = try XCTUnwrap(queueWorkspaceSidebarDrop(window.windowId, subject: .window, target: .workspace("p"),
                placement: nil, intent: intent))
            await task.value
            if shares {
                XCTAssertEqual(window.nodeWorkspace?.name, "p", "It joined the pin")
                XCTAssertEqual(window.nodeWorkspace?.workspaceMonitor.rect, third.rect, "On the pin's display")
            } else {
                XCTAssertEqual(window.nodeWorkspace?.name, "a", "B's own list never showed it")
            }
            setMonitorsForTests(nil)
            config = defaultConfig
        }
    }

    /// The display changes after the release and before the session: the drop is refused, and says so.
    func testADisplayChangeBeforeTheSessionRefusesTheDrop() async throws {
        let (_, right, window) = try twoDisplaysWithTabs()
        let intent = try listIntent(for: right)
        let rightScope = workspaceSidebarMonitorScopeId(for: right)
        for target in [WorkspaceSidebarDropTargetKind.newWorkspace(projectId: workspaceProjectDefaultId, monitorScopeId: rightScope),
                       .tabGap(projectId: workspaceProjectDefaultId, monitorScopeId: rightScope,
                           gap: .init(workspaceName: "r", isAfter: true))]
        {
            let task = try XCTUnwrap(queueWorkspaceSidebarDrop(window.windowId, subject: .window, target: target,
                placement: nil, intent: intent))
            MonitorConfigurationObserver.shared.noteDisplayChangeForTests()
            await task.value
            XCTAssertEqual(window.nodeWorkspace?.name, "a", "Nothing moved for \(target)")
            XCTAssertNotNil(MessageModel.shared.message)
            MessageModel.shared.message = nil
        }
    }

    /// Before, a display that went away fell back to the window's own display and made a tab there.
    func testADropOnAGoneDisplaysListMakesNoTabElsewhere() async throws {
        let (_, _, window) = try twoDisplaysWithTabs()
        let task = try XCTUnwrap(queueWorkspaceSidebarDrop(window.windowId, subject: .window,
            target: .newWorkspace(projectId: workspaceProjectDefaultId, monitorScopeId: "monitor:5000.0,0.0"),
            placement: nil, intent: .physical))
        await task.value
        XCTAssertEqual(window.nodeWorkspace?.name, "a", "No new tab took it")
        XCTAssertNotNil(MessageModel.shared.message)
    }

    /// Unpinning succeeds, then moving the tab to the gap's project fails: the pin comes back.
    func testADropBetweenTabsThatStopsPartwayIsUndone() throws {
        let tab = Workspace.get(byName: "p")
        _ = TestWindow.new(id: 3, parent: tab.rootTilingContainer)
        try setWorkspaceSidebarTabFavorite(tab, true)
        let other = createWorkspaceProject()
        let anchor = Workspace.get(byName: "elsewhere")
        _ = TestWindow.new(id: 7, parent: anchor.rootTilingContainer)
        anchor.assignProject(other.id)
        // The project goes away, so the move into it fails after the unpin.
        let projects = winMuxWorkspaceState.projectsById
        winMuxWorkspaceState.projectsById[other.id] = nil
        defer { winMuxWorkspaceState.projectsById = projects }

        let moved = try withWorkspaceSidebarDropTransaction {
            moveWholeTabToGap(tab, projectId: other.id, monitor: tab.workspaceMonitor,
                gap: .init(workspaceName: anchor.name, isAfter: true), focusing: nil)
        }
        XCTAssertFalse(moved)
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite, true, "Pinned again")
        XCTAssertEqual(tab.projectId, workspaceProjectDefaultId)
    }

    func testATransactionUndoesWhatAThrowingDropChanged() throws {
        let tab = Workspace.get(byName: "p")
        _ = TestWindow.new(id: 3, parent: tab.rootTilingContainer)
        let before = tab.preferredMonitorPoint
        XCTAssertThrowsError(try withWorkspaceSidebarDropTransaction {
            try setWorkspaceSidebarTabFavorite(tab, true)
            tab.preferredMonitorPoint = CGPoint(x: 1920, y: 0)
            throw WorkspaceMutationError.displayUnavailable
        })
        XCTAssertNotEqual(workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite, true)
        XCTAssertEqual(tab.preferredMonitorPoint, before, "The live state goes back too")

        XCTAssertTrue(try withWorkspaceSidebarDropTransaction {
            try setWorkspaceSidebarTabFavorite(tab, true)
            return true
        })
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite, true, "A drop that worked stays")
    }

    // MARK: Helpers

    private func twoDisplays(rightIdentity: String) -> (left: Monitor, right: Monitor) {
        let left = IdentifiedMonitor(id: 1, rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), identity: "A")
        let right = IdentifiedMonitor(id: 2, rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            identity: rightIdentity)
        setMonitorsForTests([left, right])
        return (left, right)
    }

    /// Tab "a" with window 1 on the left display; tab "r" with window 5 on the right one.
    private func twoDisplaysWithTabs() throws -> (left: Monitor, right: Monitor, window: Window) {
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        let (left, right) = twoDisplays(rightIdentity: "B")
        Workspace.reconcileWorkspaceState()
        let a = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        let r = Workspace.get(byName: "r")
        _ = TestWindow.new(id: 5, parent: r.rootTilingContainer)
        a.preferredMonitorPoint = left.rect.topLeftCorner
        r.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(left.setActiveWorkspace(a))
        XCTAssertTrue(right.setActiveWorkspace(r))
        return (left, right, window)
    }

    private func listIntent(for monitor: Monitor) throws -> WorkspaceSidebarDropIntent {
        let list = IntentTestSurface(generation: 1,
            destination: .init(monitorScopeId: workspaceSidebarMonitorScopeId(for: monitor)))
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(list)
        // Registered only while the release captures it: the session must not need the list.
        defer { WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(list) }
        return try XCTUnwrap(WorkspaceSidebarDropIntent.captured(for: .init(kind: .workspace("r"),
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 10, height: 10), surface: list.surfaceRef)))
    }
}

private struct IdentifiedMonitor: Monitor {
    let monitorAppKitNsScreenScreensId: Int
    let name: String
    let rect: Rect
    let visibleRect: Rect
    let isMain: Bool
    let displayIdentity: MonitorDisplayIdentity?

    init(id: Int, rect: Rect, identity: String) {
        monitorAppKitNsScreenScreensId = id
        name = "Display \(id)"
        self.rect = rect
        visibleRect = rect
        isMain = id == 1
        displayIdentity = .init(uuid: identity)
    }

    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}

@MainActor
private final class IntentTestSurface: WorkspaceSidebarTemporaryDropSurface {
    let surfaceRef: WorkspaceSidebarSurfaceRef
    let stackingOrder = 1
    let dropDestination: WorkspaceSidebarDropDestinationIdentity?

    init(generation: UInt64, destination: WorkspaceSidebarDropDestinationIdentity?) {
        surfaceRef = .dropDestination(generation: generation)
        dropDestination = destination
    }

    func surfaceRectNormalized(containing _: CGPoint) -> Rect? { nil }
    func dropTarget(atNormalizedPoint _: CGPoint, hitSlop _: NSEdgeInsets, includesTabGaps _: Bool) -> WorkspaceSidebarDropTarget? {
        nil
    }
}
