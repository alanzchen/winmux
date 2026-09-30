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
