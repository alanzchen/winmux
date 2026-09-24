import Common
import Foundation

protocol AbstractApp: AnyObject, Hashable, WinMuxAny {
    var pid: Int32 { get }
    var rawAppBundleId: String? { get }

    @MainActor func getFocusedWindow() async throws -> Window?
    @MainActor var hasActiveTransientNativeFocus: Bool { get }
    var name: String? { get }
    var execPath: String? { get }
    var bundlePath: String? { get }
    /// When the app process launched. Saved workspaces route a relaunched app's first windows.
    var launchDate: Date? { get }
}

extension AbstractApp {
    @MainActor var hasActiveTransientNativeFocus: Bool { false }
    var launchDate: Date? { nil }

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
