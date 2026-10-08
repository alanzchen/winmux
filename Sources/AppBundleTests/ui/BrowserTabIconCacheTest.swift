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

    func testKeptIconsSurviveARelaunchOnlyInTheirOwnProfileAndBrowser() throws {
        let red = try icon(.red)
        BrowserTabIconDiskCache(directory: directory).store(partition: try partition(profileA), host: "example.test", icon: red.key, png: red.png)
        let relaunched = BrowserTabIconDiskCache(directory: directory)
        let found = try XCTUnwrap(relaunched.icon(partition: try partition(profileA), host: "Example.TEST"))
        XCTAssertEqual(found.key, red.key)
        XCTAssertEqual(found.png, red.png)
        XCTAssertNil(relaunched.icon(partition: try partition(profileB), host: "example.test"), "Never another profile's")
        XCTAssertNil(relaunched.icon(partition: try partition(profileA, browser: "chrome"), host: "example.test"), "Never another browser's")
        XCTAssertNil(relaunched.icon(partition: try partition(profileA), host: "other.test"))
    }

    func testTheDiskHoldsNoHostNamesTitlesOrAddressesAndOnlyTheUserCanReadIt() throws {
        let red = try icon(.red)
        let cache = BrowserTabIconDiskCache(directory: directory)
        cache.store(partition: try partition(profileA), host: "private-bank.example", icon: red.key, png: red.png)
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
        cache.store(partition: try partition(profileA), host: "red.test", icon: red.key, png: red.png)
        cache.store(partition: try partition(profileA), host: "blue.test", icon: blue.key, png: blue.png)
        // Another image under the red icon's name, and the blue one gone.
        try blue.png.write(to: directory.appendingPathComponent("icons/\(red.key).png"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("icons/\(blue.key).png"))
        let relaunched = BrowserTabIconDiskCache(directory: directory)
        XCTAssertNil(relaunched.icon(partition: try partition(profileA), host: "red.test"))
        XCTAssertNil(relaunched.icon(partition: try partition(profileA), host: "blue.test"))
        // Only icons the extension's key could name, of bounded size, that decode, are kept.
        cache.store(partition: try partition(profileA), host: "bad.test", icon: "../../etc", png: red.png)
        cache.store(partition: try partition(profileA), host: "text.test", icon: red.key, png: Data("not an image".utf8))
        XCTAssertNil(cache.icon(partition: try partition(profileA), host: "bad.test"))
        XCTAssertNil(cache.icon(partition: try partition(profileA), host: "text.test"))
    }

    func testLeastRecentlyUsedSitesAndOldOnesAreDroppedWithinTheBounds() throws {
        var now = 1_000.0
        let colors: [NSColor] = [.red, .green, .blue, .yellow]
        let icons = try colors.map(icon)
        let cache = BrowserTabIconDiskCache(directory: directory, maximumEntries: 3, lifetime: 100, clock: { now })
        for (index, icon) in icons.prefix(3).enumerated() {
            now += 1
            cache.store(partition: try partition(profileA), host: "site\(index).test", icon: icon.key, png: icon.png)
        }
        now += 1
        XCTAssertNotNil(cache.icon(partition: try partition(profileA), host: "site0.test"), "Reading a site counts as using it")
        now += 1
        cache.store(partition: try partition(profileA), host: "site3.test", icon: icons[3].key, png: icons[3].png)
        XCTAssertNil(cache.icon(partition: try partition(profileA), host: "site1.test"), "The least recently used goes first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("icons/\(icons[1].key).png").path),
                       "and its image with it")
        for host in ["site0.test", "site2.test", "site3.test"] {
            XCTAssertNotNil(cache.icon(partition: try partition(profileA), host: host), host)
        }
        now += 100
        XCTAssertNil(cache.icon(partition: try partition(profileA), host: "site3.test"), "A site unused for its lifetime goes")

        // The byte bound, across distinct images.
        let small = BrowserTabIconDiskCache(directory: directory.appendingPathComponent("bytes"),
            maximumBytes: icons[0].png.count + icons[1].png.count, clock: { now })
        for (index, icon) in icons.prefix(3).enumerated() {
            now += 1
            small.store(partition: try partition(profileA), host: "b\(index).test", icon: icon.key, png: icon.png)
        }
        XCTAssertNil(small.icon(partition: try partition(profileA), host: "b0.test"))
        XCTAssertNotNil(small.icon(partition: try partition(profileA), host: "b2.test"))
    }

    func testOnlyProfilesThatLastArePartitionsAndRemovalWipesEverything() throws {
        XCTAssertNotNil(BrowserTabIconDiskCache.partition(browser: "safari", profile: profileA))
        XCTAssertNotNil(BrowserTabIconDiskCache.partition(browser: "safari", profile: "profile:Work"))
        XCTAssertNil(BrowserTabIconDiskCache.partition(browser: "safari", profile: "session:abc"), "A session-only scope isn't kept")
        let red = try icon(.red)
        let cache = BrowserTabIconDiskCache(directory: directory)
        cache.store(partition: try partition(profileA), host: "example.test", icon: red.key, png: red.png)
        cache.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(BrowserTabIconDiskCache(directory: directory).icon(partition: try partition(profileA), host: "example.test"))
    }

    // MARK: - Bridge

    private func envelope(_ message: [String: Any], profile: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["message": message, "profile": profile])
    }

    private func state(_ tabs: [[String: Any]], session: String = "s", incognito: Bool = false) -> [String: Any] {
        ["v": 1, "type": "state", "session": session, "time": 5, "allSites": true,
         "windows": [["id": 1, "incognito": incognito, "tabs": tabs]]]
    }

    func testABridgeKeepsASitesIconAndShowsItAfterARelaunchOnlyInItsProfile() async throws {
        let original = try png(.red)
        let redKey = key(original)
        let cache = BrowserTabIconDiskCache(directory: directory)
        let first = SafariExtensionBridge(configuration: { nil }, icons: SafariExtensionIcons(), iconCache: cache, now: { 1 })
        first.setEnabled(true)
        _ = first.receive(SafariExtensionMessage.decode(try envelope(state([
            ["title": "Example", "host": "example.test", "active": true, "icon": redKey]]), profile: profileA)))
        _ = first.receive(SafariExtensionMessage.decode(try envelope(
            ["v": 1, "type": "icons", "session": "s", "icons": [redKey: original.base64EncodedString()]], profile: profileA)))
        first.waitForKeptIcons()

        // Relaunched: the extension restarted too, and describes the page without an icon.
        let icons = SafariExtensionIcons()
        let second = SafariExtensionBridge(configuration: { nil }, icons: icons, iconCache: BrowserTabIconDiskCache(directory: directory), now: { 1 })
        second.setEnabled(true)
        _ = second.receive(SafariExtensionMessage.decode(try envelope(state([
            ["title": "Example", "host": "example.test", "active": true]], session: "t"), profile: profileA)))
        _ = second.receive(SafariExtensionMessage.decode(try envelope(state([
            ["title": "Example", "host": "example.test", "active": true]], session: "u"), profile: profileB)))
        second.waitForKeptIcons()
        for _ in 0..<50 where second.siteIcon(source: "\(profileA):t", host: "example.test") == nil { await Task.yield() }
        XCTAssertEqual(second.siteIcon(source: "\(profileA):t", host: "example.test"), redKey)
        XCTAssertNotNil(icons.images[redKey])
        XCTAssertNil(second.siteIcon(source: "\(profileB):u", host: "example.test"), "Another profile's tab of the site gets none")
        XCTAssertNil(second.siteIcon(source: "\(profileA):t", host: "other.test"))
        // Turning browser tabs off forgets them.
        second.removeKeptIcons()
        second.waitForKeptIcons()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPrivateWindowsAndChromeNeverReachTheDisk() throws {
        let original = try png(.red)
        let redKey = key(original)
        let safari = SafariExtensionBridge(configuration: { nil }, icons: SafariExtensionIcons(), iconCache: BrowserTabIconDiskCache(directory: directory), now: { 1 })
        safari.setEnabled(true)
        _ = safari.receive(SafariExtensionMessage.decode(try envelope(state([
            ["title": "Secret", "host": "private.test", "active": true, "icon": redKey]], incognito: true), profile: profileA)))
        _ = safari.receive(SafariExtensionMessage.decode(try envelope(
            ["v": 1, "type": "icons", "session": "s", "icons": [redKey: original.base64EncodedString()]], profile: profileA)))
        safari.waitForKeptIcons()
        XCTAssertNil(BrowserTabIconDiskCache(directory: directory).icon(partition: try partition(profileA), host: "private.test"))

        let chromeDirectory = directory.appendingPathComponent("chrome")
        let chrome = SafariExtensionBridge(browser: "chrome", configuration: { nil }, icons: SafariExtensionIcons(),
            iconCache: BrowserTabIconDiskCache(directory: chromeDirectory), now: { 1 })
        chrome.setEnabled(true)
        _ = chrome.receive(SafariExtensionMessage.decode(try envelope(state([
            ["title": "Example", "host": "example.test", "active": true, "icon": redKey]]), profile: profileA)))
        chrome.waitForKeptIcons()
        XCTAssertFalse(FileManager.default.fileExists(atPath: chromeDirectory.path), "Chrome's connections have no lasting profile")
    }

    // MARK: - Continuity

    private func tab(_ target: BrowserTabTarget, title: String = "Inbox", source: String?, host: String?, icon: String?) -> BrowserTab {
        var tab = BrowserTab(target: target, title: title, isSelected: true)
        tab.extensionTab = source.map { .init(source: $0, id: 7) }
        tab.host = host
        tab.siteIcon = icon
        return tab
    }

    func testContinuityKeepsTheSameTabsIconOnlyForTheSamePage() {
        let target = BrowserTabTarget(windowId: 1, pid: 2, windowSession: UUID(), tabId: UUID())
        var continuity = BrowserTabSiteIconContinuity()
        XCTAssertEqual(continuity.icon(for: tab(target, source: "p:s:e", host: "mail.test", icon: "a"), now: 0), "a")
        XCTAssertEqual(continuity.icon(for: tab(target, source: "p:s:e", host: "mail.test", icon: nil), now: 1), "a",
                       "An omitted icon keeps the one before, for the same site")
        XCTAssertEqual(continuity.icon(for: tab(target, source: "p:s:e", host: "mail.test", icon: "b"), now: 2), "b", "A new icon replaces it")
        XCTAssertNil(continuity.icon(for: tab(target, source: "p:s:e", host: "news.test", icon: nil), now: 3),
                     "A navigation to another site never shows the previous site's icon")
        XCTAssertNil(continuity.icon(for: tab(target, source: "p:s:e", host: "mail.test", icon: nil), now: 4), "and it stays gone")

        // A report gap: kept while the tab's title stays, for at most the gap lifetime.
        _ = continuity.icon(for: tab(target, source: "p:s:e", host: "mail.test", icon: "a"), now: 10)
        XCTAssertEqual(continuity.icon(for: tab(target, source: nil, host: nil, icon: nil), now: 10 + 149.9), "a")
        XCTAssertNil(continuity.icon(for: tab(target, source: nil, host: nil, icon: nil), now: 10 + 150))
        _ = continuity.icon(for: tab(target, source: "p:s:e", host: "mail.test", icon: "a"), now: 200)
        XCTAssertNil(continuity.icon(for: tab(target, title: "News", source: nil, host: nil, icon: nil), now: 201),
                     "A title change during a gap is a navigation")
        // Described with no host (not a web page): nothing kept.
        _ = continuity.icon(for: tab(target, source: "p:s:e", host: "mail.test", icon: "a"), now: 300)
        XCTAssertNil(continuity.icon(for: tab(target, source: "p:s:e", host: nil, icon: nil), now: 301))
        XCTAssertEqual(continuity.icons, [])
    }

    func testContinuityNeverLetsAnotherTabOrEpochInheritAnIcon() {
        let first = BrowserTabTarget(windowId: 1, pid: 2, windowSession: UUID(), tabId: UUID())
        let other = BrowserTabTarget(windowId: 1, pid: 2, windowSession: UUID(), tabId: UUID())
        var continuity = BrowserTabSiteIconContinuity()
        _ = continuity.icon(for: tab(first, source: "p:s:e1", host: "mail.test", icon: "a"), now: 0)
        XCTAssertEqual(continuity.icons, ["a"], "Held icons are kept in the icon store")
        XCTAssertNil(continuity.icon(for: tab(other, source: "p:s:e1", host: "mail.test", icon: nil), now: 1),
                     "Another native tab, even bound to the same extension id, starts with nothing")
        XCTAssertNil(continuity.icon(for: tab(first, source: "p:s:e2", host: "mail.test", icon: nil), now: 2),
                     "A new transport epoch can reuse ids: no inheritance across it")
        _ = continuity.icon(for: tab(first, source: "p:s:e2", host: "mail.test", icon: "a"), now: 3)
        continuity.retain([other])
        XCTAssertEqual(continuity.icons, [], "A tab that's gone keeps nothing")
    }

    func testTheSidebarFallsBackToAKeptSiteIconOnlyForATabBoundById() {
        let target = BrowserTabTarget(windowId: 1, pid: 2, windowSession: UUID(), tabId: UUID())
        var continuity = BrowserTabSiteIconContinuity()
        var origins = BrowserTabIconAssociations()
        func shown(_ tab: BrowserTab) -> String? {
            browserTabIconShown(tab, chrome: false, now: 0, continuity: &continuity, origins: &origins,
                keptIcon: { source, host in source == "p:s:e" && host == "mail.test" ? "kept" : nil }).siteIcon
        }
        XCTAssertEqual(shown(tab(target, source: "p:s:e", host: "mail.test", icon: nil)), "kept")
        XCTAssertEqual(shown(tab(target, source: "p:s:e", host: "mail.test", icon: "fresh")), "fresh", "What the extension gives wins")
        var positional = tab(target, source: nil, host: "mail.test", icon: nil)
        positional.extensionTab = nil
        XCTAssertNil(shown(positional), "An older extension's position pairing proves no tab identity")
    }

    func testChromeDropsAnOriginIconWhenTheExtensionSaysTheTabNavigated() {
        let target = BrowserTabTarget(windowId: 1, pid: 2, windowSession: UUID(), tabId: UUID())
        var origins = BrowserTabIconAssociations()
        let read = BrowserWindowTabs(windowId: 1, pid: 2, windowSession: target.windowSession,
            tabs: [.init(target: target, title: "Inbox", isSelected: true)],
            iconCandidate: .init(target: target, origin: URL(string: "https://mail.test")))
        origins.update(read, now: 0)
        origins.update(read, now: 1)
        XCTAssertEqual(origins.origins[target], URL(string: "https://mail.test"))
        var continuity = BrowserTabSiteIconContinuity()
        func shown(host: String?, bound: Bool = true) -> URL? {
            var tab = tab(target, source: bound ? "p:s:e" : nil, host: host, icon: nil)
            tab.iconOrigin = origins.origins[target]
            return browserTabIconShown(tab, chrome: true, now: 2, continuity: &continuity, origins: &origins, keptIcon: { _, _ in nil }).iconOrigin
        }
        XCTAssertEqual(shown(host: "MAIL.test"), URL(string: "https://mail.test"), "The same site keeps its icon")
        XCTAssertEqual(shown(host: "news.test", bound: false), URL(string: "https://mail.test"),
                       "Without a tab bound by id, the extension's host says nothing about this tab")
        XCTAssertNil(shown(host: "news.test"), "The extension says the tab is on another site now")
        XCTAssertNil(origins.origins[target], "and it stays dropped until a read confirms the new site")
        origins.update(read, now: 3)
        XCTAssertNil(shown(host: nil))
    }
}
