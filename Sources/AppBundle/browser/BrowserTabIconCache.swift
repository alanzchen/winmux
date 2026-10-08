import CryptoKit
import Foundation

/// Which website icon a tab may show, by one rule: an icon shows only for the exact page
/// instance that produced it. A page instance is what the live report of the extension tab the
/// native tab is bound to says: the scoped tab key (browser profile, extension session, transport
/// epoch and tab id), the page's origin and the extension's revision of the page, which changes
/// with every address the tab commits. Titles and hosts are never evidence.
///
/// Safari (`icon`): the icon the live report gives the page instance (the extension gives one only
/// for the revision whose page made it), and while that same instance is reported without one, the
/// icon it gave before. Nothing without a live report for the bound tab, or from an extension
/// without revisions. Its origin's kept icon (`fallback`) only for the extension's first page in
/// the tab (`SafariExtensionTab.isFirstPage`), and only until WinMux sees the tab change pages
/// within one report stream: from then on, the tab shows only icons its own pages give.
///
/// Chrome (`origin`): the origin icon Accessibility confirmed for the tab
/// (`BrowserTabIconAssociations`), only while the live report says the page is at that origin and
/// a read that started after WinMux first saw the page instance confirmed it. Without a live
/// report with a revision (an older extension, a gap, or a tab the extension described before but
/// no longer pairs), only the selected tab's, while its window's latest read still confirms it. A
/// tab the extension never described keeps the icon as without the extension.
///
/// Keyed by the native tab, which is never reused: one entry per listed tab.
struct BrowserTabSiteIconContinuity {
    private struct Page: Equatable {
        let tab: SafariExtensionTabKey
        /// Nil for a page that isn't a website.
        let origin: String?
        let revision: String
    }
    private struct State {
        let page: Page
        /// When WinMux first saw this page instance.
        let since: TimeInterval
        /// Whether WinMux saw the tab change pages within one report stream, for this page or before.
        let changed: Bool
        /// The icon this page instance's reports gave.
        var icon: String?
    }
    private var states: [BrowserTabTarget: State] = [:]
    /// Tabs the extension has described.
    private var described: Set<BrowserTabTarget> = []

    /// The page instance the live report says the tab shows, noted if it's new.
    private mutating func page(_ target: BrowserTabTarget, key: SafariExtensionTabKey, live: SafariExtensionTab?,
                               now: TimeInterval) -> State? {
        guard let live, let revision = live.revision else { return nil }
        let page = Page(tab: key, origin: live.origin, revision: revision)
        let known = states[target]
        if let known, known.page == page { return known }
        // Another page in the same stream is a page change. A new stream (the extension's page
        // reloading, or a new session) isn't one in itself, but a change seen before still counts.
        let state = State(page: page, since: now, changed: known.map { $0.changed || $0.page.tab.source == key.source } ?? false)
        states[target] = state
        return state
    }

    /// A Safari tab's icon. `reported` is the live report's tab for its bound key; `fallback`
    /// gives the kept icon of an origin, for the tab's report source.
    mutating func icon(for tab: BrowserTab, reported: SafariExtensionTab?, now: TimeInterval,
                       fallback: (SafariExtensionTabKey, String) -> String?) -> String? {
        guard let key = tab.extensionTab, let reported, var state = page(tab.target, key: key, live: reported, now: now) else {
            return nil
        }
        if let icon = reported.icon {
            state.icon = icon
            states[tab.target] = state
        }
        if let icon = state.icon { return icon }
        guard !state.changed, reported.isFirstPage, let origin = state.page.origin else { return nil }
        return fallback(key, origin)
    }

    /// A Chrome tab's origin icon, as `origins` confirmed it, if it may show.
    mutating func origin(for tab: BrowserTab, reported: SafariExtensionTab?, origins: BrowserTabIconAssociations,
                         now: TimeInterval) -> URL? {
        let state = tab.extensionTab.flatMap { page(tab.target, key: $0, live: reported, now: now) }
        if tab.extensionTab != nil { described.insert(tab.target) }
        guard let origin = tab.iconOrigin else { return nil }
        let fresh = tab.isSelected && origins.isCurrent(tab.target) ? origin : nil
        guard tab.extensionTab != nil else { return described.contains(tab.target) ? fresh : origin }
        guard let state else { return fresh }
        guard let expected = state.page.origin, browserTabOriginKey(origin.absoluteString) == expected,
              let confirmed = origins.confirmed[tab.target], confirmed >= state.since else { return nil }
        return origin
    }

    mutating func retain(_ targets: Set<BrowserTabTarget>) {
        states = states.filter { targets.contains($0.key) }
        described.formIntersection(targets)
    }

    /// Icons pages gave, which the icon store must keep.
    var icons: Set<String> { Set(states.values.compactMap(\.icon)) }
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
