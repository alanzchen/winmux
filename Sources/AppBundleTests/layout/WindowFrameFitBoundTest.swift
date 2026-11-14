@testable import AppBundle
import AppKit
import Common
import XCTest

/// The design committee's review (Astra + Carbon, 2026-11-13) of the bounded learning in 1e3750d6: what a layout's size
/// writes may cost, when an answer counts toward learning a size, and what starts that over. Against the production
/// `setFrame` and simulated apps, one call per layout or follow-up, on a test clock.
final class WindowFrameFitBoundTest: XCTestCase {
    private let area = Rect(topLeftX: 0, topLeftY: 0, width: 1440, height: 900)
    private let builtIn = Rect(topLeftX: 0, topLeftY: 0, width: 1512, height: 982)
    private let external = Rect(topLeftX: 1512, topLeftY: 0, width: 2560, height: 1440)
    /// An external display on the other side, at negative coordinates.
    private let leftExternal = Rect(topLeftX: -2560, topLeftY: -200, width: 2560, height: 1440)
    private var builtInCell: Rect { Rect(topLeftX: 8, topLeftY: 33, width: 1496, height: 941) }
    private var externalCell: Rect { Rect(topLeftX: 1520, topLeftY: 33, width: 2544, height: 1399) }
    private var leftExternalCell: Rect { Rect(topLeftX: -2552, topLeftY: -167, width: 2544, height: 1399) }
    /// The hard bound for one cell size on one display: three writes to get a size, one kept for a change after.
    private let maxSizeWrites = 4

    private var clock: TimeInterval = 1000
    private var fit = WindowFrameFit()

    /// A layout writing `app` into `cell`, `delay` after the last call (by default well past the settle interval).
    @discardableResult
    private func lay<W: AxFrameAccess>(_ app: W, _ cell: Rect, on display: Rect, monitor: Int, epoch: UInt64 = 0,
                                       after delay: TimeInterval = 0.1, job: RunLoopJob = RunLoopJob()) throws -> Rect? {
        clock += delay
        return try layFrame(app, cell: cell, bounds: display, display: display, monitor: monitor, epoch: epoch, now: clock, fit: &fit, job: job)
    }

    /// The layouts a constrained window needs before its size is learned, as many as before 2026-11-13's committee.
    private func settle<W: AxFrameAccess>(_ app: W, _ cell: Rect, on display: Rect, monitor: Int) throws {
        for _ in 0 ... WindowFrameFit.answersToLearn { try lay(app, cell, on: display, monitor: monitor) }
    }

    /// The follow-up the last write asked for, run when it's due as MacApp schedules it, and every one it asks for
    /// in turn: how many ran.
    @discardableResult
    private func followUps<W: AxFrameAccess>(_ app: W, _ cell: Rect, on display: Rect, monitor: Int, epoch: UInt64 = 0) throws -> Int {
        var count = 0
        while count < 10, let at = followUpTime(fit) {
            clock = max(clock, at)
            try layFrame(app, cell: cell, bounds: display, display: display, monitor: monitor, epoch: epoch, now: clock, continuing: true,
                fit: &fit)
            count += 1
        }
        return count
    }

    // MARK: Screen adoption: the display AppKit fits a resized window to, after a move to another one

    /// A window whose app notices its new display at once takes its cell there with one size write, either way and
    /// on either side: it's moved to its cell's corner first, then asked once.
    func testAWindowWhoseScreenFollowsAtOnceTakesItsCellWithOneWriteEitherWay() throws {
        for (other, otherCell) in [(external, externalCell), (leftExternal, leftExternalCell)] {
            fit = WindowFrameFit()
            let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 900, height: 600))
            app.displays = [builtIn, other]
            try lay(app, builtInCell, on: builtIn, monitor: 1)
            XCTAssertEqual(app.frame, builtInCell)
            var writes = app.sizeWrites
            try lay(app, otherCell, on: other, monitor: 2)
            XCTAssertEqual(app.frame, otherCell, "\(other)")
            XCTAssertEqual(app.sizeWrites - writes, 1, "Moved to its cell's corner on the new display first, then asked once")
            writes = app.sizeWrites
            try lay(app, builtInCell, on: builtIn, monitor: 1)
            XCTAssertEqual(app.frame, builtInCell, "And back")
            XCTAssertEqual(app.sizeWrites - writes, 1)
        }
    }

    /// The app goes on fitting the window to the display it left until its run loop turns: the follow-up the first
    /// write leaves asks again once that's past, and the window takes its cell, with nothing else to bring a layout.
    /// Back on the smaller display it's asked for less than either display allows, so at once.
    func testAWindowWhoseScreenLagsOneTryTakesItsCellOnTheFollowUpEitherWay() throws {
        for (other, otherCell) in [(external, externalCell), (leftExternal, leftExternalCell)] {
            fit = WindowFrameFit()
            let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 900, height: 600))
            app.displays = [builtIn, other]
            app.screenLagsMoves = true
            try lay(app, builtInCell, on: builtIn, monitor: 1)
            XCTAssertEqual(app.frame, builtInCell)
            let writes = app.sizeWrites

            try lay(app, otherCell, on: other, monitor: 2)
            XCTAssertNotEqual(app.frame.size, otherCell.size, "Still fit to the display it came from")
            XCTAssertNil(learnedSize(fit))
            app.catchUp()
            try followUps(app, otherCell, on: other, monitor: 2)
            XCTAssertEqual(app.frame, otherCell, "\(other): the follow-up asks again once the app noticed its display")
            XCTAssertEqual(app.sizeWrites - writes, 2)
            let settled = (app.sizeWrites, app.positionWrites)
            for _ in 0 ..< 5 { try lay(app, otherCell, on: other, monitor: 2) }
            XCTAssertEqual(app.sizeWrites, settled.0, "Then left alone")
            XCTAssertEqual(app.positionWrites, settled.1)

            try lay(app, builtInCell, on: builtIn, monitor: 1)
            app.catchUp()
            try followUps(app, builtInCell, on: builtIn, monitor: 1)
            XCTAssertEqual(app.frame, builtInCell, "And back")
            XCTAssertEqual(app.sizeWrites - settled.0, 1)
        }
    }

    /// If the app went on fitting the window to its old display past every try, the size it keeps there is learned
    /// after two of them (the trade-off for the bound) and not fought. Displays changing (a new epoch) asks again.
    func testAWindowWhoseScreenLagsPastItsTriesIsLeftAtItsLimitUntilDisplaysChange() throws {
        for (other, otherCell) in [(external, externalCell), (leftExternal, leftExternalCell)] {
            fit = WindowFrameFit()
            let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 900, height: 600))
            app.displays = [builtIn, other]
            app.screenLagsMoves = true
            try lay(app, builtInCell, on: builtIn, monitor: 1)
            app.catchUp()
            let writes = app.sizeWrites

            try lay(app, otherCell, on: other, monitor: 2)
            try followUps(app, otherCell, on: other, monitor: 2)
            for _ in 0 ..< 5 { try lay(app, otherCell, on: other, monitor: 2) }
            XCTAssertLessThanOrEqual(app.sizeWrites - writes, maxSizeWrites - 1, "\(other): within the writes for getting a size")
            XCTAssertEqual(app.frame.size, builtIn.size, "Left at the size the old display allowed")
            XCTAssertEqual(app.frame.center.x, otherCell.center.x, accuracy: 1, "Centered in its cell")
            let frame = app.frame
            app.catchUp()
            for _ in 0 ..< 5 { try lay(app, otherCell, on: other, monitor: 2) }
            XCTAssertEqual(app.frame, frame, "Not fought")

            try lay(app, otherCell, on: other, monitor: 2, epoch: 1)
            XCTAssertEqual(app.frame, otherCell, "Asked again once displays changed")
        }
    }

    /// Displays are told apart by id, not by where they are: a size learned on one isn't taken for another's, with a
    /// cell of the same size, or even the very same rectangle (mirrored, or reported alike while reconfiguring).
    func testAKeptSizeIsAskedForAgainOnAnotherDisplayWithAnEqualCellOrTheSameRectangle() throws {
        let twin = Rect(topLeftX: 1512, topLeftY: 0, width: 1512, height: 982)
        let twinCell = Rect(topLeftX: 1520, topLeftY: 33, width: 1496, height: 941)
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 640, height: 360), aspect: 16.0 / 9.0)
        app.displays = [builtIn, twin]
        try settle(app, builtInCell, on: builtIn, monitor: 1)
        XCTAssertNotNil(learnedSize(fit))

        var writes = app.sizeWrites
        try lay(app, twinCell, on: twin, monitor: 2)
        XCTAssertEqual(app.sizeWrites - writes, 1, "Asked on the other display, for a cell of the same size")
        try settle(app, twinCell, on: twin, monitor: 2)
        XCTAssertNotNil(learnedSize(fit))

        writes = app.sizeWrites
        try lay(app, twinCell, on: twin, monitor: 3)
        XCTAssertEqual(app.sizeWrites - writes, 1, "Asked on a display with the same rectangle but another id")
    }

    /// Layouts can come less than 10 ms apart, before the app has noticed where its window went: they neither ask
    /// again nor count toward learning a size, so they neither latch the old display's limit nor spend the writes.
    func testABurstOfLayoutsBeforeTheAppNoticesItsDisplayNeitherLatchesNorSpends() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 900, height: 600))
        app.displays = [builtIn, external]
        app.screenLagsMoves = true
        try lay(app, builtInCell, on: builtIn, monitor: 1)
        app.catchUp()
        let writes = app.sizeWrites

        try lay(app, externalCell, on: external, monitor: 2)
        for _ in 0 ..< 3 { try lay(app, externalCell, on: external, monitor: 2, after: 0.003) }
        XCTAssertEqual(app.sizeWrites - writes, 1, "One write for the burst")
        XCTAssertNil(learnedSize(fit), "Nothing learned from it")
        app.catchUp()
        try lay(app, externalCell, on: external, monitor: 2)
        XCTAssertEqual(app.frame, externalCell)
        XCTAssertEqual(app.sizeWrites - writes, 2)
    }

    /// A window larger than the display it goes to: the move to its cell's corner first may be refused while it's that
    /// large, which mustn't keep it from shrinking. It's placed in its cell once it has.
    func testALargeWindowShrinksIntoASmallerCellWhenTheMoveBeforeIsRefused() throws {
        let app = SimulatedAppWindow(externalCell)
        app.displays = [builtIn, external]
        // No move that would leave a window wider than the built-in display mostly off the external one.
        app.takesPosition = { [builtIn] topLeft, frame in
            frame.width > builtIn.width && topLeft.x < builtIn.maxX
                ? frame
                : Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: frame.width, height: frame.height)
        }
        try lay(app, builtInCell, on: builtIn, monitor: 1)
        XCTAssertEqual(app.frame, builtInCell)
        XCTAssertEqual(app.sizeWrites, 1)
    }

    /// An app that takes the size but keeps its window where it is: a refused move is no reason to write the size,
    /// and isn't asked for again in the same cell.
    func testAWindowAtItsSizeWhoseMoveIsRefusedIsNeitherResizedNorMovedAgain() throws {
        let cell = Rect(topLeftX: 0, topLeftY: 25, width: 1000, height: 600)
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 1000, height: 600))
        app.takesPosition = { _, frame in frame }
        for _ in 0 ..< 10 { try lay(app, cell, on: area, monitor: 1) }
        XCTAssertEqual(app.sizeWrites, 0)
        XCTAssertEqual(app.positionWrites, 1, "Asked to move once")
        // Another place in the same display is another move to ask for.
        try lay(app, Rect(topLeftX: 10, topLeftY: 25, width: 1000, height: 600), on: area, monitor: 1)
        XCTAssertEqual(app.positionWrites, 2)
        XCTAssertEqual(app.sizeWrites, 0)
    }

    // MARK: The hard bound: at most four size writes for one cell size on one display

    func testSizesThatCantBeReadCostAtMostTheBound() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 900, height: 600))
        app.sizeReadable = false
        for _ in 0 ..< 20 {
            try lay(app, builtInCell, on: builtIn, monitor: 1)
            try followUps(app, builtInCell, on: builtIn, monitor: 1)
        }
        XCTAssertLessThanOrEqual(app.sizeWrites, maxSizeWrites)
        XCTAssertNil(learnedSize(fit))
    }

    /// Writes the app never takes count toward the bound, and say nothing about a size of its own.
    func testWritesThatFailCostAtMostTheBoundAndTeachNothing() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 900, height: 600))
        app.answers = false
        for _ in 0 ..< 20 {
            try lay(app, builtInCell, on: builtIn, monitor: 1)
            try followUps(app, builtInCell, on: builtIn, monitor: 1)
        }
        XCTAssertLessThanOrEqual(app.sizeWrites, maxSizeWrites)
        XCTAssertNil(learnedSize(fit), "A failed write isn't the app keeping a size")
        XCTAssertEqual(app.frame.size, CGSize(width: 900, height: 600))
    }

    /// A write that fails once, then works: the window takes its cell, within the bound, and nothing's learned.
    func testAWriteThatFailsOnceThenWorksTakesTheCell() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 900, height: 600))
        app.failingWrites = 1
        for _ in 0 ..< 20 {
            try lay(app, builtInCell, on: builtIn, monitor: 1)
            try followUps(app, builtInCell, on: builtIn, monitor: 1)
        }
        XCTAssertEqual(app.frame, builtInCell)
        XCTAssertLessThanOrEqual(app.sizeWrites, maxSizeWrites)
        XCTAssertNil(learnedSize(fit))
    }

    /// Layouts a newer one cancels, at any point after they began writing: every size write made still counts. The app
    /// never answers the same twice in a row, so nothing is learned and only the bound stops the writes.
    func testLayoutsCancelledAtAnyPointCostAtMostTheBound() throws {
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        for boundary in ["first move", "size", "placement"] {
            fit = WindowFrameFit()
            let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 640, height: 480))
            app.answersInTurn = [CGSize(width: 800, height: 600), CGSize(width: 900, height: 500), CGSize(width: 700, height: 550)]
            for _ in 0 ..< 20 {
                let job = RunLoopJob()
                var moves = 0
                app.onPositionWrite = {}
                app.onSizeWrite = {}
                switch boundary {
                    case "first move": app.onPositionWrite = { moves += 1; if moves == 1 { job.cancel() } }
                    case "size": app.onSizeWrite = { job.cancel() }
                    default: app.onPositionWrite = { moves += 1; if moves == 2 { job.cancel() } }
                }
                _ = try? lay(app, cell, on: area, monitor: 1, job: job)
            }
            XCTAssertLessThanOrEqual(app.sizeWrites, maxSizeWrites, "Cancelled after the \(boundary)")
        }
    }

    /// An app that goes to sizes of its own, one after another, once its size was learned (A → B → C → D → E): the
    /// write kept for a change is spent on the first, and that's all.
    func testSizesAnAppGoesToAfterItsSizeWasLearnedCostAtMostTheBound() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 640, height: 480), aspect: 4.0 / 3.0)
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        try settle(app, cell, on: area, monitor: 1)
        XCTAssertEqual(learnedSize(fit), CGSize(width: 800, height: 600))
        for size in [CGSize(width: 700, height: 525), CGSize(width: 600, height: 450), CGSize(width: 500, height: 375),
                     CGSize(width: 400, height: 300)]
        {
            app.resizeOnItsOwn(to: size)
            app.answersInTurn = [size]
            for _ in 0 ..< 3 {
                try lay(app, cell, on: area, monitor: 1)
                try followUps(app, cell, on: area, monitor: 1)
            }
        }
        XCTAssertLessThanOrEqual(app.sizeWrites, maxSizeWrites)
    }

    /// An app that takes each write, then goes to another size of its own (request → A → request → B …): the writes
    /// stop within the bound.
    func testAnAppThatKeepsLeavingTheRequestCostsAtMostTheBound() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480))
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        let away = [CGSize(width: 900, height: 600), CGSize(width: 1000, height: 500)]
        for i in 0 ..< 20 {
            try lay(app, cell, on: area, monitor: 1)
            try followUps(app, cell, on: area, monitor: 1)
            app.resizeOnItsOwn(to: away[i % 2])
        }
        XCTAssertLessThanOrEqual(app.sizeWrites, maxSizeWrites)
    }

    // MARK: When answers count

    /// The same differing size with the request reached in between isn't two answers in a row.
    func testADifferingSizeOnEitherSideOfTheRequestIsntLearned() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480))
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        let other = CGSize(width: 900, height: 600)
        try lay(app, cell, on: area, monitor: 1)
        app.resizeOnItsOwn(to: other)
        try lay(app, cell, on: area, monitor: 1)
        XCTAssertEqual(app.frame, cell)
        try lay(app, cell, on: area, monitor: 1)
        XCTAssertEqual(app.frame, cell, "At the request: the run of differing answers is over")

        app.resizeOnItsOwn(to: other)
        try lay(app, cell, on: area, monitor: 1)
        XCTAssertNil(learnedSize(fit), "One differing answer since the request isn't two in a row")
        XCTAssertEqual(app.frame, cell)
    }

    /// Attempts ending at the same other size, with one ending at the request between them, aren't two in a row: out of
    /// writes, the window is left at that size, not taken to keep it.
    func testAttemptsEndingAtTheSameOtherSizeAcrossASuccessArentLearned() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480))
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        let other = CGSize(width: 900, height: 600)
        app.answersInTurn = [other, cell.size, other]
        for _ in 0 ..< 3 { try lay(app, cell, on: area, monitor: 1) }
        XCTAssertEqual(app.frame, cell, "Its second write took")

        app.resizeOnItsOwn(to: other)
        for _ in 0 ..< 3 { try lay(app, cell, on: area, monitor: 1) }
        XCTAssertEqual(app.frame.size, other)
        XCTAssertNil(learnedSize(fit), "Not two answers in a row: the request came between")
        XCTAssertLessThanOrEqual(app.sizeWrites, maxSizeWrites)
    }

    /// A size write AppKit takes 100 ms over: the settle interval runs from when it's done, so the follow-up doesn't look
    /// before the app has had its time to notice its new display (Astra's review, 2026-11-13, for slow reads before it).
    func testASlowSizeWriteDoesntEatTheSettleInterval() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 900, height: 600))
        app.displays = [builtIn, external]
        app.screenLagsMoves = true
        try lay(app, builtInCell, on: builtIn, monitor: 1)
        app.catchUp()

        clock += 0.1
        var writeDone = clock
        app.onSizeWrite = { [unowned self] in
            clock += 0.1
            writeDone = clock
        }
        try setFrame(app, externalCell.topLeftCorner, externalCell.size, fit: &fit, within: external,
            target: FrameFitTarget(monitor: 2, epoch: 0), now: self.clock, RunLoopJob())
        app.onSizeWrite = {}
        let due = try XCTUnwrap(followUpTime(fit))
        XCTAssertGreaterThanOrEqual(due, writeDone + WindowFrameFit.settleInterval - 0.001, "From the end of the write")

        // The app notices its display 20 ms after the write is done, well inside the interval.
        clock = max(clock, due)
        if clock >= writeDone + 0.02 { app.catchUp() }
        try followUps(app, externalCell, on: external, monitor: 2)
        XCTAssertEqual(app.frame, externalCell)
        XCTAssertNil(learnedSize(fit))
    }

    /// A layout that begins inside the settle interval after a write that failed leaves the size to its follow-up. An AX
    /// read that runs past the interval's end mustn't lose that follow-up (Carbon's delta review, 2026-11-14).
    func testALayoutDeferredInsideTheIntervalKeepsItsFollowUpWhenItsReadRunsPastIt() throws {
        let cell = Rect(topLeftX: 0, topLeftY: 25, width: 1200, height: 800)
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 640, height: 480))
        app.failingWrites = 1
        let slow = SlowSizeReads(app)
        let target = FrameFitTarget(monitor: 1, epoch: 0)
        try setFrame(slow, cell.topLeftCorner, cell.size, fit: &fit, within: area, target: target, now: slow.clock, RunLoopJob())
        XCTAssertEqual(app.sizeWrites, 1)
        let due = try XCTUnwrap(followUpTime(fit))

        slow.clock = due - 0.04
        slow.readDelay = 0.05
        try setFrame(slow, cell.topLeftCorner, cell.size, fit: &fit, within: area, target: target, now: slow.clock, RunLoopJob())
        XCTAssertEqual(app.sizeWrites, 1, "It began inside the interval: no write")
        XCTAssertEqual(followUpTime(fit), due, "Its follow-up is kept")

        slow.readDelay = 0
        slow.clock = due + 0.001
        try setFrame(slow, cell.topLeftCorner, cell.size, fit: &fit, within: area, target: target, continuing: true, now: slow.clock,
            RunLoopJob())
        XCTAssertEqual(app.frame, cell, "And the follow-up asks again")
    }

    /// A write that fails, in a layout a newer one cancels right after it, still breaks a run of answers: the attempts on
    /// either side of it aren't two in a row (Carbon's review, 2026-11-13).
    func testAFailedWriteCancelledRightAfterStillBreaksTheRunOfAnswers() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480))
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        app.answersInTurn = [CGSize(width: 900, height: 600)]
        try lay(app, cell, on: area, monitor: 1)
        app.failingWrites = 1
        let job = RunLoopJob()
        app.onSizeWrite = { job.cancel() }
        XCTAssertThrowsError(try lay(app, cell, on: area, monitor: 1, job: job))
        app.onSizeWrite = {}
        try lay(app, cell, on: area, monitor: 1)
        try lay(app, cell, on: area, monitor: 1)
        XCTAssertNil(learnedSize(fit), "The failed write came between")
        XCTAssertLessThanOrEqual(app.sizeWrites, maxSizeWrites)
    }

    /// A FaceTime-like window, which keeps a ratio during a call, moved to a larger display: its size there is learned
    /// within the writes for getting a size and not fought. When the call ends (the window leaves that size on its
    /// own), the write kept for a change gets it its cell; changes of its own after that are left alone.
    func testACallWindowLearnedOnAnotherDisplayGetsItsCellBackWhenTheCallEnds() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 640, height: 360), aspect: 16.0 / 9.0)
        app.displays = [builtIn, external]
        app.screenLagsMoves = true
        try settle(app, builtInCell, on: builtIn, monitor: 1)
        app.catchUp()
        let before = app.sizeWrites

        try lay(app, externalCell, on: external, monitor: 2)
        app.catchUp()
        for _ in 0 ..< 3 { try lay(app, externalCell, on: external, monitor: 2) }
        XCTAssertEqual(learnedSize(fit), CGSize(width: 2487, height: 1399), "The ratio it keeps there, not the old display's limit")
        XCTAssertLessThanOrEqual(app.sizeWrites - before, maxSizeWrites - 1)
        let learned = app.sizeWrites
        for _ in 0 ..< 5 { try lay(app, externalCell, on: external, monitor: 2) }
        XCTAssertEqual(app.sizeWrites, learned, "Not fought")

        app.aspect = nil
        app.resizeOnItsOwn(to: CGSize(width: 1280, height: 720))
        try lay(app, externalCell, on: external, monitor: 2)
        XCTAssertEqual(app.frame, externalCell, "The call ended: back in its cell")
        XCTAssertEqual(app.sizeWrites - learned, 1, "With the one write kept for a change")

        app.resizeOnItsOwn(to: CGSize(width: 1280, height: 720))
        for _ in 0 ..< 5 { try lay(app, externalCell, on: external, monitor: 2) }
        XCTAssertEqual(app.sizeWrites - learned, 1, "A change after that isn't asked about")
    }

    // MARK: Writes that aren't a layout's

    /// A frame written as asked (a window put back after it was moved out of view, a tab strip action) says nothing
    /// about what the app keeps in a cell: what was learned is gone, and the next layout asks again.
    func testAnExplicitFrameStartsTheFitOver() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 640, height: 480), aspect: 4.0 / 3.0)
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        try settle(app, cell, on: area, monitor: 1)
        XCTAssertNotNil(learnedSize(fit))

        try writeFrame(app, cell.topLeftCorner, cell.size, fit: &fit)
        XCTAssertNil(learnedSize(fit))
        let writes = app.sizeWrites
        try lay(app, cell, on: area, monitor: 1)
        XCTAssertEqual(app.sizeWrites - writes, 1, "Asked again")
    }

    /// Parked in a corner while its tab is hidden (a move alone), then shown: on the same display what was learned
    /// still holds and no size is written; on another, it's asked for there.
    func testParkingAndShowingOnTheSameDisplayCostsNoWriteAndOnAnotherAsksAgain() throws {
        let twin = Rect(topLeftX: 1512, topLeftY: 0, width: 1512, height: 982)
        let twinCell = Rect(topLeftX: 1520, topLeftY: 33, width: 1496, height: 941)
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 640, height: 360), aspect: 16.0 / 9.0)
        app.displays = [builtIn, twin]
        try settle(app, builtInCell, on: builtIn, monitor: 1)
        let frame = app.frame
        let writes = app.sizeWrites

        try writeFrame(app, CGPoint(x: builtIn.maxX - 1, y: builtIn.maxY - 1), nil, fit: &fit)
        try lay(app, builtInCell, on: builtIn, monitor: 1)
        XCTAssertEqual(app.frame, frame)
        XCTAssertEqual(app.sizeWrites, writes, "Back on the same display: placed, not asked")

        try writeFrame(app, CGPoint(x: builtIn.maxX - 1, y: builtIn.maxY - 1), nil, fit: &fit)
        try lay(app, twinCell, on: twin, monitor: 2)
        XCTAssertEqual(app.sizeWrites - writes, 1, "Shown on another display: asked there")
    }

    /// A follow-up for a cell the window has since left (the same size elsewhere) does nothing: it can't put the
    /// window back where it was.
    func testAFollowUpForACellTheWindowLeftDoesNothing() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 900, height: 600))
        app.displays = [builtIn, external]
        app.screenLagsMoves = true
        try lay(app, builtInCell, on: builtIn, monitor: 1)
        app.catchUp()
        try lay(app, externalCell, on: external, monitor: 2)
        let moved = Rect(topLeftX: externalCell.topLeftX, topLeftY: externalCell.topLeftY + 1, width: externalCell.width,
            height: externalCell.height)
        try lay(app, moved, on: external, monitor: 2, after: 0.001)
        let frame = app.frame
        let writes = (app.sizeWrites, app.positionWrites)

        clock += 0.1
        try layFrame(app, cell: externalCell, bounds: external, display: external, monitor: 2, epoch: 0, now: clock, continuing: true,
            fit: &fit)
        XCTAssertEqual(app.frame, frame)
        XCTAssertEqual(app.sizeWrites, writes.0)
        XCTAssertEqual(app.positionWrites, writes.1)
    }

    /// A move alone (a park) keeps what was learned, and holds off a follow-up until a layout writes the window again.
    func testAMoveAloneHoldsOffAFollowUp() throws {
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 100, width: 900, height: 600))
        app.displays = [builtIn, external]
        app.screenLagsMoves = true
        try lay(app, builtInCell, on: builtIn, monitor: 1)
        app.catchUp()
        try lay(app, externalCell, on: external, monitor: 2)
        try writeFrame(app, CGPoint(x: external.maxX - 1, y: external.maxY - 1), nil, fit: &fit)
        XCTAssertNil(followUpTime(fit))
        let writes = (app.sizeWrites, app.positionWrites)
        clock += 0.1
        try layFrame(app, cell: externalCell, bounds: external, display: external, monitor: 2, epoch: 0, now: clock, continuing: true,
            fit: &fit)
        XCTAssertEqual(app.sizeWrites, writes.0)
        XCTAssertEqual(app.positionWrites, writes.1, "Still parked")
    }
}

/// A window whose size reads take `readDelay` on `clock`: AX reads that run long.
private final class SlowSizeReads: AxFrameAccess {
    let app: SimulatedAppWindow
    var clock: TimeInterval = 1000
    var readDelay: TimeInterval = 0

    init(_ app: SimulatedAppWindow) { self.app = app }

    var axSize: CGSize? {
        clock += readDelay
        return app.axSize
    }

    var axTopLeft: CGPoint? { app.axTopLeft }
    func setAxTopLeft(_ topLeft: CGPoint) { app.setAxTopLeft(topLeft) }
    func setAxSize(_ size: CGSize) -> Bool { app.setAxSize(size) }
}
