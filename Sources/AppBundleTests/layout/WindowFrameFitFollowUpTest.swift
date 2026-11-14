@testable import AppBundle
import AppKit
import Common
import XCTest

/// The design committee's review (Astra + Carbon, 2026-11-13), through the real layout, commands and display
/// observer: what rearms a window's frame fit, what keeps it, and the follow-up that finishes a write no later
/// layout would (post-drag AX suppression, frames reused).
@MainActor
final class WindowFrameFitFollowUpTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setMonitorsForTests([FitTestMonitor()])
        startFrameFitTestClock()
    }

    override func tearDown() async throws {
        stopFrameFitTestClock()
        currentlyManipulatedWithMouseWindowId = nil
        setCurrentMouseManipulationKind(.none)
        setMonitorsForTests(nil)
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    /// Layout passes for `event`, each well past the settle interval after the last: follow-ups due meanwhile ran first.
    private func layout(_ workspace: Workspace, passes: Int = 1, event: RefreshSessionEvent = .ax(kAXResizedNotification as String))
        async throws
    {
        for _ in 0 ..< passes {
            advanceFrameFitTestClock(by: 0.1)
            try await $refreshSessionEvent.withValue(event) { try await workspace.layoutWorkspace() }
        }
    }

    private func layoutAll(event: RefreshSessionEvent = .ax(kAXResizedNotification as String)) async throws {
        advanceFrameFitTestClock(by: 0.1)
        try await $refreshSessionEvent.withValue(event) { try await layoutWorkspaces() }
    }

    /// The built-in display, and a larger one to its right.
    private func twoDisplays() -> (Monitor, Monitor) {
        let builtIn = SavedWorkspaceTestMonitor(id: 1, name: "Built-in", x: 0, width: 1512, height: 982, isMain: true,
            uuid: "BUILTIN", isBuiltin: true)
        let external = SavedWorkspaceTestMonitor(id: 2, name: "External", x: 1512, y: -200, width: 2560, height: 1440, uuid: "EXTERNAL")
        setMonitorsForTests([builtIn, external])
        MonitorConfigurationObserver.shared.noteDisplayChangeForTests()
        Workspace.reconcileWorkspaceState()
        return (builtIn, external)
    }

    /// Hands focus back to the first display: the last focused monitor outlives the test, and a later test would
    /// otherwise see its own first focus as a change of display.
    private func refocusFirstDisplay(_ builtIn: Monitor) {
        XCTAssertTrue(builtIn.activeWorkspace.focusWorkspace())
        checkOnFocusChangedCallbacks()
    }

    // MARK: Kept

    /// Two tiles of the same size trade places: each is only moved, whatever its app keeps.
    func testSwappingTwoTilesOfTheSameSizeWritesNoSize() async throws {
        let workspace = Workspace.get(byName: "swap")
        XCTAssertTrue(workspace.focusWorkspace())
        let plainApp = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480))
        let callApp = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 360), aspect: 16.0 / 9.0)
        let plain = FrameFitTestWindow(id: 1, parent: workspace.rootTilingContainer, native: plainApp)
        let call = FrameFitTestWindow(id: 2, parent: workspace.rootTilingContainer, native: callApp)
        try await layout(workspace, passes: WindowFrameFit.answersToLearn + 1)
        let left = try XCTUnwrap(plain.lastAppliedLayoutPhysicalRect)
        let right = try XCTUnwrap(call.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(left.size, right.size)
        XCTAssertEqual(plainApp.frame, left)
        let callSize = callApp.frame.size
        XCTAssertNotEqual(callSize, right.size, "The call window keeps its ratio")
        let writes = (plainApp.sizeWrites, callApp.sizeWrites)

        XCTAssertTrue(call.focusWindow())
        let result = try await parseCommand("swap left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)")
        try await layout(workspace, passes: 3)
        XCTAssertEqual(plain.lastAppliedLayoutPhysicalRect, right)
        XCTAssertEqual(plainApp.frame, right, "Moved to the other cell")
        XCTAssertEqual(plainApp.sizeWrites, writes.0, "Only moved")
        XCTAssertEqual(callApp.sizeWrites, writes.1, "The size its app keeps in a cell that size still holds")
        XCTAssertEqual(callApp.frame.size, callSize)
    }

    // MARK: Rearmed

    /// The user drags the edge of a lone tiled window, five times: each time it goes back to its cell, since there's
    /// no neighbour to give way. Letting go of a resize starts the window's fit over; the resize's own kAXResized
    /// wouldn't (it's no different from an app resizing itself).
    func testFiveEdgeDragsOnALoneTiledWindowEachSnapBack() async throws {
        let workspace = Workspace.get(byName: "drag")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480))
        let window = FrameFitTestWindow(id: 1, parent: workspace.rootTilingContainer, native: app)
        try await layout(workspace)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(app.frame, cell)

        for drag in 1 ... 5 {
            let dragged = Rect(topLeftX: cell.topLeftX, topLeftY: cell.topLeftY, width: cell.width - CGFloat(40 * drag), height: cell.height)
            app.resizeOnItsOwn(to: dragged.size)
            applyResizeWithMouse(window, rect: dragged)
            // The mouse goes up.
            currentlyManipulatedWithMouseWindowId = nil
            setCurrentMouseManipulationKind(.none)
            try await layout(workspace)
            XCTAssertEqual(app.frame, cell, "Drag \(drag) snaps back")
        }
    }

    /// A clamp AppKit applied for a moment while displays came back (a wake, a lid) and that was learned: waking with
    /// the very same displays asks again.
    func testWakingWithTheSameDisplaysAsksAgainForASizeLearnedWhileTheyChanged() async throws {
        let workspace = Workspace.get(byName: "wake")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 900, height: 600))
        app.displays = [Rect(topLeftX: 0, topLeftY: 0, width: 1024, height: 768)]
        let window = FrameFitTestWindow(id: 1, parent: workspace.rootTilingContainer, native: app)
        try await layout(workspace, passes: WindowFrameFit.answersToLearn + 1)
        advanceFrameFitTestClock(by: 1)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertNotEqual(app.frame.size, cell.size, "Clamped, and learned")

        app.displays = [FitTestMonitor().rect]
        let writes = app.sizeWrites
        try await layout(workspace, passes: 3)
        XCTAssertEqual(app.sizeWrites, writes, "Nothing asks again by itself: the displays WinMux lays out on never changed")
        noteScreensWokeForFrameFit()
        try await layout(workspace)
        XCTAssertEqual(app.frame, cell, "Asked again after the wake")
    }

    /// The same, learned between a display change and the displays settling: once they've settled it's asked again.
    func testDisplaysSettlingAsksAgainForASizeLearnedWhileTheyChanged() async throws {
        let workspace = Workspace.get(byName: "settle")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 900, height: 600))
        let window = FrameFitTestWindow(id: 1, parent: workspace.rootTilingContainer, native: app)
        try await layout(workspace)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(app.frame, cell)

        MonitorConfigurationObserver.shared.handleScreenParametersChanged(settleDelay: .milliseconds(100))
        app.displays = [Rect(topLeftX: 0, topLeftY: 0, width: 1024, height: 768)]
        app.resizeOnItsOwn(to: CGSize(width: 1024, height: 743))
        try await layout(workspace, passes: WindowFrameFit.answersToLearn + 1)
        advanceFrameFitTestClock(by: 1)
        XCTAssertNotEqual(app.frame.size, cell.size, "Clamped while displays change, and learned")
        app.displays = [FitTestMonitor().rect]

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(MonitorConfigurationObserver.shared.isSettling)
        try await layout(workspace)
        XCTAssertEqual(app.frame, cell, "Asked again once displays settled")
    }

    /// A layout that may reuse the frames it wrote (a focus change right after the mouse goes up) doesn't skip a window the
    /// user just resized: rearmed, it isn't laid out until it's written anew (Carbon's delta-3 review, 2026-11-14).
    func testAnEdgeDragFollowedByALayoutThatReusesFramesStillSnapsBack() async throws {
        let workspace = Workspace.get(byName: "drag-reuse")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480))
        let window = FrameFitTestWindow(id: 1, parent: workspace.rootTilingContainer, native: app)
        try await layout(workspace)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(app.frame, cell)

        let dragged = Rect(topLeftX: cell.topLeftX, topLeftY: cell.topLeftY, width: cell.width - 80, height: cell.height)
        app.resizeOnItsOwn(to: dragged.size)
        applyResizeWithMouse(window, rect: dragged)
        currentlyManipulatedWithMouseWindowId = nil
        setCurrentMouseManipulationKind(.none)
        try await layout(workspace, event: .onFocusChanged)
        XCTAssertEqual(app.frame, cell, "Written anew, not taken for the frame written before the drag")
    }

    /// A window that leaves tiling (here minimized) no longer has the cell layout had it in, nor where in it the app kept
    /// it: neither is where layout puts it now.
    func testLeavingTilingDropsTheCellLayoutHadTheWindowIn() async throws {
        let workspace = Workspace.get(byName: "leaving")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 360), aspect: 16.0 / 9.0)
        let window = FrameFitTestWindow(id: 1, parent: workspace.rootTilingContainer, native: app)
        try await layout(workspace, passes: WindowFrameFit.answersToLearn + 1)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertNotEqual(window.layoutPlacedRect, cell, "Placed where the app keeps it in its cell")

        window.rememberMacOsLayoutOrigin(detachFromWorkspace: true)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertNil(window.lastAppliedLayoutPhysicalRect)
        XCTAssertNil(window.lastAppliedLayoutVirtualRect)
        XCTAssertNil(window.layoutPlacedRect)
    }

    // MARK: Followed up

    /// move-node-to-monitor right after a drag: the window's kAXMoved and kAXResized bring no layout, and a later
    /// layout may reuse frames. The write fit to the old display is finished by its own follow-up.
    func testMoveNodeToMonitorRightAfterADragTakesItsCellOnTheFollowUp() async throws {
        let (builtIn, external) = twoDisplays()
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 900, height: 600))
        app.displays = [builtIn.rect, external.rect]
        app.screenLagsMoves = true
        let window = FrameFitTestWindow(id: 2, parent: builtIn.activeWorkspace.rootTilingContainer, native: app)
        XCTAssertTrue(window.focusWindow())
        try await layoutAll()
        app.catchUp()
        try await layoutAll()
        XCTAssertEqual(app.frame, window.lastAppliedLayoutPhysicalRect)

        suppressPostDragAxObserverEvents(for: [window.windowId])
        let result = try await parseCommand("move-node-to-monitor right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)")
        XCTAssertTrue(window.nodeWorkspace === external.activeWorkspace)
        try await layoutAll(event: .hotkeyBinding)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertNotEqual(app.frame, cell, "The first write is fit to the display it came from")
        app.catchUp()
        try await layoutAll(event: .onFocusChanged)
        advanceFrameFitTestClock(by: 1)
        XCTAssertEqual(app.frame, cell, "Its follow-up asked again once the app had noticed its display")
        refocusFirstDisplay(builtIn)
    }

    /// An app that takes the write and goes to a size of its own a moment later, with no layout to see it: the
    /// follow-up's look once the settle interval is up catches it, asks once more, and learns the size.
    func testAFollowUpCatchesAnAppResizingItselfAfterTakingTheWrite() async throws {
        let workspace = Workspace.get(byName: "late")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480), laterAspect: 4.0 / 3.0)
        let window = FrameFitTestWindow(id: 1, parent: workspace.rootTilingContainer, native: app)
        try await layout(workspace)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(app.frame, cell, "It took the write, as far as the read right after could tell")

        for _ in 0 ..< 3 {
            app.settleOnItsOwn()
            advanceFrameFitTestClock(by: 0.1)
        }
        XCTAssertNotEqual(app.frame.size, cell.size)
        XCTAssertEqual(app.sizeWrites, 2, "Asked once more, then its own size was learned")
        XCTAssertEqual(app.frame.center.x, cell.center.x, accuracy: 1, "Centered in its cell")
        XCTAssertEqual(window.layoutPlacedRect, app.frame)
    }

    // MARK: Owned by layout, or not

    /// A park, once it has begun, owns the window: a follow-up that comes due while the park waits on AX doesn't ask
    /// for the size again or put the window back in its cell, whatever path hid it.
    func testAParkThatHasBegunHoldsOffAFollowUpDueWhileItWaitsOnAX() async throws {
        let workspace = Workspace.get(byName: "park")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 360), aspect: 16.0 / 9.0)
        let window = FrameFitTestWindow(id: 1, parent: workspace.rootTilingContainer, native: app)
        try await layout(workspace)
        XCTAssertTrue(FrameFitFollowUps.shared.isPending(window.windowId), "Its first answer is still to be read")
        let writes = app.sizeWrites

        window.onGetAxRect = { advanceFrameFitTestClock(by: 0.1) }
        try await parkHiddenWindow(window, in: .bottomRightCorner, reasserting: false)
        XCTAssertEqual(app.sizeWrites, writes, "Not asked for its size while it's being hidden")
        XCTAssertTrue(window.isHiddenInCorner)
        XCTAssertFalse(FrameFitFollowUps.shared.isPending(window.windowId))
    }

    /// Right before it writes, a follow-up checks that layout still has the window in that cell: once layout has taken
    /// it out (an inactive tab, a window behind a full-screen one), the follow-up does nothing, park or no park.
    func testAFollowUpForAWindowLayoutTookOutOfItsCellDoesNothing() async throws {
        let workspace = Workspace.get(byName: "taken")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 360), aspect: 16.0 / 9.0)
        let window = FrameFitTestWindow(id: 1, parent: workspace.rootTilingContainer, native: app)
        try await layout(workspace)
        XCTAssertTrue(FrameFitFollowUps.shared.isPending(window.windowId))
        // As hideTabbedWindows and hideAllWindowsExcept do before they park it.
        window.lastAppliedLayoutPhysicalRect = nil
        let writes = (app.sizeWrites, app.positionWrites)
        advanceFrameFitTestClock(by: 1)
        XCTAssertEqual(app.sizeWrites, writes.0)
        XCTAssertEqual(app.positionWrites, writes.1)
    }

    /// A window that closes takes its follow-up with it.
    func testClosingAWindowDropsItsFollowUp() async throws {
        let workspace = Workspace.get(byName: "closing")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 360), aspect: 16.0 / 9.0)
        let window = FrameFitTestWindow(id: 1, parent: workspace.rootTilingContainer, native: app)
        try await layout(workspace)
        XCTAssertTrue(FrameFitFollowUps.shared.isPending(window.windowId))
        window.removeClosedWindowFromTree()
        XCTAssertFalse(FrameFitFollowUps.shared.isPending(window.windowId))
    }

    /// A tab dropped on another display's sidebar list right after the drag: the same, through the sidebar's drop.
    func testASidebarDropOnAnotherDisplaysListTakesItsCellOnTheFollowUp() async throws {
        let (builtIn, external) = twoDisplays()
        let tab = builtIn.activeWorkspace
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 900, height: 600))
        app.displays = [builtIn.rect, external.rect]
        app.screenLagsMoves = true
        let window = FrameFitTestWindow(id: 3, parent: tab.rootTilingContainer, native: app)
        XCTAssertTrue(window.focusWindow())
        try await layoutAll()
        app.catchUp()
        try await layoutAll()
        XCTAssertEqual(app.frame, window.lastAppliedLayoutPhysicalRect)

        try withWorkspaceTabOnDropDisplay(tab, monitorScopeId: workspaceSidebarMonitorScopeId(for: external), focusing: window) {}
        XCTAssertEqual(tab.workspaceMonitor.rect, external.rect)
        try await layoutAll(event: .onTabSwitched)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertNotEqual(app.frame, cell, "The first write is fit to the display it came from")
        app.catchUp()
        try await layoutAll(event: .onFocusChanged)
        advanceFrameFitTestClock(by: 1)
        XCTAssertEqual(app.frame, cell, "Its follow-up asked again once the app had noticed its display")
        refocusFirstDisplay(builtIn)
    }
}
