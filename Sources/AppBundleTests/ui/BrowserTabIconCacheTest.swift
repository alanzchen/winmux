import AppKit
@testable import AppBundle
import CryptoKit
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

    func testKeptIconsSurviveARelaunchOnlyInTheirOwnProfileBrowserAndOrigin() throws {
        let red = try icon(.red)
        BrowserTabIconDiskCache(directory: directory).store(partition: try partition(profileA), origin: "https://example.test", icon: red.key, png: red.png)
        let relaunched = BrowserTabIconDiskCache(directory: directory)
        let found = try XCTUnwrap(relaunched.icon(partition: try partition(profileA), origin: "HTTPS://Example.TEST:443"))
        XCTAssertEqual(found.key, red.key)
        XCTAssertEqual(found.png, red.png)
        XCTAssertNil(relaunched.icon(partition: try partition(profileB), origin: "https://example.test"), "Never another profile's")
        XCTAssertNil(relaunched.icon(partition: try partition(profileA, browser: "chrome"), origin: "https://example.test"), "Never another browser's")
        XCTAssertNil(relaunched.icon(partition: try partition(profileA), origin: "https://other.test"))
        for other in ["https://example.test:8443", "http://example.test", "https://example.test/path"] {
            XCTAssertNil(relaunched.icon(partition: try partition(profileA), origin: other), "Another origin, or not an origin: \(other)")
        }
    }

    func testTheDiskHoldsNoHostNamesTitlesOrAddressesAndOnlyTheUserCanReadIt() throws {
        let red = try icon(.red)
        let cache = BrowserTabIconDiskCache(directory: directory)
        cache.store(partition: try partition(profileA), origin: "https://private-bank.example", icon: red.key, png: red.png)
        let manager = FileManager.default
        var files: [URL] = []
        for case let url as URL in try XCTUnwrap(manager.enumerator(at: directory, includingPropertiesForKeys: nil)) { files.append(url) }
        let base = directory.resolvingSymlinksInPath().path + "/"
        let names = files.map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") }.sorted()
        XCTAssertEqual(names, ["icons", "icons/\(red.key).png", "index.json", "key"])
        for file in files where !file.hasDirectoryPath {
            let bytes = try Data(contentsOf: file)
            for secret in ["private-bank", profileA, "safari:"] {
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
        cache.store(partition: try partition(profileA), origin: "https://red.test", icon: red.key, png: red.png)
        cache.store(partition: try partition(profileA), origin: "https://blue.test", icon: blue.key, png: blue.png)
        // Another image under the red icon's name, and the blue one gone.
        try blue.png.write(to: directory.appendingPathComponent("icons/\(red.key).png"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("icons/\(blue.key).png"))
        let relaunched = BrowserTabIconDiskCache(directory: directory)
        XCTAssertNil(relaunched.icon(partition: try partition(profileA), origin: "https://red.test"))
        XCTAssertNil(relaunched.icon(partition: try partition(profileA), origin: "https://blue.test"))
        // Only icons the extension's key could name, of bounded size, that decode, are kept.
        cache.store(partition: try partition(profileA), origin: "https://bad.test", icon: "../../etc", png: red.png)
        cache.store(partition: try partition(profileA), origin: "https://text.test", icon: red.key, png: Data("not an image".utf8))
        XCTAssertNil(cache.icon(partition: try partition(profileA), origin: "https://bad.test"))
        XCTAssertNil(cache.icon(partition: try partition(profileA), origin: "https://text.test"))
    }

    func testLeastRecentlyUsedSitesAndOldOnesAreDroppedWithinTheBounds() throws {
        var now = 1_000.0
        let colors: [NSColor] = [.red, .green, .blue, .yellow]
        let icons = try colors.map(icon)
        let cache = BrowserTabIconDiskCache(directory: directory, maximumEntries: 3, lifetime: 100, clock: { now })
        for (index, icon) in icons.prefix(3).enumerated() {
            now += 1
            cache.store(partition: try partition(profileA), origin: "https://site\(index).test", icon: icon.key, png: icon.png)
        }
        now += 1
        XCTAssertNotNil(cache.icon(partition: try partition(profileA), origin: "https://site0.test"), "Reading a site counts as using it")
        now += 1
        cache.store(partition: try partition(profileA), origin: "https://site3.test", icon: icons[3].key, png: icons[3].png)
        XCTAssertNil(cache.icon(partition: try partition(profileA), origin: "https://site1.test"), "The least recently used goes first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("icons/\(icons[1].key).png").path),
                       "and its image with it")
        for host in ["site0.test", "site2.test", "site3.test"] {
            XCTAssertNotNil(cache.icon(partition: try partition(profileA), origin: "https://" + host), host)
        }
        now += 100
        XCTAssertNil(cache.icon(partition: try partition(profileA), origin: "https://site3.test"), "A site unused for its lifetime goes")
        // Not just unreadable: pruning deletes expired sites' images from the disk.
        cache.prune()
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("icons").path)
        XCTAssertEqual(left, [], "Every site expired, so every image is deleted")

        // The byte bound, across distinct images.
        let small = BrowserTabIconDiskCache(directory: directory.appendingPathComponent("bytes"),
            maximumBytes: icons[0].png.count + icons[1].png.count, clock: { now })
        for (index, icon) in icons.prefix(3).enumerated() {
            now += 1
            small.store(partition: try partition(profileA), origin: "https://b\(index).test", icon: icon.key, png: icon.png)
        }
        XCTAssertNil(small.icon(partition: try partition(profileA), origin: "https://b0.test"))
        XCTAssertNotNil(small.icon(partition: try partition(profileA), origin: "https://b2.test"))
    }

    func testOnlyProfilesThatLastArePartitionsAndRemovalWipesEverything() throws {
        XCTAssertNotNil(BrowserTabIconDiskCache.partition(browser: "safari", profile: profileA))
        XCTAssertNotNil(BrowserTabIconDiskCache.partition(browser: "safari", profile: "profile:Work"))
        XCTAssertNil(BrowserTabIconDiskCache.partition(browser: "safari", profile: "session:abc"), "A session-only scope isn't kept")
        let red = try icon(.red)
        let cache = BrowserTabIconDiskCache(directory: directory)
        cache.store(partition: try partition(profileA), origin: "https://example.test", icon: red.key, png: red.png)
        cache.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(BrowserTabIconDiskCache(directory: directory).icon(partition: try partition(profileA), origin: "https://example.test"))
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
        XCTAssertNil(BrowserTabIconDiskCache(directory: directory).icon(partition: try partition(profileA), origin: "https://private.test"))
        // A normal window's icon is kept, and turning browser tabs off removes everything.
        var normal = tab
        normal["title"] = "Example"
        normal["origin"] = "https://example.test"
        _ = safari.receive(SafariExtensionMessage.decode(try envelope(state([normal]), profile: profileA)))
        _ = safari.receive(SafariExtensionMessage.decode(try envelope(
            ["v": 2, "type": "icons", "session": "s", "icons": [redKey: original.base64EncodedString()]], profile: profileA)))
        safari.waitForKeptIcons()
        XCTAssertNotNil(BrowserTabIconDiskCache(directory: directory).icon(partition: try partition(profileA), origin: "https://example.test"))
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
            now = time
            sequence += 1
            let described: [[String: Any]] = tabs.enumerated().map { index, tab in
                var entry: [String: Any] = ["id": window * 10 + index, "title": tab.0, "active": index == 0]
                if let origin = tab.1 { entry["origin"] = origin; entry["host"] = URL(string: origin)?.host ?? "" }
                if let revision = tab.2 { entry["rev"] = revision }
                if let icon = tab.3 { entry["icon"] = icon }
                return entry
            }
            let message: [String: Any] = ["v": 2, "type": "state", "session": session, "time": time * 1000, "measured": time * 1000,
                "allSites": true, "order": 0, "windows": [["id": window, "tabs": described]],
                "push": ["v": 1, "browser": "safari", "epoch": epoch, "seq": sequence, "kind": "snapshot", "removed": [] as [Int]]]
            _ = bridge.receive(SafariExtensionMessage.decode(try JSONSerialization.data(withJSONObject: ["profile": profile, "message": message])))
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

        var shown: [String?] {
            let published = browserTabsShown(native, read: observed, now: now, safari: associations, iconOrigins: [:])
            return published.tabs.map { tab in
                browserTabIconShown(tab, chrome: false, continuity: &continuity, origins: &origins,
                    reported: { [bridge] key in bridge!.reportedTab(key) },
                    keptIcon: { [bridge] key, origin in bridge!.siteIcon(source: key.source, origin: origin) }).siteIcon
            }
        }
    }

    func testANavigationToAnotherSiteUnderTheSameTitleNeverShowsTheOldIconEvenAcrossAGap() throws {
        let red = try png(.red)
        let p = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA)
        try p.settle([("Inbox", "https://a.test", "x-1", key(red))], at: 0)
        try p.send(icons: [key(red): red])
        XCTAssertEqual(p.shown, [key(red)])
        // A report gap: the window's report goes (another window reported instead). The association
        // still describes the row for a few seconds, but no live report has the tab: app icon.
        try p.report([("Other", "https://o.test", "y-1", nil)], window: 20, at: 5)
        p.read(at: 5.1)
        XCTAssertEqual(p.shown, [nil], "No live page evidence: the app icon, not the icon from before")
        // Meanwhile the tab went to another site; its title is still Inbox.
        try p.settle([("Inbox", "https://b.test", "x-2", nil)], at: 6)
        XCTAssertEqual(p.shown, [nil], "Same title, same native tab, another site: never a.test's icon")

        // The same page across a gap keeps its icon: its revision says nothing was committed.
        let q = Pipeline(cache: nil, profile: profileB)
        try q.settle([("Inbox", "https://a.test", "x-1", key(red))], at: 0)
        try q.send(icons: [key(red): red])
        XCTAssertEqual(q.shown, [key(red)])
        try q.report([("Other", "https://o.test", "y-1", nil)], window: 20, at: 5)
        q.read(at: 5.1)
        XCTAssertEqual(q.shown, [nil])
        try q.settle([("Inbox", "https://a.test", "x-1", nil)], at: 6)
        XCTAssertEqual(q.shown, [key(red)], "The same scoped tab and revision, reported without an icon, keeps it")
    }

    func testAnotherPortSchemeOrAddressOnTheSameHostDropsTheIconAndTheFallbackNeverRestoresIt() throws {
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
        XCTAssertNotNil(p.bridge.siteIcon(source: "\(p.profile):\(p.session):\(p.epoch)", origin: "https://service.test"),
                        "service.test's kept icon still exists; it just isn't brought back to the page that dropped it")
        time += 1
        try p.report([("Service", "https://service.test", "x-4", key(red))], at: time)
        p.read(at: time + 0.1)
        XCTAssertEqual(p.shown, [key(red)], "Once the extension gives the new page an icon, it shows")
    }

    func testTheSameNativeTabUnderAnotherExtensionTabKeyStartsOver() throws {
        let red = try png(.red), blue = try png(.blue)
        let p = Pipeline(cache: nil, profile: profileA)
        try p.settle([("Inbox", "https://a.test", "x-1", key(red))], at: 0)
        try p.send(icons: [key(red): red])
        XCTAssertEqual(p.shown, [key(red)])
        // The extension's page restarts: a new epoch, where tab id 100 and revision x-1 can repeat.
        p.restartStream()
        try p.settle([("Inbox", "https://a.test", "x-1", nil)], at: 5)
        XCTAssertEqual(p.shown, [nil], "Another scoped tab key isn't the page that had the icon")
        try p.report([("Inbox", "https://a.test", "x-1", key(blue))], at: 7)
        try p.send(icons: [key(blue): blue])
        p.read(at: 7.1)
        XCTAssertEqual(p.shown, [key(blue)])
    }

    func testAKeptIconShowsOnlyForAPageThatHadNoneAndOldExtensionsGetNoContinuity() throws {
        let red = try png(.red)
        let first = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA)
        try first.settle([("Inbox", "https://a.test", "x-1", key(red))], at: 0)
        try first.send(icons: [key(red): red])
        first.bridge.waitForKeptIcons()

        // Relaunched: the page is open but the restarted extension describes it without an icon.
        let p = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA)
        try p.settle([("Inbox", "https://a.test", "z-1", nil)], at: 0)
        p.bridge.waitForKeptIcons()
        for _ in 0..<50 where p.shown == [nil] { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(p.shown, [key(red)], "Its origin's kept icon")
        // The tab commits another address on the same origin: what it showed is revoked.
        try p.report([("Inbox", "https://a.test", "z-2", nil)], at: 3)
        p.read(at: 3.1)
        XCTAssertEqual(p.shown, [nil], "The fallback never brings back the icon the previous page showed")
        // Another profile's tab on the same origin gets nothing kept by profile A.
        let other = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileB)
        try other.settle([("Inbox", "https://a.test", "z-1", nil)], at: 0)
        other.bridge.waitForKeptIcons()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(other.shown, [nil])

        // An extension from before page revisions: only what it says now, no fallback.
        let old = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA)
        try old.settle([("Inbox", nil, nil, key(red))], at: 0)
        try old.send(icons: [key(red): red])
        XCTAssertEqual(old.shown, [key(red)])
        try old.report([("Inbox", nil, nil, nil)], at: 3)
        old.read(at: 3.1)
        XCTAssertEqual(old.shown, [nil], "An omitted icon isn't kept without page evidence")
        try old.report([("Inbox", nil, nil, key(red))], at: 4)
        old.read(at: 4.1)
        XCTAssertEqual(old.shown, [key(red)])
        try old.report([("Other", nil, nil, nil)], window: 20, at: 5)
        old.read(at: 5.1)
        XCTAssertEqual(old.shown, [nil], "Nor across a report gap, while its window still keeps its pairing")
    }

    func testChromeComparesTheFullOriginFromTheLiveReport() {
        let target = BrowserTabTarget(windowId: 1, pid: 2, windowSession: UUID(), tabId: UUID())
        let key = SafariExtensionTabKey(source: "p:s:e", id: 7)
        var origins = BrowserTabIconAssociations()
        let read = BrowserWindowTabs(windowId: 1, pid: 2, windowSession: target.windowSession,
            tabs: [.init(target: target, title: "Service", isSelected: true)],
            iconCandidate: .init(target: target, origin: URL(string: "https://service.test")))
        var continuity = BrowserTabSiteIconContinuity()
        func shown(_ live: SafariExtensionTab?) -> URL? {
            origins.update(read, now: 0)
            origins.update(read, now: 1)
            var tab = BrowserTab(target: target, title: "Service", isSelected: true)
            tab.extensionTab = key
            tab.iconOrigin = origins.origins[target]
            return browserTabIconShown(tab, chrome: true, continuity: &continuity, origins: &origins,
                reported: { $0 == key ? live : nil }, keptIcon: { _, _ in nil }).iconOrigin
        }
        func live(_ origin: String?, revision: String? = "x-1", host: String? = "service.test") -> SafariExtensionTab {
            .init(id: 7, title: "Service", host: host, origin: origin, revision: revision, isActive: true)
        }
        XCTAssertEqual(shown(live("https://service.test")), URL(string: "https://service.test"))
        XCTAssertNil(shown(live("https://service.test:8443")), "Same host, another port")
        XCTAssertNil(shown(live("http://service.test")), "Same host, another scheme")
        XCTAssertNil(shown(live(nil, host: nil)), "Not a web page")
        XCTAssertEqual(shown(nil), URL(string: "https://service.test"), "No live report: the AX origin stands")
        XCTAssertEqual(shown(live(nil, revision: nil)), URL(string: "https://service.test"),
                       "An older extension sends only the host, which still matches")
        XCTAssertNil(shown(live(nil, revision: nil, host: "news.test")))
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

    // MARK: - Bounded memory

    func testTheBridgesIndexesStayBoundedAcrossManySitesEpochsAndIconChanges() throws {
        let colors = (0..<4).map { NSColor(red: CGFloat($0) / 4, green: 0.5, blue: 0.5, alpha: 1) }
        let pngs = try colors.map(png)
        let p = Pipeline(cache: BrowserTabIconDiskCache(directory: directory), profile: profileA)
        // Thousands of sites, half with an icon, half without (each asked of the disk once).
        for index in 0..<3000 {
            let icon = index % 2 == 0 ? key(pngs[index % 4]) : nil
            try p.report([("Site \(index)", "https://site\(index).test", "r-\(index)", icon)], at: Double(index))
            if index < 4 { try p.send(icons: [key(pngs[index]): pngs[index]]) }
            if index % 500 == 0 { p.restartStream() }
        }
        p.bridge.waitForKeptIcons()
        let counts = p.bridge.siteIndexCounts
        XCTAssertLessThanOrEqual(counts.sites, 1024)
        XCTAssertLessThanOrEqual(counts.asked, 1024)
        XCTAssertLessThanOrEqual(counts.written, 1024)
        XCTAssertEqual(counts.sources, 1, "Only the live report's source, not every epoch's")
        XCTAssertLessThanOrEqual(counts.thumbnails, SafariExtensionBridge.maximumImages)

        // One site whose icon keeps changing: the indexes don't grow, and the latest shows.
        let q = Pipeline(cache: BrowserTabIconDiskCache(directory: directory.appendingPathComponent("changes")), profile: profileB)
        var latest = ""
        for index in 0..<600 {
            let image = try png(NSColor(red: CGFloat(index % 255) / 255, green: CGFloat(index / 255) / 3, blue: 0.2, alpha: 1))
            latest = key(image)
            if index == 0 {
                try q.settle([("Inbox", "https://a.test", "r-1", latest)], at: 0)
            } else {
                try q.report([("Inbox", "https://a.test", "r-1", latest)], at: Double(index))
            }
            try q.send(icons: [latest: image])
        }
        q.read(at: 700)
        XCTAssertEqual(q.shown, [latest], "The current icon still updates")
        XCTAssertEqual(q.bridge.siteIcon(source: "\(q.profile):\(q.session):\(q.epoch)", origin: "https://a.test"), latest)
        let changed = q.bridge.siteIndexCounts
        XCTAssertEqual(changed.sites, 1)
        XCTAssertLessThanOrEqual(changed.written, 1)
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
