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
            return switch NSWorkspace.shared.frontmostApplication {
                case let frontmostApplication?: try await MacApp.getOrRegister(frontmostApplication)
                case nil: nil
            }
        }
    }
}

@MainActor
func getNativeFocusedWindow() async throws -> Window? {
    try await focusedApp?.getFocusedWindow()
}
// WINMUX-HOOK-BEGIN(nativeFocusObservation)
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
// WINMUX-HOOK-END(nativeFocusObservation)
