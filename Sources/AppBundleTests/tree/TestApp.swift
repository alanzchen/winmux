@testable import AppBundle
import Common
import Foundation

final class TestApp: AbstractApp {
    let pid: Int32
    let rawAppBundleId: String?
    let name: String?
    let execPath: String? = nil
    let bundlePath: String?
    var launchDate: Date?
    @MainActor
    static let shared = TestApp()

    private init() {
        self.pid = 0
        self.rawAppBundleId = "bobko.WinMux.test-app"
        self.name = rawAppBundleId
        self.bundlePath = nil
        self.launchDate = nil
    }

    /// Another app. `AbstractApp ==` compares pids, so every instance needs its own pid.
    init(pid: Int32, bundleId: String?, name: String? = nil, bundlePath: String? = nil, launchDate: Date? = nil) {
        check(pid != 0, "pid 0 belongs to TestApp.shared")
        self.pid = pid
        self.rawAppBundleId = bundleId
        self.name = name ?? bundleId
        self.bundlePath = bundlePath
        self.launchDate = launchDate
    }

    var _windows: [Window] = []
    var windows: [Window] {
        get { _windows }
        set {
            if let focusedWindow {
                check(newValue.contains(focusedWindow))
            }
            _windows = newValue
        }
    }

    private var _focusedWindow: Window? = nil
    @MainActor var hasActiveTransientNativeFocus = false
    var focusedWindow: Window? {
        get { _focusedWindow }
        set {
            if let window = newValue {
                check(windows.contains(window))
            }
            _focusedWindow = newValue
        }
    }
    @MainActor func getFocusedWindow() -> Window? { _focusedWindow }
}
