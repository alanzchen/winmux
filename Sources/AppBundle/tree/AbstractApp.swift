import Common
import Foundation // WINMUX-HOOK(appState)

protocol AbstractApp: AnyObject, Hashable, AeroAny {
    var pid: Int32 { get }
    var rawAppBundleId: String? { get }

    @MainActor func getFocusedWindow() async throws -> Window?
    // WINMUX-HOOK-BEGIN(appState)
    /// Complete frame writes queued for this app before another app's windows are hidden.
    @MainActor func waitForPendingFrameWrites() async throws
    @MainActor var hasActiveTransientNativeFocus: Bool { get }
    // WINMUX-HOOK-END(appState)
    var name: String? { get }
    var execPath: String? { get }
    var bundlePath: String? { get }
    // WINMUX-HOOK-BEGIN(appState)
    /// When the app process launched. Saved workspaces route a relaunched app's first windows.
    var launchDate: Date? { get }
    // WINMUX-HOOK-END(appState)
}

extension AbstractApp {
    // WINMUX-HOOK-BEGIN(appState)
    @MainActor func waitForPendingFrameWrites() async throws {}
    @MainActor var hasActiveTransientNativeFocus: Bool { false }
    var launchDate: Date? { nil }

    // WINMUX-HOOK-END(appState)
    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.pid == rhs.pid {
            check(lhs === rhs)
            return true
        } else {
            check(lhs !== rhs)
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }
}

extension Window {
    var macAppUnsafe: MacApp { app as! MacApp }
}
