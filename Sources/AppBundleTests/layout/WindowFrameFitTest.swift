@testable import AppBundle
import AppKit
import Common
import XCTest

/// A window whose app keeps a size of its own: a minimum size, a fixed aspect ratio, or whole points.
/// It answers AX frame reads and writes the way such an app might. These are simulations of app
/// behaviour, not captures of a real app: FaceTime's own constraints during a call are not known here.
final class SimulatedAppWindow: AxFrameAccess {
    var frame: Rect
    var minSize: CGSize?
    /// The width-to-height ratio the app keeps, applied as a size write lands.
    var aspect: CGFloat?
    /// The ratio the app goes to on its own some time after a write lands: `settleOnItsOwn()`.
    var laterAspect: CGFloat?
    /// Whether the app takes size writes at all.
    var answers = true
    /// Displays, as AppKit fits a window resized over AX to the screen from where the window is (seen in
    /// a macOS 27 guest): no wider or taller than the room left on the display from its top-left corner.
    var displays: [Rect] = []
    private(set) var sizeWrites = 0
    private(set) var positionWrites = 0
    /// Every position written, in order: a stop on the way shows as a jump on screen.
    private(set) var positions: [CGPoint] = []
    /// Size changes the app made: each is a kAXResized WinMux would hear, and lay out again for.
    private(set) var resizes = 0

    init(_ frame: Rect, minSize: CGSize? = nil, aspect: CGFloat? = nil, laterAspect: CGFloat? = nil) {
        self.frame = frame
        self.minSize = minSize
        self.aspect = aspect
        self.laterAspect = laterAspect
    }

    var axTopLeft: CGPoint? { frame.topLeftCorner }
    var axSize: CGSize? { frame.size }

    func setAxTopLeft(_ topLeft: CGPoint) {
        positionWrites += 1
        positions.append(topLeft)
        frame.topLeftX = topLeft.x.rounded()
        frame.topLeftY = topLeft.y.rounded()
    }

    func setAxSize(_ size: CGSize) -> Bool {
        sizeWrites += 1
        guard answers else { return false }
        var size = kept(size, aspect: aspect)
        if let display = displays.first(where: { $0.contains(frame.topLeftCorner) }) {
            let room = CGSize(width: display.maxX - frame.topLeftX, height: display.maxY - frame.topLeftY)
            if size.width > room.width || size.height > room.height {
                let scale = aspect == nil ? 1 : min(room.width / size.width, room.height / size.height)
                size = aspect == nil
                    ? CGSize(width: min(size.width, room.width), height: min(size.height, room.height))
                    : CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
            }
        }
        resize(to: size)
        return true
    }

    /// The app applies its later ratio, within the frame it has.
    func settleOnItsOwn() {
        guard let laterAspect else { return }
        resize(to: kept(frame.size, aspect: laterAspect))
    }

    /// The app resizes its window itself.
    func resizeOnItsOwn(to size: CGSize) { resize(to: size) }

    private func resize(to size: CGSize) {
        if size != frame.size { resizes += 1 }
        frame.width = size.width
        frame.height = size.height
    }

    /// The largest size within `size` with the ratio, no smaller than the minimum, in whole points.
    private func kept(_ size: CGSize, aspect: CGFloat?) -> CGSize {
        var width = size.width, height = size.height
        if let aspect {
            if width / height > aspect { width = height * aspect } else { height = width / aspect }
        }
        if let minSize {
            width = max(width, minSize.width)
            height = max(height, minSize.height)
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}

/// The production frame write (`setFrame`) against simulated apps, one call per layout pass.
final class WindowFrameFitTest: XCTestCase {
    private let area = Rect(topLeftX: 0, topLeftY: 0, width: 1440, height: 900)

    @discardableResult
    private func lay(_ window: SimulatedAppWindow, in cell: Rect, _ fit: inout WindowFrameFit, bounds: Rect? = nil) throws -> Rect? {
        try setFrame(window, cell.topLeftCorner, cell.size, fit: &fit, within: bounds ?? area, RunLoopJob())
    }

    func testAnAspectLockedWindowIsAskedOnceThenCenteredAndLeftAloneOnRepeatedLayouts() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 640, height: 480), aspect: 4.0 / 3.0)
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)

        let observed = try lay(app, in: cell, &fit)
        XCTAssertEqual(observed, Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 600),
            "What's reported is the app's answer, centered, not the cell")
        XCTAssertEqual(app.frame, Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 600))
        XCTAssertEqual(app.positions, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
            "Asked at the cell's corner, then placed once")
        let (sizes, moves) = (app.sizeWrites, app.positionWrites)
        XCTAssertEqual(sizes, 2, "One ask: the size, and once more after the move, as before")

        for _ in 0 ..< 10 { XCTAssertNil(try lay(app, in: cell, &fit), "Nothing new to report") }
        XCTAssertEqual(app.sizeWrites, sizes, "Repeated layouts don't ask again for a size the app keeps")
        XCTAssertEqual(app.positionWrites, moves)
        XCTAssertEqual(app.resizes, 1)
        XCTAssertEqual(app.frame, Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 600))
    }

    func testTheSizeIsAskedWithTheWindowAtItsCellsCornerWhereTheWholeCellIsOnScreen() throws {
        // The guest's display and cell; the window starts off-center, as a centered one would be.
        let display = Rect(topLeftX: 0, topLeftY: 0, width: 1024, height: 768)
        let app = SimulatedAppWindow(Rect(topLeftX: 300, topLeftY: 200, width: 640, height: 360), aspect: 16.0 / 9.0)
        app.displays = [display]
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 11, topLeftY: 74, width: 1002, height: 626)

        try lay(app, in: cell, &fit, bounds: display)
        XCTAssertEqual(app.frame.size, CGSize(width: 1002, height: 564), "The app's own answer for the cell, not the screen's limit")
        XCTAssertEqual(app.frame.topLeftCorner, CGPoint(x: 11, y: 105))
        XCTAssertEqual(fit.heldSize, CGSize(width: 1002, height: 564))
    }

    func testAWindowFromAnotherDisplayGoesToItsCellFirstThenTakesTheSize() throws {
        let small = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)
        let large = Rect(topLeftX: 800, topLeftY: 0, width: 1600, height: 1000)
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 400, height: 300))
        app.displays = [small, large]
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 800, topLeftY: 0, width: 1200, height: 900)

        XCTAssertEqual(try lay(app, in: cell, &fit, bounds: large), cell)
        XCTAssertEqual(app.frame, cell)
        XCTAssertEqual(app.positions, [cell.topLeftCorner], "No stop where the size its old display allowed would be centered")
        XCTAssertNil(fit.heldSize, "The old display's clamp isn't the app keeping a size")
    }

    func testAWindowThatCantShrinkToItsCellStaysOnItsDisplayWithoutChurn() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 700, height: 600), minSize: CGSize(width: 900, height: 400))
        var fit = WindowFrameFit()
        let rightHalf = Rect(topLeftX: 720, topLeftY: 0, width: 720, height: 900)

        XCTAssertEqual(try lay(app, in: rightHalf, &fit), Rect(topLeftX: 540, topLeftY: 0, width: 900, height: 900))
        XCTAssertEqual(app.frame.maxX, area.maxX, "Overlaps its neighbour rather than leave the display")
        let writes = (app.sizeWrites, app.positionWrites)
        for _ in 0 ..< 10 { try lay(app, in: rightHalf, &fit) }
        XCTAssertEqual(app.sizeWrites, writes.0)
        XCTAssertEqual(app.positionWrites, writes.1)

        // Without bounds (a caller that has none), it starts at the cell's edge, as before.
        var unbounded = WindowFrameFit()
        let other = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 700, height: 600), minSize: CGSize(width: 900, height: 400))
        XCTAssertEqual(try setFrame(other, rightHalf.topLeftCorner, rightHalf.size, fit: &unbounded, RunLoopJob()), Rect(topLeftX: 720, topLeftY: 0, width: 900, height: 900))
    }

    func testAnAppThatTakesTheSizeIsWrittenOnceEvenForCellsBetweenWholePoints() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 500))
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 1000.0 / 3, topLeftY: 0, width: 1000.0 / 3, height: 900)
        XCTAssertEqual(try lay(app, in: cell, &fit), Rect(topLeftX: 333, topLeftY: 0, width: 333, height: 900),
            "The frame reported is the one read back, in whole points")
        XCTAssertEqual(app.sizeWrites, 1, "A size within a point of the cell is the cell's")
        for _ in 0 ..< 5 { try lay(app, in: cell, &fit) }
        XCTAssertEqual(app.sizeWrites, 1)
        XCTAssertEqual(app.positionWrites, 1)
        XCTAssertNil(fit.heldSize)
    }

    func testANewCellIsAskedForAgainWithoutGuessingFromTheLastAnswer() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 700), minSize: CGSize(width: 900, height: 500))
        var fit = WindowFrameFit()
        try lay(app, in: Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 700), &fit)
        XCTAssertEqual(app.frame.size, CGSize(width: 900, height: 700))
        let sizes = app.sizeWrites

        // 900 × 700 isn't a ratio the app keeps: the wider cell fits exactly.
        let wide = Rect(topLeftX: 0, topLeftY: 200, width: 1200, height: 500)
        XCTAssertEqual(try lay(app, in: wide, &fit), wide)
        XCTAssertEqual(app.frame, wide)
        XCTAssertEqual(app.sizeWrites, sizes + 1)
        XCTAssertNil(fit.heldSize)
    }

    func testAnAppThatResizesItselfAfterTakingTheSizeIsAskedOnceMoreThenLeftAlone() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 640, height: 480), laterAspect: 4.0 / 3.0)
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)

        XCTAssertEqual(try lay(app, in: cell, &fit), cell, "It took the size, as far as the read right after could tell")
        for _ in 0 ..< 10 {
            app.settleOnItsOwn()
            try lay(app, in: cell, &fit)
        }
        XCTAssertEqual(app.sizeWrites, 2, "Asked again once after it went back on its own, then no more")
        XCTAssertEqual(fit.heldSize, CGSize(width: 800, height: 600))
        XCTAssertEqual(app.frame, Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 600))
        XCTAssertEqual(app.resizes, 4, "Two writes, two of the app's own: no fight")
    }

    func testAWindowBackInTheSameCellIsOnlyPlaced() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480), aspect: 4.0 / 3.0)
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        try lay(app, in: cell, &fit)
        let sizes = app.sizeWrites

        // Parked in a corner while its tab is hidden: a move alone.
        try setFrame(app, CGPoint(x: 1439, y: 899), nil, fit: &fit, RunLoopJob())
        XCTAssertEqual(app.frame.topLeftCorner, CGPoint(x: 1439, y: 899))
        try lay(app, in: cell, &fit)
        XCTAssertEqual(app.frame, Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 600))
        XCTAssertEqual(app.sizeWrites, sizes)
    }

    func testAnAppThatDropsItsConstraintIsAskedAgainAndFillsTheCell() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480), aspect: 4.0 / 3.0)
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        try lay(app, in: cell, &fit)
        XCTAssertEqual(app.frame.size, CGSize(width: 800, height: 600))

        app.aspect = nil
        app.resizeOnItsOwn(to: CGSize(width: 900, height: 600))
        XCTAssertEqual(try lay(app, in: cell, &fit), cell)
        XCTAssertNil(fit.heldSize)
        let sizes = app.sizeWrites
        try lay(app, in: cell, &fit)
        XCTAssertEqual(app.sizeWrites, sizes)
    }

    func testNothingIsLearnedFromAWriteTheAppDidntTakeIn() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480))
        app.answers = false
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        try lay(app, in: cell, &fit)
        try lay(app, in: cell, &fit)
        XCTAssertEqual(app.sizeWrites, 4, "An AX error isn't the app keeping a size: each layout asks, as before")
        XCTAssertNil(fit.heldSize)
        XCTAssertFalse(fit.asked)
    }

    func testAMoveAloneWritesOnlyWhenTheWindowIsElsewhere() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480))
        var fit = WindowFrameFit()
        XCTAssertNil(try setFrame(app, CGPoint(x: 10, y: 20), nil, fit: &fit, RunLoopJob()))
        XCTAssertNil(try setFrame(app, CGPoint(x: 10, y: 20), nil, fit: &fit, RunLoopJob()))
        XCTAssertEqual(app.positionWrites, 1)
        XCTAssertEqual(app.sizeWrites, 0)
    }

    func testACancelledLayoutStopsBeforeMovingAndLeavesTheNextOneToAsk() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480), aspect: 4.0 / 3.0)
        var fit = WindowFrameFit()
        let job = RunLoopJob()
        job.cancel()
        XCTAssertThrowsError(try setFrame(app, .zero, CGSize(width: 1000, height: 600), fit: &fit, within: area, job))
        XCTAssertEqual(app.positionWrites, 0)
        XCTAssertFalse(fit.asked, "A newer layout took over: this one's answer isn't recorded")
        try lay(app, in: Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600), &fit)
        XCTAssertEqual(app.frame, Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 600))
    }
}

// MARK: - Through the layout

private struct FitTestMonitor: Monitor {
    let monitorAppKitNsScreenScreensId = 1
    let name = "Fit"
    let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1440, height: 900)
    let visibleRect = Rect(topLeftX: 0, topLeftY: 25, width: 1440, height: 875)
    let isMain = true
    let displayIdentity: MonitorDisplayIdentity? = MonitorDisplayIdentity(uuid: "FIT", isBuiltin: true)
    let isFallbackMonitor = false
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}

/// A window whose app is simulated, laid out by the real layout and written through the real
/// `setFrame`, with its fit kept as MacApp keeps it with the AX window.
private final class FrameFitTestWindow: Window {
    let native: SimulatedAppWindow
    private var fit = WindowFrameFit()
    fileprivate let cornerParking = CornerParkingState()

    @MainActor init(id: UInt32, parent: NonLeafTreeNodeObject, native: SimulatedAppWindow) {
        self.native = native
        super.init(id: id, TestApp.shared, lastFloatingSize: native.frame.size, parent: parent, adaptiveWeight: 1,
            index: INDEX_BIND_LAST)
        recordAuthoritativeActualRect(native.frame)
    }

    @MainActor override var title: String { get async { "Fit \(windowId)" } }
    override var isHiddenInCorner: Bool { cornerParking.isHiddenInCorner }

    @MainActor override func getAxRect() async throws -> Rect? {
        let token = nativeStateObservationToken()
        recordObservedActualRect(native.frame, token: token)
        return native.frame
    }

    @MainActor override func getAxSize() async throws -> CGSize? { native.frame.size }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        _ = try? setFrame(native, topLeft, size, fit: &fit, RunLoopJob())
    }

    /// As MacApp does it, minus the thread hop: the token taken before the write, the frame reported after.
    @MainActor override func setAxLayoutFrame(_ cell: Rect, within bounds: Rect) {
        let token = nativeStateObservationToken()
        if let frame = try? setFrame(native, cell.topLeftCorner, cell.size, fit: &fit, within: bounds, RunLoopJob()) {
            recordLayoutFrame(frame, in: cell, token: token)
        }
    }

}

extension FrameFitTestWindow: WorkspaceWindowVisibility {
    func hideInCorner(_ corner: OptimalHideCorner, reassert: Bool, ifStillValid: () -> Bool) async throws {
        try await parkInCorner(corner, cornerParking, reassert: reassert, onePixelOffset: true, ifStillValid: ifStillValid)
    }

    func unhideFromCorner() { restoreFromCorner(cornerParking) }
}

@MainActor
final class WindowFrameFitLayoutTest: XCTestCase {
    private let resized = RefreshSessionEvent.ax(kAXResizedNotification as String)

    override func setUp() async throws {
        setUpWorkspacesForTests()
        setMonitorsForTests([FitTestMonitor()])
    }

    override func tearDown() async throws {
        setMonitorsForTests(nil)
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    /// One layout pass for each kAXResized the app's resizes would bring: every one re-sends frames.
    private func layoutAfterResizes(_ workspace: Workspace, passes: Int = 1) async throws {
        for _ in 0 ..< passes {
            try await $refreshSessionEvent.withValue(resized) { try await workspace.layoutWorkspace() }
        }
    }

    private func fitted(_ size: CGSize, in cell: Rect, bounds: Rect) -> Rect {
        let topLeft = frameFitTopLeft(cell: cell, size: size, bounds: bounds)
        return Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: size.width, height: size.height)
    }

    func testAnAspectLockedWindowInASplitStaysInItAndStopsBeingResized() async throws {
        let workspace = Workspace.get(byName: "call")
        XCTAssertTrue(workspace.focusWorkspace())
        let notes = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480), aspect: 16.0 / 9.0)
        let call = FrameFitTestWindow(id: 2, parent: workspace.rootTilingContainer, native: app)

        try await layoutAfterResizes(workspace)
        let cell = try XCTUnwrap(call.lastAppliedLayoutPhysicalRect)
        let bounds = workspace.workspaceMonitor.standardTilingRect
        XCTAssertLessThan(app.frame.height, cell.height, "The app kept its ratio in a tall half")
        XCTAssertEqual(app.frame, fitted(app.frame.size, in: cell, bounds: bounds), "Centered in its cell")
        XCTAssertEqual(call.lastKnownActualRect, app.frame, "Known as the app's frame, not the cell")
        XCTAssertEqual(call.layoutPlacedRect, app.frame)
        // The kAXResized and kAXMoved of WinMux's own writes drop the observation, not where layout put it.
        call.invalidateLastKnownNativeState()
        XCTAssertNil(call.lastKnownActualRect)
        XCTAssertEqual(call.layoutPlacedRect, app.frame)
        XCTAssertEqual(notes.layoutPlacedRect, notes.lastAppliedLayoutPhysicalRect, "A window that fills its cell is placed at it")
        let writes = (app.sizeWrites, app.positionWrites)

        try await layoutAfterResizes(workspace, passes: 8)
        XCTAssertEqual(app.sizeWrites, writes.0, "No size is asked for again in the same cell")
        XCTAssertEqual(app.positionWrites, writes.1)
        XCTAssertTrue(call.parent === workspace.rootTilingContainer, "Still a member of the split")
        XCTAssertEqual(workspace.rootTilingContainer.children.map { ($0 as? Window)?.windowId }, [1, 2])
        XCTAssertEqual(notes.lastAppliedLayoutPhysicalRect?.width, cell.width, "Its neighbour's cell is unchanged")
    }

    func testANewCellIsAskedForOnceAndAWindowBackFromAHiddenTabIsOnlyPlaced() async throws {
        let workspace = Workspace.get(byName: "call")
        let other = Workspace.get(byName: "other")
        _ = TestWindow.new(id: 3, parent: other.rootTilingContainer)
        XCTAssertTrue(workspace.focusWorkspace())
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480), aspect: 16.0 / 9.0)
        let call = FrameFitTestWindow(id: 2, parent: workspace.rootTilingContainer, native: app)
        try await layoutAfterResizes(workspace)
        let first = app.sizeWrites

        // The split moves: one new ask, then quiet again.
        call.setWeight(.h, call.getWeight(.h) * 1.5)
        try await layoutAfterResizes(workspace, passes: 4)
        let cell = try XCTUnwrap(call.lastAppliedLayoutPhysicalRect)
        XCTAssertGreaterThan(app.sizeWrites, first)
        XCTAssertLessThanOrEqual(app.sizeWrites - first, 2, "One ask for the new cell")
        let settled = app.sizeWrites
        XCTAssertEqual(app.frame, fitted(app.frame.size, in: cell, bounds: workspace.workspaceMonitor.standardTilingRect))
        let frame = app.frame
        XCTAssertEqual(call.layoutPlacedRect, frame)
        // A report that arrives late, for the cell before the split moved, doesn't replace it.
        let oldCell = Rect(topLeftX: cell.minX, topLeftY: cell.minY, width: cell.width - 100, height: cell.height)
        call.recordLayoutFrame(Rect(topLeftX: 0, topLeftY: 0, width: 10, height: 10), in: oldCell, token: call.nativeStateObservationToken())
        XCTAssertEqual(call.layoutPlacedRect, frame)

        // Another tab is shown and this one parked, then it's shown again.
        XCTAssertTrue(other.focusWorkspace())
        try await $refreshSessionEvent.withValue(resized) { try await layoutWorkspaces() }
        XCTAssertTrue(call.isHiddenInCorner)
        XCTAssertNotEqual(app.frame.topLeftCorner, frame.topLeftCorner)
        XCTAssertTrue(workspace.focusWorkspace())
        try await $refreshSessionEvent.withValue(resized) { try await layoutWorkspaces() }
        XCTAssertEqual(app.frame, frame, "Back where it was")
        XCTAssertEqual(app.sizeWrites, settled, "Coming back to the same cell asks for no size")
    }

    func testAPinnedSplitKeepsAWindowThatCantShrinkToItsCell() async throws {
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        let a = Workspace.get(byName: "a")
        let one = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        let d = Workspace.get(byName: "d")
        // Wider than half the display, at least.
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600), minSize: CGSize(width: 900, height: 300))
        let call = FrameFitTestWindow(id: 4, parent: d.rootTilingContainer, native: app)
        try setWorkspaceSidebarTabsFavorite([a], true)
        try splitPinnedTabWindowWithTab(a, "d", placement: .left)
        try setWorkspaceSidebarTabFavorite(d, true)
        let members = d.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)
        XCTAssertEqual(members, [1, 4], "The window that can't shrink is on the right, toward the display's edge")
        XCTAssertTrue(d.focusWorkspace())

        try await layoutAfterResizes(d)
        let cell = try XCTUnwrap(call.lastAppliedLayoutPhysicalRect)
        let bounds = d.workspaceMonitor.standardTilingRect
        XCTAssertGreaterThan(app.frame.width, cell.width, "The app can't shrink to its cell")
        XCTAssertGreaterThanOrEqual(app.frame.minX, bounds.minX)
        XCTAssertLessThanOrEqual(app.frame.maxX, bounds.maxX, "It stays on its display, over its neighbour")
        let writes = (app.sizeWrites, app.positionWrites)

        try await layoutAfterResizes(d, passes: 8)
        XCTAssertEqual(app.sizeWrites, writes.0)
        XCTAssertEqual(app.positionWrites, writes.1)
        XCTAssertEqual(d.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), members, "The pinned split keeps both windows")
        XCTAssertTrue(workspaceSidebarIsPinned(d))
        XCTAssertTrue(workspaceSidebarLentWindow(of: a) === one, "The pin still lends its window to the split")
        XCTAssertTrue(call.nodeWorkspace === d)
    }

    func testAWindowThatTakesItsCellAgainIsPlacedAtTheCell() async throws {
        let workspace = Workspace.get(byName: "call")
        XCTAssertTrue(workspace.focusWorkspace())
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480), aspect: 16.0 / 9.0)
        let call = FrameFitTestWindow(id: 2, parent: workspace.rootTilingContainer, native: app)
        try await layoutAfterResizes(workspace)
        let cell = try XCTUnwrap(call.lastAppliedLayoutPhysicalRect)
        XCTAssertNotEqual(call.layoutPlacedRect, cell)

        // The call ended: the app fills its cell on its own and keeps no ratio.
        app.aspect = nil
        app.frame = cell
        try await layoutAfterResizes(workspace)
        XCTAssertEqual(call.layoutPlacedRect, cell)
    }
}
