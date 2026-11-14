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
    /// Where the app lets the window go when asked to move it, and what the move does to its size. By
    /// default it goes where it's asked, in whole points.
    var takesPosition: (CGPoint, Rect) -> Rect = { topLeft, frame in
        Rect(topLeftX: topLeft.x.rounded(), topLeftY: topLeft.y.rounded(), width: frame.width, height: frame.height)
    }
    /// Whether the app answers reads of the window's position.
    var positionReadable = true
    /// Whether the app answers reads of the window's size.
    var sizeReadable = true
    /// How many of the next size writes fail outright, as an AX error would: nothing changes.
    var failingWrites = 0
    /// Run after each position or size write lands: a newer layout cancelling this one, say.
    var onPositionWrite: () -> Void = {}
    var onSizeWrite: () -> Void = {}
    /// Sizes the app takes in turn, whatever it's asked for: one that never settles on an answer.
    var answersInTurn: [CGSize] = []
    private var nextAnswer = 0
    /// Whether the display AppKit fits a resized window to lags an AX move until the app's run loop turns
    /// (`catchUp()`): within one burst of writes, a window just moved to another display is still fit to
    /// the one it came from. A hypothesis for multi-display hardware, not an observation: the guest that
    /// showed the fit itself had one display. Which display that is follows NSWindow.screen: "the screen
    /// where most of the window is on".
    var screenLagsMoves = false
    /// The window's frame when the app last noticed which display it's on.
    private var noticedFrame: Rect?
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
        noticedFrame = frame
    }

    /// The app's run loop turns: it notices the display its window is on now.
    func catchUp() { noticedFrame = frame }

    /// NSWindow.screen: the display with the most of `frame` on it, if any.
    private func screen(for frame: Rect) -> Rect? {
        func overlap(_ display: Rect) -> CGFloat {
            let common = CGRect(x: frame.topLeftX, y: frame.topLeftY, width: frame.width, height: frame.height)
                .intersection(CGRect(x: display.topLeftX, y: display.topLeftY, width: display.width, height: display.height))
            return common.isNull ? 0 : common.width * common.height
        }
        guard let most = displays.max(by: { overlap($0) < overlap($1) }), overlap(most) > 0 else { return nil }
        return most
    }

    var axTopLeft: CGPoint? { positionReadable ? frame.topLeftCorner : nil }
    var axSize: CGSize? { sizeReadable ? frame.size : nil }

    func setAxTopLeft(_ topLeft: CGPoint) {
        defer { onPositionWrite() }
        positionWrites += 1
        positions.append(topLeft)
        let moved = takesPosition(topLeft, frame)
        frame.topLeftX = moved.topLeftX
        frame.topLeftY = moved.topLeftY
        resize(to: moved.size)
    }

    func setAxSize(_ size: CGSize) -> Bool {
        sizeWrites += 1
        defer { onSizeWrite() }
        if failingWrites > 0 {
            failingWrites -= 1
            return false
        }
        guard answers else { return false }
        if !answersInTurn.isEmpty {
            resize(to: answersInTurn[nextAnswer % answersInTurn.count])
            nextAnswer += 1
            return true
        }
        var size = kept(size, aspect: aspect)
        if let display = screen(for: screenLagsMoves ? noticedFrame ?? frame : frame) {
            // From where the window is on that display; from its corner once the window has left it.
            let from = display.contains(frame.topLeftCorner) ? frame.topLeftCorner : display.topLeftCorner
            let room = CGSize(width: display.maxX - from.x, height: display.maxY - from.y)
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
    /// The monotonic clock layouts run on: each one here comes well past the settle interval after the last.
    private var clock: TimeInterval = 1000

    /// A layout writing `window` into `cell` in `bounds` (by default the whole display) on display `monitor`, in
    /// frame-fit epoch `epoch`.
    @discardableResult
    private func lay(_ window: SimulatedAppWindow, in cell: Rect, _ fit: inout WindowFrameFit, bounds: Rect? = nil, monitor: Int = 1,
                     epoch: UInt64 = 0) throws -> Rect? {
        clock += 0.1
        return try layFrame(window, cell: cell, bounds: bounds ?? area, display: bounds ?? area, monitor: monitor, epoch: epoch, now: clock,
            fit: &fit)
    }

    /// The layouts a constrained window needs before its size is learned: two attempts, then the one that reads the
    /// second's final size.
    private func settle(_ window: SimulatedAppWindow, in cell: Rect, _ fit: inout WindowFrameFit, bounds: Rect? = nil, monitor: Int = 1) throws {
        for _ in 0 ... WindowFrameFit.answersToLearn { try lay(window, in: cell, &fit, bounds: bounds, monitor: monitor) }
    }

    /// The most size writes one cell size on one display can cost, whatever the app does.
    private let maxSizeWritesPerRequest = WindowFrameFit.acquisitionWrites + 1

    func testAnAspectLockedWindowIsAskedTwiceThenCenteredAndLeftAloneOnRepeatedLayouts() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 640, height: 480), aspect: 4.0 / 3.0)
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)

        let observed = try lay(app, in: cell, &fit)
        XCTAssertEqual(observed, Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 600),
            "What's reported is the app's answer, centered, not the cell")
        XCTAssertEqual(app.frame, Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 600))
        XCTAssertEqual(app.positions, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
            "Asked at the cell's corner, then placed once")
        XCTAssertEqual(app.sizeWrites, 1, "One write, at the cell's corner")
        XCTAssertNil(fit.heldSize, "One answer isn't learned")
        // The next layout asks again and gets the same answer: learned on the one after.
        XCTAssertEqual(try lay(app, in: cell, &fit), Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 600))
        let (sizes, moves) = (app.sizeWrites, app.positionWrites)
        XCTAssertEqual(sizes, 2)

        for _ in 0 ..< 10 { XCTAssertNil(try lay(app, in: cell, &fit), "Nothing new to report") }
        XCTAssertEqual(fit.heldSize, CGSize(width: 800, height: 600))
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
        // Asked again from its centered place: still from the corner, so the same answer, and learned.
        try settle(app, in: cell, &fit, bounds: display)
        XCTAssertEqual(fit.heldSize, CGSize(width: 1002, height: 564))
    }

    func testAWindowFromAnotherDisplayGoesToItsCellFirstThenTakesTheSize() throws {
        let small = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)
        let large = Rect(topLeftX: 800, topLeftY: 0, width: 1600, height: 1000)
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 400, height: 300))
        app.displays = [small, large]
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 800, topLeftY: 0, width: 1200, height: 900)

        XCTAssertEqual(try lay(app, in: cell, &fit, bounds: large, monitor: 2), cell)
        XCTAssertEqual(app.frame, cell)
        XCTAssertEqual(app.positions, [cell.topLeftCorner], "No stop where the size its old display allowed would be centered")
        XCTAssertNil(fit.heldSize, "The old display's clamp isn't the app keeping a size")
    }

    // MARK: Moves between displays

    private let builtIn = Rect(topLeftX: 0, topLeftY: 0, width: 1512, height: 982)
    private let external = Rect(topLeftX: 1512, topLeftY: 0, width: 2560, height: 1440)
    private var builtInCell: Rect { Rect(topLeftX: 8, topLeftY: 33, width: 1496, height: 941) }
    private var externalCell: Rect { Rect(topLeftX: 1520, topLeftY: 33, width: 2544, height: 1399) }

    /// The built-in display is display 1, the external one display 2.
    private func id(of display: Rect) -> Int { display == external ? 2 : 1 }

    /// One move to another display: a layout, the app noticing its new display, and the layout the move's
    /// kAXMoved and kAXResized bring (or its follow-up).
    private func move(_ app: SimulatedAppWindow, to cell: Rect, on display: Rect, _ fit: inout WindowFrameFit) throws {
        try lay(app, in: cell, &fit, bounds: display, monitor: id(of: display))
        app.catchUp()
        try lay(app, in: cell, &fit, bounds: display, monitor: id(of: display))
        app.catchUp()
    }

    func testAWindowMovedToALargerDisplayTakesItsNewCellOnceItIsThere() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 900, height: 600))
        app.displays = [builtIn, external]
        app.screenLagsMoves = true
        var fit = WindowFrameFit()
        try move(app, to: builtInCell, on: builtIn, &fit)
        XCTAssertEqual(app.frame, builtInCell)

        try move(app, to: externalCell, on: external, &fit)
        XCTAssertEqual(app.frame, externalCell, "Resized to its cell on the larger display, not kept at the size the old one allowed")
        XCTAssertNil(fit.heldSize)
        let writes = (app.sizeWrites, app.positionWrites)
        try lay(app, in: externalCell, &fit, bounds: external, monitor: 2)
        XCTAssertEqual(app.sizeWrites, writes.0, "Then left alone")
        XCTAssertEqual(app.positionWrites, writes.1)

        try move(app, to: builtInCell, on: builtIn, &fit)
        XCTAssertEqual(app.frame, builtInCell, "And back")
    }

    func testAKeptSizeIsLearnedOnTheDisplayOfItsCellAndNotFoughtThere() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 640, height: 360), aspect: 16.0 / 9.0)
        app.displays = [builtIn, external]
        app.screenLagsMoves = true
        var fit = WindowFrameFit()
        try move(app, to: builtInCell, on: builtIn, &fit)
        XCTAssertEqual(app.frame.size, CGSize(width: 1496, height: 842))

        let before = app.sizeWrites
        try move(app, to: externalCell, on: external, &fit)
        XCTAssertEqual(app.frame.size, CGSize(width: 2487, height: 1399), "The ratio it keeps on the larger display, not the old display's limit")
        // The old display's limit answered first, then the app's ratio: learned from the same answer twice in a row.
        for _ in 0 ..< 2 { try lay(app, in: externalCell, &fit, bounds: external, monitor: 2) }
        XCTAssertEqual(fit.heldSize, CGSize(width: 2487, height: 1399))
        XCTAssertLessThanOrEqual(app.sizeWrites - before, maxSizeWritesPerRequest)
        let writes = (app.sizeWrites, app.positionWrites)
        for _ in 0 ..< 5 { try lay(app, in: externalCell, &fit, bounds: external, monitor: 2) }
        XCTAssertEqual(app.sizeWrites, writes.0, "Not fought once learned")
        XCTAssertEqual(app.positionWrites, writes.1)
    }

    func testAWindowHiddenOnOneDisplayAndShownOnAnotherTakesItsCellThere() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 900, height: 600))
        app.displays = [builtIn, external]
        app.screenLagsMoves = true
        var fit = WindowFrameFit()
        try move(app, to: builtInCell, on: builtIn, &fit)
        // Its tab is hidden: parked in the built-in display's corner, a move alone.
        try setFrame(app, CGPoint(x: builtIn.maxX - 1, y: builtIn.maxY - 1), nil, fit: &fit, RunLoopJob())
        app.catchUp()
        // Then shown on the external display, in a cell of another size.
        try move(app, to: externalCell, on: external, &fit)
        XCTAssertEqual(app.frame, externalCell)
    }

    func testASizeLearnedWhileItsDisplayIsGoneLastsOnlyUntilDisplaysChange() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 1600, topLeftY: 100, width: 900, height: 600))
        app.displays = [builtIn, external]
        var fit = WindowFrameFit()
        try move(app, to: externalCell, on: external, &fit)
        XCTAssertEqual(app.frame, externalCell)

        // The external display goes away: macOS puts the window on the built-in one, at a size that fits
        // there, and won't move it back. WinMux lays it out in its old cell until displays settle.
        app.displays = [builtIn]
        app.frame = Rect(topLeftX: 0, topLeftY: 33, width: 1512, height: 949)
        app.takesPosition = { [builtIn] topLeft, frame in
            builtIn.contains(topLeft) ? Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: frame.width, height: frame.height) : frame
        }
        let before = app.sizeWrites
        for _ in 0 ..< 10 { try lay(app, in: externalCell, &fit, bounds: external, monitor: 2, epoch: 1) }
        XCTAssertLessThanOrEqual(app.sizeWrites - before, maxSizeWritesPerRequest, "Asked a bounded number of times while it's gone")

        // It comes back: the displays changed again, so whatever was learned meanwhile is dropped.
        app.displays = [builtIn, external]
        app.takesPosition = { topLeft, frame in Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: frame.width, height: frame.height) }
        try lay(app, in: externalCell, &fit, bounds: external, monitor: 2, epoch: 2)
        XCTAssertEqual(app.frame, externalCell, "Back in its cell at its cell's size")
    }

    func testAWindowThatCantShrinkToItsCellStaysOnItsDisplayWithoutChurn() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 700, height: 600), minSize: CGSize(width: 900, height: 400))
        var fit = WindowFrameFit()
        let rightHalf = Rect(topLeftX: 720, topLeftY: 0, width: 720, height: 900)

        XCTAssertEqual(try lay(app, in: rightHalf, &fit), Rect(topLeftX: 540, topLeftY: 0, width: 900, height: 900))
        XCTAssertEqual(app.frame.maxX, area.maxX, "Overlaps its neighbour rather than leave the display")
        try settle(app, in: rightHalf, &fit)
        let writes = (app.sizeWrites, app.positionWrites)
        for _ in 0 ..< 10 { try lay(app, in: rightHalf, &fit) }
        XCTAssertEqual(app.sizeWrites, writes.0)
        XCTAssertEqual(app.positionWrites, writes.1)

        // A frame written as asked (a caller that isn't a layout) is written as it is: at the cell's edge.
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
        try settle(app, in: cell, &fit)
        let sizes = app.sizeWrites

        // Parked in a corner while its tab is hidden: a move alone.
        try setFrame(app, CGPoint(x: 1439, y: 899), nil, fit: &fit, RunLoopJob())
        XCTAssertEqual(app.frame.topLeftCorner, CGPoint(x: 1439, y: 899))
        try lay(app, in: cell, &fit)
        XCTAssertEqual(app.frame, Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 600))
        XCTAssertEqual(app.sizeWrites, sizes)
    }

    /// Independent review (2026-11-12), as it was reproduced: an app that keeps 800 × 600 and doesn't let
    /// its window left of x = 200. Its position setter says nothing about where the window went.
    func testCachedConstrainedPlacementReportsActualClampedPosition() throws {
        let window = PositionClampedWindow()
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        // Since the design committee (2026-11-13) a layout's write names its display and runs on a clock, and only a
        // layout's learns a size: each call here is a layout, well past the settle interval after the last.
        func layout() throws -> Rect? {
            clock += 0.1
            return try setFrame(window, cell.topLeftCorner, cell.size, fit: &fit, target: FrameFitTarget(monitor: 1, epoch: 0), now: clock,
                RunLoopJob())
        }
        let first = try layout()
        XCTAssertEqual(first, window.frame)
        // Since 2026-11-13 a size is learned from the same answer to two asks in a row, not from one.
        for _ in 0 ..< WindowFrameFit.answersToLearn { _ = try layout() }
        XCTAssertEqual(fit.heldSize, CGSize(width: 800, height: 600))
        let second = try layout()
        if let second { XCTAssertEqual(second, window.frame, "A repeated placement must report the actual frame, or return nil when unchanged") }
    }

    func testAPlacementTheAppClampsOrResizesReportsTheFrameItHas() throws {
        // Keeps 800 × 600; a move right of x = 640 costs it width (the room left of 1440).
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480), aspect: 4.0 / 3.0)
        app.takesPosition = { topLeft, frame in
            Rect(topLeftX: max(200, topLeft.x), topLeftY: topLeft.y, width: min(frame.width, 1440 - max(200, topLeft.x)), height: frame.height)
        }
        var fit = WindowFrameFit()
        XCTAssertEqual(try lay(app, in: Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600), &fit), app.frame)
        XCTAssertEqual(app.frame, Rect(topLeftX: 200, topLeftY: 0, width: 800, height: 600), "Clamped right of its centered place")

        // The cell moves, not its size: the window is only placed, and the app keeps it at x = 200.
        XCTAssertEqual(try lay(app, in: Rect(topLeftX: 50, topLeftY: 0, width: 1000, height: 600), &fit), app.frame)
        XCTAssertEqual(app.frame.topLeftX, 200)
        // Moved far right, it loses width on the way: the report says so.
        XCTAssertEqual(try lay(app, in: Rect(topLeftX: 700, topLeftY: 0, width: 1000, height: 600), &fit), app.frame)
        XCTAssertEqual(app.frame, Rect(topLeftX: 800, topLeftY: 0, width: 640, height: 600))
        // And when the move to its centered place after an ask costs it width, the ask reports the width it has.
        XCTAssertEqual(try lay(app, in: Rect(topLeftX: 600, topLeftY: 0, width: 900, height: 600), &fit), app.frame)
        XCTAssertEqual(app.frame, Rect(topLeftX: 650, topLeftY: 0, width: 790, height: 600))
    }

    func testAPlacementTheAppTakesReportsItsNewPlace() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480), aspect: 4.0 / 3.0)
        var fit = WindowFrameFit()
        try settle(app, in: Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600), &fit)
        let sizes = app.sizeWrites
        XCTAssertEqual(try lay(app, in: Rect(topLeftX: 300, topLeftY: 50, width: 1000, height: 600), &fit),
            Rect(topLeftX: 400, topLeftY: 50, width: 800, height: 600))
        XCTAssertEqual(app.frame, Rect(topLeftX: 400, topLeftY: 50, width: 800, height: 600))
        XCTAssertEqual(app.sizeWrites, sizes, "Placed, not asked again")
    }

    func testAPlacementWhoseResultCantBeReadReportsNothing() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480), aspect: 4.0 / 3.0)
        var fit = WindowFrameFit()
        try settle(app, in: Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600), &fit)
        app.positionReadable = false
        XCTAssertNil(try lay(app, in: Rect(topLeftX: 300, topLeftY: 50, width: 1000, height: 600), &fit),
            "No frame is made up from where the window was asked to go")
        let sizes = app.sizeWrites
        app.positionReadable = true
        // Once it can be read, the window is reported where it is.
        XCTAssertEqual(try lay(app, in: Rect(topLeftX: 300, topLeftY: 50, width: 1000, height: 600), &fit), app.frame)
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

    func testAWriteTheAppDoesntTakeIsAskedAgainThenLeftAlone() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480))
        app.answers = false
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        try lay(app, in: cell, &fit)
        XCTAssertNil(fit.heldSize, "Not learned from one write it didn't take")
        try lay(app, in: cell, &fit)
        XCTAssertEqual(app.sizeWrites, 2)
        // Nor asked forever: out of writes, it's left at its size, centered. A failed write says nothing about a size
        // of the app's own, so nothing is learned (since the design committee, 2026-11-13).
        for _ in 0 ..< 5 { try lay(app, in: cell, &fit) }
        XCTAssertEqual(app.sizeWrites, WindowFrameFit.acquisitionWrites)
        XCTAssertNil(fit.heldSize)
        XCTAssertEqual(fit.phase, .exhausted(CGSize(width: 640, height: 480)))
        XCTAssertEqual(app.frame, Rect(topLeftX: 180, topLeftY: 60, width: 640, height: 480))
    }

    func testNoRequestIsAskedForMoreThanTheBoundAllowsOnOneDisplay() throws {
        // An app that never settles on an answer: each write leaves another size.
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480))
        app.answersInTurn = [CGSize(width: 700, height: 500), CGSize(width: 800, height: 550), CGSize(width: 900, height: 580)]
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        for _ in 0 ..< 20 { try lay(app, in: cell, &fit) }
        XCTAssertLessThanOrEqual(app.sizeWrites, maxSizeWritesPerRequest)
        XCTAssertEqual(fit.phase, .exhausted(CGSize(width: 900, height: 580)), "Then it's left at what it has, never taken for its own")
        let writes = app.sizeWrites
        for _ in 0 ..< 10 { try lay(app, in: cell, &fit) }
        XCTAssertEqual(app.sizeWrites, writes)
    }

    func testALearnedSizeIsAskedForAgainOnAnotherDisplayAndAfterDisplaysChange() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 640, height: 480), aspect: 4.0 / 3.0)
        var fit = WindowFrameFit()
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        let other = Rect(topLeftX: 1440, topLeftY: 0, width: 1440, height: 900)
        let otherCell = Rect(topLeftX: 1440, topLeftY: 0, width: 1000, height: 600)
        try settle(app, in: cell, &fit)
        XCTAssertNotNil(fit.heldSize)

        // A cell of the same size on another display: what was learned here doesn't hold there.
        var writes = app.sizeWrites
        try lay(app, in: otherCell, &fit, bounds: other, monitor: 2)
        XCTAssertGreaterThan(app.sizeWrites, writes, "Asked again on the other display")
        XCTAssertNil(fit.heldSize)
        try settle(app, in: otherCell, &fit, bounds: other, monitor: 2)
        XCTAssertNotNil(fit.heldSize)

        // The displays change, the cell doesn't: asked again.
        writes = app.sizeWrites
        try lay(app, in: otherCell, &fit, bounds: other, monitor: 2, epoch: 7)
        XCTAssertGreaterThan(app.sizeWrites, writes, "Asked again after the displays changed")
        XCTAssertEqual(app.frame.size, CGSize(width: 800, height: 600))
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
        XCTAssertThrowsError(try layFrame(app, cell: Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600), bounds: area, display: area,
            monitor: 1, epoch: 0, now: clock, fit: &fit, job: job))
        XCTAssertEqual(app.positionWrites, 0)
        XCTAssertEqual(fit.sizeWritesSpent, 0, "A newer layout took over before this one wrote anything")
        try lay(app, in: Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600), &fit)
        XCTAssertEqual(app.frame, Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 600))
    }
}

/// The independent reviewer's stand-in (2026-11-12): an app that keeps at most 800 × 600 and clamps
/// position writes to x ≥ 200, with no success signal.
private final class PositionClampedWindow: AxFrameAccess {
    var frame = Rect(topLeftX: 200, topLeftY: 100, width: 800, height: 600)
    var axTopLeft: CGPoint? { frame.topLeftCorner }
    var axSize: CGSize? { frame.size }
    func setAxTopLeft(_ point: CGPoint) {
        frame.topLeftX = max(200, point.x)
        frame.topLeftY = point.y
    }
    func setAxSize(_ size: CGSize) -> Bool {
        frame.width = min(800, size.width)
        frame.height = min(600, size.height)
        return true
    }
}

// MARK: - Through the layout

@MainActor
final class WindowFrameFitLayoutTest: XCTestCase {
    private let resized = RefreshSessionEvent.ax(kAXResizedNotification as String)

    override func setUp() async throws {
        setUpWorkspacesForTests()
        setMonitorsForTests([FitTestMonitor()])
        startFrameFitTestClock()
    }

    override func tearDown() async throws {
        stopFrameFitTestClock()
        setMonitorsForTests(nil)
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    /// One layout pass for each kAXResized the app's resizes would bring: every one re-sends frames. Each comes well past
    /// the settle interval after the last, with the follow-ups due meanwhile run first.
    private func layoutAfterResizes(_ workspace: Workspace, passes: Int = 1) async throws {
        for _ in 0 ..< passes {
            advanceFrameFitTestClock(by: 0.1)
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

        try await layoutAfterResizes(workspace, passes: WindowFrameFit.answersToLearn + 1)
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
        // Its first cell's follow-ups done (since 2026-11-13): what follows is the new cell's alone.
        advanceFrameFitTestClock(by: 1)
        let first = app.sizeWrites

        // The split moves: one new ask, then quiet again.
        call.setWeight(.h, call.getWeight(.h) * 1.5)
        try await layoutAfterResizes(workspace, passes: 4)
        let cell = try XCTUnwrap(call.lastAppliedLayoutPhysicalRect)
        XCTAssertGreaterThan(app.sizeWrites, first)
        XCTAssertLessThanOrEqual(app.sizeWrites - first, WindowFrameFit.answersToLearn, "Asked twice for the new cell")
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

        try await layoutAfterResizes(d, passes: WindowFrameFit.answersToLearn + 1)
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

    /// A layout, the app noticing the display its window is on, and the layout its kAXMoved and kAXResized
    /// bring, on every display.
    private func layoutAllAndCatchUp(_ app: SimulatedAppWindow) async throws {
        for _ in 0 ..< 2 {
            advanceFrameFitTestClock(by: 0.1)
            try await $refreshSessionEvent.withValue(resized) { try await layoutWorkspaces() }
            app.catchUp()
        }
    }

    /// Independent review (Astra, 2026-11-13), verbatim.
func testAstraAConstraintOnItsPhysicalDisplaySettlesOutsideThePaddedTilingArea() async throws {
        config.workspaceSidebar.enabled = false
        config.gaps = .zero
        config.gaps.outer.right = .constant(940)
        let workspace = Workspace.get(byName: "narrow-usable-area")
        XCTAssertTrue(workspace.focusWorkspace())
        let physical = FitTestMonitor().rect
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 25, width: 1100, height: 600),
            minSize: CGSize(width: 1100, height: 400))
        app.displays = [physical]
        let window = FrameFitTestWindow(id: 42, parent: workspace.rootTilingContainer, native: app)
        XCTAssertTrue(window.focusWindow())
        try await layoutAfterResizes(workspace)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(cell.width, 500)
        XCTAssertTrue(physical.contains(app.frame.center), "The window is on its physical display")
        XCTAssertFalse(workspace.workspaceMonitor.standardTilingRect.contains(app.frame.center), "Its minimum width crosses the padded area")
        XCTAssertEqual(app.frame.width, 1100)
        // Since 2026-11-13 a size is learned from the same answer to two asks in a row, not one: let it settle.
        try await layoutAfterResizes(workspace, passes: WindowFrameFit.answersToLearn)
        let writes = app.sizeWrites
        for _ in 0..<10 { try await layoutAfterResizes(workspace) }
        XCTAssertEqual(app.sizeWrites, writes, "The same constrained window on the same physical display must not be resized on every layout")
    }

    /// Independent review (Astra delta, 2026-11-13).
func testAstraASizeLargerThanTheOnlyDisplayStillStopsBeingAskedFor() async throws {
        config.workspaceSidebar.enabled = false
        config.gaps = .zero
        let workspace = Workspace.get(byName: "oversized-constraint")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 25, width: 1920, height: 1440),
            minSize: CGSize(width: 1920, height: 1440))
        let window = FrameFitTestWindow(id: 43, parent: workspace.rootTilingContainer, native: app)
        XCTAssertTrue(window.focusWindow())
        try await layoutAfterResizes(workspace)
        XCTAssertEqual(app.frame.size, CGSize(width: 1920, height: 1440))
        XCTAssertTrue(FitTestMonitor().rect.contains(app.frame.center))
        XCTAssertTrue(workspace.workspaceMonitor.standardTilingRect.contains(app.frame.center))
        // Since 2026-11-13 a size is learned from the same answer to two asks in a row, not one: let it settle.
        try await layoutAfterResizes(workspace, passes: WindowFrameFit.answersToLearn)
        let writes = app.sizeWrites
        for _ in 0..<10 { try await layoutAfterResizes(workspace) }
        XCTAssertEqual(app.sizeWrites, writes, "A stable oversize constraint on the only display must be learned")
    }

    func testMoveNodeToMonitorResizesTheWindowToItsCellThereAndBack() async throws {
        let builtIn = SavedWorkspaceTestMonitor(id: 1, name: "Built-in", x: 0, width: 1512, height: 982, isMain: true,
            uuid: "BUILTIN", isBuiltin: true)
        let pairs: [(String, Monitor)] = [
            ("larger, further along", SavedWorkspaceTestMonitor(id: 2, name: "External", x: 1512, y: -200, width: 2560, height: 1440, uuid: "EXTERNAL")),
            ("the same size", SavedWorkspaceTestMonitor(id: 2, name: "Twin", x: 1512, width: 1512, height: 982, uuid: "TWIN")),
        ]
        for (label, other) in pairs {
            setUpWorkspacesForTests()
            setMonitorsForTests([builtIn, other])
            MonitorConfigurationObserver.shared.noteDisplayChangeForTests()
            Workspace.reconcileWorkspaceState()
            let source = builtIn.activeWorkspace
            let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 900, height: 600))
            app.displays = [builtIn.rect, other.rect]
            app.screenLagsMoves = true
            let call = FrameFitTestWindow(id: 2, parent: source.rootTilingContainer, native: app)
            XCTAssertTrue(call.focusWindow())
            try await layoutAllAndCatchUp(app)
            XCTAssertEqual(app.frame, call.lastAppliedLayoutPhysicalRect, label)

            for (direction, monitor) in [("right", other), ("left", builtIn as Monitor)] {
                XCTAssertTrue(call.focusWindow())
                let result = try await parseCommand("move-node-to-monitor \(direction)").cmdOrDie.run(.defaultEnv, .emptyStdin)
                XCTAssertEqual(result.exitCode, 0, "\(label) \(direction): \(result.stderr)")
                XCTAssertTrue(call.nodeWorkspace === monitor.activeWorkspace, "\(label) \(direction)")
                try await layoutAllAndCatchUp(app)
                let cell = try XCTUnwrap(call.lastAppliedLayoutPhysicalRect)
                XCTAssertEqual(app.frame, cell, "\(label) \(direction): resized to its cell on that display")
            }
            // Leave focus known on the first display: the last focused monitor outlives the test, and a later
            // test would otherwise see its own first focus as a change of display.
            XCTAssertTrue(call.focusWindow())
            checkOnFocusChangedCallbacks()
        }
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

    func testDraggingTheRightEdgeOfACenteredWindowResizesOnlyTowardThatEdge() async throws {
        let workspace = Workspace.get(byName: "call")
        XCTAssertTrue(workspace.focusWorkspace())
        workspace.rootTilingContainer.layout = .tiles
        let left = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        // Tall and narrow: in a third of the display it keeps the cell's height and leaves room on both sides.
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 300, height: 750), aspect: 0.4)
        let call = FrameFitTestWindow(id: 2, parent: workspace.rootTilingContainer, native: app)
        let right = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        try await layoutAfterResizes(workspace)
        let cell = try XCTUnwrap(call.lastAppliedLayoutPhysicalRect)
        let placed = try XCTUnwrap(call.layoutPlacedRect)
        XCTAssertGreaterThan(placed.minX - cell.minX, 5, "Centered with room on the left")

        // The user drags its right edge 40 points to the right; the left edge stays where it was.
        let dragged = Rect(topLeftX: placed.minX, topLeftY: placed.minY, width: placed.width + 40, height: placed.height)
        let changes = try XCTUnwrap(proposedResizeWeightMap(call, rect: dragged)).changes
        let changed = Set(changes.compactMap { ($0.node as? Window)?.windowId })
        XCTAssertTrue(changed.contains(right.windowId), "The neighbour on the dragged side gives way")
        XCTAssertFalse(changed.contains(left.windowId), "The neighbour on the other side is left alone")
        workspace.rootTilingContainer.resetResizeWeightBeforeResizeRecursive()
    }
}
