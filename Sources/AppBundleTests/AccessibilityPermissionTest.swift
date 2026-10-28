@testable import AppBundle
import XCTest

@MainActor
final class AccessibilityPermissionTest: XCTestCase {
    func testAlreadyGrantedPermissionContinuesWithoutWaiting() async throws {
        let model = TrayMenuModel()
        try await waitForAccessibilityPermission(
            model: model,
            checkTrusted: { _ in true },
            waitBeforeRetry: { XCTFail("Already granted permission must not wait") },
        )
        XCTAssertEqual(model.accessibilityPermissionStatus, .granted)
    }

    func testFirstApprovalResumesSameWaiterAndPromptsOnlyOnce() async throws {
        let model = TrayMenuModel()
        var requestedPrompts: [Bool] = []
        var waits = 0
        try await waitForAccessibilityPermission(
            model: model,
            checkTrusted: { prompt in
                requestedPrompts.append(prompt)
                return waits == 2
            },
            waitBeforeRetry: {
                XCTAssertEqual(model.accessibilityPermissionStatus, .waiting)
                waits += 1
            },
        )
        XCTAssertEqual(requestedPrompts, [true, false, false])
        XCTAssertEqual(model.accessibilityPermissionStatus, .granted)
    }

    func testExplicitSettingsActionCanRequestAnotherPrompt() async throws {
        let model = TrayMenuModel()
        var requestedPrompts: [Bool] = []
        try await waitForAccessibilityPermission(
            model: model,
            checkTrusted: { prompt in
                requestedPrompts.append(prompt)
                return requestedPrompts.count == 2
            },
            waitBeforeRetry: { model.accessibilityPermissionStatus = .waitingWithPrompt },
        )
        XCTAssertEqual(requestedPrompts, [true, true])
        XCTAssertEqual(model.accessibilityPermissionStatus, .granted)
    }

    func testCancellationDoesNotContinueStartupWithoutPermission() async {
        let model = TrayMenuModel()
        do {
            try await waitForAccessibilityPermission(
                model: model,
                checkTrusted: { _ in false },
                waitBeforeRetry: { throw CancellationError() },
            )
            XCTFail("Cancellation must stop startup")
        } catch is CancellationError {
            XCTAssertEqual(model.accessibilityPermissionStatus, .waiting)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
