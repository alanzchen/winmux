@testable import AppBundle
import AppKit
import XCTest

/// Where the other displays' hints and the list they open go, beside the sidebar a drag started in.
final class WorkspaceSidebarDropDestinationLayoutTest: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
    private let sidebar = CGRect(x: 0, y: 0, width: 280, height: 1027)

    func testDirectionsFollowTheArrangement() {
        let main = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        XCTAssertEqual(workspaceSidebarDisplayDirection(from: main, to: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080)), .right)
        XCTAssertEqual(workspaceSidebarDisplayDirection(from: main, to: Rect(topLeftX: -2560, topLeftY: -200, width: 2560, height: 1440)), .left,
            "A taller display to the left, offset upward, is still to the left")
        XCTAssertEqual(workspaceSidebarDisplayDirection(from: main, to: Rect(topLeftX: 0, topLeftY: -1080, width: 1920, height: 1080)), .up)
        XCTAssertEqual(workspaceSidebarDisplayDirection(from: main, to: Rect(topLeftX: 200, topLeftY: 1080, width: 1080, height: 1920)), .down,
            "A portrait display below")
        XCTAssertEqual(workspaceSidebarDisplayDirection(from: main, to: Rect(topLeftX: 1920, topLeftY: -1080, width: 1920, height: 1080)), .upRight)
    }

    func testHintsSkipTheSourceAndKeepTheArrangementOrderWithNumberedTwins() {
        let left = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 2, name: "DELL U3224KB",
            rect: Rect(topLeftX: -1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: -1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        let main = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Built-in Retina Display",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1512, height: 982),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1512, height: 982), isMain: true)
        let right = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 3, name: "DELL U3224KB",
            rect: Rect(topLeftX: 1512, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1512, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        let hints = workspaceSidebarDropDestinationHints(source: main, monitors: [left, main, right])
        XCTAssertEqual(hints.map(\.name), ["DELL U3224KB 1", "DELL U3224KB 2"])
        XCTAssertEqual(hints.map(\.direction), [.left, .right])
        XCTAssertEqual(hints.map(\.id), [workspaceSidebarMonitorScopeId(for: left), workspaceSidebarMonitorScopeId(for: right)])
        XCTAssertTrue(workspaceSidebarDropDestinationHints(source: main, monitors: [main]).isEmpty)
    }

    func testOneDisplayGetsOneHintBesideTheSidebarAndItsListNextToIt() {
        let layout = workspaceSidebarDropDestinationLayout(sourceSurface: sidebar, visibleFrame: visible, position: .left,
            hintCount: 1, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertEqual(layout.hints.count, 1)
        XCTAssertEqual(layout.hintArea.minX, sidebar.maxX + workspaceSidebarDropDestinationGap)
        XCTAssertEqual(layout.hintArea.height, workspaceSidebarDropDestinationSingleHintHeight)
        XCTAssertEqual(layout.hintArea.midY, sidebar.midY, accuracy: 0.5)
        let column = try? XCTUnwrap(layout.column)
        XCTAssertEqual(column?.minX, layout.hintArea.maxX + workspaceSidebarDropDestinationGap)
        XCTAssertEqual(column?.width, 280)
        XCTAssertFalse(layout.isInward)
        XCTAssertTrue(visible.contains(column ?? .zero))
    }

    func testSeveralDisplaysStackTheirHintsInOrderAndScrollPastSix() {
        let layout = workspaceSidebarDropDestinationLayout(sourceSurface: sidebar, visibleFrame: visible, position: .left,
            hintCount: 3, preferredColumnWidth: 280, opensColumn: false)
        XCTAssertNil(layout.column)
        XCTAssertEqual(layout.hints.count, 3)
        XCTAssertTrue(layout.hints[0].minY > layout.hints[1].minY, "The first hint is on top")
        XCTAssertEqual(layout.hints[0].height, workspaceSidebarDropDestinationHintHeight)
        let many = workspaceSidebarDropDestinationLayout(sourceSurface: sidebar, visibleFrame: visible, position: .left,
            hintCount: 9, preferredColumnWidth: 280, opensColumn: false)
        XCTAssertEqual(many.hints.count, 9)
        XCTAssertEqual(many.hintArea.height, 6 * workspaceSidebarDropDestinationHintHeight + 5 * workspaceSidebarDropDestinationHintSpacing,
            accuracy: 0.5, "Six show; the rest scroll")
        XCTAssertTrue(many.hintsOverflow)
        XCTAssertEqual(Set(many.hints.map(\.minY)).count, 9, "Each hint has its own place")
        let ids = (0 ..< 9).map { "d\($0)" }
        XCTAssertEqual(workspaceSidebarDropDestinationVisibleHints(many, ids: ids, offset: 0, isRow: false).map(\.id),
            Array(ids.prefix(6)), "Hints scrolled out of view take no pointer")
        let range = workspaceSidebarDropDestinationHintScrollRange(many, isRow: false)
        XCTAssertEqual(workspaceSidebarDropDestinationVisibleHints(many, ids: ids, offset: range, isRow: false).map(\.id),
            Array(ids.suffix(6)), "Scrolled to the end, the last ones")
    }

    func testAShortSidebarShrinksItsHintsBeforeTheyScroll() {
        let short = CGRect(x: 0, y: 400, width: 280, height: 160)
        let layout = workspaceSidebarDropDestinationLayout(sourceSurface: short, visibleFrame: visible, position: .left,
            hintCount: 5, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertLessThan(layout.hints[0].height, workspaceSidebarDropDestinationHintHeight)
        XCTAssertGreaterThanOrEqual(layout.hints[0].height, workspaceSidebarDropDestinationMinHintHeight)
        XCTAssertFalse(layout.hintsOverflow, "Five fit once shrunk")
        XCTAssertNil(layout.column, "Too short for a list")
        XCTAssertFalse(layout.columnFits)

        let tiny = CGRect(x: 0, y: 400, width: 280, height: 100)
        let scrolling = workspaceSidebarDropDestinationLayout(sourceSurface: tiny, visibleFrame: visible, position: .left,
            hintCount: 5, preferredColumnWidth: 280, opensColumn: false)
        XCTAssertEqual(scrolling.hints[0].height, workspaceSidebarDropDestinationMinHintHeight)
        XCTAssertTrue(scrolling.hintsOverflow)
        XCTAssertLessThanOrEqual(scrolling.hintArea.height, tiny.height)
    }

    func testANarrowDisplayShrinksTheListThenPutsItOverTheSidebar() {
        let narrow = CGRect(x: 0, y: 0, width: 700, height: 740)
        let wide = CGRect(x: 0, y: 0, width: 280, height: 740)
        let shrunk = workspaceSidebarDropDestinationLayout(sourceSurface: wide, visibleFrame: narrow, position: .left,
            hintCount: 1, preferredColumnWidth: 360, opensColumn: true)
        XCTAssertFalse(shrunk.isInward)
        XCTAssertEqual(shrunk.column?.maxX ?? 0, narrow.maxX - workspaceSidebarDropDestinationMargin, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(shrunk.column?.width ?? 0, workspaceSidebarDropDestinationMinColumnWidth)

        let browsing = CGRect(x: 0, y: 0, width: 560, height: 740)
        let inward = workspaceSidebarDropDestinationLayout(sourceSurface: browsing, visibleFrame: narrow, position: .left,
            hintCount: 1, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertTrue(inward.isInward, "Two projects side by side leave no room beside them")
        let column = try? XCTUnwrap(inward.column)
        XCTAssertEqual(column?.maxX ?? 0, narrow.maxX - workspaceSidebarDropDestinationMargin, accuracy: 0.5)
        XCTAssertFalse(inward.hintArea.intersects(column ?? .zero), "The hints move clear of the list")
        XCTAssertTrue(narrow.contains(inward.hintArea))
    }

    func testARightDockMirrorsAndABottomDockGoesAbove() {
        let rightDock = CGRect(x: 1840, y: 300, width: 72, height: 400)
        let mirrored = workspaceSidebarDropDestinationLayout(sourceSurface: rightDock, visibleFrame: visible, position: .right,
            hintCount: 1, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertEqual(mirrored.hintArea.maxX, rightDock.minX - workspaceSidebarDropDestinationGap)
        XCTAssertEqual(mirrored.column?.maxX ?? 0, mirrored.hintArea.minX - workspaceSidebarDropDestinationGap)

        let bottomDock = CGRect(x: 600, y: 4, width: 700, height: 72)
        let above = workspaceSidebarDropDestinationLayout(sourceSurface: bottomDock, visibleFrame: visible, position: .bottom,
            hintCount: 2, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertEqual(above.hintArea.minY, bottomDock.maxY + workspaceSidebarDropDestinationGap)
        XCTAssertEqual(above.hints.count, 2)
        XCTAssertLessThan(above.hints[0].minX, above.hints[1].minX)
        XCTAssertEqual(above.column?.minY ?? 0, above.hintArea.maxY + workspaceSidebarDropDestinationGap)
        XCTAssertTrue(visible.contains(above.column ?? .zero))
    }

    func testEveryLayoutStaysOnScreen() {
        let screens = [visible, CGRect(x: -1080, y: -400, width: 1080, height: 1920), CGRect(x: 0, y: 0, width: 1024, height: 740)]
        for screen in screens {
            for position in [WorkspaceDockPosition.left, .right, .bottom] {
                let surface = switch position {
                    case .left: CGRect(x: screen.minX, y: screen.minY, width: 300, height: screen.height - 28)
                    case .right: CGRect(x: screen.maxX - 72, y: screen.minY + 100, width: 72, height: 400)
                    case .bottom: CGRect(x: screen.midX - 300, y: screen.minY + 4, width: 600, height: 72)
                }
                for count in [1, 3] {
                    let layout = workspaceSidebarDropDestinationLayout(sourceSurface: surface, visibleFrame: screen,
                        position: position, hintCount: count, preferredColumnWidth: 400, opensColumn: true)
                    XCTAssertTrue(screen.contains(layout.hintArea), "\(screen) \(position) \(count)")
                    XCTAssertTrue(screen.contains(layout.column ?? .zero), "\(screen) \(position) \(count)")
                    XCTAssertLessThanOrEqual(layout.column?.width ?? 0, workspaceSidebarDropDestinationMaxColumnWidth)
                }
            }
        }
    }
}
