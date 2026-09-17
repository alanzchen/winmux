import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceSidebarDockMotionTest: XCTestCase {
    func testEntryBeginsGentlyAndMovesIconSizesAndPositionsTogether() {
        for rate in [60.0, 120.0, 144.0] {
            var motion = WorkspaceSidebarDockMotion()
            motion.receive(CGPoint(x: 32, y: 80))
            XCTAssertEqual(motion.frame.strength, 0, "A mouse event must not jump to an enlarged pose")
            let first = motion.advance(to: 1 / rate, initialInterval: 1 / rate)
            XCTAssertGreaterThan(first.strength, 0)
            XCTAssertLessThan(first.strength, 0.15, "Entry must start gently, even at 60 Hz")
            let resting = WorkspaceSidebarDockMagnification(itemSize: 40, count: 4, enabled: true, amount: 0)
                .frames(width: 50, pointerY: 80)
            let full = WorkspaceSidebarDockMagnification(itemSize: 40, count: 4, enabled: true, amount: 1)
                .frames(width: 50, pointerY: 80)
            let entering = WorkspaceSidebarDockMagnification(itemSize: 40, count: 4, enabled: true, amount: first.strength)
                .frames(width: 50, pointerY: 80)
            for index in entering.indices {
                XCTAssertEqual(entering[index].width, resting[index].width + (full[index].width - resting[index].width) * first.strength, accuracy: 0.001)
                XCTAssertEqual(entering[index].minY, resting[index].minY + (full[index].minY - resting[index].minY) * first.strength, accuracy: 0.001)
                XCTAssertEqual(entering[index].minX, resting[index].minX)
            }
        }
    }

    func testRapidEntryExitAndReentryRemainContinuousAndBounded() {
        var motion = WorkspaceSidebarDockMotion()
        var previous = motion.frame.strength
        for step in 1...120 {
            motion.receive(step < 5 || step >= 9 ? CGPoint(x: 75, y: 160) : nil)
            let frame = motion.advance(to: Double(step) / 120, initialInterval: 1 / 120)
            XCTAssertTrue((0...1).contains(frame.strength))
            XCTAssertLessThan(abs(frame.strength - previous), 0.13)
            previous = frame.strength
        }
        XCTAssertTrue(motion.isSettled)
    }

    func testPointerBurstsProduceOnlyOneFrameWithTheLatestTarget() throws {
        let view = WorkspaceSidebarDockDisplayLinkView()
        var delivered: [WorkspaceSidebarDockMotionFrame] = []
        view.onFrame = { delivered.append($0) }
        for y in 0..<1_000 { view.receive(CGPoint(x: 32, y: y)) }
        XCTAssertTrue(delivered.isEmpty, "Mouse events must not trigger SwiftUI layout")
        view.advance(to: 1)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(view.motion.target, CGPoint(x: 32, y: 999))
        XCTAssertGreaterThan(try XCTUnwrap(delivered.last?.pointer).y, 500)
    }

    func testResponseHasTheSameDurationAt60And120Hz() {
        func run(rate: Double) -> WorkspaceSidebarDockMotionFrame {
            var motion = WorkspaceSidebarDockMotion()
            motion.receive(CGPoint(x: 32, y: 100))
            for step in 1...Int(rate / 10) {
                _ = motion.advance(to: Double(step) / rate, initialInterval: 1 / rate)
            }
            return motion.frame
        }
        XCTAssertEqual(run(rate: 60).strength, run(rate: 120).strength, accuracy: 0.000_001)
        XCTAssertGreaterThan(run(rate: 120).strength, 0.9)
    }

    func testLeavingTheDockShrinksAtTheLastValidPointThenStops() {
        var motion = WorkspaceSidebarDockMotion()
        let point = CGPoint(x: 32, y: 160)
        motion.receive(point)
        for step in 0..<60 { _ = motion.advance(to: Double(step) / 120, initialInterval: 1 / 120) }
        XCTAssertTrue(motion.isSettled)
        motion.receive(nil)
        let firstExit = motion.advance(to: 0.5, initialInterval: 1 / 120)
        XCTAssertEqual(firstExit.pointer, point)
        XCTAssertGreaterThan(firstExit.strength, 0)
        XCTAssertLessThan(firstExit.strength, 1)
        for step in 61..<120 { _ = motion.advance(to: Double(step) / 120, initialInterval: 1 / 120) }
        XCTAssertEqual(motion.frame, .init())
        XCTAssertTrue(motion.isSettled)
    }

    func testSettledPointerDoesNotPublishIdenticalFrames() {
        let view = WorkspaceSidebarDockDisplayLinkView()
        var updates = 0
        view.onFrame = { _ in updates += 1 }
        view.receive(CGPoint(x: 32, y: 100))
        for step in 0..<120 { view.advance(to: Double(step) / 120) }
        let settledUpdates = updates
        for step in 120..<240 { view.advance(to: Double(step) / 120) }
        XCTAssertEqual(updates, settledUpdates)
        XCTAssertFalse(view.isRunning)
    }

    func testResetForMenusDraggingAndExpansionImmediatelyReleasesMagnification() {
        let view = WorkspaceSidebarDockDisplayLinkView()
        var last = WorkspaceSidebarDockMotionFrame()
        view.onFrame = { last = $0 }
        view.receive(CGPoint(x: 32, y: 100))
        view.advance(to: 1)
        XCTAssertNotNil(last.pointer)
        view.reset()
        XCTAssertEqual(last, .init())
        XCTAssertNil(view.motion.target)
        XCTAssertFalse(view.isRunning)
    }

    func testHighRefreshDisplaysAreNotCappedAt60Hz() {
        for rate in [30, 60, 120, 144, 240] {
            XCTAssertEqual(WorkspaceSidebarDockDisplayLinkView.preferredRate(maximumFramesPerSecond: rate), Float(rate))
        }
        XCTAssertEqual(WorkspaceSidebarDockDisplayLinkView.preferredRate(maximumFramesPerSecond: 0), 60)
    }

    func testDelayedEntryFrameCannotSkipMostOfTheMagnificationRamp() {
        var motion = WorkspaceSidebarDockMotion()
        motion.receive(CGPoint(x: 32, y: 100))
        let first = motion.advance(to: 1, initialInterval: 1 / 120)
        let afterHitch = motion.advance(to: 1.050, initialInterval: 1 / 120)
        XCTAssertGreaterThan(afterHitch.strength, first.strength)
        XCTAssertLessThan(afterHitch.strength, 0.3, "A 50 ms stall must not teleport the icon to its enlarged pose")
    }

    func testHorizontalPointerMotionDoesNotRestartOrPublishTheVerticalLens() {
        let view = WorkspaceSidebarDockDisplayLinkView()
        var updates = 0
        view.onFrame = { _ in updates += 1 }
        view.receive(CGPoint(x: 32, y: 100))
        for step in 0..<120 { view.advance(to: Double(step) / 120) }
        let settledUpdates = updates
        for step in 120..<240 {
            view.receive(CGPoint(x: Double(step % 50), y: 100))
            view.advance(to: Double(step) / 120)
        }
        XCTAssertEqual(updates, settledUpdates)
        XCTAssertTrue(view.motion.isSettled)
        view.receive(nil) // X-based native exit must still shrink the icons.
        view.advance(to: 2)
        XCTAssertGreaterThan(updates, settledUpdates)
    }

    func testLegacyDisplayDeliveryCoalescesStalledMainThreadFrames() {
        let delivery = DisplayRefreshDelivery()
        var scheduled = 0
        for frame in 0..<1_000 {
            if delivery.offer(Double(frame) / 120) { scheduled += 1 }
        }
        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(delivery.takeLatest(), 999.0 / 120)
        XCTAssertNil(delivery.takeLatest())
        XCTAssertTrue(delivery.offer(10), "Delivery must re-arm after draining")
        XCTAssertEqual(delivery.takeLatest(), 10)
    }
}
