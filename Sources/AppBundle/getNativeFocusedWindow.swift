import AppKit
import Common

@MainActor
var appForTests: (any AbstractApp)? = nil

@MainActor
private var focusedApp: (any AbstractApp)? {
    get async throws {
        if isUnitTest {
            return appForTests
        } else {
            check(appForTests == nil)
            return try await NSWorkspace.shared.frontmostApplication.flatMapAsync { @MainActor @Sendable in
                try await MacApp.getOrRegister($0)
            }
        }
    }
}

@MainActor
func getNativeFocusedWindow() async throws -> Window? {
    try await getNativeFocusObservation().window
}

struct NativeFocusObservation {
    let window: Window?
    let isTransient: Bool
}

@MainActor
func getNativeFocusObservation() async throws -> NativeFocusObservation {
    let app = try await focusedApp
    let window = try await app?.getFocusedWindow()
    return NativeFocusObservation(window: window, isTransient: app?.hasActiveTransientNativeFocus == true)
}
