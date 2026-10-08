import CryptoKit
import Foundation

/// Keeps a tab's website icon while the extension's latest report describes the same page
/// without one, and never across a page change. The page is the extension's whole word for it,
/// from the live report of the extension tab the native tab is bound to: the scoped tab key
/// (browser profile, extension session, transport epoch and tab id), the page's origin and the
/// extension's page revision, which changes with every address the tab commits. A title or host
/// is never taken as evidence the page is the same.
///
/// - The same page reported without an icon keeps the icon it last had, even after a report gap
///   in between: its revision says no address was committed meanwhile.
/// - While no live report has the bound tab (a gap or a disconnect), the app icon, whatever the
///   extension. A tab not bound by id, or one an older extension (without revisions) reports,
///   shows only what the extension describes, as before.
/// - Another page (another revision, origin or tab key) drops what was held. The kept icon of its
///   origin (`fallback`) then shows only if it isn't what the tab showed before, so a fallback
///   never brings a revoked icon back.
/// Keyed by the native tab, which is never reused.
struct BrowserTabSiteIconContinuity {
    private struct Page: Equatable {
        let tab: SafariExtensionTabKey
        let origin: String
        let revision: String
    }
    private struct State {
        var page: Page
        /// What the extension last gave this page.
        var icon: String?
        /// What this page showed last, and what the page before showed, which the fallback mustn't bring back.
        var shown: String?
        var revoked: String?
    }
    private var states: [BrowserTabTarget: State] = [:]

    /// The icon to show for `tab`, as the association describes it (`siteIcon`, `extensionTab`,
    /// `pageRevision`). `reported` is the live report's tab for its bound key, if any; `fallback`
    /// gives the kept icon of an origin, for the tab's report source.
    mutating func icon(for tab: BrowserTab, reported: SafariExtensionTab?,
                       fallback: (SafariExtensionTabKey, String) -> String?) -> String? {
        guard let key = tab.extensionTab else { return tab.siteIcon }
        guard let reported else { return nil }
        guard let origin = reported.origin, let revision = reported.revision else { return tab.siteIcon }
        let page = Page(tab: key, origin: origin, revision: revision)
        var state = states[tab.target].map { $0.page == page ? $0 : State(page: page, revoked: $0.shown ?? $0.revoked) }
            ?? State(page: page)
        if let icon = reported.icon { state.icon = icon }
        state.shown = state.icon ?? fallback(key, origin).flatMap { $0 == state.revoked ? nil : $0 }
        states[tab.target] = state
        return state.shown
    }

    mutating func retain(_ targets: Set<BrowserTabTarget>) { states = states.filter { targets.contains($0.key) } }

    /// Icons held for tabs, which the icon store must keep.
    var icons: Set<String> { Set(states.values.flatMap { [$0.icon, $0.shown].compactMap { $0 } }) }
    var count: Int { states.count }
}

/// At most `capacity` values, each dropped `lifetime` after its last use, least recently used
/// first: for indexes that must not grow with browsing history.
struct BrowserTabRecency<Key: Hashable, Value> {
    private var entries: [Key: (value: Value, used: TimeInterval)] = [:]
    let capacity: Int
    let lifetime: TimeInterval

    init(capacity: Int, lifetime: TimeInterval) {
        self.capacity = capacity
        self.lifetime = lifetime
    }

    var count: Int { entries.count }
    var values: [Value] { entries.values.map(\.value) }

    /// The value, which counts as a use.
    mutating func value(_ key: Key, now: TimeInterval) -> Value? {
        guard let entry = entries[key] else { return nil }
        guard now - entry.used < lifetime else {
            entries[key] = nil
            return nil
        }
        entries[key]?.used = now
        return entry.value
    }

    func peek(_ key: Key, now: TimeInterval) -> Value? {
        entries[key].flatMap { now - $0.used < lifetime ? $0.value : nil }
    }

    mutating func set(_ key: Key, _ value: Value, now: TimeInterval) {
        entries[key] = (value, now)
        guard entries.count > capacity else { return }
        // Trims in batches, so filling up costs one sort per eighth of the capacity.
        let kept = entries.filter { now - $0.value.used < lifetime }
            .sorted { $0.value.used > $1.value.used }.prefix(max(1, capacity - capacity / 8))
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    mutating func removeAll(where shouldRemove: (Key, Value) -> Bool) {
        entries = entries.filter { !shouldRemove($0.key, $0.value.value) }
    }

    mutating func removeAll() { entries = [:] }
}

/// Website icons kept across WinMux launches, so a tab whose page the extension can't describe
/// again until it reloads (as after the extension restarts) still shows its site's icon.
///
/// Each icon is the 32-pixel PNG WinMux made from what the extension sent, filed under the icon's
/// key with the SHA-256 of its bytes, checked again when read. An index maps a keyed hash of the
/// browser profile and the site's origin (scheme, host and port) to it: no host name, address,
/// title or page content is written, and nothing from Private Browsing, which the extension never
/// reports. At most `maximumEntries` sites and `maximumBytes` of images, least recently used
/// first; a site unused for `lifetime` is never read again, and its image is deleted at the next
/// `prune` (WinMux prunes when it first reads the folder, on each write, and hourly while
/// reports arrive). Readable only by the user, under the app's Caches folder.
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

    /// The icon key and 32-pixel PNG kept for a site's origin in a profile, if still valid.
    func icon(partition: String, origin: String) -> (key: String, png: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard var index = loadIndex(), let name = name(partition: partition, origin: origin), var entry = index.entries[name] else { return nil }
        let now = clock()
        guard now - entry.used < lifetime,
              let png = try? Data(contentsOf: iconFile(entry.icon)), png.count == entry.bytes,
              Self.digest(png) == entry.digest, BrowserTabIconDownload.thumbnail(png) != nil else {
            index.entries[name] = nil
            evict(&index)
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

    /// Keeps `png`, the icon the extension's key `icon` names, for a site's origin in a profile.
    func store(partition: String, origin: String, icon: String, png: Data) {
        guard SafariExtensionMessage.isIconKey(icon), png.count <= Self.maximumIconBytes,
              BrowserTabIconDownload.thumbnail(png) != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var index = loadIndex(), let name = name(partition: partition, origin: origin) else { return }
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

    /// Deletes sites unused for their lifetime, beyond the bounds, and images no site names.
    func prune() {
        lock.lock()
        defer { lock.unlock() }
        guard let loaded = loadIndex() else { return }
        var index = loaded
        evict(&index)
        self.index = index
        if index.entries.count != loaded.entries.count { write(index) }
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

    private func name(partition: String, origin: String) -> String? {
        guard let secret, let origin = browserTabOriginKey(origin) else { return nil }
        let code = HMAC<SHA256>.authenticationCode(for: Data("\(partition)\n\(origin)".utf8), using: secret)
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
