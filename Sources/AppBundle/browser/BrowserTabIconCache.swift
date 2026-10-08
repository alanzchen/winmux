import CryptoKit
import Foundation

/// Which origin icon a Chrome tab may show. Chrome's icons come from Accessibility reading the
/// selected tab's address (`BrowserTabIconAssociations`); the extension's live report says which
/// page instance each tab shows: its scoped tab key (browser profile, extension session, transport
/// epoch and tab id), origin and page revision, which changes with every address the tab commits
/// and never repeats.
///
/// Per native tab it remembers the latest page instance a live report described, and when WinMux
/// first saw it: the latest page change it knows of. Missing information (a report gap, a lost
/// pairing, an extension without revisions) never clears that. An icon counts only from a read
/// that started after that change. With a live report, also only at the page's origin; without
/// one, also only for the selected tab, while its window's latest read still finds it there. A tab
/// the extension never described keeps its icon as without the extension.
///
/// Keyed by the native tab, which is never reused: one entry per listed tab.
struct BrowserTabChromeIconGate {
    private struct Page: Equatable {
        let tab: SafariExtensionTabKey
        /// Nil for a page that isn't a website.
        let origin: String?
        let revision: String
    }
    private struct State {
        /// The latest page instance a live report described; nil while the tab is described only
        /// without revisions.
        let page: Page?
        /// When WinMux first saw that page instance, or first saw the tab described.
        let since: TimeInterval
    }
    private var states: [BrowserTabTarget: State] = [:]

    /// The tab's origin icon, as `origins` confirmed it, if it may show. `reported` is the live
    /// report's tab for its bound key.
    mutating func origin(for tab: BrowserTab, reported: SafariExtensionTab?, origins: BrowserTabIconAssociations,
                         now: TimeInterval) -> URL? {
        var live: Page?
        if let key = tab.extensionTab {
            if let reported, let revision = reported.revision {
                let page = Page(tab: key, origin: reported.origin, revision: revision)
                if states[tab.target]?.page != page { states[tab.target] = State(page: page, since: now) }
                live = page
            } else if states[tab.target].map({ $0.page.map { $0.tab != key } ?? false }) ?? true {
                // Described without page evidence, or by another tab key than the last page's: a change.
                states[tab.target] = State(page: nil, since: now)
            }
        }
        guard let origin = tab.iconOrigin else { return nil }
        guard let state = states[tab.target] else { return origin }
        guard let confirmed = origins.confirmed[tab.target], confirmed >= state.since else { return nil }
        guard let live else { return tab.isSelected && origins.isCurrent(tab.target) ? origin : nil }
        guard let expected = live.origin, browserTabOriginKey(origin.absoluteString) == expected else { return nil }
        return origin
    }

    mutating func retain(_ targets: Set<BrowserTabTarget>) { states = states.filter { targets.contains($0.key) } }
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

/// Website icon images kept across WinMux launches, so a page that names an icon WinMux has had
/// before shows it at once, without the extension sending it again. It decides nothing about
/// which page shows which icon: it only keeps images by the key the extension gives an icon (the
/// SHA-256 of its PNG).
///
/// Each icon is the 32-pixel PNG WinMux made from what the extension sent, filed under the icon's
/// key with the SHA-256 of its bytes, checked again when read. An index maps a keyed hash of the
/// browser profile and the icon's key to it, so each profile's icons stay its own: no host name,
/// address, title or page content is written, and nothing from Private Browsing, which the
/// extension never reports. At most `maximumEntries` icons and `maximumBytes` of images, least
/// recently used first; one unused for `lifetime` is never read again, and its image is deleted
/// at the next `prune` (WinMux prunes when it first reads the folder, on each write, and hourly
/// while reports arrive). Readable only by the user, under the app's Caches folder.
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
        var v = 2
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

    /// Reads the index, so `knows` can answer.
    func prepare() {
        lock.lock()
        defer { lock.unlock() }
        _ = loadIndex()
    }

    /// Whether a profile's icon is kept, without waiting: false while the index isn't read yet, or
    /// another thread is using it.
    func knows(partition: String, icon: String) -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        guard let index, let name = name(partition: partition, icon: icon), let entry = index.entries[name] else { return false }
        return clock() - entry.used < lifetime
    }

    /// The 32-pixel PNG kept for a profile's icon, if still valid.
    func icon(partition: String, icon key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard var index = loadIndex(), let name = name(partition: partition, icon: key), var entry = index.entries[name] else { return nil }
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
        return png
    }

    /// Keeps `png`, the image of the icon the extension's key `icon` names, for a profile.
    func store(partition: String, icon: String, png: Data) {
        guard SafariExtensionMessage.isIconKey(icon), png.count <= Self.maximumIconBytes,
              BrowserTabIconDownload.thumbnail(png) != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var index = loadIndex(), let name = name(partition: partition, icon: icon) else { return }
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

    /// Deletes icons unused for their lifetime, beyond the bounds, and images no entry names.
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
        // Version 1 filed icons by site; none of it is used now.
        if loaded.v != 2 { loaded = Index() }
        loaded.entries = loaded.entries.filter { SafariExtensionMessage.isIconKey($0.value.icon) && $0.value.bytes > 0 }
        evict(&loaded)
        index = loaded
        return loaded
    }

    private func name(partition: String, icon: String) -> String? {
        guard let secret, SafariExtensionMessage.isIconKey(icon) else { return nil }
        let code = HMAC<SHA256>.authenticationCode(for: Data("\(partition)\n\(icon)".utf8), using: secret)
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
