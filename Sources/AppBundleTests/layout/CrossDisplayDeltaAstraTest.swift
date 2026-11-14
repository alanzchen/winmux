@testable import AppBundle
import AppKit
import XCTest

final class CrossDisplayDeltaAstraTest: XCTestCase {
    private var clock: TimeInterval = 1000

    // Since the design committee (2026-11-13) a layout's write names its display by id and runs on a clock: each call here
    // is a layout on the target display, well past the settle interval after the last.
    private func lay(_ app: SimulatedAppWindow, cell: Rect, display: Rect, fit: inout WindowFrameFit) throws {
        clock += 0.1
        try setFrame(app, cell.topLeftCorner, cell.size, fit: &fit, within: display, target: FrameFitTarget(monitor: 1, epoch: 0), now: clock,
            RunLoopJob())
    }

    func testExactlyHalfOfAFixedWindowOnItsDisplaySettles() throws {
        let display = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)
        let fixed = CGSize(width: 1600, height: 600)
        let app = SimulatedAppWindow(Rect(topLeftX: 0, topLeftY: 0, width: fixed.width, height: fixed.height), minSize: fixed)
        var fit = WindowFrameFit()
        // Since 2026-11-13 a size is learned from the same answer to two asks in a row, not one: let it settle.
        for _ in 0 ... WindowFrameFit.answersToLearn { try lay(app, cell: display, display: display, fit: &fit) }
        let writes = app.sizeWrites
        for _ in 0..<10 { try lay(app, cell: display, display: display, fit: &fit) }
        XCTAssertEqual(app.sizeWrites, writes)
        XCTAssertEqual(fit.heldSize, fixed)
    }

    func testAWindowLargerThanItsDisplayWithMoreThanHalfVisibleSettles() throws {
        let display = Rect(topLeftX: -800, topLeftY: -600, width: 800, height: 600)
        let fixed = CGSize(width: 1100, height: 600)
        let app = SimulatedAppWindow(Rect(topLeftX: -800, topLeftY: -600, width: fixed.width, height: fixed.height), minSize: fixed)
        var fit = WindowFrameFit()
        // Since 2026-11-13 a size is learned from the same answer to two asks in a row, not one: let it settle.
        for _ in 0 ... WindowFrameFit.answersToLearn { try lay(app, cell: display, display: display, fit: &fit) }
        let writes = app.sizeWrites
        for _ in 0..<10 { try lay(app, cell: display, display: display, fit: &fit) }
        XCTAssertEqual(app.sizeWrites, writes)
        XCTAssertEqual(fit.heldSize, fixed)
    }

    func testTheLargestOfThreeDisplaySharesCanBeLessThanHalfAndStillSettle() throws {
        let left = Rect(topLeftX: -500, topLeftY: 0, width: 500, height: 600)
        let target = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)
        let right = Rect(topLeftX: 800, topLeftY: 0, width: 500, height: 600)
        let fixed = CGSize(width: 1800, height: 600)
        let app = SimulatedAppWindow(Rect(topLeftX: -500, topLeftY: 0, width: fixed.width, height: fixed.height), minSize: fixed)
        // AX may answer with a size larger than the display. Do not add the simulator's optional
        // AppKit screen clamp, which overrides its minimum size rather than modelling this case.
        func overlap(_ rect: Rect) -> CGFloat {
            let intersection = CGRect(x: app.frame.minX, y: app.frame.minY, width: app.frame.width, height: app.frame.height)
                .intersection(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        XCTAssertGreaterThan(overlap(target), overlap(left))
        XCTAssertGreaterThan(overlap(target), overlap(right))
        XCTAssertLessThan(overlap(target) * 2, fixed.width * fixed.height)
        var fit = WindowFrameFit()
        // Since 2026-11-13 a size is learned from the same answer to two asks in a row, not one: let it settle.
        for _ in 0 ... WindowFrameFit.answersToLearn { try lay(app, cell: target, display: target, fit: &fit) }
        let writes = app.sizeWrites
        for _ in 0..<10 { try lay(app, cell: target, display: target, fit: &fit) }
        XCTAssertEqual(app.sizeWrites, writes, "An unchanging constrained window must not be resized forever when no display holds half")
    }

    func testAResizableWindowStraddlingThreeDisplaysConverges() throws {
        let left = Rect(topLeftX: -500, topLeftY: 0, width: 500, height: 600)
        let target = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)
        let right = Rect(topLeftX: 800, topLeftY: 0, width: 500, height: 600)
        let app = SimulatedAppWindow(Rect(topLeftX: -500, topLeftY: 0, width: 1800, height: 600))
        app.displays = [left, target, right]
        app.screenLagsMoves = true
        var fit = WindowFrameFit()
        for _ in 0..<3 { try lay(app, cell: target, display: target, fit: &fit); app.catchUp() }
        XCTAssertEqual(app.frame, target)
        let writes = app.sizeWrites
        for _ in 0..<10 { try lay(app, cell: target, display: target, fit: &fit) }
        XCTAssertEqual(app.sizeWrites, writes)
    }

    func testAnExactlyHalfStraddlingWindowConvergesForEitherScreenTieOrder() throws {
        let source = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)
        let target = Rect(topLeftX: 800, topLeftY: 0, width: 1600, height: 1200)
        let cell = Rect(topLeftX: 808, topLeftY: 33, width: 1584, height: 1159)
        for order in [[source, target], [target, source]] {
            let app = SimulatedAppWindow(Rect(topLeftX: 600, topLeftY: 50, width: 400, height: 300))
            app.displays = order
            app.screenLagsMoves = true
            var fit = WindowFrameFit()
            for _ in 0..<3 { try lay(app, cell: cell, display: target, fit: &fit); app.catchUp() }
            XCTAssertEqual(app.frame, cell, "Equal area does not establish which screen AppKit used; first screen = \(order[0])")
        }
    }
}
