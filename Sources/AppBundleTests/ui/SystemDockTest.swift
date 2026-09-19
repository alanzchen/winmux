@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class SystemDockTest: XCTestCase {
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
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: true, dockVisible: true, timeSincePointerActivity: 20), 0.15)
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: true, dockVisible: false, timeSincePointerActivity: 20), 1)
        // A freshly enabled coordinator has never seen a pointer packet. Its
        // monotonic sentinel must still produce a finite, convertible interval.
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: false, dockVisible: false, timeSincePointerActivity: .infinity), 1)
        XCTAssertEqual(systemDockPollInterval(pointerNearDock: false, dockVisible: true, timeSincePointerActivity: .infinity), 0.15)
    }

    func testVisibleDockOnlySuppressesItsDisplayInQuartzCoordinates() {
        let displays = [Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            Rect(topLeftX: -1600, topLeftY: -900, width: 1600, height: 900),
            Rect(topLeftX: 0, topLeftY: 1080, width: 1920, height: 1080)]
        for (index, display) in displays.enumerated() {
            let dock = CGRect(x: display.minX + 200, y: display.maxY - 80, width: 600, height: 80)
            XCTAssertEqual(displays.map { systemDockOverlapsDisplay(visible: dock, display: $0) },
                displays.indices.map { $0 == index })
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
