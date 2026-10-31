import Foundation

// An app's own helper processes can show windows: a background helper inside the app's bundle (a
// mini-program or web runtime, say), or a system XPC service working for it, such as Quick Look's
// preview. Such a window may sit in a saved tab or pin while the app is used, but the process isn't an
// app the user opens: the tab doesn't keep a place for it, wait for it to relaunch, show it as one of
// its apps, or launch it. Its windows come with the app that uses them.

/// Whether the process whose bundle is at `bundlePath` is a helper, by what its bundle declares: an XPC
/// service, or an agent or background-only app inside another app's bundle. A regular app nested in
/// another (Simulator inside Xcode) isn't one; nor is anything without a bundle path, which there's no
/// telling.
@MainActor
func savedWorkspaceAppIsHelper(bundlePath: String?) -> Bool {
    guard let bundlePath, !bundlePath.isEmpty else { return false }
    let path = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
    if let known = savedWorkspaceHelperCache[path] { return known }
    let isHelper = savedWorkspaceBundleIsHelper(path, info: savedWorkspaceBundleInfo(path))
    savedWorkspaceHelperCache[path] = isHelper
    return isHelper
}

/// The bundle's Info.plist, as read from disk. Replaceable for tests.
@MainActor
var savedWorkspaceBundleInfo: @MainActor (String) -> [String: Any]? = { path in
    let info = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: info),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return plist
}

@MainActor private var savedWorkspaceHelperCache: [String: Bool] = [:]

@MainActor
func resetSavedWorkspaceHelperCacheForTests() { savedWorkspaceHelperCache = [:] }

/// The rule itself, for a standardized path and its Info.plist if it could be read.
func savedWorkspaceBundleIsHelper(_ path: String, info: [String: Any]?) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    // An XPC service, by its kind or by where XPC services live, even with its Info.plist unreadable.
    if info?["CFBundlePackageType"] as? String == "XPC!" { return true }
    if path.hasSuffix(".xpc") || components.dropLast().contains("XPCServices") { return true }
    // An agent or background-only app living inside another app's bundle.
    let insideAnotherApp = components.dropLast().contains { $0.hasSuffix(".app") }
    guard insideAnotherApp, let info else { return false }
    func declares(_ key: String) -> Bool {
        switch info[key] {
            case let flag as Bool: flag
            case let number as NSNumber: number.boolValue
            case let text as String: ["1", "yes", "true"].contains(text.lowercased())
            default: false
        }
    }
    return declares("LSUIElement") || declares("LSBackgroundOnly")
}
