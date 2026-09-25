@testable import AppBundle
import AppKit
import XCTest

/// A refresh during unit tests sees the machine's real apps. Registering them would read real
/// AX elements wherever the test runner is trusted for Accessibility, and those crash code that
/// expects mocks (as in the macOS 27 Tart guest).
@MainActor
final class RealAppIsolationTest: XCTestCase {
    func testUnitTestsNeverRegisterRealRunningApps() async throws {
        let realApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        try XCTSkipIf(realApps.isEmpty, "No regular app is running")
        for app in realApps {
            let registered = try await MacApp.getOrRegister(app)
            XCTAssertNil(registered, "\(app.bundleIdentifier ?? "pid \(app.processIdentifier)") was registered")
        }
    }
}
