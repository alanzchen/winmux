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

    /// One rail per other display, side by side, each exactly the sidebar's visible height.
    func testRailsStandSideBySideTheSidebarsWholeHeight() {
        for count in 1 ... 3 {
            let layout = workspaceSidebarDropDestinationLayout(sourceSurface: sidebar, visibleFrame: visible, position: .left,
                hintCount: count, preferredColumnWidth: 280, opensColumn: true)
            XCTAssertEqual(layout.hints.count, count)
            XCTAssertEqual(layout.hints.first?.minX, sidebar.maxX + workspaceSidebarDropDestinationGap, "Beside the sidebar")
            for (index, rail) in layout.hints.enumerated() {
                XCTAssertEqual(rail.minY, sidebar.minY, "\(count) rails, rail \(index)")
                XCTAssertEqual(rail.height, sidebar.height, "The sidebar's height, not the display's")
                XCTAssertEqual(rail.width, workspaceSidebarDropDestinationRailWidth)
                if index > 0 {
                    XCTAssertEqual(rail.minX, layout.hints[index - 1].maxX + workspaceSidebarDropDestinationRailSpacing,
                        accuracy: 0.01, "Side by side, in order, never stacked")
                }
            }
            XCTAssertEqual(layout.hintArea, layout.hints.reduce(layout.hints[0]) { $0.union($1) })
            let column = try? XCTUnwrap(layout.column)
            XCTAssertEqual(column?.minX, layout.hintArea.maxX + workspaceSidebarDropDestinationGap, "The list after the rails")
            XCTAssertFalse(layout.isInward)
        }
    }

    func testARightSidebarMirrors() {
        let right = CGRect(x: visible.maxX - 280, y: 0, width: 280, height: 1027)
        let layout = workspaceSidebarDropDestinationLayout(sourceSurface: right, visibleFrame: visible, position: .right,
            hintCount: 2, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertEqual(layout.hintArea.maxX, right.minX - workspaceSidebarDropDestinationGap)
        XCTAssertLessThan(layout.hints[0].minX, layout.hints[1].minX, "Still in the arrangement's order, left to right")
        XCTAssertEqual(layout.hints.map(\.height), [right.height, right.height])
        XCTAssertEqual(layout.column?.maxX ?? 0, layout.hintArea.minX - workspaceSidebarDropDestinationGap)
    }

    /// A shorter sidebar, such as a Dock column, gets rails its own height.
    func testRailsFollowTheSidebarNotTheDisplay() {
        let dock = CGRect(x: 0, y: 262, width: 72, height: 420)
        let layout = workspaceSidebarDropDestinationLayout(sourceSurface: dock, visibleFrame: visible, position: .left,
            hintCount: 2, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertEqual(layout.hints.map(\.minY), [262, 262])
        XCTAssertEqual(layout.hints.map(\.height), [420, 420])
        XCTAssertEqual(layout.column?.height, 420)
    }

    /// A short sidebar keeps rails its own height, and its list still gets a usable height,
    /// centred on it.
    func testAShortSidebarGetsAUsableList() {
        let short = CGRect(x: 0, y: 400, width: 280, height: 160)
        let layout = workspaceSidebarDropDestinationLayout(sourceSurface: short, visibleFrame: visible, position: .left,
            hintCount: 2, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertEqual(layout.hints.map(\.height), [160, 160])
        let column = try? XCTUnwrap(layout.column)
        XCTAssertEqual(column?.height, workspaceSidebarDropDestinationMinColumnHeight)
        XCTAssertEqual(column?.midY ?? 0, short.midY, accuracy: 0.5)
        // Only a display itself too short for a list offers none.
        let tiny = workspaceSidebarDropDestinationLayout(sourceSurface: CGRect(x: 0, y: 0, width: 280, height: 200),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 200), position: .left, hintCount: 2,
            preferredColumnWidth: 280, opensColumn: true)
        XCTAssertNil(tiny.column)
        XCTAssertFalse(tiny.columnFits)
        XCTAssertEqual(tiny.hints.count, 2)
    }

    func testLimitedRoomNarrowsTheRailsThenPutsThemOverTheSidebar() {
        // Room for the rails beside the sidebar, not for the list too: the list goes against the far
        // edge, and the rails stand beside it, over the sidebar's inner edge.
        let narrow = CGRect(x: 0, y: 0, width: 700, height: 740)
        let wide = CGRect(x: 0, y: 0, width: 560, height: 740)
        let inward = workspaceSidebarDropDestinationLayout(sourceSurface: wide, visibleFrame: narrow, position: .left,
            hintCount: 3, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertTrue(inward.isInward)
        let column = try? XCTUnwrap(inward.column)
        XCTAssertEqual(column?.maxX ?? 0, narrow.maxX - workspaceSidebarDropDestinationMargin, accuracy: 0.5)
        XCTAssertEqual(inward.hintArea.maxX, (column?.minX ?? 0) - workspaceSidebarDropDestinationGap, accuracy: 0.5)
        XCTAssertFalse(inward.hintArea.intersects(column ?? .zero), "Neither covers the other")
        XCTAssertTrue(narrow.contains(inward.hintArea))

        // A sidebar filling the display: the list and the rails over it, still apart.
        let full = CGRect(x: 0, y: 0, width: 600, height: 740)
        let tight = workspaceSidebarDropDestinationLayout(sourceSurface: CGRect(x: 0, y: 0, width: 590, height: 740),
            visibleFrame: full, position: .left, hintCount: 3, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertTrue(full.contains(tight.hintArea))
        XCTAssertFalse(tight.hintArea.intersects(tight.column ?? .zero))
    }

    /// Astra R1.1: a 700 pt display with the sidebar's edge at 380. The list and the rails share
    /// the room beside it, so opening the list moves no rail from under a still pointer.
    func testRoomBesideForBothKeepsTheRailsWhereTheyAre() {
        let screen = CGRect(x: 0, y: 0, width: 700, height: 900)
        for position in [WorkspaceDockPosition.left, .right] {
            let source = position == .left ? CGRect(x: 0, y: 0, width: 380, height: 900)
                : CGRect(x: 320, y: 0, width: 380, height: 900)
            let closed = workspaceSidebarDropDestinationLayout(sourceSurface: source, visibleFrame: screen, position: position,
                hintCount: 3, preferredColumnWidth: 280, opensColumn: false)
            let open = workspaceSidebarDropDestinationLayout(sourceSurface: source, visibleFrame: screen, position: position,
                hintCount: 3, preferredColumnWidth: 280, opensColumn: true)
            XCTAssertEqual(closed.hints, open.hints, "\(position)")
            let column = try? XCTUnwrap(open.column)
            XCTAssertFalse(open.hintArea.intersects(column ?? .zero), "\(position)")
            XCTAssertGreaterThanOrEqual(column?.width ?? 0, workspaceSidebarDropDestinationMinColumnWidth)
            XCTAssertEqual(position == .left ? open.hintArea.minX : screen.maxX - open.hintArea.maxX, 386, accuracy: 0.5,
                "The bank's edge is beside the sidebar")
            // Beside the sidebar, the list's width comes out of its own share: whatever it prefers,
            // the rails are the same.
            for width in [220.0, 300, 360] {
                XCTAssertEqual(workspaceSidebarDropDestinationLayout(sourceSurface: source, visibleFrame: screen, position: position,
                    hintCount: 3, preferredColumnWidth: width, opensColumn: true).hints, open.hints, "\(position) \(width)")
            }
        }
    }

    /// Astra R1.2: a 500 pt display, the sidebar's edge at 300, five rails and a 360 pt list. They're
    /// fitted together, over the sidebar, never overlapping.
    func testTheRailsAndTheListAreFittedTogether() {
        let screen = CGRect(x: 0, y: 0, width: 500, height: 900)
        let layout = workspaceSidebarDropDestinationLayout(sourceSurface: CGRect(x: 0, y: 0, width: 300, height: 900),
            visibleFrame: screen, position: .left, hintCount: 5, preferredColumnWidth: 360, opensColumn: true)
        let column = try? XCTUnwrap(layout.column)
        XCTAssertTrue(layout.isInward)
        XCTAssertFalse(layout.hintArea.intersects(column ?? .zero))
        XCTAssertTrue(screen.contains(layout.hintArea))
        XCTAssertTrue(screen.contains(column ?? .zero))
        XCTAssertTrue(layout.hints.allSatisfy { $0.width >= workspaceSidebarDropDestinationMinRailWidth - 0.01 })
        for (index, rail) in layout.hints.enumerated() where index > 0 {
            XCTAssertFalse(rail.intersects(layout.hints[index - 1]), "Rails don't overlap each other either")
        }
    }

    /// Where not even the narrowest rails and list fit, no list is offered, and every rail still shows.
    func testNoRoomForAListStillShowsEveryRail() {
        let screen = CGRect(x: 0, y: 0, width: 300, height: 900)
        let layout = workspaceSidebarDropDestinationLayout(sourceSurface: CGRect(x: 0, y: 0, width: 200, height: 900),
            visibleFrame: screen, position: .left, hintCount: 6, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertNil(layout.column)
        XCTAssertFalse(layout.columnFits)
        XCTAssertEqual(layout.hints.count, 6)
        XCTAssertTrue(layout.hints.allSatisfy { screen.contains($0) && $0.width > 0 })
    }

    /// Opening the list never moves the rails, so the one under the pointer stays under it.
    func testTheRailsStayPutWhenTheListOpens() {
        let cases: [(CGRect, CGRect, WorkspaceDockPosition)] = [
            (sidebar, visible, .left),
            (CGRect(x: visible.maxX - 280, y: 0, width: 280, height: 1027), visible, .right),
            (CGRect(x: 0, y: 0, width: 560, height: 740), CGRect(x: 0, y: 0, width: 700, height: 740), .left),
            (CGRect(x: 140, y: 0, width: 560, height: 740), CGRect(x: 0, y: 0, width: 700, height: 740), .right),
            (CGRect(x: 600, y: 4, width: 700, height: 72), visible, .bottom),
        ]
        for (surface, screen, position) in cases {
            let closed = workspaceSidebarDropDestinationLayout(sourceSurface: surface, visibleFrame: screen, position: position,
                hintCount: 3, preferredColumnWidth: 280, opensColumn: false)
            let open = workspaceSidebarDropDestinationLayout(sourceSurface: surface, visibleFrame: screen, position: position,
                hintCount: 3, preferredColumnWidth: 280, opensColumn: true)
            XCTAssertEqual(closed.hints, open.hints, "\(position) \(surface)")
            XCTAssertNotNil(open.column)
        }
    }

    func testABottomDockGetsOneStripAlongIt() {
        let bottomDock = CGRect(x: 600, y: 4, width: 700, height: 72)
        let above = workspaceSidebarDropDestinationLayout(sourceSurface: bottomDock, visibleFrame: visible, position: .bottom,
            hintCount: 2, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertEqual(above.hintArea.minY, bottomDock.maxY + workspaceSidebarDropDestinationGap)
        XCTAssertEqual(above.hintArea.width, bottomDock.width, "As long as the Dock")
        XCTAssertEqual(above.hints.count, 2)
        XCTAssertEqual(above.hints[0].width, above.hints[1].width)
        XCTAssertLessThan(above.hints[0].maxX, above.hints[1].minX, "Side by side")
        XCTAssertEqual(above.column?.minY ?? 0, above.hintArea.maxY + workspaceSidebarDropDestinationGap)
        XCTAssertTrue(visible.contains(above.column ?? .zero))

        // A short Dock with many long-named displays: segments stay wide enough to read, the strip
        // running past the Dock's ends, but never off the display.
        let small = CGRect(x: 40, y: 4, width: 180, height: 72)
        let many = workspaceSidebarDropDestinationLayout(sourceSurface: small, visibleFrame: visible, position: .bottom,
            hintCount: 5, preferredColumnWidth: 280, opensColumn: true)
        XCTAssertTrue(many.hints.allSatisfy { $0.width >= workspaceSidebarDropDestinationMinSegmentWidth - 0.01 })
        XCTAssertTrue(visible.contains(many.hintArea))
        XCTAssertFalse(many.hintArea.intersects(many.column ?? .zero))
    }

    func testEveryLayoutStaysOnScreen() {
        let screens = [visible, CGRect(x: -1080, y: -400, width: 1080, height: 1920), CGRect(x: 0, y: 0, width: 1024, height: 740)]
        for screen in screens {
            for position in [WorkspaceDockPosition.left, .right, .bottom] {
                let surfaces: [CGRect] = switch position {
                    case .left: [CGRect(x: screen.minX, y: screen.minY, width: 300, height: screen.height - 28),
                                 CGRect(x: screen.minX, y: screen.minY, width: screen.width - 4, height: screen.height)]
                    case .right: [CGRect(x: screen.maxX - 72, y: screen.minY + 100, width: 72, height: 400),
                                  CGRect(x: screen.minX + 4, y: screen.minY, width: screen.width - 4, height: screen.height)]
                    case .bottom: [CGRect(x: screen.midX - 300, y: screen.minY + 4, width: 600, height: 72)]
                }
                for surface in surfaces {
                    for count in [1, 3, 8] {
                        let layout = workspaceSidebarDropDestinationLayout(sourceSurface: surface, visibleFrame: screen,
                            position: position, hintCount: count, preferredColumnWidth: 400, opensColumn: true)
                        let label = "\(screen) \(position) \(surface) \(count)"
                        XCTAssertTrue(screen.insetBy(dx: -0.5, dy: -0.5).contains(layout.hintArea), label)
                        XCTAssertTrue(layout.hints.allSatisfy { screen.insetBy(dx: -0.5, dy: -0.5).contains($0) }, label)
                        XCTAssertTrue(screen.contains(layout.column ?? .zero), label)
                        XCTAssertLessThanOrEqual(layout.column?.width ?? 0, workspaceSidebarDropDestinationMaxColumnWidth)
                        if let column = layout.column { XCTAssertFalse(column.intersects(layout.hintArea), label) }
                    }
                }
            }
        }
    }
}
