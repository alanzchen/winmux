import AppKit
import Common
import XCTest

/// Hidden (corner-parked) windows are re-asserted only when macOS could have moved windows
/// behind our back with no AX events delivered: wake, startup, and a settled display change.
/// Every other event must leave parked windows alone — re-asserting them costs one AX
/// round-trip per hidden window per event.
final class RefreshSessionEventReassertionTest: XCTestCase {
    func testOnlyWakeStartupAndSettledDisplaysRequireHiddenWindowsReassertion() {
        XCTAssertEqual(RefreshSessionEvent.startup.hiddenWindowsReassertion, .always)
        XCTAssertEqual(RefreshSessionEvent.globalObserver(NSWorkspace.didWakeNotification.rawValue).hiddenWindowsReassertion, .always)
        XCTAssertEqual(RefreshSessionEvent.globalObserver(NSWorkspace.screensDidWakeNotification.rawValue).hiddenWindowsReassertion, .always)
        XCTAssertEqual(RefreshSessionEvent.displayTopologySettled(generation: 7).hiddenWindowsReassertion, .displayTopology(generation: 7))

        let ordinary: [RefreshSessionEvent] = [
            .ax(kAXMovedNotification as String),
            .ax(kAXResizedNotification as String),
            .ax(kAXWindowCreatedNotification as String),
            .ax(kAXUIElementDestroyedNotification as String),
            .globalObserverLeftMouseUp,
            .resetManipulatedWithMouse,
            .hotkeyBinding,
            .configAutoReload,
            .globalObserver(NSWorkspace.didActivateApplicationNotification.rawValue),
            // The unsettled change re-parks only what moved to new geometry; the settled one reasserts.
            .globalObserver(NSApplication.didChangeScreenParametersNotification.rawValue),
            .onTabSwitched,
        ]
        for event in ordinary {
            XCTAssertNil(event.hiddenWindowsReassertion, "\(event)")
            XCTAssertNil(event.requirements.hiddenWindowsReassertion, "\(event)")
        }
    }

    func testASettledDisplayChangeIsAFullRefresh() {
        let requirements = RefreshSessionEvent.displayTopologySettled(generation: 1).requirements
        XCTAssertTrue(requirements.windowRefreshBarrier)
        XCTAssertTrue(requirements.layoutReasonNormalization)
        XCTAssertTrue(requirements.freshWindowFrames)
    }

    func testASettledReassertionAppliesOnlyAtItsOwnTopology() {
        XCTAssertTrue(HiddenWindowsReassertion.displayTopology(generation: 3).applies(atTopologyGeneration: 3))
        XCTAssertFalse(HiddenWindowsReassertion.displayTopology(generation: 3).applies(atTopologyGeneration: 4))
        XCTAssertTrue(HiddenWindowsReassertion.always.applies(atTopologyGeneration: 4))
    }

    func testRequirementsUnionKeepsEveryEventsNeeds() {
        let tabSwitch = RefreshSessionEvent.onTabSwitched.requirements
        let focus = RefreshSessionEvent.ax(kAXFocusedWindowChangedNotification as String).requirements
        let mouseUp = RefreshSessionEvent.globalObserverLeftMouseUp.requirements
        let wake = RefreshSessionEvent.globalObserver(NSWorkspace.didWakeNotification.rawValue).requirements
        let settled = RefreshSessionEvent.displayTopologySettled(generation: 2).requirements

        XCTAssertFalse(tabSwitch.windowRefreshBarrier)
        XCTAssertTrue(tabSwitch.union(mouseUp).windowRefreshBarrier)
        XCTAssertTrue(mouseUp.union(tabSwitch).layoutReasonNormalization)
        XCTAssertTrue(focus.canReuseLastAppliedWindowFrames)
        XCTAssertFalse(focus.union(mouseUp).canReuseLastAppliedWindowFrames)
        XCTAssertFalse(mouseUp.union(focus).canReuseLastAppliedWindowFrames)
        XCTAssertEqual(wake.union(mouseUp).hiddenWindowsReassertion, .always)
        XCTAssertEqual(mouseUp.union(wake).hiddenWindowsReassertion, .always)
        XCTAssertEqual(settled.union(wake).hiddenWindowsReassertion, .always)
        XCTAssertEqual(wake.union(settled).hiddenWindowsReassertion, .always)
        XCTAssertEqual(settled.union(mouseUp).hiddenWindowsReassertion, .displayTopology(generation: 2))
        XCTAssertEqual(
            RefreshSessionEvent.displayTopologySettled(generation: 5).requirements.union(settled).hiddenWindowsReassertion,
            .displayTopology(generation: 5),
            "The newest settled topology is the one that can still apply",
        )
        XCTAssertEqual(tabSwitch.union(tabSwitch), tabSwitch)
    }
}
