@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class SystemDockTest: XCTestCase {
    func testHoveringWinMuxDoesNotPollTheInvisibleNativeShelfAtPointerRate() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let target = CGRect(x: 500, y: 990, width: 900, height: 90)
        let iconCenter = CGPoint(x: 800, y: 34)
        XCTAssertFalse(systemDockPointerNearActivation(iconCenter, target: target,
            primaryHeight: 1080, screens: [screen], nativePosition: .bottom))
        XCTAssertTrue(systemDockPointerNearActivation(CGPoint(x: 800, y: 1), target: target,
            primaryHeight: 1080, screens: [screen], nativePosition: .bottom))
        XCTAssertTrue(systemDockPointerNearActivation(iconCenter, target: target,
            primaryHeight: 1080, screens: [screen], nativePosition: .bottom, visibleRect: target))
    }

    func testCapturedAutoHiddenDockRevealDoesNotRequireReservedThickness() throws {
        let url = projectRoot.appending(path: "test-fixtures/accessibility/native-dock-autohide.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func rect(_ key: String) throws -> CGRect {
            let value = try XCTUnwrap(fixture[key] as? [String: Double])
            return try CGRect(x: XCTUnwrap(value["x"]), y: XCTUnwrap(value["y"]),
                width: XCTUnwrap(value["width"]), height: XCTUnwrap(value["height"]))
        }
        let reserved = try rect("reservedRect")
        let list = try rect("listFrame")
        let screen = try rect("screen")
        let position = try XCTUnwrap(WorkspaceDockPosition(rawValue: XCTUnwrap(fixture["nativePosition"] as? String)))
        XCTAssertTrue(reserved.isEmpty, "The old reader aborted here before reading the visible AX list")
        let target = try XCTUnwrap(systemDockVisibilityTarget(reservedRect: reserved, listSize: list.size, position: position))
        let snapshot = SystemDockSnapshot(targetRect: target,
            visibleRect: systemDockVisibleRect(listFrame: list, targetFrame: target), nativePosition: position)
        let display = Rect(topLeftX: screen.minX, topLeftY: screen.minY, width: screen.width, height: screen.height)
        for winmuxPosition in WorkspaceDockPosition.allCases {
            XCTAssertEqual(systemDockHidesDock(snapshot, position: winmuxPosition, display: display), winmuxPosition == position)
        }
        XCTAssertTrue(systemDockPointerNearActivation(CGPoint(x: screen.midX, y: 1), target: target,
            primaryHeight: screen.height, screens: [screen], nativePosition: position))
    }

    func testAutoHiddenDockUsesItsEdgeAnchorThroughRevealOnAdjacentDisplays() throws {
        let owner = Rect(topLeftX: -1920, topLeftY: -1080, width: 1920, height: 1080)
        let displays = [owner,
            Rect(topLeftX: -3840, topLeftY: -1080, width: 1920, height: 1080),
            Rect(topLeftX: 0, topLeftY: -1080, width: 1920, height: 1080),
            Rect(topLeftX: -1920, topLeftY: 0, width: 1920, height: 1080)]
        let docks: [(WorkspaceDockPosition, CGRect, CGRect, CGFloat, CGFloat)] = [
            (.left, CGRect(x: -1920, y: -800, width: 0, height: 600),
                CGRect(x: -1910, y: -800, width: 80, height: 600), -1, 0),
            (.bottom, CGRect(x: -1500, y: 0, width: 800, height: 0),
                CGRect(x: -1500, y: -90, width: 800, height: 80), 0, 1),
            (.right, CGRect(x: 0, y: -800, width: 0, height: 600),
                CGRect(x: -90, y: -800, width: 80, height: 600), 1, 0),
        ]
        for (nativePosition, reserved, restingList, dx, dy) in docks {
            let target = try XCTUnwrap(systemDockVisibilityTarget(reservedRect: reserved,
                listSize: restingList.size, position: nativePosition))
            for offset: CGFloat in [0, 40, 88, 89, 90, 170] {
                let list = restingList.offsetBy(dx: dx * offset, dy: dy * offset)
                let snapshot = SystemDockSnapshot(targetRect: target,
                    visibleRect: systemDockVisibleRect(listFrame: list, targetFrame: target), nativePosition: nativePosition)
                for position in WorkspaceDockPosition.allCases {
                    XCTAssertEqual(displays.map { systemDockHidesDock(snapshot, position: position, display: $0) },
                        displays.indices.map { $0 == 0 && position == nativePosition && offset < 89 })
                }
            }
        }
    }

    func testVisibilityTargetPreservesReservedBoundsAndRejectsUnavailableGeometry() {
        let target = CGRect(x: 300, y: 900, width: 800, height: 100)
        XCTAssertEqual(systemDockVisibilityTarget(reservedRect: target, listSize: CGSize(width: 850, height: 120), position: nil), target)
        for reserved in [CGRect.zero, .null, .infinite, CGRect(x: 0, y: 0, width: -80, height: 600)] {
            XCTAssertNil(systemDockVisibilityTarget(reservedRect: reserved, listSize: CGSize(width: 80, height: 600), position: .left))
        }
        for size in [CGSize.zero, CGSize(width: 80, height: CGFloat.nan), CGSize(width: -80, height: 600)] {
            XCTAssertNil(systemDockVisibilityTarget(reservedRect: target, listSize: size, position: .bottom))
        }
        let edge = CGRect(x: 0, y: 200, width: 0, height: 600)
        XCTAssertNil(systemDockVisibilityTarget(reservedRect: edge, listSize: CGSize(width: 80, height: 600), position: nil),
            "Do not guess whether a zero-width edge belongs to the display on its left or right")
        XCTAssertNil(systemDockVisibilityTarget(reservedRect: edge, listSize: CGSize(width: 80, height: 600), position: .bottom))
        let thinBottom = CGRect(x: 300, y: 999, width: 800, height: 1)
        XCTAssertEqual(systemDockVisibilityTarget(reservedRect: thinBottom, listSize: CGSize(width: 800, height: 100), position: .bottom), target)
    }

    func testNativePositionKeepsShortDocksPollingTheirPhysicalEdge() {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let shortLeft = CGRect(x: 0, y: 500, width: 80, height: 40)
        XCTAssertTrue(systemDockPointerNearActivation(CGPoint(x: 1, y: 100), target: shortLeft,
            primaryHeight: 1080, screens: screens, nativePosition: .left))
        XCTAssertFalse(systemDockPointerNearActivation(CGPoint(x: 900, y: 1), target: shortLeft,
            primaryHeight: 1080, screens: screens, nativePosition: .left))
        let shortBottom = CGRect(x: 900, y: 1000, width: 40, height: 80)
        XCTAssertTrue(systemDockPointerNearActivation(CGPoint(x: 200, y: 1), target: shortBottom,
            primaryHeight: 1080, screens: screens, nativePosition: .bottom))
        XCTAssertFalse(systemDockPointerNearActivation(CGPoint(x: 1, y: 500), target: shortBottom,
            primaryHeight: 1080, screens: screens, nativePosition: .bottom))
    }

    func testNativeOrientationDisambiguatesShortSideDockAtBottomCorner() {
        let display = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        for (nativePosition, x): (WorkspaceDockPosition, CGFloat) in [(.left, 0), (.right, 1840)] {
            // A short side Dock pinned to the bottom looks horizontal. Prefer
            // the native orientation over the ambiguous aspect-ratio fallback.
            let target = CGRect(x: x, y: 1040, width: 80, height: 40)
            let snapshot = SystemDockSnapshot(targetRect: target, visibleRect: target, nativePosition: nativePosition)
            for position in WorkspaceDockPosition.allCases {
                XCTAssertEqual(systemDockHidesDock(snapshot, position: position, display: display), position == nativePosition,
                    "Native \(nativePosition) at the bottom corner must only suppress WinMux \(nativePosition), not \(position)")
            }
        }
    }

    func testBottomLeaseChangesPreferenceOnceAndRestoresOnce() {
        let preferences = DockPreferences()
        let lease = preferences.lease()
        for _ in 0..<20 { lease.configure(active: true) }
        XCTAssertEqual(preferences.writes, [true])
        XCTAssertEqual(preferences.saved, [false])
        for _ in 0..<20 { lease.configure(active: false) }
        XCTAssertEqual(preferences.writes, [true, false])
        XCTAssertEqual(preferences.saved, [false, nil])
    }

    func testAlreadyAutoHiddenDockIsNeverModified() {
        let preferences = DockPreferences(current: true)
        let lease = preferences.lease()
        lease.configure(active: true)
        lease.configure(active: false)
        XCTAssertTrue(preferences.writes.isEmpty)
        XCTAssertTrue(preferences.saved.isEmpty)
    }

    func testExplicitUserChangeEndsOwnership() {
        let preferences = DockPreferences()
        let lease = preferences.lease()
        lease.configure(active: true)
        preferences.current = false
        lease.observeCurrentPreference()
        lease.configure(active: true)
        // A subsequent user change should also survive leaving Bottom mode.
        preferences.current = true
        lease.configure(active: false)
        XCTAssertEqual(preferences.writes, [true])
        XCTAssertEqual(preferences.current, true)
    }

    func testRecoveryRestoresAfterCrashOrAdoptsExistingBottomLease() {
        for resumesBottom in [false, true] {
            let preferences = DockPreferences(current: true)
            let lease = preferences.lease(original: false)
            if resumesBottom {
                lease.configure(active: true)
                XCTAssertTrue(preferences.writes.isEmpty)
            }
            lease.configure(active: false)
            XCTAssertEqual(preferences.writes, [false])
            XCTAssertEqual(preferences.saved, [nil])
        }
    }

    func testUnavailableDockDoesNotLoseRecoveryAndAcquisitionCanRetry() {
        let preferences = DockPreferences(current: nil)
        let lease = preferences.lease(original: false)
        lease.configure(active: false)
        XCTAssertTrue(preferences.saved.isEmpty)
        preferences.current = true
        lease.configure(active: false)
        XCTAssertEqual(preferences.writes, [false])
        preferences.current = nil
        lease.configure(active: true)
        preferences.current = false
        lease.configure(active: true)
        XCTAssertEqual(preferences.writes, [false, true])
    }

    func testUnconfirmedSetterKeepsRecoveryUntilRelease() {
        let preferences = DockPreferences()
        preferences.acceptWrites = false
        let lease = preferences.lease()
        lease.configure(active: true)
        lease.observeCurrentPreference()
        XCTAssertEqual(preferences.saved, [false], "An asynchronous setter may still take effect")
        lease.configure(active: false)
        XCTAssertEqual(preferences.writes, [true, false])
        XCTAssertEqual(preferences.saved, [false, nil])
    }

    func testDelayedEnableAndOlderVisibilityReadsCannotEraseRestoreRecord() {
        let preferences = DockPreferences()
        preferences.acceptWrites = false
        let lease = preferences.lease()
        lease.configure(active: true)
        lease.observeCurrentPreference() // Native setter has not taken effect yet.
        XCTAssertEqual(preferences.saved, [false])
        preferences.current = true // Delayed enable completes.
        lease.observeCurrentPreference() // Even if triggered by an older AX result, read current state.
        XCTAssertEqual(preferences.saved, [false])
        preferences.acceptWrites = true
        lease.configure(active: false)
        XCTAssertEqual(preferences.current, false)
        XCTAssertEqual(preferences.writes, [true, false])
        XCTAssertEqual(preferences.saved, [false, nil])
    }

    func testDelayedRestoreFinishesAfterVisibilityPollingStops() async {
        let preferences = DockPreferences()
        let restored = expectation(description: "Delayed restore clears the recovery journal")
        let lease = SystemDockAutoHideLease(read: { preferences.current },
            write: { preferences.writes.append($0); if preferences.acceptWrites { preferences.current = $0 } },
            save: { preferences.saved.append($0); if $0 == nil { restored.fulfill() } })
        lease.configure(active: true)
        preferences.acceptWrites = false
        for _ in 0..<20 { lease.configure(active: false) }
        XCTAssertEqual(preferences.writes, [true, false], "Do not resend an in-flight restore on every refresh")
        XCTAssertEqual(preferences.saved, [false])
        preferences.current = false // The native restore completes after configure returned.
        // No visibility snapshots or configuration refreshes: disabled mode stops both.
        await fulfillment(of: [restored], timeout: 2)
        preferences.current = true // A later user choice must survive shutdown/recovery.
        preferences.acceptWrites = true
        lease.configure(active: false)
        XCTAssertEqual(preferences.current, true)
        XCTAssertEqual(preferences.writes, [true, false])
        XCTAssertEqual(preferences.saved, [false, nil])
    }

    func testReacquisitionWaitsForPendingRestore() {
        let preferences = DockPreferences()
        let lease = preferences.lease()
        lease.configure(active: true)
        preferences.acceptWrites = false
        lease.configure(active: false)
        lease.configure(active: true)
        XCTAssertEqual(preferences.writes, [true, false], "Wait for the queued restore, even though auto-hide still reads true")
        preferences.current = false
        preferences.acceptWrites = true
        lease.observeCurrentPreference()
        XCTAssertEqual(preferences.writes, [true, false, true])
        XCTAssertEqual(preferences.saved, [false, nil, false])
        lease.configure(active: false)
        XCTAssertEqual(preferences.writes, [true, false, true, false])
        XCTAssertEqual(preferences.saved, [false, nil, false, nil])
    }

    func testOnlyTheNativeDockEdgeTriggersFastPollingAcrossDisplays() {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                       CGRect(x: -1600, y: -200, width: 1600, height: 900)]
        let bottom = CGRect(x: 600, y: 1000, width: 800, height: 80)
        XCTAssertTrue(systemDockPointerNearActivation(CGPoint(x: -800, y: -199), target: bottom,
            primaryHeight: 1080, screens: screens))
        XCTAssertFalse(systemDockPointerNearActivation(CGPoint(x: 1, y: 500), target: bottom,
            primaryHeight: 1080, screens: screens))
        let right = CGRect(x: 1840, y: 200, width: 80, height: 600)
        XCTAssertTrue(systemDockPointerNearActivation(CGPoint(x: -1, y: 300), target: right,
            primaryHeight: 1080, screens: screens))
        XCTAssertFalse(systemDockPointerNearActivation(CGPoint(x: -1599, y: 300), target: right,
            primaryHeight: 1080, screens: screens))
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: true, dockVisible: false, timeSincePointerActivity: 0.1), 0.05)
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: false, dockVisible: true, timeSincePointerActivity: 0.1), 0.15)
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: true, dockVisible: true, timeSincePointerActivity: 20), 1)
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: true, dockVisible: false, timeSincePointerActivity: 20), 1)
        // A freshly enabled coordinator has never seen a pointer packet. Its
        // monotonic sentinel must still produce a finite, convertible interval.
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: false, dockVisible: false, timeSincePointerActivity: .infinity), 1)
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: false, dockVisible: true, timeSincePointerActivity: .infinity), 1)
    }

    func testKeyboardDockTransitionStaysResponsiveThenReturnsToIdleCadence() {
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: false, dockVisible: true,
            timeSincePointerActivity: .infinity, timeSinceSnapshotChange: 0.2), 0.15)
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: false, dockVisible: true,
            timeSincePointerActivity: .infinity, timeSinceSnapshotChange: 2), 1)
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: true, dockVisible: false,
            timeSincePointerActivity: 0.2, timeSinceSnapshotChange: 2), 0.05)
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: false, dockVisible: false,
            timeSincePointerActivity: .infinity, timeSinceKeyboardActivity: 0.2), 0.15,
            "A shortcut can precede the first visible AX frame")
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: false, dockVisible: false,
            timeSincePointerActivity: .infinity, timeSinceKeyboardActivity: 2), 1)
    }

    func testPollingWaitsForNativeReadBeforeChoosingTransitionCadence() async throws {
        let probe = SystemDockPollingProbe()
        let coordinator = pollingCoordinator(probe)
        coordinator.configure(enabled: true, position: .left)
        defer { coordinator.configure(enabled: false, position: .left) }
        try await waitForPolling { await probe.reads == 1 }
        let beforeRead = await probe.sleeps
        XCTAssertTrue(beforeRead.isEmpty, "Do not choose an idle sleep using the pre-read snapshot")
        await probe.completeFirstRead(visibleBottomDock())
        try await waitForPolling { await probe.sleeps.count == 1 }
        let intervals = await probe.sleeps
        XCTAssertEqual(intervals, [0.15])
    }

    func testDisablingDuringNativeReadDoesNotScheduleAnotherPoll() async throws {
        let probe = SystemDockPollingProbe()
        let coordinator = pollingCoordinator(probe)
        coordinator.configure(enabled: true, position: .left)
        try await waitForPolling { await probe.reads == 1 }
        coordinator.configure(enabled: false, position: .left)
        await probe.completeFirstRead(visibleBottomDock())
        try await Task.sleep(for: .milliseconds(10))
        let intervals = await probe.sleeps
        XCTAssertTrue(intervals.isEmpty)
    }

    func testDockShortcutsWakeIdlePollingWhilePlainTypingDoesNot() async throws {
        let shortcuts: [(UInt16, NSEvent.ModifierFlags)] = [(2, [.command, .option]), (99, [.control]), (53, [])]
        for (key, modifiers) in shortcuts {
            let probe = SystemDockPollingProbe()
            let coordinator = pollingCoordinator(probe)
            coordinator.configure(enabled: true, position: .left)
            defer { coordinator.configure(enabled: false, position: .left) }
            try await waitForPolling { await probe.reads == 1 }
            await probe.completeFirstRead(nil)
            try await waitForPolling { await probe.sleeps.count == 1 }
            coordinator.noteKeyboardActivity(keyCode: 0, modifierFlags: [.shift])
            let idleIntervals = await probe.sleeps
            XCTAssertEqual(idleIntervals, [1])
            coordinator.noteKeyboardActivity(keyCode: key, modifierFlags: modifiers)
            try await waitForPolling { await probe.sleeps.count == 2 }
            let shortcutIntervals = await probe.sleeps
            XCTAssertEqual(shortcutIntervals, [1, 0.15])
        }
    }

    private func pollingCoordinator(_ probe: SystemDockPollingProbe) -> SystemDockCoordinator {
        let lease = SystemDockAutoHideLease(read: { false }, write: { _ in XCTFail("Unexpected Dock preference write") },
                                           save: { _ in XCTFail("Unexpected Dock recovery write") })
        return SystemDockCoordinator(lease: lease, read: { await probe.read() },
                                     sleep: { try await probe.sleep($0) })
    }

    private func visibleBottomDock() -> SystemDockSnapshot {
        let rect = CGRect(x: 200, y: 900, width: 600, height: 80)
        return .init(targetRect: rect, visibleRect: rect, nativePosition: .bottom)
    }

    private func waitForPolling(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw SystemDockPollingProbe.Timeout() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func testVisibleDockOnlySuppressesMatchingEdgeOnItsDisplayInQuartzCoordinates() {
        let displays = [Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            Rect(topLeftX: -1600, topLeftY: -900, width: 1600, height: 900),
            Rect(topLeftX: 0, topLeftY: 1080, width: 1920, height: 1080)]
        for (index, display) in displays.enumerated() {
            let docks: [(WorkspaceDockPosition, CGRect)] = [
                (.left, CGRect(x: display.minX, y: display.minY + 100, width: 80, height: 600)),
                (.bottom, CGRect(x: display.minX + 200, y: display.maxY - 80, width: 600, height: 80)),
                (.right, CGRect(x: display.maxX - 80, y: display.minY + 100, width: 80, height: 600)),
            ]
            for (nativePosition, dock) in docks {
                let snapshot = SystemDockSnapshot(targetRect: dock, visibleRect: dock)
                for position in WorkspaceDockPosition.allCases {
                    XCTAssertEqual(displays.map { systemDockHidesDock(snapshot, position: position, display: $0) },
                        displays.indices.map { $0 == index && position == nativePosition },
                        "Native \(nativePosition) must only hide WinMux \(nativePosition) on display \(index), not \(position) elsewhere")
                }
            }
        }
    }

    func testHiddenOrUnavailableNativeDockDoesNotSuppressAnyEdge() {
        let display = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let target = CGRect(x: 200, y: 1000, width: 800, height: 80)
        for snapshot: SystemDockSnapshot in [
            .init(), .init(targetRect: target), .init(visibleRect: target),
            .init(targetRect: target, visibleRect: target.offsetBy(dx: 0, dy: 80)),
        ] {
            for position in WorkspaceDockPosition.allCases {
                XCTAssertFalse(systemDockHidesDock(snapshot, position: position, display: display))
            }
        }
    }

    func testNativeDockEdgeRemainsStableDuringRevealAndHide() {
        let display = Rect(topLeftX: -1920, topLeftY: -1080, width: 1920, height: 1080)
        let docks: [(WorkspaceDockPosition, CGRect, CGFloat, CGFloat)] = [
            (.left, CGRect(x: -1920, y: -800, width: 80, height: 600), -1, 0),
            (.bottom, CGRect(x: -1200, y: -80, width: 800, height: 80), 0, 1),
            (.right, CGRect(x: -80, y: -800, width: 80, height: 600), 1, 0),
        ]
        for (nativePosition, target, dx, dy) in docks {
            for offset: CGFloat in [0, 40, 78, 79, 80] {
                let visible = systemDockVisibleRect(listFrame: target.offsetBy(dx: dx * offset, dy: dy * offset), targetFrame: target)
                let snapshot = SystemDockSnapshot(targetRect: target, visibleRect: visible)
                for position in WorkspaceDockPosition.allCases {
                    XCTAssertEqual(systemDockHidesDock(snapshot, position: position, display: display),
                        nativePosition == position && offset < 79)
                }
            }
        }
    }

    func testNativeDockEdgeHandlesScreenSpanningAndShortDocks() {
        let display = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let docks: [(WorkspaceDockPosition, CGRect)] = [
            (.bottom, CGRect(x: 0, y: 1000, width: 1920, height: 80)),
            (.left, CGRect(x: 0, y: 0, width: 80, height: 1080)),
            (.right, CGRect(x: 1840, y: 0, width: 80, height: 1080)),
            // A small system margin must not make a screen-spanning Dock yield
            // to the perpendicular edge merely because that edge is closer.
            (.bottom, CGRect(x: 0, y: 998, width: 1920, height: 80)),
            (.left, CGRect(x: 2, y: 0, width: 80, height: 1080)),
            (.right, CGRect(x: 1838, y: 0, width: 80, height: 1080)),
            // The nearest edge determines orientation even when a short Dock's
            // long axis differs from its edge; allow an inset from the display.
            (.bottom, CGRect(x: 900, y: 998, width: 40, height: 80)),
            (.left, CGRect(x: 2, y: 500, width: 80, height: 40)),
            (.right, CGRect(x: 1838, y: 500, width: 80, height: 40)),
        ]
        for (nativePosition, target) in docks {
            for position in WorkspaceDockPosition.allCases {
                XCTAssertEqual(systemDockHidesDock(.init(targetRect: target, visibleRect: target),
                    position: position, display: display), nativePosition == position)
            }
        }
    }

    func testDockVisibilityUsesActualListFrameNotTheReservedFrame() {
        let target = CGRect(x: 300, y: 900, width: 800, height: 100)
        XCTAssertNil(systemDockVisibleRect(listFrame: CGRect(x: 300, y: 1000, width: 800, height: 100), targetFrame: target),
            "Offscreen AX elements must not hide WinMux on a monitor below this one")
        XCTAssertEqual(systemDockVisibleRect(listFrame: CGRect(x: 300, y: 940, width: 800, height: 100), targetFrame: target),
            CGRect(x: 300, y: 940, width: 800, height: 60))
        for edge in [CGRect(x: -1920, y: -100, width: 80, height: 600), CGRect(x: 1840, y: 200, width: 80, height: 600)] {
            XCTAssertEqual(systemDockVisibleRect(listFrame: edge, targetFrame: edge), edge)
            XCTAssertNil(systemDockVisibleRect(listFrame: edge.offsetBy(dx: edge.minX < 0 ? -80 : 80, dy: 0), targetFrame: edge))
        }
    }
}

@MainActor
private final class DockPreferences {
    var current: Bool?
    var writes: [Bool] = []
    var saved: [Bool?] = []
    var acceptWrites = true
    init(current: Bool? = false) { self.current = current }
    func lease(original: Bool? = nil) -> SystemDockAutoHideLease {
        SystemDockAutoHideLease(original: original, read: { self.current },
            write: { self.writes.append($0); if self.acceptWrites { self.current = $0 } },
            save: { self.saved.append($0) })
    }
}

private actor SystemDockPollingProbe {
    struct Timeout: Error {}
    private(set) var reads = 0
    private(set) var sleeps: [TimeInterval] = []
    private var firstRead: CheckedContinuation<SystemDockSnapshot?, Never>?
    private var snapshot: SystemDockSnapshot?

    func read() async -> SystemDockSnapshot? {
        reads += 1
        if reads == 1 { return await withCheckedContinuation { firstRead = $0 } }
        return snapshot
    }

    func completeFirstRead(_ next: SystemDockSnapshot?) {
        snapshot = next
        firstRead?.resume(returning: next)
        firstRead = nil
    }

    func sleep(_ seconds: TimeInterval) async throws {
        sleeps.append(seconds)
        // The test controls each read and cancels the loop. No real cadence delay
        // is needed to observe the interval that the production loop selected.
        try await Task.sleep(for: .seconds(60))
    }
}
