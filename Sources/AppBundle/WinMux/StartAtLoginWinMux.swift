import Foundation

extension WinMuxHooks {
    /// WinMux's launch agents from before `SMAppService`. Replaces upstream's cleanup, which removes AeroSpace's own
    /// `bobko.aerospace.plist`: WinMux must not touch another app's launch agent.
    static let legacyLaunchAgentPlists = ["com.zxzimeng.winmux.plist", "com.zimengxiong.winmux.plist"]

    static func cleanupLaunchAgentPlists(in launchAgentsDir: URL) {
        for name in legacyLaunchAgentPlists {
            try? FileManager.default.removeItem(at: launchAgentsDir.appending(path: name))
        }
    }
}
