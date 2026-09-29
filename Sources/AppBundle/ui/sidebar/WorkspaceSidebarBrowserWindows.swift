import SwiftUI

/// What browser windows' tabs say about the windows themselves, for the rows and tiles that
/// show them.
struct WorkspaceSidebarBrowserWindows: Equatable {
    /// The website icon of each window with one tab, which the window shows in place of its
    /// browser's. A window with more lists its tabs, each with its own icon, under the browser's.
    var siteIcons: [UInt32: WorkspaceSidebarSiteIcon] = [:]
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
            if !snapshot.isGroup, let tab = snapshot.tabs.first, tab.siteIcon != nil || tab.iconOrigin != nil {
                siteIcons[id] = .init(key: tab.siteIcon, origin: tab.iconOrigin)
            }
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

/// A browser tab's website icon: the Safari extension's, by key, or one WinMux fetches for its origin.
struct WorkspaceSidebarSiteIcon: Equatable {
    var key: String?
    var origin: URL?
}

/// A window's icon: the website its one browser tab shows, once that icon is at hand, and its
/// app's until then, and for every other window.
struct WorkspaceSidebarWindowIcon: View {
    let window: WorkspaceSidebarWindowViewModel
    var size: CGFloat = workspaceSidebarTabIconSize
    var isOnLightBackground = false
    @Environment(\.workspaceSidebarBrowserWindows) private var browserWindows

    var body: some View {
        if let site = browserWindows.siteIcons[window.windowId] {
            WorkspaceSidebarSiteIconView(site: site, window: window, size: size, isOnLightBackground: isOnLightBackground)
        } else {
            WorkspaceSidebarTabIcon(bundleId: window.appBundleId, bundlePath: window.appBundlePath, size: size,
                isOnLightBackground: isOnLightBackground)
        }
    }
}

/// Watches the icons only for windows with a website, so an icon arriving redraws no other row.
private struct WorkspaceSidebarSiteIconView: View {
    let site: WorkspaceSidebarSiteIcon
    let window: WorkspaceSidebarWindowViewModel
    let size: CGFloat
    let isOnLightBackground: Bool
    @ObservedObject private var icons = BrowserTabIconModel.shared
    @ObservedObject private var siteIcons = SafariExtensionIcons.shared

    var body: some View {
        Group {
            if let key = site.key, let image = siteIcons.images[key] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if let origin = site.origin, let image = icons.images[origin] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                WorkspaceSidebarTabIcon(bundleId: window.appBundleId, bundlePath: window.appBundlePath, size: size,
                    isOnLightBackground: isOnLightBackground)
            }
        }
        .frame(width: size, height: size)
        .onAppear { icons.request(site.origin) }
        .onChange(of: site.origin) { icons.request($0) }
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
