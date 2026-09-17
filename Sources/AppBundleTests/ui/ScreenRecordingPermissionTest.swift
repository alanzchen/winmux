@testable import AppBundle
import XCTest

@MainActor
final class ScreenRecordingPermissionTest: XCTestCase {
    func testOpeningAndRefreshingSettingsNeverRequestPermission() {
        var requests = 0
        var granted = false
        let model = ScreenRecordingPermissionModel(preflight: { granted }, request: { requests += 1; return false })
        for _ in 0 ..< 3 { model.refresh() }
        XCTAssertFalse(model.isGranted)
        granted = true
        model.refresh()
        XCTAssertTrue(model.isGranted)
        granted = false
        model.refresh()
        XCTAssertFalse(model.isGranted)
        XCTAssertEqual(requests, 0)
    }

    func testExistingAuthorizationNeverRequestsAgainIncludingAfterRelaunch() {
        var requests = 0
        for _ in 0 ..< 3 {
            let model = ScreenRecordingPermissionModel(preflight: { true }, request: { requests += 1; return false })
            model.requestFromSettings()
            XCTAssertTrue(model.isGranted)
        }
        XCTAssertEqual(requests, 0)
    }

    func testDeniedRequestDoesNotRetryOnActivationOrRepeatedAction() {
        var requests = 0
        let model = ScreenRecordingPermissionModel(preflight: { false }, request: { requests += 1; return false })
        model.requestFromSettings()
        model.refresh()
        model.requestFromSettings()
        XCTAssertFalse(model.isGranted)
        XCTAssertTrue(model.didRequest)
        XCTAssertEqual(requests, 1)
    }

    func testExplicitGrantUpdatesStatusImmediately() {
        let model = ScreenRecordingPermissionModel(preflight: { false }, request: { true })
        model.requestFromSettings()
        XCTAssertTrue(model.isGranted)
    }
}
