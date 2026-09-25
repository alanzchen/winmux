import AppKit
import Common

struct LauncherApp: Identifiable, Hashable, Sendable {
    let bundleId: String
    let name: String
    let url: URL?

    var id: String { bundleId }
    var bundleFileName: String? { url?.deletingPathExtension().lastPathComponent }
}

/// What choosing an app in the launcher does, shown beside it before it is chosen.
enum LauncherAppAction: Equatable {
    case newWindow
    case open
    case newWindowFromMenu
    /// No way to make a new window: the launcher can only switch to the app's existing one.
    case switchTo

    var label: String {
        switch self {
            case .newWindow, .newWindowFromMenu: "New window"
            case .open: "Open"
            case .switchTo: "Switch to app"
        }
    }
}

func launcherAppAction(bundleId: String, isRunning: Bool, menuFallbackEnabled: Bool) -> LauncherAppAction {
    switch newWindowMethod(bundleId: bundleId, isRunning: isRunning, menuFallbackEnabled: menuFallbackEnabled) {
        case .launch: .open
        case .script: .newWindow
        case .menuItem: .newWindowFromMenu
        case .unsupported: .switchTo
    }
}

/// Apps to offer: running apps first when nothing is typed, then everything by match quality,
/// running apps winning ties. Apps that can only be switched to come after those that can
/// open a new window. Each app appears once; WinMux itself never does.
func launcherResults(
    installed: [LauncherApp],
    running: [LauncherApp],
    query: String,
    isSwitchOnly: (LauncherApp) -> Bool = { _ in false },
) -> [LauncherApp] {
    var seen: Set<String> = [winMuxAppId]
    var merged: [LauncherApp] = []
    for app in running + installed where seen.insert(app.bundleId).inserted {
        merged.append(app)
    }
    let runningIds = Set(running.map(\.bundleId))
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else {
        return merged.sorted { lhs, rhs in
            let lhsSwitchOnly = isSwitchOnly(lhs)
            let rhsSwitchOnly = isSwitchOnly(rhs)
            if lhsSwitchOnly != rhsSwitchOnly { return rhsSwitchOnly }
            let lhsRunning = runningIds.contains(lhs.bundleId)
            let rhsRunning = runningIds.contains(rhs.bundleId)
            if lhsRunning != rhsRunning { return lhsRunning }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
    return merged
        .compactMap { app -> (LauncherApp, Int)? in
            let haystacks = [app.name, app.bundleFileName].compactMap { $0?.lowercased() }
            let best = haystacks.compactMap { switcherPaletteFuzzyScore(needle, in: $0) }.max()
            // A name that starts with the query beats a scattered match.
            return best.map { (app, $0 + (app.name.lowercased().hasPrefix(needle) ? 100 : 0)) }
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let lhsSwitchOnly = isSwitchOnly(lhs.0)
            let rhsSwitchOnly = isSwitchOnly(rhs.0)
            if lhsSwitchOnly != rhsSwitchOnly { return rhsSwitchOnly }
            let lhsRunning = runningIds.contains(lhs.0.bundleId)
            let rhsRunning = runningIds.contains(rhs.0.bundleId)
            if lhsRunning != rhsRunning { return lhsRunning }
            return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
        }
        .map(\.0)
}

let launcherApplicationDirectories: [URL] = [
    URL(fileURLWithPath: "/Applications"),
    URL(fileURLWithPath: "/Applications/Utilities"),
    URL(fileURLWithPath: "/System/Applications"),
    URL(fileURLWithPath: "/System/Applications/Utilities"),
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
]

/// Apps in the given folders and one level of subfolders, such as a suite's folder in
/// /Applications. Reads bundles from disk, so call it off the main thread.
func scanLauncherApps(in directories: [URL], extraBundles: [URL] = []) -> [LauncherApp] {
    let fileManager = FileManager.default
    var bundleURLs = extraBundles
    for directory in directories {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { continue }
        for entry in entries {
            if entry.pathExtension == "app" {
                bundleURLs.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let nested = try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil,
                          options: [.skipsHiddenFiles])
            {
                bundleURLs += nested.filter { $0.pathExtension == "app" }
            }
        }
    }
    var seen: Set<String> = []
    return bundleURLs.compactMap { url in
        guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier, seen.insert(bundleId).inserted,
              // Menu-bar helpers and agents have no windows to open.
              bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
              bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true
        else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return LauncherApp(bundleId: bundleId, name: name, url: url)
    }
}

@MainActor
func runningLauncherApps() -> [LauncherApp] {
    NSWorkspace.shared.runningApplications.compactMap { app in
        guard app.activationPolicy == .regular, !app.isTerminated, let bundleId = app.bundleIdentifier else { return nil }
        return LauncherApp(bundleId: bundleId, name: app.localizedName ?? bundleId, url: app.bundleURL)
    }
}

/// Installed apps, scanned in the background and kept between launcher sessions.
@MainActor
final class LauncherAppCatalog {
    static let shared = LauncherAppCatalog()
    private(set) var installed: [LauncherApp] = []
    private var scan: Task<[LauncherApp], Never>?

    func refresh() async -> [LauncherApp] {
        if scan == nil {
            scan = Task.detached(priority: .userInitiated) {
                scanLauncherApps(in: launcherApplicationDirectories,
                    extraBundles: [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")])
            }
        }
        let apps = await scan?.value ?? installed
        installed = apps
        scan = nil
        return apps
    }
}
