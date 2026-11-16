import AppKit
import Common
import ServiceManagement

@MainActor
func syncStartAtLogin() {
    if isUnitTest { return } // WINMUX-HOOK(unitTestIsolation)
    cleanupPlistFromPrevVersions()
    let service = SMAppService.mainApp
    switch true {
        case !config.startAtLogin: _ = try? service.unregister()
        case isDebug: print("'start-at-login = true' has no effect in debug builds")
        default: _ = try? service.register()
    }
}

private func cleanupPlistFromPrevVersions() { // todo Drop after a couple of versions
    let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser.appending(component: "Library/LaunchAgents/")
    Result { try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true) }.getOrDie()
    // WINMUX-HOOK-REPLACES(cleanupLaunchAgentPlists)
    if true { return WinMuxHooks.cleanupLaunchAgentPlists(in: launchAgentsDir) } // WINMUX-HOOK(cleanupLaunchAgentPlists)
    let url: URL = launchAgentsDir.appending(path: "bobko.aerospace.plist")
    try? FileManager.default.removeItem(at: url)
}
