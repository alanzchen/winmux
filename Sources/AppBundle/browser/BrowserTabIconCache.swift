import CryptoKit
import Foundation

/// Keeps a tab's website icon through brief gaps in what the extension says about it, and only
/// for the same page. Keyed by the native tab, which is never reused: a tab id an extension
/// reuses after a restart, or a new transport epoch, starts over (`SafariExtensionTabKey.source`
/// names the profile, session and epoch).
///
/// - A description of the tab without an icon, from the same scope and for the same host, keeps
///   the icon it last had: the extension can omit one while it rasterizes the page's again.
/// - A description for another host, without a host, or from another scope drops it: a page
///   navigated away never shows the previous site's icon.
/// - While nothing describes the tab (a report gap, a disconnect), it keeps the icon as long as
///   the tab's title is unchanged, for at most `gapLifetime`: a navigation changes the title.
struct BrowserTabSiteIconContinuity {
    private struct Held: Equatable {
        let scope: String
        let host: String
        let icon: String
        let title: String
        let confirmed: TimeInterval
    }
    private var held: [BrowserTabTarget: Held] = [:]
    /// As long as a report keeps describing a window.
    static let gapLifetime: TimeInterval = 150

    /// The icon to show for `tab`, whose `siteIcon`, `host` and `extensionTab` say what the
    /// extension describes now (all nil while it describes nothing).
    mutating func icon(for tab: BrowserTab, now: TimeInterval) -> String? {
        let target = tab.target
        guard let scope = tab.extensionTab?.source else {
            // Nothing describes it now, or only a position pairing that proves no tab identity.
            guard tab.host == nil, tab.siteIcon == nil, let kept = held[target], kept.title == tab.title,
                  now - kept.confirmed < Self.gapLifetime else {
                held[target] = nil
                return tab.siteIcon
            }
            return kept.icon
        }
        guard let host = tab.host else {
            held[target] = nil
            return tab.siteIcon
        }
        if let icon = tab.siteIcon {
            held[target] = Held(scope: scope, host: host, icon: icon, title: tab.title, confirmed: now)
            return icon
        }
        guard let kept = held[target], kept.scope == scope, kept.host == host else {
            held[target] = nil
            return nil
        }
        held[target] = Held(scope: scope, host: host, icon: kept.icon, title: tab.title, confirmed: kept.confirmed)
        return kept.icon
    }

    mutating func retain(_ targets: Set<BrowserTabTarget>) { held = held.filter { targets.contains($0.key) } }

    /// Icons held for tabs, which the icon store must keep.
    var icons: Set<String> { Set(held.values.map(\.icon)) }
}

/// Website icons kept across WinMux launches, so a tab whose page the extension can't describe
/// again until it reloads (as after the extension restarts) still shows its site's icon.
///
/// Each icon is the 32-pixel PNG WinMux made from what the extension sent, filed under the icon's
/// key with the SHA-256 of its bytes, checked again when read. An index maps a keyed hash of the
/// browser profile and the site's host name to it: no host name, address, title or page content
/// is written, and nothing from Private Browsing, which the extension never reports. At most
/// `maximumEntries` sites and `maximumBytes` of images, each dropped after `lifetime` unused,
/// least recently used first. Readable only by the user, under the app's Caches folder.
final class BrowserTabIconDiskCache: @unchecked Sendable {
    static let maximumEntries = 512
    static let maximumBytes = 8 * 1024 * 1024
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    static let maximumIconBytes = 96 * 1024
    /// How often a read's newer use is written down.
    static let useWriteInterval: TimeInterval = 60

    private struct Entry: Codable, Equatable {
        var icon: String
        var digest: String
        var bytes: Int
        var used: TimeInterval
    }
    private struct Index: Codable {
        var v = 1
        var entries: [String: Entry] = [:]
    }

    let directory: URL
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let lifetime: TimeInterval
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private var index: Index?
    private var secret: SymmetricKey?
    private var lastWrite: TimeInterval = -.infinity

    init(directory: URL, maximumEntries: Int = BrowserTabIconDiskCache.maximumEntries,
         maximumBytes: Int = BrowserTabIconDiskCache.maximumBytes, lifetime: TimeInterval = BrowserTabIconDiskCache.lifetime,
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.directory = directory
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
        self.lifetime = lifetime
        self.clock = clock
    }

    /// `~/Library/Caches/<WinMux's bundle id>/BrowserTabIcons`.
    static var standard: BrowserTabIconDiskCache? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return .init(directory: caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.zimengxiong.winmux")
            .appendingPathComponent("BrowserTabIcons"))
    }

    /// Only profiles the browser names stay the same across launches; anything else isn't kept.
    static func partition(browser: String, profile: String) -> String? {
        guard UUID(uuidString: profile) != nil || profile.hasPrefix("profile:") else { return nil }
        return "\(browser):\(profile)"
    }

    /// The icon key and 32-pixel PNG kept for a site's host in a profile, if still valid.
    func icon(partition: String, host: String) -> (key: String, png: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard var index = loadIndex(), let name = name(partition: partition, host: host), var entry = index.entries[name] else { return nil }
        let now = clock()
        guard now - entry.used < lifetime,
              let png = try? Data(contentsOf: iconFile(entry.icon)), png.count == entry.bytes,
              Self.digest(png) == entry.digest, BrowserTabIconDownload.thumbnail(png) != nil else {
            index.entries[name] = nil
            self.index = index
            write(index)
            return nil
        }
        entry.used = now
        index.entries[name] = entry
        self.index = index
        if now - lastWrite >= Self.useWriteInterval { write(index) }
        return (entry.icon, png)
    }

    /// Keeps `png`, the icon the extension's key `icon` names, for a site's host in a profile.
    func store(partition: String, host: String, icon: String, png: Data) {
        guard SafariExtensionMessage.isIconKey(icon), png.count <= Self.maximumIconBytes,
              BrowserTabIconDownload.thumbnail(png) != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var index = loadIndex(), let name = name(partition: partition, host: host) else { return }
        let digest = Self.digest(png)
        let now = clock()
        if let kept = index.entries[name], kept.icon == icon, kept.digest == digest {
            index.entries[name]?.used = now
            self.index = index
            if now - lastWrite >= Self.useWriteInterval { write(index) }
            return
        }
        let entry = Entry(icon: icon, digest: digest, bytes: png.count, used: now)
        let file = iconFile(icon)
        if (try? Data(contentsOf: file)).map(Self.digest) != digest {
            guard (try? png.write(to: file, options: .atomic)) != nil else { return }
            restrict(file)
        }
        index.entries[name] = entry
        evict(&index)
        self.index = index
        write(index)
    }

    /// Everything, as when browser tabs are turned off.
    func remove() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
        index = nil
        secret = nil
        lastWrite = -.infinity
    }

    // MARK: - Files

    private var iconsDirectory: URL { directory.appendingPathComponent("icons") }
    private func iconFile(_ icon: String) -> URL { iconsDirectory.appendingPathComponent(icon + ".png") }

    private func loadIndex() -> Index? {
        if let index { return index }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
            for folder in [directory, iconsDirectory] { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        } catch { return nil }
        let keyFile = directory.appendingPathComponent("key")
        var bytes = (try? Data(contentsOf: keyFile)) ?? Data()
        if bytes.count != 32 {
            bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            guard (try? bytes.write(to: keyFile, options: .atomic)) != nil else { return nil }
            restrict(keyFile)
            // A new key can't find old names: start empty.
            try? manager.removeItem(at: iconsDirectory)
            try? manager.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: iconsDirectory.path)
            try? manager.removeItem(at: directory.appendingPathComponent("index.json"))
        }
        secret = SymmetricKey(data: bytes)
        var loaded = (try? Data(contentsOf: directory.appendingPathComponent("index.json")))
            .flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index()
        if loaded.v != 1 { loaded = Index() }
        loaded.entries = loaded.entries.filter { SafariExtensionMessage.isIconKey($0.value.icon) && $0.value.bytes > 0 }
        evict(&loaded)
        index = loaded
        return loaded
    }

    private func name(partition: String, host: String) -> String? {
        guard let secret, !host.isEmpty else { return nil }
        let code = HMAC<SHA256>.authenticationCode(for: Data("\(partition)\n\(host.lowercased())".utf8), using: secret)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// Drops expired entries, then the least recently used beyond the bounds, then any image no
    /// entry names.
    private func evict(_ index: inout Index) {
        let now = clock()
        index.entries = index.entries.filter { now - $0.value.used < lifetime }
        var ordered = index.entries.sorted { $0.value.used < $1.value.used }
        func total() -> Int { Dictionary(ordered.map { ($0.value.icon, $0.value.bytes) }, uniquingKeysWith: max).values.reduce(0, +) }
        while !ordered.isEmpty, ordered.count > maximumEntries || total() > maximumBytes { ordered.removeFirst() }
        index.entries = Dictionary(uniqueKeysWithValues: ordered.map { ($0.key, $0.value) })
        let named = Set(index.entries.values.map { $0.icon + ".png" })
        for file in (try? FileManager.default.contentsOfDirectory(atPath: iconsDirectory.path)) ?? [] where !named.contains(file) {
            try? FileManager.default.removeItem(at: iconsDirectory.appendingPathComponent(file))
        }
    }

    private func write(_ index: Index) {
        let file = directory.appendingPathComponent("index.json")
        guard let data = try? JSONEncoder().encode(index), (try? data.write(to: file, options: .atomic)) != nil else { return }
        restrict(file)
        lastWrite = clock()
    }

    private func restrict(_ file: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
