@testable import AppBundle
import AppKit
import XCTest

/// Pausing on another display's hint opens its list; moving on to the list keeps it open; leaving
/// both for a moment closes it. A steady pass over a hint opens nothing.
final class WorkspaceSidebarDropDestinationStateTest: XCTestCase {
    private let right = (id: "monitor:1920.0,0.0", frame: CGRect(x: 286, y: 480, width: 128, height: 60))
    private let above = (id: "monitor:0.0,-1080.0", frame: CGRect(x: 286, y: 440, width: 128, height: 36))
    private let column = CGRect(x: 420, y: 0, width: 280, height: 1027)
    private var keepOpen: CGRect { right.frame.union(above.frame).union(column) }

    private func step(_ state: WorkspaceSidebarDropDestinationState, _ point: CGPoint, at now: TimeInterval,
                      hints: [(id: String, frame: CGRect)]? = nil) -> WorkspaceSidebarDropDestinationState {
        workspaceSidebarDropDestinationStep(state, pointer: point, now: now, hints: hints ?? [right, above],
            keepOpen: state.openId == nil ? nil : keepOpen)
    }

    func testAPauseOnAHintOpensItsListAndAPassDoesNot() {
        var state = WorkspaceSidebarDropDestinationState()
        state = step(state, CGPoint(x: 300, y: 500), at: 10)
        XCTAssertEqual(state.arming, .init(id: right.id, since: 10, at: CGPoint(x: 300, y: 500)))
        XCTAssertNil(state.openId)
        XCTAssertEqual(state.nextWake ?? 0, 10 + workspaceSidebarDropDestinationDwell, accuracy: 0.0001)
        XCTAssertEqual(step(state, CGPoint(x: 300, y: 500), at: 10.1), state, "Still pausing: nothing changes")

        let passed = step(state, CGPoint(x: 200, y: 500), at: 10.1)
        XCTAssertNil(passed.arming, "Moving off before the pause ends opens nothing")
        XCTAssertNil(passed.openId)
        XCTAssertNil(passed.nextWake)

        let opened = step(state, CGPoint(x: 300, y: 500), at: 10 + workspaceSidebarDropDestinationDwell)
        XCTAssertEqual(opened.openId, right.id)
        XCTAssertNil(opened.arming)
        XCTAssertNil(opened.nextWake)
    }

    func testTheListStaysOpenFromTheHintIntoItAndClosesAfterTheDelayOutside() {
        var state = WorkspaceSidebarDropDestinationState(openId: right.id)
        for (x, t) in [(CGFloat(414), 20.0), (417, 20.01), (500, 20.02), (690, 20.05)] {
            state = step(state, CGPoint(x: x, y: 500), at: t)
            XCTAssertEqual(state.openId, right.id, "Across the gap and inside the list at x=\(x)")
            XCTAssertNil(state.outsideSince)
        }
        state = step(state, CGPoint(x: 710, y: 500), at: 20.1)
        XCTAssertEqual(state.openId, right.id, "Within the keep-open margin")
        state = step(state, CGPoint(x: 900, y: 500), at: 20.2)
        XCTAssertEqual(state.outsideSince, 20.2)
        XCTAssertEqual(state.nextWake ?? 0, 20.2 + workspaceSidebarDropDestinationCloseDelay, accuracy: 0.0001)
        let back = step(state, CGPoint(x: 600, y: 500), at: 20.3)
        XCTAssertNil(back.outsideSince, "Coming back in time keeps it open")
        XCTAssertEqual(back.openId, right.id)
        let closed = step(state, CGPoint(x: 900, y: 500), at: 20.2 + workspaceSidebarDropDestinationCloseDelay)
        XCTAssertNil(closed.openId)
        XCTAssertNil(closed.nextWake)
    }

    func testPausingOnAnotherHintSwitchesToItsList() {
        var state = WorkspaceSidebarDropDestinationState(openId: right.id)
        state = step(state, CGPoint(x: 300, y: 450), at: 30)
        XCTAssertEqual(state.openId, right.id, "The open list stays while the other hint arms")
        XCTAssertEqual(state.arming?.id, above.id)
        state = step(state, CGPoint(x: 300, y: 450), at: 30 + workspaceSidebarDropDestinationDwell)
        XCTAssertEqual(state.openId, above.id, "Only one list at a time")
        XCTAssertNil(state.arming)
        XCTAssertNil(step(state, CGPoint(x: 300, y: 450), at: 31).arming, "Its own hint doesn't arm again")
    }

    /// A steady pass over a hint never rests, however long it takes to cross.
    func testASlowPassWithoutRestingOpensNothing() {
        var state = WorkspaceSidebarDropDestinationState()
        var x: CGFloat = 290
        var t: TimeInterval = 50
        while x < 410 {
            state = step(state, CGPoint(x: x, y: 500), at: t)
            XCTAssertNil(state.openId, "Moving 5 pt every 50 ms at x=\(x)")
            x += 5
            t += 0.05
        }
        // Stopping: the pause completes once the pointer has rested.
        let rest = state.nextWake ?? 0
        XCTAssertGreaterThan(rest, t - 0.05)
        XCTAssertEqual(step(state, CGPoint(x: x - 5, y: 500), at: rest).openId, right.id)
    }

    func testAHintVanishingEndsItsPause() {
        let state = step(.init(), CGPoint(x: 300, y: 500), at: 40)
        XCTAssertNotNil(state.arming)
        XCTAssertNil(step(state, CGPoint(x: 300, y: 500), at: 40.3, hints: []).openId)
    }
}

/// Rails side by side, a list open to their side: the rails crossed on the way into it are
/// passed, however slowly, while a real stop on any rail still switches to its display.
final class WorkspaceSidebarDropDestinationTransitTest: XCTestCase {
    private let rails: [(id: String, frame: CGRect)] = [
        ("a", CGRect(x: 300, y: 0, width: 30, height: 900)),
        ("b", CGRect(x: 332, y: 0, width: 30, height: 900)),
        ("c", CGRect(x: 364, y: 0, width: 30, height: 900)),
    ]
    private let list = CGRect(x: 400, y: 0, width: 280, height: 900)
    private let frame: TimeInterval = 1.0 / 60

    private func step(_ state: WorkspaceSidebarDropDestinationState, x: CGFloat, y: CGFloat = 450, at now: TimeInterval,
                      rails: [(id: String, frame: CGRect)]? = nil, list: CGRect? = nil, side: CGFloat = 1)
        -> WorkspaceSidebarDropDestinationState {
        let rails = rails ?? self.rails
        let area = rails.map(\.frame).reduce(rails[0].frame) { $0.union($1) }
        return workspaceSidebarDropDestinationStep(state, pointer: CGPoint(x: x, y: y), now: now, hints: rails,
            keepOpen: area.union(list ?? self.list), listSide: side)
    }

    /// From the open rail into its list at `speed` pt/s, a sample a frame.
    private func cross(from open: String, fromX: CGFloat, toX: CGFloat, speed: CGFloat,
                       rails: [(id: String, frame: CGRect)]? = nil, list: CGRect? = nil, side: CGFloat = 1) {
        var state = WorkspaceSidebarDropDestinationState(openId: open)
        var x = fromX
        var now: TimeInterval = 100
        while (toX - x) * side > 0 {
            state = step(state, x: x, at: now, rails: rails, list: list, side: side)
            XCTAssertEqual(state.openId, open, "At \(speed) pt/s, x=\(x)")
            x += side * speed * CGFloat(frame)
            now += frame
        }
    }

    func testCrossingRailsIntoTheListNeverSwitchesAtAnySpeed() {
        for speed: CGFloat in [4, 5, 20, 100, 400] {
            cross(from: "a", fromX: 315, toX: 420, speed: speed)
        }
        // From the middle rail, and from the last, which has none to cross.
        cross(from: "b", fromX: 347, toX: 420, speed: 4)
        cross(from: "c", fromX: 379, toX: 420, speed: 4)
    }

    /// A right sidebar mirrors it: the list is to the left, and the rails crossed have lower indices.
    func testCrossingIsMirroredForARightSidebar() {
        let mirroredList = CGRect(x: 10, y: 0, width: 280, height: 900)
        for speed: CGFloat in [4, 100] {
            cross(from: "c", fromX: 379, toX: 280, speed: speed, list: mirroredList, side: -1)
        }
    }

    /// A hesitation with the smallest nudge on towards the list starts its pause over.
    func testANudgeOnDuringAHesitationRestartsThePause() {
        var state = WorkspaceSidebarDropDestinationState(openId: "a")
        var now: TimeInterval = 200
        // Stopped on b for most of a pause, then 0.4 pt on.
        for _ in 0 ..< 12 { state = step(state, x: 345, at: now); now += frame }
        state = step(state, x: 345.4, at: now)
        let nudged = now
        now += frame
        while now < nudged + workspaceSidebarDropDestinationDwell - 0.01 {
            state = step(state, x: 345.4, at: now)
            XCTAssertEqual(state.openId, "a", "The pause starts again at the nudge")
            now += frame
        }
        state = step(state, x: 345.4, at: nudged + workspaceSidebarDropDestinationDwell)
        XCTAssertEqual(state.openId, "b", "Then held still for a whole pause: a deliberate switch")
    }

    /// On the way in: a step back, then on again. Moving back pauses as anywhere; moving on again
    /// passes. Only stopping for a whole pause switches.
    func testAReversalThenResumingOnStillPasses() {
        var state = WorkspaceSidebarDropDestinationState(openId: "a")
        var now: TimeInterval = 250
        var x: CGFloat = 334
        for _ in 0 ..< 6 { state = step(state, x: x, at: now); x += 1; now += frame }
        for _ in 0 ..< 3 { state = step(state, x: x, at: now); x -= 0.5; now += frame }
        while x < 420 {
            state = step(state, x: x, at: now)
            XCTAssertEqual(state.openId, "a", "x=\(x)")
            x += 0.07 // 4 pt/s
            now += frame
        }
        // Back onto b, and staying there: a deliberate switch.
        state = step(state, x: 350, at: now)
        state = step(state, x: 350, at: now + workspaceSidebarDropDestinationDwell)
        XCTAssertEqual(state.openId, "b")
    }

    func testHoldingStillOnACrossedRailSwitchesToIt() {
        var state = WorkspaceSidebarDropDestinationState(openId: "a")
        state = step(state, x: 350, at: 300)
        XCTAssertEqual(state.arming?.id, "b")
        state = step(state, x: 350, at: 300 + workspaceSidebarDropDestinationDwell)
        XCTAssertEqual(state.openId, "b")
    }

    /// Coming back from the list onto a rail, and stopping there, chooses it.
    func testReturningFromTheListAndStoppingSwitches() {
        var state = WorkspaceSidebarDropDestinationState(openId: "a")
        var now: TimeInterval = 400
        var x: CGFloat = 450
        while x > 380 {
            state = step(state, x: x, at: now)
            XCTAssertEqual(state.openId, "a")
            x -= 2
            now += frame
        }
        state = step(state, x: 380, at: now)
        state = step(state, x: 380, at: now + workspaceSidebarDropDestinationDwell)
        XCTAssertEqual(state.openId, "c")
    }

    func testEveryRailCanBeChosenDeliberately() {
        var state = WorkspaceSidebarDropDestinationState(openId: "a")
        var now: TimeInterval = 500
        for (id, x) in [("c", 379.0), ("a", 315), ("b", 347), ("a", 305), ("c", 390)] as [(String, CGFloat)] {
            state = step(state, x: x, at: now)
            state = step(state, x: x, at: now + workspaceSidebarDropDestinationDwell)
            XCTAssertEqual(state.openId, id)
            now += 1
        }
    }

    /// A bottom Dock's strip: from a segment at either end into the list above it, the path leaves
    /// the strip at once, crosses no other segment, and the list stays open.
    func testFromABottomStripsEndIntoItsListStaysOpen() {
        let layout = workspaceSidebarDropDestinationLayout(sourceSurface: CGRect(x: 600, y: 4, width: 700, height: 72),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), position: .bottom, hintCount: 5,
            preferredColumnWidth: 280, opensColumn: true)
        let column = try? XCTUnwrap(layout.column)
        let ids = ["a", "b", "c", "d", "e"]
        let segments = Array(zip(ids, layout.hints)).map { (id: $0.0, frame: $0.1) }
        for end in [0, ids.count - 1] {
            var state = WorkspaceSidebarDropDestinationState(openId: ids[end])
            let from = CGPoint(x: layout.hints[end].midX, y: layout.hints[end].midY)
            let to = CGPoint(x: column?.midX ?? 0, y: column?.midY ?? 0)
            for step in 0 ... 120 {
                let t = CGFloat(step) / 120
                let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                state = workspaceSidebarDropDestinationStep(state, pointer: point, now: 800 + Double(step) * frame,
                    hints: segments, keepOpen: layout.hintArea.union(column ?? .zero), listSide: nil)
                XCTAssertEqual(state.openId, ids[end], "From segment \(end), step \(step)")
                XCTAssertFalse(segments.enumerated().contains { $0.offset != end && $0.element.frame.contains(point) },
                    "No other segment is crossed")
            }
        }
    }

    /// The rails have no tolerance: each is exactly its frame. The gap between two is neither's,
    /// so crossing it starts any pause over.
    func testRailSeamsAndGaps() {
        let hovered: (CGFloat) -> String? = { x in
            self.step(.init(), x: x, at: 600).arming?.id
        }
        XCTAssertEqual(hovered(329.9), "a")
        XCTAssertNil(hovered(331), "The 2 pt gap is no rail's")
        XCTAssertEqual(hovered(332), "b")
        XCTAssertEqual(hovered(361.9), "b")
        XCTAssertNil(hovered(299), "Outside the first")
        var state = step(.init(), x: 320, at: 700)
        state = step(state, x: 331, at: 700.1)
        XCTAssertNil(state.arming)
        state = step(state, x: 320, at: 700.2)
        XCTAssertEqual(state.arming?.since, 700.2, "Back on it, a fresh pause")
    }
}
