import AppKit
@testable import AppBundle
import ImageIO
import XCTest

final class BrowserTabIconsTest: XCTestCase {
    @MainActor
    func testDownloadsAreBoundedAndTurningOffDropsQueuedAndLateResults() async throws {
        let gate = IconDownloadGate()
        let model = BrowserTabIconModel(download: { _ in await gate.read() })
        model.setEnabled(true)
        for index in 0..<8 { model.request(URL(string: "https://site\(index).example")) }
        for _ in 0..<100 {
            if await gate.started == 3 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let started = await gate.started
        XCTAssertEqual(started, 3, "Only three downloads run at once")
        model.setEnabled(false)
        await gate.finishAll()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.images.isEmpty)
        let afterDisable = await gate.started
        XCTAssertEqual(afterDisable, 3, "Disabled queued origins never start")
        model.request(URL(string: "https://disabled.example"))
        let afterRequest = await gate.started
        XCTAssertEqual(afterRequest, 3)
    }
    func testOriginsStripPageDataAndRejectNonPublicAndNonHTTPSAddresses() {
        XCTAssertEqual(browserTabIconOrigin("https://example.com:443/path"), URL(string: "https://example.com"))
        XCTAssertEqual(browserTabIconOrigin("https://user:secret@EXAMPLE.com:8443/path?token=secret#fragment")?.absoluteString,
            "https://example.com:8443")
        for address in ["http://example.com/a", "file:///tmp/x", "data:text/html,x", "chrome://newtab",
                        "https://localhost/x", "https://service.local/x", "https://router/x",
                        "https://127.0.0.1/x", "https://10.0.0.1/x", "https://[::1]/x", "https://[fe80::1]/x"] {
            XCTAssertNil(browserTabIconOrigin(address), address)
        }
        XCTAssertEqual(browserTabIconOrigin("https://bücher.de/path")?.host, "xn--bcher-kva.de")
    }

    func testRedirectsStayOnHTTPSOriginWithoutCredentialsOrExtraHops() {
        let origin = URL(string: "https://example.com")!
        XCTAssertTrue(BrowserTabIconDownload.allowsRedirect(to: URL(string: "https://example.com:443/icon.png"), origin: origin, count: 3))
        for address in ["http://example.com/icon.png", "https://cdn.example.com/icon.png",
                        "https://example.com:8443/icon.png", "https://user:secret@example.com/icon.png"] {
            XCTAssertFalse(BrowserTabIconDownload.allowsRedirect(to: URL(string: address), origin: origin, count: 1), address)
        }
        XCTAssertFalse(BrowserTabIconDownload.allowsRedirect(to: origin, origin: origin, count: 4))
        XCTAssertFalse(BrowserTabIconDownload.allowsRedirect(to: nil, origin: origin, count: 1))
    }

    func testKnownIconsSurviveReselectionRetitlingAndTransientMetadata() {
        let target = BrowserTabTarget(windowId: 1, pid: 2, windowSession: UUID(), tabId: UUID())
        let original = URL(string: "https://original.example")!
        let next = URL(string: "https://next.example")!
        var snapshot = BrowserWindowTabs(windowId: 1, pid: 2, windowSession: target.windowSession,
            tabs: [.init(target: target, title: "Inbox", isSelected: true)], iconCandidate: .init(target: target, origin: original))
        var associations = BrowserTabIconAssociations()
        associations.update(snapshot, now: 0)
        associations.update(snapshot, now: 1)
        snapshot.iconCandidate = nil
        snapshot.tabs[0].title = "(1) Inbox"
        associations.update(snapshot, now: 2)
        XCTAssertEqual(associations.origins[target], original)
        snapshot.iconCandidate = .init(target: target, origin: original)
        associations.update(snapshot, now: 3)
        XCTAssertEqual(associations.origins[target], original, "Reselection keeps a known icon while confirming metadata")
        snapshot.iconCandidate = .init(target: target, origin: next)
        associations.update(snapshot, now: 4)
        XCTAssertEqual(associations.origins[target], original)
        associations.update(snapshot, now: 5)
        XCTAssertEqual(associations.origins[target], next, "A different confirmed origin replaces the icon")
        snapshot.iconCandidate = .init(target: target, origin: nil)
        associations.update(snapshot, now: 6)
        XCTAssertEqual(associations.origins[target], next)
        associations.update(snapshot, now: 7)
        XCTAssertNil(associations.origins[target], "A confirmed ineligible address clears a known icon; failed reads do not")
        associations.retain([])
        XCTAssertTrue(associations.origins.isEmpty)
    }

    func testIconRequiresTwoStableObservationsAndDropsLaggingOrRetiredOrigins() {
        let target = BrowserTabTarget(windowId: 1, pid: 2, windowSession: UUID(), tabId: UUID())
        let other = BrowserTabTarget(windowId: 1, pid: 2, windowSession: target.windowSession, tabId: UUID())
        let alpha = URL(string: "https://alpha.example")!
        let beta = URL(string: "https://beta.example")!
        var snapshot = BrowserWindowTabs(windowId: 1, pid: 2, windowSession: target.windowSession,
            tabs: [.init(target: target, title: "Alpha", isSelected: true), .init(target: other, title: "Beta", isSelected: false)],
            iconCandidate: .init(target: target, origin: alpha))
        var associations = BrowserTabIconAssociations()
        associations.update(snapshot, now: 0)
        XCTAssertNil(associations.origins[target])
        associations.update(snapshot, now: 0.5)
        XCTAssertNil(associations.origins[target])
        associations.update(snapshot, now: 1)
        XCTAssertEqual(associations.origins[target], alpha)
        snapshot.tabs[0].isSelected = false
        snapshot.tabs[1].isSelected = true
        snapshot.iconCandidate = .init(target: other, origin: alpha)
        associations.update(snapshot, now: 2)
        XCTAssertNil(associations.origins[other], "The previous page URL may lag behind the newly selected tab")
        snapshot.iconCandidate = .init(target: other, origin: beta)
        associations.update(snapshot, now: 2.4)
        associations.update(snapshot, now: 3.4)
        XCTAssertEqual(associations.origins[other], beta)
        associations.retain([target])
        XCTAssertNil(associations.origins[other])
        snapshot.iconCandidate = nil
        associations.update(snapshot, now: 4)
        XCTAssertNil(associations.origins[other], "Ambiguous metadata never reuses a pending origin")
    }

    func testDisablingIconMetadataClearsAddressesButKeepsTabs() {
        let target = BrowserTabTarget(windowId: 1, pid: 2, windowSession: UUID(), tabId: UUID())
        let origin = URL(string: "https://example.com")!
        var cache = BrowserTabSnapshotCache()
        cache.receive(.init(windowId: 1, pid: 2, windowSession: target.windowSession,
            tabs: [.init(target: target, title: "Example", isSelected: true, iconOrigin: origin)],
            iconCandidate: .init(target: target, origin: origin)), now: 0)
        cache.clearIconMetadata()
        XCTAssertNil(cache.snapshots[1]?.iconCandidate)
        XCTAssertNil(cache.snapshots[1]?.tabs[0].iconOrigin)
        XCTAssertEqual(cache.snapshots[1]?.tabs[0].title, "Example")
    }

    func testDecodingBoundsDimensionsAndProducesSmallPNG() throws {
        XCTAssertNil(BrowserTabIconDownload.thumbnail(Data(repeating: 0, count: BrowserTabIconDownload.maximumBytes + 1)))
        XCTAssertNil(BrowserTabIconDownload.thumbnail(Data("<svg width='32' height='32'></svg>".utf8)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let source = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let thumbnail = try XCTUnwrap(BrowserTabIconDownload.thumbnail(source))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: thumbnail))
        XCTAssertEqual(decoded.pixelsWide, 32)
        XCTAssertEqual(decoded.pixelsHigh, 32)
        let oversized = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1025, pixelsHigh: 1025,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let compressed = try XCTUnwrap(oversized.representation(using: .png, properties: [:]))
        XCTAssertLessThan(compressed.count, BrowserTabIconDownload.maximumBytes)
        XCTAssertNil(BrowserTabIconDownload.thumbnail(compressed), "A small compressed image still has a decoded dimension limit")
    }
}

private actor IconDownloadGate {
    private(set) var started = 0
    private var pending: [CheckedContinuation<Data?, Never>] = []
    func read() async -> Data? {
        started += 1
        return await withCheckedContinuation { pending.append($0) }
    }
    func finishAll() { pending.forEach { $0.resume(returning: Data()) }; pending = [] }
}
