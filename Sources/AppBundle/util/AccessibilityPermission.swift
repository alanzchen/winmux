import AppKit
import Common

enum AccessibilityPermissionStatus: Equatable {
    case waitingWithPrompt
    case waiting
    case granted
}

/// Adapted from AeroSpace fb8b1df6. Do not reset TCC while acquiring permission: that can erase
/// approval as the user grants it. Signed updates retain their identity; recovery is in Settings.
@MainActor
func waitForAccessibilityPermission(
    model: TrayMenuModel = .shared,
    checkTrusted: @MainActor (Bool) -> Bool = checkAccessibilityTrust,
    waitBeforeRetry: @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
) async throws {
    while true {
        try Task.checkCancellation()
        let shouldPrompt = model.accessibilityPermissionStatus == .waitingWithPrompt
        if checkTrusted(shouldPrompt) {
            model.accessibilityPermissionStatus = .granted
            return
        }
        model.accessibilityPermissionStatus = .waiting
        try await waitBeforeRetry()
    }
}

@MainActor
private func checkAccessibilityTrust(prompt: Bool) -> Bool {
    if prompt {
        return AXIsProcessTrustedWithOptions([axTrustedCheckOptionPrompt: true] as CFDictionary)
    }
    return AXIsProcessTrusted()
}
