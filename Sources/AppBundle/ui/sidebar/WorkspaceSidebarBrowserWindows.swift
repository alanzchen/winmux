import SwiftUI

/// What browser windows' tabs say about the windows themselves, for the rows and tiles that
/// show them.
struct WorkspaceSidebarBrowserWindows: Equatable {
    /// Windows with a tab playing sound, or else a muted one.
    var audio: [UInt32: BrowserTabAudio] = [:]
    /// Windows whose every tab's sound is known, and none plays.
    var silent: Set<UInt32> = []
    /// Apps with a window playing sound. That's where the app's sound comes from, so its other
    /// windows show none.
    var playingApps: Set<String> = []

    init() {}

    /// `windows` are the sidebar's windows, which name each one's app.
    init(_ browserTabs: [UInt32: BrowserWindowTabs], windows: [WorkspaceSidebarWindowViewModel]) {
        for (id, snapshot) in browserTabs {
            if snapshot.tabs.contains(where: { $0.audio == .playing }) {
                audio[id] = .playing
            } else if snapshot.tabs.contains(where: { $0.audio == .muted }) {
                audio[id] = .muted
            } else if snapshot.knowsSound {
                silent.insert(id)
            }
        }
        for window in windows where audio[window.windowId] == .playing {
            if let bundleId = window.appBundleId { playingApps.insert(bundleId) }
        }
    }

    /// The sound a window shows. Its tabs', where they say. Otherwise Core Audio's for its whole
    /// app, `appIsPlaying`, unless another window is where that comes from or its tabs are all
    /// silent: an app with one window, or with none described, shows it on every window.
    func audio(windowId: UInt32, bundleId: String?, appIsPlaying: Bool) -> BrowserTabAudio? {
        if let audio = audio[windowId] { return audio }
        guard appIsPlaying, !silent.contains(windowId), !(bundleId.map(playingApps.contains) ?? false) else { return nil }
        return .playing
    }
}

private struct WorkspaceSidebarBrowserWindowsKey: EnvironmentKey {
    static let defaultValue = WorkspaceSidebarBrowserWindows()
}

extension EnvironmentValues {
    var workspaceSidebarBrowserWindows: WorkspaceSidebarBrowserWindows {
        get { self[WorkspaceSidebarBrowserWindowsKey.self] }
        set { self[WorkspaceSidebarBrowserWindowsKey.self] = newValue }
    }
}
