@testable import AppBundle
import AppKit
import Common
import XCTest

/// A display with a menu bar. Sizes are example logical points: a 6K panel's and a MacBook's
/// point sizes depend on their scaling.
private struct ParkingTestMonitor: Monitor {
    let monitorAppKitNsScreenScreensId: Int
    let name: String
    let rect: Rect
    let visibleRect: Rect
    let isMain: Bool
    let displayIdentity: MonitorDisplayIdentity?
    let isFallbackMonitor: Bool
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }

    init(_ name: String, x: CGFloat = 0, width: CGFloat, height: CGFloat, menuBar: CGFloat = 25, uuid: String?,
         isMain: Bool = true, isBuiltin: Bool = false, isFallback: Bool = false)
    {
        monitorAppKitNsScreenScreensId = 1
        self.name = name
        rect = Rect(topLeftX: x, topLeftY: 0, width: width, height: height)
        visibleRect = Rect(topLeftX: x, topLeftY: menuBar, width: width, height: height - menuBar)
        self.isMain = isMain
        displayIdentity = uuid.map { MonitorDisplayIdentity(uuid: $0, isBuiltin: isBuiltin) }
        isFallbackMonitor = isFallback
    }
}

/// A window with a simulated native side, running the real corner-parking code. AX reads and
/// writes are counted the way MacApp makes them; the app can fail writes, and "macOS" can move
/// the window with or without telling WinMux.
private final class ParkingTestWindow: Window {
    let cornerParking = CornerParkingState()
    var nativeRect: Rect
    /// The next N frame writes fail (the app is busy right after wake).
    var failingWrites = 0
    /// The app never accepts a frame write.
    var refusesWrites = false
    /// The app reports its own moves (kAXMoved); movedObs then drops the cached frame.
    var reportsMoves = true
    /// The app doesn't answer frame reads.
    var readsFail = false
    var onWrite: (() -> Void)?
    /// Runs while a frame read is in flight, before it returns.
    var onRead: (() -> Void)?
    /// The next frame read waits until `readGate` is resumed; `onReadHeld` runs once it waits.
    var holdNextRead = false
    var onReadHeld: (() -> Void)?
    var readGate: CheckedContinuation<Void, Never>?
    private(set) var axReads = 0
    private(set) var axWrites = 0
    /// setAxFrame calls, including ones that turn out to be no-ops.
    private(set) var frameSubmissions = 0

    @MainActor init(id: UInt32, parent: NonLeafTreeNodeObject, rect: Rect, app: TestApp) {
        nativeRect = rect
        super.init(id: id, app, lastFloatingSize: CGSize(width: rect.width, height: rect.height), parent: parent,
                   adaptiveWeight: 1, index: INDEX_BIND_LAST)
        recordAuthoritativeActualRect(rect)
    }

    @MainActor override var title: String { get async { "Parking \(windowId)" } }
    override var isHiddenInCorner: Bool { cornerParking.isHiddenInCorner }

    @MainActor override func getAxRect() async throws -> Rect? {
        axReads += 1
        let token = nativeStateObservationToken()
        if holdNextRead {
            holdNextRead = false
            await withCheckedContinuation {
                readGate = $0
                onReadHeld?()
            }
        }
        onRead?()
        let rect = readsFail ? nil : nativeRect
        recordObservedActualRect(rect, token: token)
        return rect
    }

    @MainActor override func getAxSize() async throws -> CGSize? {
        axReads += 1
        return CGSize(width: nativeRect.width, height: nativeRect.height)
    }

    /// Like MacApp.setFrame: read the frame, write only what differs.
    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        frameSubmissions += 1
        axReads += 1
        let current = nativeRect
        let target = Rect(topLeftX: topLeft?.x ?? current.minX, topLeftY: topLeft?.y ?? current.minY,
                          width: size?.width ?? current.width, height: size?.height ?? current.height)
        guard target != current else { return }
        axWrites += 1
        onWrite?()
        if failingWrites > 0 {
            failingWrites -= 1
            return
        }
        if refusesWrites { return }
        nativeRect = target
        guard reportsMoves else { return }
        // Tests run on the main actor, like movedObs's handler.
        nonisolated(unsafe) let window = self
        MainActor.assumeIsolated { window.invalidateLastKnownNativeState() }
    }

    /// macOS moved the window and no kAXMoved reached WinMux.
    @MainActor func silentlyMove(to point: CGPoint) {
        nativeRect = Rect(topLeftX: point.x, topLeftY: point.y, width: nativeRect.width, height: nativeRect.height)
    }

    /// The window moved and its kAXMoved arrived.
    @MainActor func moveReportingAxEvent(to point: CGPoint) {
        silentlyMove(to: point)
        invalidateLastKnownNativeState()
    }

    func visibleArea(on monitor: Monitor) -> CGFloat {
        let window = CGRect(x: nativeRect.minX, y: nativeRect.minY, width: nativeRect.width, height: nativeRect.height)
        let screen = CGRect(x: monitor.rect.minX, y: monitor.rect.minY, width: monitor.rect.width, height: monitor.rect.height)
        let visible = window.intersection(screen)
        return visible.isNull ? 0 : visible.width * visible.height
    }
}

extension ParkingTestWindow: WorkspaceWindowVisibility {
    func hideInCorner(_ corner: OptimalHideCorner, reassert: Bool, ifStillValid: () -> Bool) async throws {
        try await parkInCorner(corner, cornerParking, reassert: reassert, onePixelOffset: true, ifStillValid: ifStillValid)
    }

    func unhideFromCorner() {
        restoreFromCorner(cornerParking)
    }
}

/// Regression tests for hidden windows of inactive workspaces and tabs left visible after a
/// display change (clamshell 6K unplugged, lid opened). The macOS side (when it moves windows
/// off a display that's gone, and whether apps report it) is simulated; it is a hypothesis
/// that these tests encode, not something they prove about physical hotplug.
@MainActor
final class HiddenWindowReparkTest: XCTestCase {
    private var wasEnabled = false
    private let app = TestApp(pid: 4_242, bundleId: "test.hidden-window-repark")
    private let sixK = ParkingTestMonitor("6K", width: 3008, height: 1692, uuid: "SIXK")
    private let builtin = ParkingTestMonitor("Built-in", width: 1512, height: 982, menuBar: 33, uuid: "BUILTIN", isBuiltin: true)
    private let noDisplay = ParkingTestMonitor("No Display", width: 1920, height: 1080, menuBar: 0, uuid: nil, isFallback: true)
    private let screenParams = NSApplication.didChangeScreenParametersNotification.rawValue
    private let wake = NSWorkspace.didWakeNotification.rawValue

    override func setUp() async throws {
        wasEnabled = TrayMenuModel.shared.isEnabled
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
    }

    override func tearDown() async throws {
        setMonitorsForTests(nil)
        setScheduledRefreshOverrideForTests(nil)
        TrayMenuModel.shared.isEnabled = wasEnabled
        config = defaultConfig
    }

    // MARK: Helpers

    private func connect(_ monitors: [Monitor]) {
        setMonitorsForTests(monitors)
        MonitorConfigurationObserver.shared.noteDisplayChangeForTests()
        Workspace.reconcileWorkspaceState()
    }

    private func pass(_ event: RefreshSessionEvent) async throws {
        try await $refreshSessionEvent.withValue(event) { try await layoutWorkspaces() }
    }

    private var settled: RefreshSessionEvent {
        .displayTopologySettled(generation: MonitorConfigurationObserver.shared.topologyGeneration)
    }

    private func window(_ id: UInt32, in parent: NonLeafTreeNodeObject, _ rect: Rect) -> ParkingTestWindow {
        ParkingTestWindow(id: id, parent: parent, rect: rect, app: app)
    }

    private func hiddenWindows(_ count: Int, firstId: UInt32 = 100) -> [ParkingTestWindow] {
        (0 ..< count).map { i in
            let workspace = Workspace.get(byName: "hidden-\(i)")
            return window(firstId + UInt32(i), in: workspace.rootTilingContainer,
                          Rect(topLeftX: 100 + CGFloat(i) * 10, topLeftY: 100, width: 1200, height: 800))
        }
    }

    private func cost(_ windows: [ParkingTestWindow], _ body: () async throws -> Void) async rethrows -> (reads: Int, writes: Int) {
        let reads = windows.map(\.axReads).reduce(0, +)
        let writes = windows.map(\.axWrites).reduce(0, +)
        try await body()
        return (windows.map(\.axReads).reduce(0, +) - reads, windows.map(\.axWrites).reduce(0, +) - writes)
    }

    private func parkedPoint(on monitor: Monitor) -> CGPoint {
        monitor.visibleRect.bottomRightCorner - CGPoint(x: 1, y: 1)
    }

    private func assertHidden(_ windows: [ParkingTestWindow], on monitor: Monitor, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line)
    {
        for window in windows {
            XCTAssertLessThanOrEqual(window.visibleArea(on: monitor), 1, "\(window.windowId) \(message)", file: file, line: line)
        }
    }

    /// Starts on the given displays with the hidden windows parked and confirmed.
    private func settle(_ monitors: [Monitor], visible: [ParkingTestWindow] = [], hidden: [ParkingTestWindow]) async throws {
        connect(monitors)
        try await pass(.globalObserverLeftMouseUp)
        try await pass(.globalObserverLeftMouseUp)
        try await pass(.globalObserverLeftMouseUp)
    }

    // MARK: Coalescing keeps every event's requirements

    private func coalescedRequirements(_ followUps: [RefreshSessionEvent]) async throws -> [(RefreshSessionEvent, RefreshSessionRequirements?)] {
        var sessions: [(RefreshSessionEvent, RefreshSessionRequirements?)] = []
        await withCheckedContinuation { started in
            setScheduledRefreshOverrideForTests { event, _, _ in
                sessions.append((event, refreshSessionRequirements))
                if sessions.count == 1 {
                    for e in followUps { scheduleRefreshSession(e) }
                    started.resume()
                }
            }
            scheduleRefreshSession(.ax(kAXWindowCreatedNotification as String))
        }
        try await waitForScheduledRefreshForTests()
        return sessions
    }

    func testWakeThenScreenChangeWhileBusyStillReasserts() async throws {
        let sessions = try await coalescedRequirements([
            .globalObserver(wake),
            .globalObserver(NSWorkspace.screensDidWakeNotification.rawValue),
            .globalObserver(screenParams),
        ])
        XCTAssertEqual(sessions.count, 2, "The three events coalesce into one follow-up session")
        XCTAssertEqual(sessions.last?.1?.hiddenWindowsReassertion, .always, "Wake's re-park survives the later screen change")
        XCTAssertEqual(sessions.last?.1?.windowRefreshBarrier, true)
    }

    func testWakeThenAxMovedWhileBusyStillReasserts() async throws {
        let sessions = try await coalescedRequirements([
            .globalObserver(NSWorkspace.screensDidWakeNotification.rawValue),
            .ax(kAXMovedNotification as String),
        ])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.last?.1?.hiddenWindowsReassertion, .always)
    }

    func testCoalescedSessionRunsTheUnionOfAllRequirements() async throws {
        let followUps: [RefreshSessionEvent] = [
            .onTabSwitched,
            .displayTopologySettled(generation: MonitorConfigurationObserver.shared.topologyGeneration),
            .ax(kAXFocusedWindowChangedNotification as String),
            .hotkeyBinding,
        ]
        let sessions = try await coalescedRequirements(followUps)
        XCTAssertEqual(sessions.count, 2)
        let expected = followUps.map(\.requirements).reduce(RefreshSessionEvent.onTabSwitched.requirements) { $0.union($1) }
        XCTAssertEqual(sessions.last?.1, expected)
        XCTAssertEqual(expected.windowRefreshBarrier, true)
        XCTAssertEqual(expected.layoutReasonNormalization, true)
        XCTAssertEqual(expected.freshWindowFrames, true)
        XCTAssertNotNil(expected.hiddenWindowsReassertion)
    }

    func testAnUncoalescedSessionRunsItsOwnRequirements() async throws {
        let sessions = try await coalescedRequirements([])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.1, RefreshSessionEvent.ax(kAXWindowCreatedNotification as String).requirements)
    }

    func testACommandThatCancelsASettledRefreshStillLetsItReassert() async throws {
        var reassertions: [HiddenWindowsReassertion?] = []
        var paused: CheckedContinuation<Void, Never>?
        await withCheckedContinuation { started in
            setScheduledRefreshOverrideForTests { _, _, _ in
                reassertions.append(refreshSessionRequirements?.hiddenWindowsReassertion)
                if reassertions.count == 1 {
                    await withCheckedContinuation {
                        paused = $0
                        started.resume()
                    }
                }
            }
            scheduleRefreshSession(settled)
        }
        try await runLightSession(.hotkeyBinding, .forceRun) {}
        paused?.resume()
        try await waitForScheduledRefreshForTests()
        XCTAssertEqual(reassertions.first, .displayTopology(generation: MonitorConfigurationObserver.shared.topologyGeneration))
        XCTAssertTrue(reassertions.dropFirst().contains(.displayTopology(generation: MonitorConfigurationObserver.shared.topologyGeneration)),
                      "The cancelled settled refresh is run again: \(reassertions)")
    }

    // MARK: Settled display changes, and stale ones

    func testADisplayChangeSchedulesOneReassertingRefreshOnceItSettles() async throws {
        var sessions: [(RefreshSessionEvent, Bool)] = []
        let settledSession = expectation(description: "settled refresh")
        var settledCount = 0
        setScheduledRefreshOverrideForTests { event, _, _ in
            sessions.append((event, sessionRequiresHiddenWindowsReassertion()))
            if case .displayTopologySettled = event {
                settledCount += 1
                if settledCount == 1 { settledSession.fulfill() }
            }
        }
        MonitorConfigurationObserver.shared.handleScreenParametersChanged(settleDelay: .milliseconds(150))
        MonitorConfigurationObserver.shared.handleScreenParametersChanged(settleDelay: .milliseconds(150))
        XCTAssertTrue(MonitorConfigurationObserver.shared.isSettling)
        await fulfillment(of: [settledSession], timeout: 5)
        try await Task.sleep(for: .milliseconds(300))
        try await waitForScheduledRefreshForTests()
        XCTAssertFalse(MonitorConfigurationObserver.shared.isSettling)
        let settledSessions = sessions.filter { if case .displayTopologySettled = $0.0 { true } else { false } }
        XCTAssertEqual(settledSessions.count, 1, "Only the newest change settles")
        XCTAssertEqual(settledSessions.first?.1, true)
        XCTAssertTrue(sessions.filter { $0.0.description == "globalObserver(\(screenParams))" }.allSatisfy { !$0.1 },
                      "The unsettled refresh re-parks only what moved to new geometry")
    }

    func testASettledRefreshCapturedBeforeANewerChangeDoesNotReassert() async throws {
        var reasserts: [Bool] = []
        var paused: CheckedContinuation<Void, Never>?
        await withCheckedContinuation { started in
            setScheduledRefreshOverrideForTests { _, _, _ in
                reasserts.append(sessionRequiresHiddenWindowsReassertion())
                if reasserts.count == 1 {
                    await withCheckedContinuation {
                        paused = $0
                        started.resume()
                    }
                }
            }
            scheduleRefreshSession(.globalObserver(screenParams))
        }
        scheduleRefreshSession(settled)
        MonitorConfigurationObserver.shared.noteDisplayChangeForTests() // A newer change arrives first
        paused?.resume()
        try await waitForScheduledRefreshForTests()
        XCTAssertEqual(reasserts, [false, false], "The stale settled refresh must not re-park against newer displays")

        // Wake isn't tied to a topology.
        XCTAssertTrue(HiddenWindowsReassertion.always.applies(atTopologyGeneration: MonitorConfigurationObserver.shared.topologyGeneration))
    }

    func testAnInFlightHidePassStopsAtANewerDisplayChange() async throws {
        let hidden = hiddenWindows(2)
        try await settle([sixK], hidden: hidden)
        connect([builtin])
        for window in hidden {
            window.onWrite = { MonitorConfigurationObserver.shared.noteDisplayChangeForTests() }
        }
        try await pass(.globalObserver(screenParams))
        XCTAssertEqual(hidden.map(\.axWrites).reduce(0, +) - 2, 1, "Parking stops at the first write after the displays changed again")
    }

    // MARK: The clamshell 6K -> built-in transition

    func testClamshellSixKToBuiltinReparksWindowsMacOsMovesAfterTheFirstPass() async throws {
        connect([sixK])
        let visibleWorkspace = focus.workspace
        let shown = window(1, in: visibleWorkspace.rootTilingContainer, Rect(topLeftX: 0, topLeftY: 25, width: 3008, height: 1667))
        let hidden = hiddenWindows(2)
        hidden[1].nativeRect = Rect(topLeftX: 900, topLeftY: 300, width: 2000, height: 1300)
        try await settle([sixK], hidden: hidden)
        XCTAssertEqual(hidden[0].nativeRect.topLeftCorner, parkedPoint(on: sixK))
        XCTAssertEqual(hidden[1].nativeRect.topLeftCorner, hidden[0].nativeRect.topLeftCorner,
                       "Every bottom-right-parked window shares one point, so macOS piles them up when it moves them")
        XCTAssertEqual(hidden[0].visibleArea(on: builtin), 0, "Off every screen once the 6K is gone")

        // Every display gone for a moment: nothing is written against the placeholder.
        connect([noDisplay])
        let before = hidden.map(\.nativeRect) + [shown.nativeRect]
        let zeroScreens = try await cost(hidden + [shown]) { try await pass(.globalObserver(screenParams)) }
        XCTAssertEqual(zeroScreens.writes, 0)
        XCTAssertEqual(zeroScreens.reads, 0)
        XCTAssertEqual(hidden.map(\.nativeRect) + [shown.nativeRect], before)

        connect([builtin])
        XCTAssertTrue(builtin.activeWorkspace === visibleWorkspace)
        try await pass(.globalObserver(screenParams))
        XCTAssertEqual(hidden[0].nativeRect.topLeftCorner, parkedPoint(on: builtin))
        XCTAssertTrue(shown.nativeRect.minX >= 0 && shown.nativeRect.maxX <= builtin.rect.maxX, "Tiled onto the built-in")
        try await pass(.ax(kAXMovedNotification as String)) // confirms the parks (our own moves' events)

        // macOS moves the parked windows on-screen after that, and no kAXMoved reaches WinMux.
        for window in hidden { window.silentlyMove(to: CGPoint(x: 0, y: 33)) }
        try await pass(.globalObserverLeftMouseUp)
        XCTAssertGreaterThan(hidden[0].visibleArea(on: builtin), 1, "Ordinary events don't poll parked windows")
        try await pass(settled)
        assertHidden(hidden, on: builtin, "re-parked once the displays settled")
        XCTAssertEqual(hidden[0].nativeRect.topLeftCorner, parkedPoint(on: builtin))
    }

    func testAWindowMacOsMovesBeforeTheParkIsConfirmedIsReparkedByTheNextPass() async throws {
        let hidden = hiddenWindows(1)
        try await settle([sixK], hidden: hidden)
        connect([builtin])
        try await pass(.globalObserver(screenParams))
        hidden[0].reportsMoves = false
        hidden[0].silentlyMove(to: CGPoint(x: 0, y: 33))
        try await pass(.globalObserverLeftMouseUp)
        assertHidden(hidden, on: builtin, "the unconfirmed park was re-checked")
    }

    func testReverseBuiltinToSixKReparksAtTheSixKsCorner() async throws {
        let hidden = hiddenWindows(3)
        try await settle([builtin], hidden: hidden)
        connect([sixK])
        try await pass(.globalObserver(screenParams))
        XCTAssertTrue(hidden.allSatisfy { $0.nativeRect.topLeftCorner == parkedPoint(on: sixK) })
        assertHidden(hidden, on: sixK)
    }

    func testTwoExternalsToOneParksTheGoneDisplaysWindowsOnTheSurvivor() async throws {
        let left = ParkingTestMonitor("Left", width: 1920, height: 1080, uuid: "LEFT")
        let right = ParkingTestMonitor("Right", x: 1920, width: 2560, height: 1440, uuid: "RIGHT", isMain: false)
        connect([left, right])
        let leftWorkspace = left.activeWorkspace
        let rightWorkspace = right.activeWorkspace
        _ = window(1, in: leftWorkspace.rootTilingContainer, Rect(topLeftX: 0, topLeftY: 25, width: 1920, height: 1055))
        let rightShown = window(2, in: rightWorkspace.rootTilingContainer, Rect(topLeftX: 1920, topLeftY: 25, width: 2560, height: 1415))
        let hiddenOnRight = Workspace.get(byName: "hidden-right")
        hiddenOnRight.seedMonitorIfNeeded(right)
        let parkedOnRight = window(3, in: hiddenOnRight.rootTilingContainer, Rect(topLeftX: 2000, topLeftY: 100, width: 1200, height: 800))
        try await settle([left, right], hidden: [parkedOnRight])
        XCTAssertEqual(parkedOnRight.nativeRect.topLeftCorner, parkedPoint(on: right))

        connect([left])
        XCTAssertTrue(left.activeWorkspace === leftWorkspace, "The surviving display keeps its workspace")
        XCTAssertFalse(rightWorkspace.isVisible)
        try await pass(.globalObserver(screenParams))
        try await pass(settled)
        assertHidden([parkedOnRight, rightShown], on: left)
        XCTAssertEqual(rightShown.nativeRect.topLeftCorner, parkedPoint(on: left))
    }

    // MARK: Pins in All Projects

    /// Tabs mode with projects A, B and C, and A's `g` pinned in All Projects, which shows in the
    /// project its display is in. Returns the projects and `g`, `b1` (B's) and `c1` (C's).
    private func pinSections() throws -> (a: WorkspaceProjectId, b: WorkspaceProjectId, c: WorkspaceProjectId,
                                          g: Workspace, b1: Workspace, c1: Workspace) {
        setSavedWorkspaceTestEnvironment()
        workspaceSidebarOrganizationStore = .init()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        let a = createWorkspaceProject().id, b = createWorkspaceProject().id, c = createWorkspaceProject().id
        let g = Workspace.get(byName: "g"), b1 = Workspace.get(byName: "b1"), c1 = Workspace.get(byName: "c1")
        g.assignProject(a)
        b1.assignProject(b)
        c1.assignProject(c)
        try setWorkspaceSidebarTabPinScope(g, .allProjects, projectId: a)
        return (a, b, c, g, b1, c1)
    }

    private func memory(_ monitor: Monitor) -> [WorkspaceProjectId: WorkspaceId]? {
        winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(monitor)]?.lastActiveWorkspaceByProject
    }

    func testADisplayShowingAPinInAllProjectsGoingAwayLeavesTheSurvivorInItsProject() async throws {
        defer { workspaceSidebarOrganizationStore = .init() }
        let t = try pinSections()
        let left = ParkingTestMonitor("Left", width: 1920, height: 1080, uuid: "LEFT")
        let right = ParkingTestMonitor("Right", x: 1920, width: 2560, height: 1440, uuid: "RIGHT", isMain: false)
        connect([left, right])
        XCTAssertTrue(left.setActiveWorkspace(t.b1))
        XCTAssertTrue(right.setActiveWorkspace(t.c1))
        _ = window(1, in: t.b1.rootTilingContainer, Rect(topLeftX: 0, topLeftY: 25, width: 1920, height: 1055))
        let pinWindow = window(2, in: t.g.rootTilingContainer, Rect(topLeftX: 1920, topLeftY: 25, width: 2560, height: 1415))
        XCTAssertTrue(right.setActiveWorkspace(t.g))
        XCTAssertEqual(activeWorkspaceProjectId(for: right), t.c, "The right display shows the pin in C")
        let hiddenOnRight = Workspace.get(byName: "hidden-right")
        hiddenOnRight.assignProject(t.c)
        hiddenOnRight.seedMonitorIfNeeded(right)
        let parkedOnRight = window(3, in: hiddenOnRight.rootTilingContainer, Rect(topLeftX: 2000, topLeftY: 100, width: 1200, height: 800))
        try await settle([left, right], hidden: [parkedOnRight])

        connect([left])
        XCTAssertTrue(left.activeWorkspace === t.b1, "The surviving display keeps its tab")
        XCTAssertEqual(activeWorkspaceProjectId(for: left), t.b, "and its project")
        XCTAssertFalse(t.g.isVisible)
        XCTAssertTrue(workspaceIsPinnedInAllProjects(t.g), "Still in All Projects")
        XCTAssertEqual(t.g.projectId, t.a)
        try await pass(.globalObserver(screenParams))
        try await pass(settled)
        assertHidden([parkedOnRight, pinWindow], on: left, "re-parked on the survivor")
        XCTAssertEqual(pinWindow.nativeRect.topLeftCorner, parkedPoint(on: left))

        // Shown there now, it's in the project the survivor is in.
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertTrue(left.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: left), t.b)
    }

    func testTheSurvivingDisplayKeepsThePinInAllProjectsItShowsInItsProject() async throws {
        defer { workspaceSidebarOrganizationStore = .init() }
        let t = try pinSections()
        let left = ParkingTestMonitor("Left", width: 1920, height: 1080, uuid: "LEFT")
        let right = ParkingTestMonitor("Right", x: 1920, width: 2560, height: 1440, uuid: "RIGHT", isMain: false)
        connect([left, right])
        XCTAssertTrue(left.setActiveWorkspace(t.c1))
        XCTAssertTrue(right.setActiveWorkspace(t.b1))
        _ = window(1, in: t.g.rootTilingContainer, Rect(topLeftX: 0, topLeftY: 25, width: 1920, height: 1055))
        let rightShown = window(2, in: t.b1.rootTilingContainer, Rect(topLeftX: 1920, topLeftY: 25, width: 2560, height: 1415))
        XCTAssertTrue(left.setActiveWorkspace(t.g))
        XCTAssertEqual(activeWorkspaceProjectId(for: left), t.c)
        let remembered = memory(left)
        try await settle([left, right], hidden: [])

        connect([left])
        XCTAssertTrue(left.activeWorkspace === t.g, "The survivor keeps the pin on screen")
        XCTAssertEqual(activeWorkspaceProjectId(for: left), t.c, "in the project it was in, not the pin's own")
        XCTAssertEqual(memory(left)?[t.c], t.g.id, "and C still remembers the pin chosen there")
        for (project, id) in remembered ?? [:] where winMuxWorkspaceState.workspaceById[id] != nil {
            XCTAssertEqual(memory(left)?[project], id, "Every remembered tab that's still there is remembered")
        }
        XCTAssertFalse(t.b1.isVisible)
        try await pass(.globalObserver(screenParams))
        try await pass(settled)
        assertHidden([rightShown], on: left)
        XCTAssertEqual(rightShown.nativeRect.topLeftCorner, parkedPoint(on: left))
    }

    func testNoScreensForAWhileKeepThePinInAllProjectsOnScreenInItsProject() async throws {
        defer { workspaceSidebarOrganizationStore = .init() }
        let t = try pinSections()
        connect([sixK])
        _ = window(1, in: t.g.rootTilingContainer, Rect(topLeftX: 0, topLeftY: 25, width: 3008, height: 1667))
        let hidden = window(2, in: t.b1.rootTilingContainer, Rect(topLeftX: 100, topLeftY: 100, width: 1200, height: 800))
        // C remembers its own tab; the pin, chosen in B, was carried into C by switching project.
        XCTAssertTrue(sixK.setActiveWorkspace(t.c1))
        XCTAssertTrue(sixK.setActiveWorkspace(t.b1))
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertTrue(switchWorkspaceProject(t.c, on: sixK) === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: sixK), t.c)
        XCTAssertEqual(memory(sixK)?[t.c], t.c1.id)
        let remembered = memory(sixK)
        try await settle([sixK], hidden: [hidden])

        connect([noDisplay])
        XCTAssertTrue(noDisplay.activeWorkspace === t.g)
        connect([builtin])
        XCTAssertTrue(builtin.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: builtin), t.c, "Back on a display, the pin is still shown in C")
        XCTAssertEqual(memory(builtin)?[t.c], t.c1.id, "Showing the pin again there chose nothing: C still remembers c1")
        for (project, id) in remembered ?? [:] where winMuxWorkspaceState.workspaceById[id] != nil {
            XCTAssertEqual(memory(builtin)?[project], id)
        }
        try await pass(.globalObserver(screenParams))
        try await pass(settled)
        assertHidden([hidden], on: builtin)
    }

    // MARK: Confirmation and bounded retries

    func testAParkWriteThatFailsIsRetriedOnTheNextPass() async throws {
        let hidden = hiddenWindows(1)
        try await settle([sixK], hidden: hidden)
        connect([builtin])
        hidden[0].failingWrites = 1
        try await pass(.globalObserver(screenParams))
        XCTAssertEqual(hidden[0].nativeRect.topLeftCorner, parkedPoint(on: sixK), "The write failed")
        try await pass(.globalObserverLeftMouseUp)
        XCTAssertEqual(hidden[0].nativeRect.topLeftCorner, parkedPoint(on: builtin), "Not trusted as parked: retried")
    }

    func testAFailedReassertionWriteIsRetriedOnTheNextPass() async throws {
        let hidden = hiddenWindows(1)
        try await settle([builtin], hidden: hidden)
        hidden[0].silentlyMove(to: CGPoint(x: 0, y: 33))
        hidden[0].failingWrites = 1
        try await pass(.globalObserver(wake))
        XCTAssertGreaterThan(hidden[0].visibleArea(on: builtin), 1)
        try await pass(.ax(kAXFocusedWindowChangedNotification as String))
        assertHidden(hidden, on: builtin)
    }

    func testRetriesForAWindowThatRefusesItsParkAreBounded() async throws {
        let hidden = hiddenWindows(1)
        try await settle([sixK], hidden: hidden)
        connect([builtin])
        hidden[0].refusesWrites = true
        let firstPasses = try await cost(hidden) {
            try await pass(.globalObserver(screenParams))
            for _ in 0 ..< 10 { try await pass(.globalObserverLeftMouseUp) }
        }
        XCTAssertEqual(firstPasses.writes, HiddenWindowParking.maxUnconfirmedParks + 1)
        let idle = try await cost(hidden) {
            for _ in 0 ..< 10 { try await pass(.globalObserverLeftMouseUp) }
        }
        XCTAssertEqual(idle.writes, 0)
        XCTAssertEqual(idle.reads, 0, "No polling once retries are spent")
        let afterWake = try await cost(hidden) {
            try await pass(.globalObserver(wake))
            for _ in 0 ..< 10 { try await pass(.globalObserverLeftMouseUp) }
        }
        XCTAssertEqual(afterWake.writes, HiddenWindowParking.maxUnconfirmedParks + 1, "A reassertion gets a fresh, still bounded, budget")
    }

    // MARK: Wake, cost, and no polling

    func testWakeWithNoDisplayChangeRewritesOnlyWindowsThatMoved() async throws {
        let hidden = hiddenWindows(4)
        try await settle([builtin], hidden: hidden)
        hidden[2].silentlyMove(to: CGPoint(x: 0, y: 33))
        let submissionsBefore = hidden.map(\.frameSubmissions)
        let wakeCost = try await cost(hidden) { try await pass(.globalObserver(wake)) }
        XCTAssertEqual(wakeCost.writes, 1, "Only the moved window is written")
        XCTAssertEqual(zip(hidden.map(\.frameSubmissions), submissionsBefore).map { $0 - $1 }, [0, 0, 1, 0])
        assertHidden(hidden, on: builtin)
    }

    func testATopologyChangeParksEachHiddenWindowOnceAndThenCostsNothing() async throws {
        let hidden = hiddenWindows(10)
        try await settle([sixK], hidden: hidden)
        connect([builtin])
        let firstPass = try await cost(hidden) { try await pass(.globalObserver(screenParams)) }
        XCTAssertEqual(firstPass.writes, 10, "One write per hidden window")
        let confirmation = try await cost(hidden) { try await pass(.ax(kAXMovedNotification as String)) }
        XCTAssertEqual(confirmation.writes, 0)
        XCTAssertLessThanOrEqual(confirmation.reads, 20)
        let submissionsBefore = hidden.map(\.frameSubmissions).reduce(0, +)
        let settledPass = try await cost(hidden) { try await pass(settled) }
        XCTAssertEqual(settledPass.writes, 0, "Nothing moved: the settled re-park only reads")
        XCTAssertEqual(settledPass.reads, 10, "One read per hidden window")
        XCTAssertEqual(hidden.map(\.frameSubmissions).reduce(0, +), submissionsBefore, "Nor submits a frame for a window in place")
        let idle = try await cost(hidden) {
            for event: RefreshSessionEvent in [.globalObserverLeftMouseUp, .hotkeyBinding, .onTabSwitched,
                                               .ax(kAXFocusedWindowChangedNotification as String), .globalObserver(screenParams)]
            {
                try await pass(event)
            }
        }
        XCTAssertEqual(idle.reads, 0)
        XCTAssertEqual(idle.writes, 0)
        assertHidden(hidden, on: builtin)
    }

    // MARK: Zero screens

    func testNoWritesAgainstThePlaceholderForMissingScreens() async throws {
        connect([sixK])
        let shown = window(1, in: focus.workspace.rootTilingContainer, Rect(topLeftX: 0, topLeftY: 25, width: 3008, height: 1667))
        let hidden = hiddenWindows(2)
        try await settle([sixK], hidden: hidden)
        connect([noDisplay])
        XCTAssertFalse(hasRealMonitorTopology)
        let zeroScreens = try await cost(hidden + [shown]) {
            try await pass(.globalObserver(wake))
            try await pass(settled)
            try await pass(.globalObserverLeftMouseUp)
            try await focus.workspace.layoutWorkspace()
            try await hidden[0].hideInCorner(.bottomRightCorner, reassert: true) { true }
        }
        XCTAssertEqual(zeroScreens.writes, 0)
        XCTAssertEqual(zeroScreens.reads, 0)
        XCTAssertTrue(hidden.allSatisfy(\.isHiddenInCorner), "Hidden state is kept for when a display comes back")

        connect([builtin])
        XCTAssertTrue(hasRealMonitorTopology)
        try await pass(.globalObserver(screenParams))
        XCTAssertTrue(hidden.allSatisfy { $0.nativeRect.topLeftCorner == parkedPoint(on: builtin) })
    }

    func testTheZeroScreensMigrationKeepsTheVisibleWorkspace() {
        connect([sixK])
        let visible = focus.workspace
        let hidden = Workspace.get(byName: "hidden")
        _ = window(2, in: hidden.rootTilingContainer, Rect(topLeftX: 100, topLeftY: 100, width: 1200, height: 800))
        _ = window(1, in: visible.rootTilingContainer, Rect(topLeftX: 0, topLeftY: 25, width: 3008, height: 1667))
        Workspace.reconcileWorkspaceState()
        connect([noDisplay])
        XCTAssertTrue(noDisplay.activeWorkspace === visible)
        connect([builtin])
        XCTAssertTrue(builtin.activeWorkspace === visible)
        XCTAssertFalse(hidden.isVisible)
        XCTAssertEqual(hidden.workspaceMonitor.name, "Built-in")
    }

    // MARK: Tiling and floating windows

    func testHiddenTilingAndFloatingWindowsAreBothReparked() async throws {
        connect([sixK])
        let hiddenWorkspace = Workspace.get(byName: "hidden-mixed")
        let tiled = window(2, in: hiddenWorkspace.rootTilingContainer, Rect(topLeftX: 100, topLeftY: 100, width: 1200, height: 800))
        let floating = window(3, in: hiddenWorkspace, Rect(topLeftX: 500, topLeftY: 400, width: 900, height: 700))
        try await settle([sixK], hidden: [tiled, floating])
        connect([builtin])
        try await pass(.globalObserver(screenParams))
        try await pass(.ax(kAXMovedNotification as String))
        for window in [tiled, floating] { window.silentlyMove(to: CGPoint(x: 40, y: 60)) }
        try await pass(settled)
        assertHidden([tiled, floating], on: builtin)

        // Shown again: the floating window comes back inside the built-in.
        XCTAssertTrue(builtin.setActiveWorkspace(hiddenWorkspace))
        try await pass(.hotkeyBinding)
        XCTAssertFalse(floating.isHiddenInCorner)
        XCTAssertTrue(builtin.rect.contains(floating.nativeRect.topLeftCorner))
        XCTAssertTrue(tiled.nativeRect.minX >= 0 && tiled.nativeRect.maxX <= builtin.rect.maxX)
    }

    // MARK: Window tab groups

    private func tabGroup() -> (active: ParkingTestWindow, inactive: [ParkingTestWindow]) {
        config.windowTabs.enabled = true
        config.workspaceSidebar.enabled = false
        let group = TilingContainer(parent: focus.workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, .v, .tabGroup, index: INDEX_BIND_LAST)
        let rect = Rect(topLeftX: 0, topLeftY: 33, width: 1512, height: 949)
        let inactive = [window(11, in: group, rect), window(12, in: group, rect)]
        let active = window(10, in: group, rect)
        active.markAsMostRecentChild()
        return (active, inactive)
    }

    func testInactiveTabsAreConfirmedAndReparkedOnWakeAndOnMoveEvents() async throws {
        connect([builtin])
        let (active, inactive) = tabGroup()
        XCTAssertTrue(active.nearestWindowTabGroup?.usesWindowTabBehavior == true)
        try await pass(.globalObserverLeftMouseUp)
        try await pass(.globalObserverLeftMouseUp)
        assertHidden(inactive, on: builtin)
        XCTAssertGreaterThan(active.visibleArea(on: builtin), 1)
        let idle = try await cost(inactive) { try await pass(.globalObserverLeftMouseUp) }
        XCTAssertEqual(idle.reads + idle.writes, 0, "Confirmed parked tabs cost nothing")

        inactive[0].moveReportingAxEvent(to: CGPoint(x: 0, y: 33))
        try await pass(.globalObserverLeftMouseUp)
        assertHidden(inactive, on: builtin, "a reported move is re-parked")

        inactive[1].silentlyMove(to: CGPoint(x: 0, y: 33))
        try await pass(.globalObserver(wake))
        assertHidden(inactive, on: builtin, "wake re-parks a silently moved tab")
    }

    func testInactiveTabsStopParkingAtANewerDisplayChange() async throws {
        connect([sixK])
        let (_, inactive) = tabGroup()
        try await pass(.globalObserverLeftMouseUp)
        try await pass(.globalObserverLeftMouseUp)
        connect([builtin])
        for window in inactive {
            window.onWrite = { MonitorConfigurationObserver.shared.noteDisplayChangeForTests() }
        }
        let writes = try await cost(inactive) { try await focus.workspace.layoutWorkspace() }.writes
        XCTAssertEqual(writes, 1, "The second tab isn't parked against displays that changed again")
    }

    // MARK: Review round 1

    private func cancelSettledRefresh(with lightSession: () async throws -> Void) async throws -> [HiddenWindowsReassertion?] {
        var reassertions: [HiddenWindowsReassertion?] = []
        var paused: CheckedContinuation<Void, Never>?
        await withCheckedContinuation { started in
            setScheduledRefreshOverrideForTests { _, _, _ in
                reassertions.append(refreshSessionRequirements?.hiddenWindowsReassertion)
                if reassertions.count == 1 {
                    await withCheckedContinuation {
                        paused = $0
                        started.resume()
                    }
                }
            }
            scheduleRefreshSession(settled)
        }
        try? await lightSession()
        paused?.resume()
        try await waitForScheduledRefreshForTests()
        return reassertions
    }

    func testACommandWithoutAFollowUpRefreshStillRunsTheSettledRefreshItCancelled() async throws {
        let reassertions = try await cancelSettledRefresh {
            try await runLightSession(.hotkeyBinding, .forceRun, shouldSchedulePostRefresh: false) {}
        }
        XCTAssertEqual(reassertions.count, 2, "\(reassertions)")
        XCTAssertEqual(reassertions.last, .displayTopology(generation: MonitorConfigurationObserver.shared.topologyGeneration))
    }

    func testACommandThatThrowsStillRunsTheSettledRefreshItCancelled() async throws {
        struct CommandFailed: Error {}
        let reassertions = try await cancelSettledRefresh {
            try await runLightSession(.hotkeyBinding, .forceRun) { throw CommandFailed() }
        }
        XCTAssertEqual(reassertions.count, 2, "\(reassertions)")
        XCTAssertEqual(reassertions.last, .displayTopology(generation: MonitorConfigurationObserver.shared.topologyGeneration))
    }

    func testAFailedParkStaysUnconfirmedAfterAFullRefreshRereadsTheFrame() async throws {
        connect([builtin])
        let hiddenWorkspace = Workspace.get(byName: "hidden-floating")
        let floating = window(3, in: hiddenWorkspace, Rect(topLeftX: 500, topLeftY: 400, width: 900, height: 700))
        try await settle([builtin], hidden: [floating])
        floating.silentlyMove(to: CGPoint(x: 40, y: 60))
        floating.failingWrites = 1
        try await pass(settled)
        XCTAssertGreaterThan(floating.visibleArea(on: builtin), 1, "The re-park write failed")
        // A full refresh re-warms floating windows' dropped frame caches (refresh()).
        _ = try await floating.getAxRect()
        XCTAssertNotNil(floating.lastKnownActualRect)
        try await pass(.globalObserverLeftMouseUp)
        assertHidden([floating], on: builtin, "still owed a retry")
    }

    func testRetriesAreBoundedWhenFrameReadsFail() async throws {
        let hidden = hiddenWindows(1)
        try await settle([sixK], hidden: hidden)
        connect([builtin])
        hidden[0].readsFail = true
        hidden[0].refusesWrites = true
        for _ in 0 ..< 10 { try await pass(.globalObserverLeftMouseUp) }
        XCTAssertLessThanOrEqual(hidden[0].frameSubmissions, 1 + 1 + HiddenWindowParking.maxUnconfirmedParks)
        let idle = try await cost(hidden) {
            for _ in 0 ..< 10 { try await pass(.globalObserverLeftMouseUp) }
        }
        XCTAssertEqual(idle.reads + idle.writes, 0, "No reads or writes once retries are spent, even with the cache empty")

        // A real event for the window earns one more look.
        hidden[0].moveReportingAxEvent(to: CGPoint(x: 0, y: 33))
        let afterEvent = try await cost(hidden) {
            for _ in 0 ..< 5 { try await pass(.globalObserverLeftMouseUp) }
        }
        XCTAssertEqual(afterEvent.writes, 1)
    }

    func testAFullscreenLayoutWritesNothingOnceTheDisplaysGoAwayMidPass() async throws {
        connect([builtin])
        let root = focus.workspace.rootTilingContainer
        let other = window(21, in: root, Rect(topLeftX: 0, topLeftY: 33, width: 756, height: 949))
        let fullscreen = window(20, in: root, Rect(topLeftX: 756, topLeftY: 33, width: 756, height: 949))
        fullscreen.isFullscreen = true
        fullscreen.markAsMostRecentChild()
        other.onRead = { [self] in
            other.onRead = nil
            connect([noDisplay])
        }
        let before = fullscreen.frameSubmissions
        try await focus.workspace.layoutWorkspace()
        XCTAssertEqual(fullscreen.frameSubmissions, before, "No fullscreen frame against the placeholder")
        XCTAssertEqual(other.frameSubmissions, 0)
    }

    func testSelectingAnInactiveTabWhileItsParkReadsLeavesItShown() async throws {
        connect([builtin])
        let (active, inactive) = tabGroup()
        try await pass(.globalObserverLeftMouseUp)
        try await pass(.globalObserverLeftMouseUp)
        assertHidden(inactive, on: builtin)
        let selected = inactive[0]
        selected.onRead = {
            selected.onRead = nil
            // focusWindowFromTabStrip: put it where the active tab is, make it the active tab.
            selected.silentlyMove(to: active.nativeRect.topLeftCorner)
            selected.markAsMostRecentChild()
        }
        let submissions = selected.frameSubmissions
        try await pass(.globalObserver(wake))
        XCTAssertEqual(selected.frameSubmissions, submissions, "The old pass doesn't park the newly selected tab")
        XCTAssertGreaterThan(selected.visibleArea(on: builtin), 1)
    }

    func testAnOlderLayoutDoesNotParkATabANewerLayoutShows() async throws {
        connect([builtin])
        let (_, inactive) = tabGroup()
        try await pass(.globalObserverLeftMouseUp)
        try await pass(.globalObserverLeftMouseUp)
        let tab = inactive[0]
        let held = expectation(description: "older pass reading the tab")
        tab.holdNextRead = true
        tab.onReadHeld = { held.fulfill() }
        let older = Task { try await pass(.globalObserver(wake)) }
        await fulfillment(of: [held], timeout: 2)
        // A command takes the tab out of its group; a newer layout shows it as an ordinary tile.
        tab.bind(to: focus.workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        try await pass(.hotkeyBinding)
        XCTAssertGreaterThan(tab.visibleArea(on: builtin), 1)
        let submissions = tab.frameSubmissions
        tab.readGate?.resume()
        try await older.value
        XCTAssertEqual(tab.frameSubmissions, submissions, "The older pass doesn't park what the newer one shows")
        XCTAssertGreaterThan(tab.visibleArea(on: builtin), 1)
    }

    func testTilesAfterAParkThatSpannedADisplayChangeAreNotWritten() async throws {
        connect([builtin])
        let (_, inactive) = tabGroup()
        let tile = window(30, in: focus.workspace.rootTilingContainer, Rect(topLeftX: 5, topLeftY: 50, width: 300, height: 300))
        inactive[0].onRead = { [self] in
            inactive[0].onRead = nil
            connect([builtin]) // Displays reconfigured (same geometry, new topology).
        }
        try await focus.workspace.layoutWorkspace()
        XCTAssertEqual(tile.frameSubmissions, 0, "Laid out by the refresh for the new displays, not with the stale geometry")
    }

    func testAFloatingWindowIsNotMovedAcrossDisplaysThatChangedDuringItsRead() async throws {
        let left = ParkingTestMonitor("Left", width: 1920, height: 1080, uuid: "LEFT")
        let right = ParkingTestMonitor("Right", x: 1920, width: 2560, height: 1440, uuid: "RIGHT", isMain: false)
        connect([left, right])
        let floating = window(40, in: left.activeWorkspace, Rect(topLeftX: 2500, topLeftY: 100, width: 800, height: 600))
        floating.onRead = { [self] in
            floating.onRead = nil
            connect([left, right])
        }
        try await left.activeWorkspace.layoutWorkspace()
        XCTAssertEqual(floating.frameSubmissions, 0)
        try await left.activeWorkspace.layoutWorkspace()
        XCTAssertEqual(floating.frameSubmissions, 1, "Without a display change it's moved onto its workspace's display")
    }

    func testAParkWhoseMoveEventIsSuppressedIsConfirmedByOneRead() async throws {
        let hidden = hiddenWindows(1)
        try await settle([sixK], hidden: hidden)
        connect([builtin])
        hidden[0].reportsMoves = false // e.g. post-drag suppression of the app's kAXMoved
        try await pass(.globalObserver(screenParams))
        XCTAssertEqual(hidden[0].nativeRect.topLeftCorner, parkedPoint(on: builtin))
        let confirmation = try await cost(hidden) { try await pass(.globalObserverLeftMouseUp) }
        XCTAssertEqual(confirmation.reads, 1, "Seen in place: confirmed, nothing resubmitted")
        XCTAssertEqual(confirmation.writes, 0)
        let idle = try await cost(hidden) { for _ in 0 ..< 5 { try await pass(.globalObserverLeftMouseUp) } }
        XCTAssertEqual(idle.reads + idle.writes, 0)
    }

    func testAWorkspaceShownWhileNoDisplayExistsIsRestoredOnlyOnARealDisplay() async throws {
        connect([builtin])
        let hiddenWorkspace = Workspace.get(byName: "hidden-floating")
        let floating = window(3, in: hiddenWorkspace, Rect(topLeftX: 500, topLeftY: 400, width: 600, height: 400))
        try await settle([builtin], hidden: [floating])
        XCTAssertTrue(floating.isHiddenInCorner)
        connect([noDisplay])
        XCTAssertTrue(noDisplay.setActiveWorkspace(hiddenWorkspace))
        let submissions = floating.frameSubmissions
        try await pass(.hotkeyBinding)
        XCTAssertEqual(floating.frameSubmissions, submissions, "Not restored against the placeholder")
        XCTAssertTrue(floating.isHiddenInCorner, "Keeps where to restore it")
        connect([builtin])
        XCTAssertTrue(builtin.setActiveWorkspace(hiddenWorkspace))
        try await pass(.globalObserver(screenParams))
        XCTAssertFalse(floating.isHiddenInCorner)
        XCTAssertTrue(builtin.rect.contains(floating.nativeRect.topLeftCorner))
    }

    func testASettledReparkSupersededByANewerLayoutIsCarriedOutByIt() async throws {
        let hidden = hiddenWindows(2)
        try await settle([builtin], hidden: hidden)
        for window in hidden { window.silentlyMove(to: CGPoint(x: 0, y: 33)) }
        let held = expectation(description: "settled pass reading a parked window")
        hidden[0].holdNextRead = true
        hidden[0].onReadHeld = { held.fulfill() }
        let settledPass = Task { try await pass(settled) }
        await fulfillment(of: [held], timeout: 2)
        // A command's layout runs meanwhile and supersedes the settled pass.
        try await pass(.hotkeyBinding)
        assertHidden(hidden, on: builtin, "the newer pass re-parks on the settled refresh's behalf")
        hidden[0].readGate?.resume()
        try await settledPass.value
        assertHidden(hidden, on: builtin)
        let confirmation = try await cost(hidden) { try await pass(.hotkeyBinding) }
        XCTAssertEqual(confirmation.reads, 2, "Confirms the re-parks")
        let idle = try await cost(hidden) { for _ in 0 ..< 3 { try await pass(.hotkeyBinding) } }
        XCTAssertEqual(idle.reads + idle.writes, 0, "Owed only until a pass completes: no more re-reads")
    }

    func testAStaleFullscreenPassDoesNotOverwriteANewerLayout() async throws {
        connect([builtin])
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let other = window(21, in: root, Rect(topLeftX: 0, topLeftY: 33, width: 756, height: 949))
        let fullscreen = window(20, in: root, Rect(topLeftX: 756, topLeftY: 33, width: 756, height: 949))
        fullscreen.isFullscreen = true
        fullscreen.markAsMostRecentChild()
        let held = expectation(description: "fullscreen pass parking the other window")
        other.holdNextRead = true
        other.onReadHeld = { held.fulfill() }
        let older = Task { try await workspace.layoutWorkspace() }
        await fulfillment(of: [held], timeout: 2)
        // A command leaves fullscreen and a newer layout tiles both windows.
        fullscreen.isFullscreen = false
        try await workspace.layoutWorkspace()
        let tiled = fullscreen.nativeRect
        XCTAssertLessThan(tiled.width, builtin.visibleRect.width)
        other.readGate?.resume()
        try await older.value
        XCTAssertEqual(fullscreen.nativeRect, tiled, "The stale pass doesn't apply its fullscreen frame")
        XCTAssertFalse(other.isHiddenInCorner)
    }

    func testAStalePassDoesNotShowATileANewerLayoutHid() async throws {
        connect([builtin])
        let (_, inactive) = tabGroup()
        let tile = window(30, in: focus.workspace.rootTilingContainer, Rect(topLeftX: 5, topLeftY: 50, width: 300, height: 300))
        try await pass(.globalObserverLeftMouseUp)
        try await pass(.globalObserverLeftMouseUp)
        let held = expectation(description: "older pass re-reading a parked tab")
        inactive[0].holdNextRead = true
        inactive[0].onReadHeld = { held.fulfill() }
        let older = Task { try await pass(.globalObserver(wake)) }
        await fulfillment(of: [held], timeout: 2)
        // A command moves the tile to another workspace; a newer layout parks it.
        tile.bind(to: Workspace.get(byName: "elsewhere").rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        try await pass(.hotkeyBinding)
        assertHidden([tile], on: builtin)
        let submissions = tile.frameSubmissions
        inactive[0].readGate?.resume()
        try await older.value
        XCTAssertEqual(tile.frameSubmissions, submissions, "The stale pass doesn't lay the tile out again")
        assertHidden([tile], on: builtin)
    }

    func testAStalePassSurvivesATileMadeFloatingWhileItWaited() async throws {
        connect([builtin])
        let (_, inactive) = tabGroup()
        let workspace = focus.workspace
        let tile = window(30, in: workspace.rootTilingContainer, Rect(topLeftX: 5, topLeftY: 50, width: 300, height: 300))
        try await pass(.globalObserverLeftMouseUp)
        try await pass(.globalObserverLeftMouseUp)
        let held = expectation(description: "older pass re-reading a parked tab")
        inactive[0].holdNextRead = true
        inactive[0].onReadHeld = { held.fulfill() }
        let older = Task { try await pass(.globalObserver(wake)) }
        await fulfillment(of: [held], timeout: 2)
        // A command makes the following tile floating; its own layout hasn't run yet.
        tile.bind(to: workspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        let submissions = tile.frameSubmissions
        inactive[0].readGate?.resume()
        try await older.value // Must not reach the floating window's (nonexistent) tiling weight
        XCTAssertEqual(tile.frameSubmissions, submissions)
    }

    func testAStalePassDoesNotDischargeAReassertionItsReplacementStillOwes() async throws {
        connect([builtin])
        let (_, inactive) = tabGroup()
        let hidden = hiddenWindows(3)
        try await settle([builtin], hidden: hidden)
        let lastHidden = try XCTUnwrap(Workspace.all.filter { !$0.isVisible }.last?.allLeafWindowsRecursive.last as? ParkingTestWindow)
        let displaced = hidden.filter { $0 !== lastHidden }.prefix(1) + [lastHidden]
        let quiet = try XCTUnwrap(hidden.first { window in !displaced.contains { $0 === window } })
        for window in displaced { window.silentlyMove(to: CGPoint(x: 0, y: 33)) }
        // The settled pass waits on its last hidden window.
        let settledHeld = expectation(description: "settled pass on its last hidden window")
        lastHidden.holdNextRead = true
        lastHidden.onReadHeld = { settledHeld.fulfill() }
        let settledPass = Task { try await pass(settled) }
        await fulfillment(of: [settledHeld], timeout: 2)
        // A replacement pass starts and waits in the visible workspace's layout.
        let replacementHeld = expectation(description: "replacement pass in visible layout")
        inactive[0].moveReportingAxEvent(to: parkedPoint(on: builtin))
        inactive[0].holdNextRead = true
        inactive[0].onReadHeld = { replacementHeld.fulfill() }
        let replacement = Task { try await pass(.hotkeyBinding) }
        await fulfillment(of: [replacementHeld], timeout: 2)
        // The superseded settled pass finishes first.
        lastHidden.readGate?.resume()
        try await settledPass.value
        inactive[0].readGate?.resume()
        try await replacement.value
        assertHidden(hidden, on: builtin, "the replacement still re-parks on the settled refresh's behalf")
        let afterward = try await cost([quiet]) { try await pass(.hotkeyBinding) }
        XCTAssertEqual(afterward.reads, 0, "The completed replacement discharged the re-park: no more re-reads")
    }

    func testSelectingATabDuringAReassertionStillReparksTheOtherTabs() async throws {
        connect([builtin])
        config.windowTabs.enabled = true
        config.workspaceSidebar.enabled = false
        let group = TilingContainer(parent: focus.workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, .v, .tabGroup, index: INDEX_BIND_LAST)
        let rect = Rect(topLeftX: 0, topLeftY: 33, width: 1512, height: 949)
        let b = window(11, in: group, rect)
        let c = window(12, in: group, rect)
        let a = window(10, in: group, rect)
        a.markAsMostRecentChild()
        try await pass(.globalObserverLeftMouseUp)
        try await pass(.globalObserverLeftMouseUp)
        assertHidden([b, c], on: builtin)
        b.silentlyMove(to: CGPoint(x: 0, y: 33))
        c.silentlyMove(to: CGPoint(x: 0, y: 33))
        b.onRead = {
            b.onRead = nil
            b.markAsMostRecentChild() // focusWindowFromTabStrip selects B
        }
        try await pass(settled)
        XCTAssertGreaterThan(b.visibleArea(on: builtin), 1, "The newly selected tab isn't parked")
        assertHidden([c], on: builtin, "The other inactive tab is still re-parked")
        try await pass(.onTabSwitched) // the tab switch's own refresh
        assertHidden([a, c], on: builtin)
    }

    func testAReparkGivenUpWhenItsWindowMovedIsCarriedOutByTheNextPass() async throws {
        let hidden = hiddenWindows(2)
        try await settle([builtin], hidden: hidden)
        let hiddenWorkspaces = Workspace.all.filter { !$0.isVisible && !$0.allLeafWindowsRecursive.isEmpty }
        let first = try XCTUnwrap(hiddenWorkspaces.first)
        let last = try XCTUnwrap(hiddenWorkspaces.last)
        let moving = try XCTUnwrap(last.allLeafWindowsRecursive.first as? ParkingTestWindow)
        for window in hidden { window.silentlyMove(to: CGPoint(x: 0, y: 33)) }
        moving.onRead = {
            moving.onRead = nil
            // A command moves it to a hidden workspace this pass already went through.
            moving.bind(to: first.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        try await pass(settled)
        try await pass(.globalObserverLeftMouseUp)
        assertHidden(hidden, on: builtin, "the given-up re-park stays owed until a pass carries it out")
    }

    func testATraversalStoppedByATreeChangeLeavesTheReparkOwed() async throws {
        connect([builtin])
        config.windowTabs.enabled = true
        config.workspaceSidebar.enabled = false
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        func group(_ ids: [UInt32]) -> [ParkingTestWindow] {
            let container = TilingContainer(parent: root, adaptiveWeight: WEIGHT_AUTO, .v, .tabGroup, index: INDEX_BIND_LAST)
            let windows = ids.map { window($0, in: container, Rect(topLeftX: 0, topLeftY: 33, width: 500, height: 949)) }
            windows.last?.markAsMostRecentChild()
            return windows
        }
        let first = group([11, 10])
        let tile = window(30, in: root, Rect(topLeftX: 600, topLeftY: 33, width: 300, height: 949))
        let second = group([21, 20])
        try await pass(.globalObserverLeftMouseUp)
        try await pass(.globalObserverLeftMouseUp)
        assertHidden([first[0], second[0]], on: builtin)
        second[0].silentlyMove(to: CGPoint(x: 1000, y: 33)) // an inactive tab macOS moved back on screen
        let held = expectation(description: "settled pass re-reading the first group's inactive tab")
        first[0].holdNextRead = true
        first[0].onReadHeld = { held.fulfill() }
        let settledPass = Task { try await pass(settled) }
        await fulfillment(of: [held], timeout: 2)
        // A running command makes the tile floating; its own layout hasn't run yet.
        tile.bind(to: workspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        first[0].readGate?.resume()
        try await settledPass.value
        try await pass(.hotkeyBinding) // the command's ordinary layout
        assertHidden([second[0]], on: builtin, "the stopped pass left its re-park owed")
    }

    func testParkingStateBoundsRetriesIndependentlyOfTheFrameCache() {
        var parking = HiddenWindowParking()
        let rect = builtin.visibleRect
        let target = parkedPoint(on: builtin)
        let away = Rect(topLeftX: 0, topLeftY: 33, width: 100, height: 100)
        for attempt in 1 ... HiddenWindowParking.maxUnconfirmedParks {
            XCTAssertEqual(parking.park(corner: .bottomRightCorner, monitorVisibleRect: rect, target: target, observed: away,
                                        reasserting: false, nativeGeneration: 7), .unconfirmed, "\(attempt)")
            XCTAssertTrue(parking.awaitsConfirmation)
        }
        XCTAssertEqual(parking.park(corner: .bottomRightCorner, monitorVisibleRect: rect, target: target, observed: nil,
                                    reasserting: false, nativeGeneration: 7), .retriesExhausted)
        XCTAssertFalse(parking.awaitsConfirmation)
        XCTAssertFalse(parking.mayRetry(atNativeGeneration: 7))
        XCTAssertTrue(parking.mayRetry(atNativeGeneration: 8))
        XCTAssertEqual(parking.park(corner: .bottomRightCorner, monitorVisibleRect: rect, target: target, observed: away,
                                    reasserting: true, nativeGeneration: 8), .unconfirmed, "A reassertion starts over")
        XCTAssertEqual(parking.park(corner: .bottomRightCorner, monitorVisibleRect: rect, target: target,
                                    observed: Rect(topLeftX: target.x, topLeftY: target.y, width: 100, height: 100),
                                    reasserting: false, nativeGeneration: 9), .confirmed)
        XCTAssertFalse(parking.awaitsConfirmation)
        XCTAssertTrue(parking.mayRetry(atNativeGeneration: 9))
    }

    // MARK: Per-display sidebar panels

    func testSidebarPanelsFollowTheClamshellTransition() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        config.workspaceSidebar.enabled = true
        let second = ParkingTestMonitor("Second", x: 3008, width: 2560, height: 1440, uuid: "SECOND", isMain: false)
        connect([sixK, second])
        WorkspaceSidebarPanel.refreshAll()
        defer {
            setMonitorsForTests(nil)
            WorkspaceSidebarPanel.refreshAll()
        }
        let mainScope = workspaceSidebarMonitorScopeId(for: sixK)
        let secondScope = workspaceSidebarMonitorScopeId(for: second)
        XCTAssertNotNil(WorkspaceSidebarPanel.panel(for: mainScope))
        XCTAssertNotNil(WorkspaceSidebarPanel.panel(for: secondScope))

        connect([builtin])
        WorkspaceSidebarPanel.refreshAll()
        XCTAssertNil(WorkspaceSidebarPanel.panel(for: secondScope), "The gone display's panel is retired")
        XCTAssertNotNil(WorkspaceSidebarPanel.panel(for: workspaceSidebarMonitorScopeId(for: builtin)))
    }
}
