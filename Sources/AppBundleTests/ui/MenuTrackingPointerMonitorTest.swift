import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class MenuTrackingPointerMonitorTest: XCTestCase {
    @MainActor private final class Fixture {
        let center = NotificationCenter()
        var installed: [NSObject] = []
        var removed: [NSObject] = []
        var resumes = 0
        lazy var owner = MenuTrackingPointerMonitor(center: center,
            installMonitor: { [unowned self] in
                let token = NSObject()
                self.installed.append(token)
                return token
            },
            removeMonitor: { [unowned self] in self.removed.append($0 as! NSObject) },
            didResume: { [unowned self] in self.resumes += 1 })

        func begin(_ menu: NSMenu) { center.post(name: NSMenu.didBeginTrackingNotification, object: menu) }
        func end(_ menu: NSMenu) { center.post(name: NSMenu.didEndTrackingNotification, object: menu) }
    }

    func testMenuTrackingRemovesTheNativeMonitorAndRestoresItOnDismissal() {
        let fixture = Fixture()
        defer { fixture.owner.stop() }
        fixture.owner.start()
        let original = fixture.installed[0]
        let menu = NSMenu()

        fixture.begin(menu)
        XCTAssertEqual(fixture.removed, [original], "A callback guard alone leaves the delayed native event route installed")
        XCTAssertEqual(fixture.installed.count, 1)
        XCTAssertEqual(fixture.resumes, 0)

        fixture.end(menu) // AppKit posts this for cancellation as well as a selected action.
        XCTAssertEqual(fixture.installed.count, 2)
        XCTAssertFalse(fixture.installed[1] === original)
        XCTAssertEqual(fixture.resumes, 1, "A stationary Dock pointer must be re-evaluated after cancellation")
    }

    func testNestedMenusAndDuplicateNotificationsDoNotRestoreEarlyOrInstallTwice() {
        let fixture = Fixture()
        defer { fixture.owner.stop() }
        fixture.owner.start()
        fixture.owner.start()
        let root = NSMenu()
        let submenu = NSMenu()
        let unrelated = NSMenu()

        fixture.begin(root)
        fixture.begin(root)
        fixture.begin(submenu)
        fixture.end(unrelated)
        fixture.end(root)
        XCTAssertEqual(fixture.installed.count, 1)
        XCTAssertEqual(fixture.removed.count, 1)
        XCTAssertEqual(fixture.resumes, 0)

        fixture.end(submenu)
        fixture.end(submenu)
        fixture.end(root)
        XCTAssertEqual(fixture.installed.count, 2)
        XCTAssertEqual(fixture.resumes, 1)
    }

    func testStopDuringTrackingDoesNotLeaveObserversThatCanRestartTheMonitor() {
        let fixture = Fixture()
        defer { fixture.owner.stop() }
        fixture.owner.start()
        let menu = NSMenu()
        fixture.begin(menu)
        fixture.owner.stop()
        fixture.end(menu)
        fixture.begin(menu)
        fixture.end(menu)
        XCTAssertEqual(fixture.installed.count, 1)
        XCTAssertEqual(fixture.removed.count, 1)
        XCTAssertEqual(fixture.resumes, 0)

        fixture.owner.start()
        XCTAssertEqual(fixture.installed.count, 2)
        fixture.owner.stop()
        fixture.owner.stop()
        XCTAssertEqual(fixture.removed.count, 2)
    }

    func testRegistrationFailureStillRecoversAfterAMenuCloses() {
        let center = NotificationCenter()
        var attempts = 0
        var removals = 0
        let owner = MenuTrackingPointerMonitor(center: center,
            installMonitor: { attempts += 1; return attempts == 1 ? nil : NSObject() },
            removeMonitor: { _ in removals += 1 },
            didResume: {})
        defer { owner.stop() }
        owner.start()
        let menu = NSMenu()
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(removals, 0)
        owner.stop()
        XCTAssertEqual(removals, 1)
    }
}
