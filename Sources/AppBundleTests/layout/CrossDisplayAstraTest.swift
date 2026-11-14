@testable import AppBundle
import AppKit
import XCTest

final class CrossDisplayAstraTest: XCTestCase {
    private var clock: TimeInterval = 1000

    // Since the design committee (2026-11-13) a layout's write names its display by id and runs on a clock: each call here
    // is a layout on the destination display, well past the settle interval after the last.
    private func lay(_ app: SimulatedAppWindow, _ cell: Rect, _ display: Rect, _ fit: inout WindowFrameFit) throws {
        clock += 0.1
        try setFrame(app, cell.topLeftCorner, cell.size, fit: &fit, within: display, target: FrameFitTarget(monitor: 1, epoch: 0), now: clock,
            RunLoopJob())
    }

    func testNegativeDisplayOriginsConvergeAndThenStopWriting() throws {
        let source = Rect(topLeftX: -1920, topLeftY: -1080, width: 1920, height: 1080)
        let destination = Rect(topLeftX: 0, topLeftY: 0, width: 2560, height: 1440)
        let cell = Rect(topLeftX: 8, topLeftY: 33, width: 2544, height: 1399)
        let app = SimulatedAppWindow(Rect(topLeftX: -1800, topLeftY: -900, width: 900, height: 600))
        app.displays = [source, destination]
        app.screenLagsMoves = true
        var fit = WindowFrameFit()
        for _ in 0..<2 { try lay(app, cell, destination, &fit); app.catchUp() }
        XCTAssertEqual(app.frame, cell)
        let writes = app.sizeWrites
        for _ in 0..<5 { try lay(app, cell, destination, &fit) }
        XCTAssertEqual(app.sizeWrites, writes)
    }

    func testCoincidentDisplayGeometryDoesNotCreateAResizeLoop() throws {
        let display = Rect(topLeftX: 0, topLeftY: 0, width: 1440, height: 900)
        let cell = Rect(topLeftX: 10, topLeftY: 30, width: 1420, height: 850)
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 640, height: 360), aspect: 16.0 / 9.0)
        app.displays = [display, display]
        app.screenLagsMoves = true
        var fit = WindowFrameFit()
        for _ in 0..<2 { try lay(app, cell, display, &fit); app.catchUp() }
        let writes = app.sizeWrites
        for _ in 0..<10 { try lay(app, cell, display, &fit) }
        XCTAssertEqual(app.sizeWrites, writes)
        XCTAssertNotNil(fit.heldSize)
    }

    /// The author's screen-lag model, with the starting window straddling the boundary.
    func testAWindowWhoseCenterCrossedBeforeItsScreenCaughtUpStillGetsItsNewCell() throws {
        let source = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)
        let destination = Rect(topLeftX: 800, topLeftY: 0, width: 1600, height: 1200)
        let cell = Rect(topLeftX: 808, topLeftY: 33, width: 1584, height: 1159)
        let app = SimulatedAppWindow(Rect(topLeftX: 700, topLeftY: 50, width: 400, height: 300))
        app.displays = [source, destination]
        app.screenLagsMoves = true
        XCTAssertTrue(source.contains(app.frame.topLeftCorner))
        XCTAssertTrue(destination.contains(app.frame.center))
        var fit = WindowFrameFit()
        for _ in 0..<3 { try lay(app, cell, destination, &fit); app.catchUp() }
        XCTAssertEqual(app.frame, cell, "A destination-side center does not prove the app stopped using the old screen")
        XCTAssertNil(fit.heldSize, "The old screen's 800x600 limit must not become an app constraint")
    }
}
