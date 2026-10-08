import AppKit
@testable import AppBundle
import CryptoKit
import JavaScriptCore
import XCTest

/// Website icon continuity and the icons kept across launches, with synthetic icons in a
/// temporary folder. Never touches WinMux's real Caches folder or a browser.
@MainActor
final class BrowserTabIconCacheTest: XCTestCase {
    private var directory: URL!
    private let profileA = UUID().uuidString
    private let profileB = UUID().uuidString

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserTabIconCacheTest-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func png(_ color: NSColor) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func key(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// An icon as the bridge keeps it: the extension's key, and WinMux's 32-pixel PNG of it.
    private func icon(_ color: NSColor) throws -> (key: String, png: Data) {
        let original = try png(color)
        return (key(original), try XCTUnwrap(BrowserTabIconDownload.thumbnail(original)))
    }

    private func partition(_ profile: String, browser: String = "safari") throws -> String {
        try XCTUnwrap(BrowserTabIconDiskCache.partition(browser: browser, profile: profile))
    }

    // MARK: - Disk

    func testKeptImagesSurviveARelaunchOnlyInTheirOwnProfileAndBrowser() throws {
        let red = try icon(.red), blue = try icon(.blue)
        BrowserTabIconDiskCache(directory: directory).store(partition: try partition(profileA), icon: red.key, png: red.png)
        let relaunched = BrowserTabIconDiskCache(directory: directory)
        XCTAssertFalse(relaunched.knows(partition: try partition(profileA), icon: red.key), "Not before its index is read")
        relaunched.prepare()
        XCTAssertTrue(relaunched.knows(partition: try partition(profileA), icon: red.key))
        XCTAssertEqual(relaunched.icon(partition: try partition(profileA), icon: red.key), red.png)
        XCTAssertFalse(relaunched.knows(partition: try partition(profileB), icon: red.key))
        XCTAssertNil(relaunched.icon(partition: try partition(profileB), icon: red.key), "Never another profile's")
        XCTAssertNil(relaunched.icon(partition: try partition(profileA, browser: "chrome"), icon: red.key), "Never another browser's")
        XCTAssertNil(relaunched.icon(partition: try partition(profileA), icon: blue.key))
        XCTAssertNil(relaunched.icon(partition: try partition(profileA), icon: "../../etc"))
    }

    func testTheDiskHoldsNoProfileHostTitleOrAddressAndOnlyTheUserCanReadIt() throws {
        let red = try icon(.red)
        let cache = BrowserTabIconDiskCache(directory: directory)
        cache.store(partition: try partition(profileA), icon: red.key, png: red.png)
        let manager = FileManager.default
        var files: [URL] = []
        for case let url as URL in try XCTUnwrap(manager.enumerator(at: directory, includingPropertiesForKeys: nil)) { files.append(url) }
        let base = directory.resolvingSymlinksInPath().path + "/"
        let names = files.map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") }.sorted()
        XCTAssertEqual(names, ["icons", "icons/\(red.key).png", "index.json", "key"])
        for file in files where !file.hasDirectoryPath {
            let bytes = try Data(contentsOf: file)
            for secret in [profileA, "safari:", "http"] {
                XCTAssertNil(bytes.range(of: Data(secret.utf8)), "\(file.lastPathComponent) holds \(secret)")
            }
            XCTAssertEqual(try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600, file.lastPathComponent)
        }
        for folder in [directory!, directory.appendingPathComponent("icons")] {
            XCTAssertEqual(try manager.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int, 0o700)
        }
    }

    func testATamperedOrMissingImageIsDroppedRatherThanShown() throws {
        let red = try icon(.red), blue = try icon(.blue)
        let cache = BrowserTabIconDiskCache(directory: directory)
        cache.store(partition: try partition(profileA), icon: red.key, png: red.png)
        cache.store(partition: try partition(profileA), icon: blue.key, png: blue.png)
        // Another image under the red icon's name, and the blue one gone.
        try blue.png.write(to: directory.appendingPathComponent("icons/\(red.key).png"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("icons/\(blue.key).png"))
        let relaunched = BrowserTabIconDiskCache(directory: directory)
        XCTAssertNil(relaunched.icon(partition: try partition(profileA), icon: red.key))
        XCTAssertNil(relaunched.icon(partition: try partition(profileA), icon: blue.key))
        XCTAssertFalse(relaunched.knows(partition: try partition(profileA), icon: red.key), "A bad image is forgotten")
        // Only icons the extension's key could name, of bounded size, that decode, are kept.
        cache.store(partition: try partition(profileA), icon: "../../etc", png: red.png)
        let text = String(repeating: "a", count: 64)
        cache.store(partition: try partition(profileA), icon: text, png: Data("not an image".utf8))
        XCTAssertNil(cache.icon(partition: try partition(profileA), icon: "../../etc"))
        XCTAssertNil(cache.icon(partition: try partition(profileA), icon: text))
    }

    func testLeastRecentlyUsedIconsAndOldOnesAreDroppedWithinTheBounds() throws {
        var now = 1_000.0
        let colors: [NSColor] = [.red, .green, .blue, .yellow]
        let icons = try colors.map(icon)
        let cache = BrowserTabIconDiskCache(directory: directory, maximumEntries: 3, lifetime: 100, clock: { now })
        for icon in icons.prefix(3) {
            now += 1
            cache.store(partition: try partition(profileA), icon: icon.key, png: icon.png)
        }
        now += 1
        XCTAssertNotNil(cache.icon(partition: try partition(profileA), icon: icons[0].key), "Reading an icon counts as using it")
        now += 1
        cache.store(partition: try partition(profileA), icon: icons[3].key, png: icons[3].png)
        XCTAssertNil(cache.icon(partition: try partition(profileA), icon: icons[1].key), "The least recently used goes first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("icons/\(icons[1].key).png").path),
                       "and its image with it")
        for index in [0, 2, 3] { XCTAssertNotNil(cache.icon(partition: try partition(profileA), icon: icons[index].key), "\(index)") }
        now += 100
        XCTAssertNil(cache.icon(partition: try partition(profileA), icon: icons[3].key), "An icon unused for its lifetime goes")
        // Not just unreadable: pruning deletes expired icons' images from the disk.
        cache.prune()
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("icons").path)
        XCTAssertEqual(left, [], "Every icon expired, so every image is deleted")

        // The byte bound, across distinct images.
        let small = BrowserTabIconDiskCache(directory: directory.appendingPathComponent("bytes"),
            maximumBytes: icons[0].png.count + icons[1].png.count, clock: { now })
        for icon in icons.prefix(3) {
            now += 1
            small.store(partition: try partition(profileA), icon: icon.key, png: icon.png)
        }
        XCTAssertNil(small.icon(partition: try partition(profileA), icon: icons[0].key))
        XCTAssertNotNil(small.icon(partition: try partition(profileA), icon: icons[2].key))
    }

    func testOnlyProfilesThatLastArePartitionsAndRemovalWipesEverything() throws {
        XCTAssertNotNil(BrowserTabIconDiskCache.partition(browser: "safari", profile: profileA))
        XCTAssertNotNil(BrowserTabIconDiskCache.partition(browser: "safari", profile: "profile:Work"))
        XCTAssertNil(BrowserTabIconDiskCache.partition(browser: "safari", profile: "session:abc"), "A session-only scope isn't kept")
        let red = try icon(.red)
        let cache = BrowserTabIconDiskCache(directory: directory)
        cache.store(partition: try partition(profileA), icon: red.key, png: red.png)
        cache.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(BrowserTabIconDiskCache(directory: directory).icon(partition: try partition(profileA), icon: red.key))
    }

    // MARK: - Bridge

    private func state(_ tabs: [[String: Any]], session: String = "s", incognito: Bool = false) -> [String: Any] {
        ["v": 2, "type": "state", "session": session, "time": 5, "allSites": true,
         "windows": [["id": 1, "incognito": incognito, "tabs": tabs]]]
    }

    private func envelope(_ message: [String: Any], profile: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["message": message, "profile": profile])
    }

    func testPrivateWindowsAndChromeNeverReachTheDiskAndTurningOffRemovesIt() throws {
        let original = try png(.red)
        let redKey = key(original)
        let tab: [String: Any] = ["id": 1, "title": "Secret", "origin": "https://private.test", "rev": "x-1", "active": true, "icon": redKey]
        let safari = SafariExtensionBridge(configuration: { nil }, icons: SafariExtensionIcons(),
            iconCache: BrowserTabIconDiskCache(directory: directory), now: { 1 })
        safari.setEnabled(true)
        _ = safari.receive(SafariExtensionMessage.decode(try envelope(state([tab], incognito: true), profile: profileA)))
        _ = safari.receive(SafariExtensionMessage.decode(try envelope(
            ["v": 2, "type": "icons", "session": "s", "icons": [redKey: original.base64EncodedString()]], profile: profileA)))
        safari.waitForKeptIcons()
        XCTAssertNil(BrowserTabIconDiskCache(directory: directory).icon(partition: try partition(profileA), icon: redKey))
        // A normal window's icon is kept, and turning browser tabs off removes everything.
        var normal = tab
        normal["title"] = "Example"
        normal["origin"] = "https://example.test"
        _ = safari.receive(SafariExtensionMessage.decode(try envelope(state([normal]), profile: profileA)))
        _ = safari.receive(SafariExtensionMessage.decode(try envelope(
            ["v": 2, "type": "icons", "session": "s", "icons": [redKey: original.base64EncodedString()]], profile: profileA)))
        safari.waitForKeptIcons()
        XCTAssertNotNil(BrowserTabIconDiskCache(directory: directory).icon(partition: try partition(profileA), icon: redKey))
        safari.removeKeptIcons()
        safari.waitForKeptIcons()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let chromeDirectory = directory.appendingPathComponent("chrome")
        let chrome = SafariExtensionBridge(browser: "chrome", configuration: { nil }, icons: SafariExtensionIcons(),
            iconCache: BrowserTabIconDiskCache(directory: chromeDirectory), now: { 1 })
        chrome.setEnabled(true)
        _ = chrome.receive(SafariExtensionMessage.decode(try envelope(state([normal]), profile: profileA)))
        chrome.waitForKeptIcons()
        XCTAssertFalse(FileManager.default.fileExists(atPath: chromeDirectory.path), "Chrome's connections have no lasting profile")
    }

    // MARK: - The report → association → sidebar path

    /// One Safari window of one profile, reported through the real decoder and bridge, paired by
    /// the real association, and shown by `browserTabsShown` and `browserTabIconShown`.
    @MainActor
    private final class Pipeline {
        var now = 0.0
        let profile: String
        var session = String(UUID().uuidString.lowercased().prefix(8))
        var epoch = UUID().uuidString
        var sequence = 0
        let icons = SafariExtensionIcons()
        var bridge: SafariExtensionBridge!
        var associations = SafariExtensionAssociations()
        var continuity = BrowserTabSiteIconContinuity()
        var origins = BrowserTabIconAssociations()
        var native: BrowserWindowTabs
        var observed = -Double.infinity
        /// The icons WinMux's latest answer to a report asked the extension for.
        var wanted: [String] = []

        init(cache: BrowserTabIconDiskCache?, profile: String, titles: [String] = ["Inbox"]) {
            self.profile = profile
            let lifetime = UUID()
            native = .init(windowId: 1, pid: 7, windowSession: lifetime, tabs: titles.enumerated().map { index, title in
                .init(target: .init(windowId: 1, pid: 7, windowSession: lifetime, tabId: UUID()), title: title, isSelected: index == 0)
            })
            bridge = SafariExtensionBridge(configuration: { nil }, icons: icons, iconCache: cache,
                now: { [unowned self] in now }, clock: { [unowned self] in now })
            bridge.sightSafariWindows = { _ in [:] }
            bridge.setEnabled(true)
        }

        /// A new transport epoch, as when the extension's page restarts: its tab ids may repeat.
        func restartStream() {
            epoch = UUID().uuidString
            sequence = 0
        }

        /// One report of one window, its tabs' ids from ten times its id (unique, as Safari's are),
        /// each tab `(title, origin, revision, icon)`.
        func report(_ tabs: [(String, String?, String?, String?)], window: Int = 10, at time: Double) throws {
            sequence += 1
            let described: [[String: Any]] = tabs.enumerated().map { index, tab in
                var entry: [String: Any] = ["id": window * 10 + index, "title": tab.0, "active": index == 0]
                if let origin = tab.1 { entry["origin"] = origin; entry["host"] = URL(string: origin)?.host ?? "" }
                if let revision = tab.2 { entry["rev"] = revision }
                if let icon = tab.3 { entry["icon"] = icon }
                return entry
            }
            try receive(["v": 2, "type": "state", "session": session, "time": time * 1000, "measured": time * 1000,
                "allSites": true, "order": 0, "windows": [["id": window, "tabs": described]],
                "push": ["v": 1, "browser": "safari", "epoch": epoch, "seq": sequence, "kind": "snapshot", "removed": [] as [Int]]],
                at: time)
        }

        /// A message as the extension sent it.
        func receive(_ message: [String: Any], at time: Double) throws {
            now = time
            let reply = bridge.receive(SafariExtensionMessage.decode(try JSONSerialization.data(withJSONObject: ["profile": profile, "message": message])))
            wanted = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["want"] as? [String] ?? []
            update()
        }

        func send(icons pngs: [String: Data]) throws {
            let message: [String: Any] = ["v": 2, "type": "icons", "session": session, "icons": pngs.mapValues { $0.base64EncodedString() }]
            _ = bridge.receive(SafariExtensionMessage.decode(try JSONSerialization.data(withJSONObject: ["profile": profile, "message": message])))
        }

        func read(at time: Double) {
            now = time
            observed = time
            update()
        }

        func update() {
            associations.update([.init(snapshot: native, observed: observed)], windows: bridge.windows, now: now)
        }

        /// Reports, then two reads 0.75 s apart, so the window pairs and its tabs bind by id.
        func settle(_ tabs: [(String, String?, String?, String?)], at time: Double) throws {
            try report(tabs, at: time)
            read(at: time + 0.1)
            read(at: time + 1)
        }

        /// Waits for icons read from the disk to arrive.
        func loadKeptIcons() {
            bridge.waitForKeptIcons()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        /// What the sidebar shows for each tab: an icon only once its image is here.
        var shown: [String?] {
            let published = browserTabsShown(native, read: observed, now: now, safari: associations, iconOrigins: [:])
            return published.tabs.map { tab in
                browserTabIconShown(tab, chrome: false, now: now, continuity: &continuity, origins: origins,
                    reported: { [bridge] key in bridge!.reportedTab(key) }).siteIcon.flatMap { icons.images[$0] != nil ? $0 : nil }
            }
        }
    }

    func testAGapKeepsAnUnchangedPagesIconForAWhileButNeverAPageChangeSeenBeforeIt() throws {
        let red = try png(.red)
        let p = Pipeline(cache: nil, profile: profileA)
        try p.settle([("Inbox", "https://a.test", "x-1", key(red))], at: 0)
        try p.send(icons: [key(red): red])
        XCTAssertEqual(p.shown, [key(red)])
        // A report gap: the window's report goes (another window reported instead).
        try p.report([("Other", "https://o.test", "y-1", nil)], window: 20, at: 5)
        p.read(at: 5.1)
        XCTAssertEqual(p.shown, [key(red)], "Nothing says the page changed: its own icon stays")
        p.read(at: 140)
        XCTAssertEqual(p.shown, [key(red)])
        p.read(at: 151.5)
        XCTAssertEqual(p.shown, [nil], "Not for longer than a report is kept")

        // A page change seen before the gap stays seen.
        let q = Pipeline(cache: nil, profile: profileB)
        try q.settle([("Inbox", "https://a.test", "x-1", key(red))], at: 0)
        try q.send(icons: [key(red): red])
        try q.report([("Inbox", "https://a.test", "x-2", nil)], at: 3)
        q.read(at: 3.1)
        XCTAssertEqual(q.shown, [nil], "Same address family, another revision: no icon of its own yet")
        try q.report([("Other", "https://o.test", "y-1", nil)], window: 20, at: 5)
        q.read(at: 5.1)
        XCTAssertEqual(q.shown, [nil], "The gap doesn't bring back the earlier page's icon")

        // So does another stream: the extension's page reloading without saying which page it shows.
        let r = Pipeline(cache: nil, profile: profileB)
        try r.settle([("Inbox", "https://a.test", "x-1", key(red))], at: 0)
        try r.send(icons: [key(red): red])
        r.restartStream()
        try r.settle([("Inbox", "https://a.test", "x-1", nil)], at: 3)
        XCTAssertEqual(r.shown, [nil], "Another scoped tab key is another page instance, even with the same revision text")
        try r.report([("Other", "https://o.test", "y-1", nil)], window: 20, at: 6)
        r.read(at: 6.1)
        XCTAssertEqual(r.shown, [nil])
    }

    func testAnotherPortSchemeOrAddressOnTheSameHostShowsOnlyAnIconThatPageGives() throws {
        let red = try png(.red)
        let p = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA, titles: ["Service"])
        try p.settle([("Service", "https://service.test", "x-1", key(red))], at: 0)
        try p.send(icons: [key(red): red])
        XCTAssertEqual(p.shown, [key(red)])
        var time = 2.0
        for (origin, revision) in [("https://service.test:8443", "x-2"), ("http://service.test", "x-3"), ("https://service.test", "x-4")] {
            time += 1
            try p.report([("Service", origin, revision, nil)], at: time)
            p.read(at: time + 0.1)
            XCTAssertEqual(p.shown, [nil], "\(origin) \(revision): a new page shows the app icon until the extension gives one")
        }
        XCTAssertNotNil(p.icons.images[key(red)], "The image is still here; no other page shows it")
        time += 1
        try p.report([("Service", "https://service.test", "x-4", key(red))], at: time)
        p.read(at: time + 0.1)
        XCTAssertEqual(p.shown, [key(red)], "Once the extension gives the new page an icon, it shows")
    }

    func testAPageAtAnOriginWhoseIconTheTabShowedBeforeShowsOnlyItsOwnIcon() throws {
        let alpha = try png(.red), beta = try png(.blue)
        let p = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA)
        try p.settle([("Inbox", "https://a.test", "x-1", key(alpha))], at: 0)
        try p.send(icons: [key(alpha): alpha])
        XCTAssertEqual(p.shown, [key(alpha)], "A1 shows α")
        try p.report([("Inbox", "https://b.test", "x-2", key(beta))], at: 2)
        try p.send(icons: [key(beta): beta])
        p.read(at: 2.1)
        XCTAssertEqual(p.shown, [key(beta)], "B shows β")
        try p.report([("Inbox", "https://a.test", "x-3", nil)], at: 4)
        p.read(at: 4.1)
        XCTAssertNotNil(p.icons.images[key(alpha)], "α's image is here")
        XCTAssertEqual(p.shown, [nil], "A2 named no icon of its own: the app icon, not α")
        p.restartStream()
        try p.settle([("Inbox", "https://a.test", "x-1", nil)], at: 6)
        XCTAssertEqual(p.shown, [nil], "Nor in a new stream")
        try p.report([("Inbox", "https://a.test", "x-1", key(alpha))], at: 8)
        p.read(at: 8.1)
        XCTAssertEqual(p.shown, [key(alpha)], "The page naming the same icon as its own shows it")
    }

    func testAPageNamingAKeptImageShowsItAtOnceAfterARelaunchAndNoPageShowsOneItDidntName() throws {
        let red = try png(.red)
        let first = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA)
        try first.settle([("Inbox", "https://a.test", "x-1", key(red))], at: 0)
        XCTAssertEqual(first.wanted, [key(red)])
        try first.send(icons: [key(red): red])
        XCTAssertEqual(first.shown, [key(red)])
        first.bridge.waitForKeptIcons()

        // WinMux relaunches: a new bridge over the same folder, and the extension describes the
        // same page with its icon's key.
        let p = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA)
        p.bridge.waitForKeptIcons()
        try p.settle([("Inbox", "https://a.test", "x-1", key(red))], at: 0)
        XCTAssertEqual(p.wanted, [], "WinMux doesn't ask the extension for an image it kept")
        p.loadKeptIcons()
        XCTAssertEqual(p.shown, [key(red)], "The page's own icon, from the kept image")

        // A page that names no icon shows none, though its site's image is kept.
        let q = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA)
        q.bridge.waitForKeptIcons()
        try q.settle([("Inbox", "https://a.test", "z-1", nil)], at: 0)
        q.loadKeptIcons()
        XCTAssertEqual(q.shown, [nil])
        // Another profile's page naming it waits for the extension: the image isn't that profile's.
        let other = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileB)
        other.bridge.waitForKeptIcons()
        try other.settle([("Inbox", "https://a.test", "z-1", key(red))], at: 0)
        XCTAssertEqual(other.wanted, [key(red)])
        other.loadKeptIcons()
        XCTAssertEqual(other.shown, [nil])
        // An extension from before page revisions can't say which page an icon is for: none shows.
        let old = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA)
        old.bridge.waitForKeptIcons()
        try old.settle([("Inbox", "https://a.test", nil, key(red))], at: 0)
        try old.send(icons: [key(red): red])
        old.loadKeptIcons()
        XCTAssertEqual(old.shown, [nil])
    }

    /// Chrome's icons come from Accessibility reading the selected tab's address; the extension's
    /// live report says which page instance each tab is on.
    func testChromeShowsAnOriginIconOnlyFromAReadThatStartedAfterTheLatestPageChange() {
        let target = BrowserTabTarget(windowId: 1, pid: 2, windowSession: UUID(), tabId: UUID())
        let other = BrowserTabTarget(windowId: 1, pid: 2, windowSession: target.windowSession, tabId: UUID())
        let key = SafariExtensionTabKey(source: "p:s:e", id: 7)
        let service = URL(string: "https://service.test"), b = URL(string: "https://b.test"), port = URL(string: "https://service.test:8443")
        var origins = BrowserTabIconAssociations()
        var continuity = BrowserTabSiteIconContinuity()
        var selected = true
        /// Two reads starting at `time`, 0.8 s apart, finding the selected tab at `origin`.
        func read(_ origin: URL?, at time: Double) {
            let snapshot = BrowserWindowTabs(windowId: 1, pid: 2, windowSession: target.windowSession,
                tabs: [.init(target: target, title: "Service", isSelected: selected), .init(target: other, title: "Other", isSelected: !selected)],
                iconCandidate: .init(target: selected ? target : other, origin: selected ? origin : nil))
            origins.update(snapshot, now: time + 0.1, started: time)
            origins.update(snapshot, now: time + 0.9, started: time + 0.8)
        }
        func shown(_ live: SafariExtensionTab?, at time: Double, bound: Bool = true) -> URL? {
            var tab = BrowserTab(target: target, title: "Service", isSelected: selected)
            tab.extensionTab = bound ? key : nil
            tab.iconOrigin = origins.origins[target]
            return browserTabIconShown(tab, chrome: true, now: time, continuity: &continuity, origins: origins,
                reported: { $0 == key ? live : nil }).iconOrigin
        }
        func page(_ origin: String?, _ revision: String?) -> SafariExtensionTab {
            .init(id: 7, title: "Service", host: "service.test", origin: origin, revision: revision, isActive: selected)
        }

        XCTAssertNil(shown(page("https://service.test", "x-1"), at: 0))
        read(service, at: 1)
        XCTAssertEqual(shown(page("https://service.test", "x-1"), at: 2), service, "Confirmed after the page was seen")
        XCTAssertNil(shown(page("https://service.test", "x-2"), at: 3), "Same origin, another revision (path or query): revoked")
        read(service, at: 4)
        XCTAssertEqual(shown(page("https://service.test", "x-2"), at: 5), service, "Until a read after it confirms it again")
        XCTAssertNil(shown(page("https://service.test:8443", "x-3"), at: 6), "Same host, another port")
        XCTAssertNil(shown(page("http://service.test", "x-4"), at: 7), "Same host, another scheme")
        XCTAssertNil(shown(page(nil, "x-5"), at: 8), "Not a web page")

        // Review V3, A: a confirmed icon, a live report of another page, then the report or the
        // pairing goes before any read. The revocation stands until a read after the change.
        XCTAssertNil(shown(page("https://service.test", "x-6"), at: 9))
        read(service, at: 9.5)
        XCTAssertEqual(shown(page("https://service.test", "x-6"), at: 11), service)
        XCTAssertNil(shown(page("https://b.test", "x-7"), at: 12), "B, not yet read")
        XCTAssertNil(shown(nil, at: 12.5), "The report goes: still revoked")
        XCTAssertNil(shown(nil, at: 12.5, bound: false), "So is the pairing")
        read(b, at: 13)
        XCTAssertEqual(shown(nil, at: 14, bound: false), b, "A read that started after the change shows B")
        XCTAssertEqual(shown(page("https://b.test", "x-7"), at: 14), b)

        // In the background, a page change has nothing to confirm it, before or after the report goes.
        selected = false
        read(nil, at: 15)
        XCTAssertNil(shown(page("https://b.test", "x-8"), at: 16))
        XCTAssertNil(shown(nil, at: 17))
        XCTAssertEqual(origins.origins[target], b, "What a read confirmed before is still there; it just isn't shown")

        // An extension from before page revisions: only the selected tab, from a read after the tab
        // was described. In the background, the tab goes to https://service.test:8443/next, and
        // the older extension reports only the same host.
        continuity = BrowserTabSiteIconContinuity()
        origins = BrowserTabIconAssociations()
        selected = true
        XCTAssertNil(shown(page(nil, nil), at: 20))
        read(service, at: 21)
        XCTAssertEqual(shown(page(nil, nil), at: 22), service)
        selected = false
        read(nil, at: 23)
        XCTAssertNil(shown(page(nil, nil), at: 24), "Same host, another port: the host proves nothing")
        XCTAssertNil(shown(nil, at: 24, bound: false), "Nor once the extension no longer pairs the tab")
        selected = true
        read(port, at: 25)
        XCTAssertEqual(shown(page(nil, nil), at: 26), port, "Selected again, a fresh read shows the page's own origin")

        // A tab the extension never described keeps its icon as without the extension.
        continuity = BrowserTabSiteIconContinuity()
        selected = false
        read(nil, at: 30)
        XCTAssertEqual(shown(nil, at: 31, bound: false), port)
    }

    func testOriginsAndRevisionsAreCheckedAsTheyArrive() throws {
        XCTAssertEqual(browserTabOriginKey("HTTPS://Example.TEST:443"), "https://example.test")
        XCTAssertEqual(browserTabOriginKey("http://a.test:80/"), "http://a.test")
        XCTAssertEqual(browserTabOriginKey("https://a.test:8443"), "https://a.test:8443")
        XCTAssertEqual(browserTabOriginKey("https://[::1]:8443"), "https://[::1]:8443")
        for refused in ["https://a.test/path", "https://user@a.test", "ftp://a.test", "https://a.test?q=1", "https://a.test#x", "a.test", ""] {
            XCTAssertNil(browserTabOriginKey(refused), refused)
        }
        let message: [String: Any] = ["v": 2, "type": "state", "session": "s", "time": 1, "windows": [["id": 1, "tabs": [
            ["id": 1, "title": "A", "active": true, "origin": "https://a.test/secret/path", "rev": "x-1"],
            ["id": 2, "title": "B", "active": false, "origin": "https://b.test", "rev": "../../x"],
            ["id": 3, "title": "C", "active": false, "origin": "https://c.test:443", "rev": String(repeating: "a", count: 33)],
            ["id": 4, "title": "D", "active": false, "origin": "https://d.test", "rev": "ab12cd34-7"],
        ]]]]
        guard case .state(let state) = SafariExtensionMessage.decode(try envelope(message, profile: profileA)) else { return XCTFail() }
        let tabs = state.windows[0].tabs
        XCTAssertEqual(tabs.map(\.origin), [nil, "https://b.test", "https://c.test", "https://d.test"], "A path is never taken as an origin")
        XCTAssertEqual(tabs.map(\.revision), ["x-1", nil, nil, "ab12cd34-7"])
    }

    // MARK: - The Safari extension page itself

    /// A Safari extension page, in JavaScriptCore with synthetic browser APIs, its clock starting
    /// at `start` seconds, with one window WinMux pairs by its tabs (no frames to compare bounds
    /// with here) whose tab 10 is at `address`.
    private func safariPage(at start: Double, address: String, then setup: String = "") throws -> JSContext {
        try BrowserPushBackgroundTest.page("safari", before: """
            now = \(Int(start * 1000));
            windows = windows.slice(0, 1);
            for (const field of ['left', 'top', 'width', 'height']) delete windows[0][field];
            Object.assign(windows[0].tabs[0], { url: '\(address)', active: true });
            function latest() { return sent.filter(m => m.type === 'state' || m.type === 'events').at(-1); }
            function tab10() { return latest().windows[0].tabs[0]; }
            function go(url) { Object.assign(windows[0].tabs[0], { url }); browser.tabs.onUpdated.fire(10, { url }, windows[0].tabs[0]); }
            function names(page, candidate) {
                browser.runtime.onMessage.fire({ type: 'winmux-icon-candidates', page, report: 1, address: windows[0].tabs[0].url,
                    candidates: [candidate] }, { tab: copy(windows[0].tabs[0]), url: windows[0].tabs[0].url, frameId: 0 });
            }
            \(setup)
            """)
    }

    /// WinMux takes in the page's latest report, by the page's clock, and reads the window twice.
    private func take(_ c: JSContext, into p: Pipeline) throws {
        let json = try XCTUnwrap(c.evaluateScript("JSON.stringify(latest())")?.toString())
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let time = (c.evaluateScript("now")?.toDouble() ?? 0) / 1000
        p.session = try XCTUnwrap(message["session"] as? String)
        try p.receive(message, at: time)
        p.read(at: time + 0.1)
        p.read(at: time + 1)
    }

    /// Runs `js` in the page once WinMux's reads are behind it.
    private func step(_ c: JSContext, _ js: String) throws {
        try BrowserPushBackgroundTest.advance(c, 2)
        c.evaluateScript(js)
        try BrowserPushBackgroundTest.advance(c)
    }

    private func tab10(_ c: JSContext) throws -> [String: Any] {
        let json = try XCTUnwrap(c.evaluateScript("JSON.stringify(tab10())")?.toString())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// The shipped page with its session storage seeded with the icon the tab's page made, and the
    /// icons an earlier version kept by origin and by tab; its actual reports go to the native path.
    func testTheSafariExtensionsReportsAfterAnAddressChangeShowTheAppIconUntilTheNewPageNamesItsIcon() throws {
        let red = try png(.red), blue = try png(.blue), green = try png(.green)
        let c = try safariPage(at: 10, address: "https://example.test/tenant-a", then: """
            storage = { session: 'seeded', order: 0,
                tabPages: { 10: { address: 'https://example.test/tenant-a', revision: 'seeded-1', icon: '\(key(red))' } },
                icons: { '\(key(red))': { png: '\(red.base64EncodedString())', used: now } },
                tabIcons: { 10: { key: '\(key(red))', origin: 'https://example.test' } },
                originIcons: { 'https://example.test': { key: '\(key(red))', used: now } } };
            """)
        let p = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA, titles: ["Synthetic 1"])
        try take(c, into: p)
        try p.send(icons: [key(red): red])
        var tab = try tab10(c)
        XCTAssertEqual(tab["rev"] as? String, "seeded-1", "The same page, still at its address, as saved")
        XCTAssertEqual(tab["icon"] as? String, key(red))
        XCTAssertNil(tab["first"])
        XCTAssertEqual(p.shown, [key(red)], "The page that made the icon shows it")

        // The tab commits another address on the same origin: only the path and query change.
        try step(c, "go('https://example.test/tenant-b?q=1')")
        tab = try tab10(c)
        let moved = try XCTUnwrap(tab["rev"] as? String)
        XCTAssertNotEqual(moved, "seeded-1")
        XCTAssertNil(tab["icon"], "No icon: neither the page's before, nor one by origin or by tab from before")
        XCTAssertEqual(c.evaluateScript("JSON.stringify(storage.tabPages[10])")?.toString(),
                       #"{"address":"https://example.test/tenant-b?q=1","revision":"\#(moved)"}"#)
        try take(c, into: p)
        XCTAssertNotNil(p.icons.images[key(red)], "The image is still here, and isn't used")
        XCTAssertEqual(p.shown, [nil], "The app icon")

        // An icon finished after the tab moved on, even back to the same address, isn't the page's.
        try step(c, """
            var release; iconMade = () => new Promise(done => { release = () => done({ key: '\(key(green))', png: '\(green.base64EncodedString())' }); });
            names('slow', 'https://example.test/slow.png');
            """)
        try step(c, "go('https://example.test/tenant-c'); go('https://example.test/tenant-b?q=1');")
        try step(c, "release()")
        XCTAssertNil(try tab10(c)["icon"])
        XCTAssertEqual(c.evaluateScript("String(storage.tabPages[10].icon)")?.toString(), "undefined")
        try take(c, into: p)
        XCTAssertEqual(p.shown, [nil])

        // The page names its icon: made for this revision, it shows.
        try step(c, """
            iconMade = async () => ({ key: '\(key(blue))', png: '\(blue.base64EncodedString())' });
            names('b', 'https://example.test/b.png');
            """)
        tab = try tab10(c)
        XCTAssertEqual(tab["icon"] as? String, key(blue))
        XCTAssertEqual(c.evaluateScript("storage.tabPages[10].revision")?.toString(), tab["rev"] as? String)
        try take(c, into: p)
        try p.send(icons: [key(blue): blue])
        XCTAssertEqual(p.shown, [key(blue)])
    }

    /// Review V3, B: Safari can't save the tab's page change, and its extension page unloads before
    /// saving anything else. Nothing from before the change comes back: not the page's revision,
    /// nor its icon, even with the tab back at that address.
    func testASafariPageChangeThatCantBeSavedBringsBackNeitherTheOldRevisionNorItsIcon() throws {
        let red = try png(.red)
        let c = try safariPage(at: 10, address: "https://a.test/")
        let p = Pipeline(cache: nil, profile: profileA, titles: ["Synthetic 1"])
        try take(c, into: p)
        try step(c, """
            iconMade = async () => ({ key: '\(key(red))', png: '\(red.base64EncodedString())' });
            names('a', 'https://a.test/a.png');
            """)
        let before = try tab10(c)
        XCTAssertEqual(before["icon"] as? String, key(red))
        try take(c, into: p)
        try p.send(icons: [key(red): red])
        XCTAssertEqual(p.shown, [key(red)])

        try step(c, "failTabPages = 1; go('https://b.test/');")
        XCTAssertEqual(c.evaluateScript("'tabPages' in storage")?.toBool(), false,
                       "Pages that couldn't be saved are removed, not left as they were before")
        // The page unloads; Safari loads it again with what's saved, the tab back at a.test.
        let stored = try XCTUnwrap(c.evaluateScript("JSON.stringify(storage)")?.toString())
        let reloaded = try safariPage(at: 30, address: "https://a.test/", then: "storage = \(stored);")
        let after = try tab10(reloaded)
        XCTAssertNotEqual(after["rev"] as? String, before["rev"] as? String, "A revision no load made before")
        XCTAssertNil(after["icon"])
        try take(reloaded, into: p)
        XCTAssertEqual(p.shown, [nil])
    }

    // MARK: - Bounded memory

    func testTheBridgesIndexesStayBoundedAcrossManySitesEpochsAndIconChanges() throws {
        let colors = (0..<4).map { NSColor(red: CGFloat($0) / 4, green: 0.5, blue: 0.5, alpha: 1) }
        let pngs = try colors.map(png)
        let p = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA)
        // Thousands of sites, half with an icon.
        for index in 0..<3000 {
            let icon = index % 2 == 0 ? key(pngs[index % 4]) : nil
            try p.report([("Site \(index)", "https://site\(index).test", "r-\(index)", icon)], at: Double(index))
            if index < 4 { try p.send(icons: [key(pngs[index]): pngs[index]]) }
            if index % 500 == 0 { p.restartStream() }
        }
        p.bridge.waitForKeptIcons()
        let counts = p.bridge.iconIndexCounts
        XCTAssertLessThanOrEqual(counts.asked, 1024)
        XCTAssertLessThanOrEqual(counts.written, 1024)
        XCTAssertLessThanOrEqual(counts.thumbnails, SafariExtensionBridge.maximumImages)

        // One page whose icon keeps changing: the indexes don't grow past their bounds, and the latest shows.
        let q = Pipeline(cache: BrowserTabIconDiskCache(directory: directory.appendingPathComponent("changes")), profile: profileB)
        var latest = ""
        for index in 0..<1100 {
            let image = try png(NSColor(red: CGFloat(index % 255) / 255, green: CGFloat(index / 255) / 6, blue: 0.2, alpha: 1))
            latest = key(image)
            if index == 0 {
                try q.settle([("Inbox", "https://a.test", "r-1", latest)], at: 0)
            } else {
                try q.report([("Inbox", "https://a.test", "r-1", latest)], at: Double(index))
            }
            try q.send(icons: [latest: image])
        }
        q.read(at: 1200)
        XCTAssertEqual(q.shown, [latest], "The current icon still updates")
        let changed = q.bridge.iconIndexCounts
        XCTAssertLessThanOrEqual(changed.written, 1024)
        XCTAssertLessThanOrEqual(q.icons.images.count, SafariExtensionBridge.maximumImages)
        XCTAssertLessThanOrEqual(changed.thumbnails, SafariExtensionBridge.maximumImages)
    }

    func testRecencyKeepsAtMostItsCapacityAndDropsUnusedEntries() {
        var recency = BrowserTabRecency<Int, Int>(capacity: 8, lifetime: 10)
        for index in 0..<100 { recency.set(index, index, now: Double(index) / 100) }
        XCTAssertLessThanOrEqual(recency.count, 8)
        XCTAssertEqual(recency.peek(99, now: 1), 99, "The most recent stay")
        XCTAssertNil(recency.peek(0, now: 1))
        XCTAssertNil(recency.value(99, now: 20), "Unused for its lifetime")
    }
}
