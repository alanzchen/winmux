import AppKit
@testable import AppBundle
import CryptoKit
import JavaScriptCore
import SwiftUI
import XCTest

final class SafariExtensionTest: XCTestCase {
    private static let resources = projectRoot.appendingPathComponent("Sources/SafariExtension/Resources")

    // MARK: The extension's scripts

    private func script() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        context.evaluateScript(try String(contentsOf: Self.resources.appendingPathComponent("shared.js"), encoding: .utf8))
        XCTAssertNil(failure)
        return context
    }

    private func evaluate(_ context: JSContext, _ source: String) throws -> Any? {
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        let json = context.evaluateScript("JSON.stringify(\(source))")?.toString()
        if let failure { XCTFail(failure) }
        return try json.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
    }

    func testOnlyHostsAndOriginsLeaveAPageAddress() throws {
        let context = try script()
        XCTAssertEqual(try evaluate(context, "WinMuxTabs.host('https://user:secret@Mail.Example.com:8443/inbox?token=1#x')") as? String,
            "mail.example.com")
        XCTAssertEqual(try evaluate(context, "WinMuxTabs.origin('https://Example.com:443/path')") as? String, "https://example.com")
        XCTAssertEqual(try evaluate(context, "WinMuxTabs.origin('http://example.com:8080/')") as? String, "http://example.com:8080")
        for address in ["file:///tmp/a", "favorites://", "", "about:blank", "data:text/html,x"] {
            XCTAssertTrue(try evaluate(context, "WinMuxTabs.host('\(address)')") is NSNull, address)
        }
    }

    func testPagesCanOnlyPointTheExtensionAtTheirOwnOriginOrPublicHTTPSIcons() throws {
        let context = try script()
        let page = "http://intranet.example/app"
        for (icon, allowed) in [
            ("http://intranet.example/favicon.ico", true), ("https://cdn.example.com/icon.png", true),
            ("http://cdn.example.com/icon.png", false), ("https://192.168.1.1/icon.png", false), ("https://router/icon.png", false),
            ("https://nas.local/icon.png", false), ("https://[::1]/icon.png", false), ("data:image/png;base64,AAAA", true),
            ("data:text/html,<b>", false), ("javascript:alert(1)", false),
        ] {
            XCTAssertEqual(try evaluate(context, "WinMuxTabs.iconAddressAllowed('\(icon)', '\(page)')") as? Bool, allowed, icon)
        }
    }

    func testIconCandidatesPreferDeclaredIconsNearThirtyTwoPixelsThenTheSiteFavicon() throws {
        let context = try script()
        let candidates = try evaluate(context, """
            WinMuxTabs.iconCandidates([
                {rel: 'apple-touch-icon', href: 'https://example.com/touch.png', sizes: '180x180'},
                {rel: 'mask-icon', href: 'https://example.com/mask.svg'},
                {rel: 'icon', href: 'https://example.com/16.png', sizes: '16x16'},
                {rel: 'shortcut icon', href: 'https://example.com/32.png', sizes: '32x32'},
                {rel: 'icon', href: 'https://example.com/vector.svg', type: 'image/svg+xml'},
                {rel: 'icon', href: 'http://tracker.example/pixel.png'},
                {rel: 'stylesheet', href: 'https://example.com/site.css'},
            ], 'https://example.com/page?q=1')
            """) as? [String]
        XCTAssertEqual(candidates, ["https://example.com/32.png", "https://example.com/vector.svg", "https://example.com/16.png",
                                    "https://example.com/touch.png", "https://example.com/favicon.ico"])
        XCTAssertEqual(try evaluate(context, """
            WinMuxTabs.iconCandidates([{rel: 'icon', href: 'https://example.com/favicon.ico'}], 'https://example.com/')
            """) as? [String], ["https://example.com/favicon.ico"], "The site's favicon is listed once")
        XCTAssertEqual(try evaluate(context, "WinMuxTabs.iconCandidates([], 'favorites://')") as? [String], [])
    }

    func testImageHeadersBoundIconsBeforeDecoding() throws {
        let context = try script()
        func size(_ bytes: String) throws -> [String: Int]? {
            try evaluate(context, "WinMuxTabs.imageDimensions(new Uint8Array([\(bytes)]))") as? [String: Int]
        }
        let png = "0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,0,0,0,13,0x49,0x48,0x44,0x52,0,0,0,48,0,0,0,32"
        XCTAssertEqual(try size(png), ["width": 48, "height": 32])
        XCTAssertEqual(try size("0x47,0x49,0x46,0x38,0x39,0x61,0x10,0,0x20,0"), ["width": 16, "height": 32])
        XCTAssertEqual(try size("0,0,1,0,2,0" + ",16,16" + String(repeating: ",0", count: 14) + ",0,0" + String(repeating: ",0", count: 14)),
            ["width": 256, "height": 256], "An ICO entry of 0 means 256 pixels")
        XCTAssertEqual(try size("0xff,0xd8,0xff,0xe0,0,4,0,0,0xff,0xc0,0,11,8,0,64,0,48,3,1,1"), ["width": 48, "height": 64])
        let webp = "0x52,0x49,0x46,0x46,0,0,0,0,0x57,0x45,0x42,0x50,0x56,0x50,0x38,0x58,10,0,0,0,0,0,0,0,31,0,0,15,0,0"
        XCTAssertEqual(try size(webp), ["width": 32, "height": 16])
        XCTAssertNil(try size("1,2,3,4"))
        let huge = "0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,0,0,0,13,0x49,0x48,0x44,0x52,0,0,0x40,0,0,0,0x40,0"
        XCTAssertEqual(try evaluate(context, "WinMuxTabs.iconBytesAllowed(new Uint8Array([\(huge)]), 'image/png')") as? Bool, false,
            "A 16384-pixel PNG is refused before anything decodes it")
        XCTAssertEqual(try evaluate(context, "WinMuxTabs.iconBytesAllowed(new Uint8Array([\(png)]), 'image/png')") as? Bool, true)
        XCTAssertEqual(try evaluate(context, "WinMuxTabs.iconBytesAllowed(new Uint8Array([60]), 'image/svg+xml')") as? Bool, true)
    }

    func testReportsLeaveOutPrivateWindowsAndAddressesNameEachTabAndDecodeInWinMux() throws {
        let context = try script()
        let windows = """
            [
                {id: 7, type: 'normal', left: 10, top: 40, width: 800, height: 600, tabs: [
                    {id: 2, index: 1, title: '  Docs\\n  home ', url: 'https://docs.example.com/private/path?q=1', active: true,
                     audible: true, mutedInfo: {muted: false}},
                    {id: 1, index: 0, title: 'Start Page', url: '', active: false, pinned: true},
                ]},
                {id: 8, type: 'normal', incognito: true, tabs: [{id: 3, index: 0, title: 'Secret', url: 'https://secret.example', active: true}]},
                {id: 9, type: 'popup', tabs: []},
            ]
            """
        let icon = "(tab) => tab.id === 2 ? '\(String(repeating: "a", count: 64))' : undefined"
        let legacy = try XCTUnwrap(try evaluate(context, "WinMuxTabs.stateWindows(\(windows), \(icon), 1)") as? [[String: Any]])
        XCTAssertNil((legacy[0]["tabs"] as? [[String: Any]])?[0]["id"], "Version 1 never names tabs: an older WinMux would refuse it")
        guard case .state(let old) = try XCTUnwrap(SafariExtensionMessage.decode(try envelope(
            ["v": 1, "type": "state", "session": "s", "time": 1, "windows": legacy]))) else { return XCTFail() }
        XCTAssertEqual(old.windows[0].tabs.map(\.id), [nil, nil], "An older extension's report still counts, by position")
        let state = try XCTUnwrap(try evaluate(context, """
            ({v: WinMuxTabs.protocolVersion, type: 'state', session: 'session-1', time: 12, allSites: true,
              windows: WinMuxTabs.stateWindows([
                {id: 7, type: 'normal', left: 10, top: 40, width: 800, height: 600, tabs: [
                    {id: 2, index: 1, title: '  Docs\\n  home ', url: 'https://docs.example.com/private/path?q=1', active: true,
                     audible: true, mutedInfo: {muted: false}},
                    {id: 1, index: 0, title: 'Start Page', url: '', active: false, pinned: true},
                ]},
                {id: 8, type: 'normal', incognito: true, tabs: [{id: 3, index: 0, title: 'Secret', url: 'https://secret.example', active: true}]},
                {id: 9, type: 'popup', tabs: []},
              ], (tab) => tab.id === 2 ? '\(String(repeating: "a", count: 64))' : undefined)})
            """) as? [String: Any])
        let text = String(data: try JSONSerialization.data(withJSONObject: state), encoding: .utf8) ?? ""
        for leaked in ["private/path", "q=1", "Secret", "secret.example", "\"url\""] {
            XCTAssertFalse(text.contains(leaked), leaked)
        }
        let profile = UUID()
        let envelope = try JSONSerialization.data(withJSONObject: ["profile": profile.uuidString, "message": state])
        guard case .state(let decoded) = try XCTUnwrap(SafariExtensionMessage.decode(envelope)) else { return XCTFail() }
        XCTAssertEqual(decoded.profile, profile.uuidString)
        XCTAssertEqual(decoded.session, "session-1")
        XCTAssertTrue(decoded.allSites)
        XCTAssertEqual(decoded.windows.count, 1)
        XCTAssertEqual(decoded.windows[0].bounds, CGRect(x: 10, y: 40, width: 800, height: 600))
        XCTAssertEqual(decoded.windows[0].tabs, [
            .init(id: 1, title: "Start Page", isActive: false, isPinned: true),
            .init(id: 2, title: "Docs home", host: "docs.example.com", isActive: true, isAudible: true, icon: String(repeating: "a", count: 64)),
        ])
        XCTAssertEqual(decoded.windows[0].tabKey(decoded.windows[0].tabs[1]), .init(source: "\(profile.uuidString):session-1", id: 2))
    }

    /// The extension and WinMux update together, but Safari can run one with the other's older
    /// self for a while: each understands the other.
    @MainActor
    func testAnExtensionAndAWinMuxOfDifferentProtocolVersionsStillUnderstandEachOther() throws {
        let context = try script()
        XCTAssertEqual(try evaluate(context, "WinMuxTabs.protocolVersion") as? Int, SafariExtensionMessage.protocolVersion)
        // An older WinMux refuses a version 2 report as invalid, saying it speaks version 1.
        XCTAssertEqual(try evaluate(context, "WinMuxTabs.negotiatedVersion({v: 1, ok: false, reason: 'invalid'}, 2)") as? Int, 1)
        for reply in ["{v: 2, ok: true}", "{v: 1, ok: false, reason: 'off'}", "{v: 1, ok: true}", "undefined", "{v: 0, ok: false, reason: 'invalid'}",
                      "{v: '1', ok: false, reason: 'invalid'}", "{v: 3, ok: false, reason: 'invalid'}"] {
            XCTAssertEqual(try evaluate(context, "WinMuxTabs.negotiatedVersion(\(reply), 2)") as? Int, 2, reply)
        }
        XCTAssertEqual(try evaluate(context, "WinMuxTabs.negotiatedVersion({v: 1, ok: false, reason: 'invalid'}, 1)") as? Int, 1)
        // Version 2 says when the extension began measuring windows; version 1 has no place for it.
        let current = try XCTUnwrap(try evaluate(context, "WinMuxTabs.stateMessage({session: 's', measured: 5, time: 9, allSites: true, windows: []})") as? [String: Any])
        XCTAssertEqual(current["measured"] as? Int, 5)
        XCTAssertEqual(current["v"] as? Int, 2)
        let older = try XCTUnwrap(try evaluate(context, "WinMuxTabs.stateMessage({version: 1, session: 's', measured: 5, order: 3, time: 9, allSites: true, windows: []})") as? [String: Any])
        XCTAssertNil(older["measured"])
        XCTAssertNil(older["order"])
        XCTAssertEqual((try evaluate(context, "WinMuxTabs.stateMessage({session: 's', measured: 5, order: 3, time: 9, allSites: true, windows: []})") as? [String: Any])?["order"] as? Int, 3)
        XCTAssertNil((try evaluate(context, "WinMuxTabs.stateMessage({session: 's', measured: 5, order: undefined, time: 9, allSites: true, windows: []})") as? [String: Any])?["order"],
            "A count that changed while Safari listed its windows isn't sent")
        for (order, kept) in [(3, 3), (-1, nil)] as [(Any, Int?)] {
            guard case .state(let state) = SafariExtensionMessage.decode(try envelope(["v": 2, "type": "state", "session": "s", "time": 9,
                "order": order, "windows": [] as [Any]])) else { return XCTFail() }
            XCTAssertEqual(state.order, kept)
        }
        for (measured, kept) in [(5.0, 5.0), (9, 9), (10, nil), (Double.nan, nil)] as [(Double, Double?)] {
            var message: [String: Any] = ["v": 2, "type": "state", "session": "s", "time": 9, "windows": [] as [Any]]
            if !measured.isNaN { message["measured"] = measured }
            guard case .state(let state) = SafariExtensionMessage.decode(try envelope(message)) else { return XCTFail() }
            XCTAssertEqual(state.measured, kept, "A measurement after the report was sent can't be")
        }
        guard case .state(let legacy) = SafariExtensionMessage.decode(try envelope(["v": 1, "type": "state", "session": "s", "time": 9,
            "measured": 5, "windows": [] as [Any]])) else { return XCTFail() }
        XCTAssertNil(legacy.measured)
        // This WinMux takes both, and answers in its own version.
        let bridge = SafariExtensionBridge(configuration: { nil }, icons: SafariExtensionIcons())
        bridge.setEnabled(true)
        for version in [1, 2] {
            let tab: [String: Any] = version == 2 ? ["id": 4, "title": "A", "active": true] : ["title": "A", "active": true]
            let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: bridge.receive(SafariExtensionMessage.decode(try envelope(
                ["v": version, "type": "state", "session": "s\(version)", "time": 1, "windows": [["id": 1, "tabs": [tab]]]])))) as? [String: Any])
            XCTAssertEqual(answer["ok"] as? Bool, true)
            XCTAssertEqual(answer["v"] as? Int, 2)
        }
        let refused = try XCTUnwrap(JSONSerialization.jsonObject(with: bridge.receive(SafariExtensionMessage.decode(try envelope(
            ["v": 3, "type": "state", "session": "s", "time": 1, "windows": [] as [Any]])))) as? [String: Any])
        XCTAssertEqual(refused["reason"] as? String, "invalid")
        XCTAssertEqual(try evaluate(context, "WinMuxTabs.negotiatedVersion(\(String(decoding: try JSONSerialization.data(withJSONObject: refused), as: UTF8.self)), 2)") as? Int, 2,
            "A newer WinMux's refusal of a version it doesn't know never downgrades this one")
    }

    /// The extension titles its toolbar button with the window's ids; WinMux reads exactly that
    /// back, and nothing else as a marker.
    func testTheToolbarTitleTheExtensionSetsIsTheMarkerWinMuxReads() throws {
        let context = try script()
        let title = try XCTUnwrap(try evaluate(context, "WinMuxTabs.markerTitle('3f2a9c1e-0000-4000-8000-000000000001', 1401, 1402)") as? String)
        XCTAssertTrue(title.hasPrefix("WinMux Tabs"), "Its tooltip and accessible name still say what it is")
        XCTAssertEqual(SafariExtensionMarker(title), .init(session: "3f2a9c1e", window: 1401, tab: 1402))
        for other in [nil, "", "WinMux Tabs", "WinMux Tabs \u{00B7} 3f2a9c1e-1401", "WinMux Tabs \u{00B7} 3f2a9c1e-1401-1402-5",
                      "WinMux Tabs \u{00B7} 3F2A9C1E-1401-1402", "WinMux Tabs \u{00B7} 3f2a9c1-1401-1402", "WinMux Tabs \u{00B7} 3f2a9c1e--1-1402",
                      "WinMux Tabs \u{00B7} 3f2a9c1e-14a1-1402", "WinMux Tabs \u{00B7} 3f2a9c1e-1401-1402 ", "Other \u{00B7} 3f2a9c1e-1401-1402",
                      "WinMux Tabs \u{00B7} 3f2a9c1e-1401-1234567890123456"] as [String?] {
            XCTAssertNil(SafariExtensionMarker(other), other ?? "nil")
        }
        XCTAssertEqual(try evaluate(context, "WinMuxTabs.reportKey({v: 2, type: 'state', session: 's', measured: 1, time: 2, order: 3, allSites: true, windows: [{id: 1}]})")
            as? String, try evaluate(context, "WinMuxTabs.reportKey({v: 2, type: 'state', session: 's', measured: 8, time: 9, order: 3, allSites: true, windows: [{id: 1}]})")
            as? String, "When a report was made isn't news")
        for change in ["order: 4", "allSites: false", "session: 't'", "v: 1"] {
            XCTAssertNotEqual(try evaluate(context, "WinMuxTabs.reportKey({v: 2, type: 'state', session: 's', time: 2, order: 3, allSites: true, windows: [], \(change)})")
                as? String, try evaluate(context, "WinMuxTabs.reportKey({v: 2, type: 'state', session: 's', time: 2, order: 3, allSites: true, windows: []})")
                as? String, change)
        }
    }

    func testManifestListsItsFilesAndOnlyThePermissionsItUses() throws {
        let data = try Data(contentsOf: Self.resources.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(manifest["manifest_version"] as? Int, 3)
        XCTAssertEqual(Set(manifest["permissions"] as? [String] ?? []), ["tabs", "nativeMessaging", "storage", "alarms", "scripting"])
        let background = try XCTUnwrap(manifest["background"] as? [String: Any])
        XCTAssertEqual(background["persistent"] as? Bool, false, "Safari unloads idle extension pages; nothing may rely on staying loaded")
        XCTAssertEqual((manifest["action"] as? [String: Any])?["default_title"] as? String, "WinMux Tabs",
            "A toolbar button whose title the extension can set for each tab, named plainly until it does")
        XCTAssertEqual(((manifest["browser_specific_settings"] as? [String: Any])?["safari"] as? [String: Any])?["strict_min_version"] as? String,
            "18.4", "Safari runs Developer ID–signed web extensions from 18.4")
        let content = try XCTUnwrap((manifest["content_scripts"] as? [[String: Any]])?.first)
        let files = (background["scripts"] as? [String] ?? []) + (content["js"] as? [String] ?? [])
            + ((manifest["icons"] as? [String: String]) ?? [:]).values
        XCTAssertFalse(files.isEmpty)
        for file in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.resources.appendingPathComponent(file).path), file)
        }
        // Xcode copies the resources flat into the extension bundle.
        XCTAssertTrue(files.allSatisfy { !$0.contains("/") })
    }

    // MARK: WinMux's side

    private func envelope(_ message: [String: Any], profile: String? = nil) throws -> Data {
        var envelope: [String: Any] = ["message": message]
        if let profile { envelope["profile"] = profile }
        return try JSONSerialization.data(withJSONObject: envelope)
    }

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

    func testMalformedOrOversizedReportsAreDroppedWhole() throws {
        let tab: [String: Any] = ["title": "A", "active": true]
        let window: [String: Any] = ["id": 1, "tabs": [tab]]
        let valid: [String: Any] = ["v": 1, "type": "state", "session": "s", "time": 1, "windows": [window]]
        XCTAssertNotNil(SafariExtensionMessage.decode(try envelope(valid)))
        guard case .state(let state) = SafariExtensionMessage.decode(try envelope(valid, profile: "not a uuid")) else { return XCTFail() }
        XCTAssertEqual(state.profile, "profile:not a uuid")
        guard case .state(let unnamed) = SafariExtensionMessage.decode(try envelope(valid)) else { return XCTFail() }
        XCTAssertEqual(unnamed.profile, "session:s", "Without Safari's profile, each session stands alone")
        var invalid: [[String: Any]] = []
        invalid.append(valid.merging(["v": 2]) { $1 })
        invalid.append(valid.merging(["v": 3]) { $1 })
        let named: [String: Any] = valid.merging(["v": 2, "windows": [["id": 1, "tabs": [tab.merging(["id": 5]) { $1 }]]]]) { $1 }
        XCTAssertNotNil(SafariExtensionMessage.decode(try envelope(named)))
        for id in [5.5, true, "5"] as [Any] {
            invalid.append(named.merging(["windows": [["id": 1, "tabs": [tab.merging(["id": id]) { $1 }]]]]) { $1 })
        }
        invalid.append(named.merging(["windows": [["id": 1, "tabs": [tab.merging(["id": 5]) { $1 }, tab.merging(["id": 5, "active": false]) { $1 }]]]]) { $1 })
        invalid.append(named.merging(["windows": [["id": 1, "tabs": [tab.merging(["id": 5]) { $1 }]],
                                                  ["id": 2, "tabs": [tab.merging(["id": 5]) { $1 }]]]]) { $1 })
        invalid.append(valid.merging(["session": ""]) { $1 })
        invalid.append(valid.merging(["session": String(repeating: "s", count: 65)]) { $1 })
        invalid.append(valid.merging(["windows": [window, window]]) { $1 })
        invalid.append(valid.merging(["windows": Array(repeating: window, count: 65)]) { $1 })
        invalid.append(valid.merging(["windows": [["id": 1, "tabs": Array(repeating: tab, count: 501)]]]) { $1 })
        invalid.append(valid.merging(["windows": [["id": 1, "tabs": [["active": true]]]]]) { $1 })
        invalid.append(valid.merging(["type": "command"]) { $1 })
        for message in invalid { XCTAssertNil(SafariExtensionMessage.decode(try envelope(message))) }
        XCTAssertNil(SafariExtensionMessage.decode(Data(repeating: 0x20, count: SafariExtensionMessage.maximumBytes + 1)))
        let badKey = valid.merging(["windows": [["id": 1, "tabs": [tab.merging(["icon": "../../etc"]) { $1 }]]]]) { $1 }
        guard case .state(let dropped) = SafariExtensionMessage.decode(try envelope(badKey)) else { return XCTFail() }
        XCTAssertNil(dropped.windows[0].tabs[0].icon)
    }

    func testIconsMustBeTheImageTheirKeyNames() throws {
        let red = try png(.red)
        let blue = try png(.blue)
        let icons = [key(red): red.base64EncodedString(), String(repeating: "b", count: 64): blue.base64EncodedString(),
                     key(Data("text".utf8)): Data("text".utf8).base64EncodedString()]
        guard case .icons(_, let session, let decoded) = SafariExtensionMessage.decode(
            try envelope(["v": 1, "type": "icons", "session": "s", "icons": icons])) else { return XCTFail() }
        XCTAssertEqual(session, "s")
        XCTAssertEqual(Array(decoded.keys), [key(red)], "Mismatched keys and non-images are dropped")
    }

    private func tabs(_ titles: [String], selected: Int, window: UInt32) -> BrowserWindowTabs {
        let session = UUID()
        return .init(windowId: window, pid: 7, windowSession: session, tabs: titles.enumerated().map { index, title in
            .init(target: .init(windowId: window, pid: 7, windowSession: session, tabId: UUID()), title: title, isSelected: index == selected)
        })
    }

    private func described(_ titles: [String], selected: Int, id: Int, source: String = "p:s", bounds: CGRect? = nil,
                           icon: String? = nil, host: String? = nil, audible: Bool = false, sighting: [UInt32: CGRect] = [:]) -> SafariExtensionWindow {
        .init(key: .init(source: source, id: id), bounds: bounds, tabs: titles.enumerated().map { index, title in
            .init(title: title, host: title.isEmpty ? nil : host, isActive: index == selected, isAudible: audible && index == selected,
                icon: title.isEmpty ? nil : icon)
        }, sighting: sighting)
    }

    func testWindowsPairOnlyWhenEachIsTheOthersOneCandidate() {
        let first = tabs(["Inbox", "Docs"], selected: 0, window: 1)
        let second = tabs(["Inbox", "Docs"], selected: 0, window: 2)
        let other = tabs(["News", "Weather"], selected: 1, window: 3)
        let inbox = described(["Inbox", "Docs"], selected: 0, id: 10)
        let news = described(["News", "Weather"], selected: 1, id: 11)
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: first), .init(snapshot: other)], [inbox, news]),
            [1: inbox.key, 3: news.key])
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: first), .init(snapshot: second)], [inbox]), [:],
            "A Safari profile without the extension can't lend its twin window another profile's icons")
        let frame = CGRect(x: 0, y: 25, width: 900, height: 700)
        let placed = described(["Inbox", "Docs"], selected: 0, id: 10, bounds: frame.offsetBy(dx: 2, dy: -3),
            sighting: [1: frame, 2: frame.offsetBy(dx: 900, dy: 0)])
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: first), .init(snapshot: second)], [placed]), [1: placed.key],
            "Where the windows were when the report came settles which twin is which")
        let elsewhere = described(["Inbox", "Docs"], selected: 0, id: 12, source: "q:s", bounds: frame.offsetBy(dx: 400, dy: 0), sighting: [1: frame])
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: first)], [placed, elsewhere]), [1: placed.key])
        var unseen = placed
        unseen.sighting = [:]
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: first)], [unseen, elsewhere]), [:],
            "A window the report's arrival didn't see in place could be either twin")
        XCTAssertEqual(safariExtensionMatches([.init(snapshot: first)], [unseen, elsewhere]).needsFrames, [1], "Safari's next report may settle it")
        let together = safariExtensionMatches([.init(snapshot: first), .init(snapshot: second)], [placed, described(["Inbox", "Docs"], selected: 0, id: 11,
            bounds: frame.offsetBy(dx: 2, dy: -3), sighting: [1: frame, 2: frame])])
        XCTAssertEqual(together.pairs, [:], "Twins seen in the same place can't be told apart")
        XCTAssertEqual(together.needsFrames, [], "and another report from the same places wouldn't settle it")
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: first)], [described(["Inbox", "Docs"], selected: 1, id: 10)]), [:])
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: first)], [described(["Docs", "Inbox"], selected: 1, id: 10)]), [:])
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: first)], [described(["Inbox", "Docs", "More"], selected: 0, id: 10)]), [:])
    }

    func testTitlesSafariWithholdsMayDifferButNeverOutnumberReadableOnes() {
        let window = tabs(["Start Page", "GitHub", "Favorites"], selected: 1, window: 1)
        XCTAssertTrue(safariExtensionTabsAgree(window.tabs, described(["", "GitHub", "Favorites"], selected: 1, id: 1)))
        XCTAssertFalse(safariExtensionTabsAgree(window.tabs, described(["", "GitHub", ""], selected: 1, id: 1)),
            "One readable title can't vouch for two withheld ones")
        var hosted = described(["", "GitHub", "Favorites"], selected: 1, id: 1)
        hosted.tabs[0].host = "example.com"
        XCTAssertFalse(safariExtensionTabsAgree(window.tabs, hosted), "A web page with a title Safari shows must match it")
        XCTAssertFalse(safariExtensionTabsAgree(window.tabs, described(["", "", ""], selected: 1, id: 1)))
        let spaced = tabs(["Build  #42\n passed", "Other"], selected: 0, window: 2)
        XCTAssertTrue(safariExtensionTabsAgree(spaced.tabs, described(["Build #42 passed", "Other"], selected: 0, id: 2)))
    }

    func testAPairingCountsAfterTwoObservationsAndKeepsIconsButNotSoundThroughAMismatch() {
        let window = tabs(["Inbox", "Docs"], selected: 0, window: 1)
        let icon = String(repeating: "c", count: 64)
        let extensionWindow = described(["Inbox", "Docs"], selected: 0, id: 10, icon: icon, host: "mail.example.com", audible: true)
        var associations = SafariExtensionAssociations()
        associations.update([.init(snapshot: window, observed: 0)], windows: [extensionWindow], now: 0)
        XCTAssertNil(associations.described(window.tabs[0]).siteIcon, "One observation isn't enough")
        associations.update([.init(snapshot: window, observed: 0.5)], windows: [extensionWindow], now: 0.5)
        XCTAssertNil(associations.described(window.tabs[0]).siteIcon)
        associations.update([.init(snapshot: window, observed: 0.5)], windows: [extensionWindow], now: 0.8)
        XCTAssertNil(associations.described(window.tabs[0]).siteIcon, "Time passing isn't a new Accessibility read")
        associations.update([.init(snapshot: window, observed: 0.8)], windows: [extensionWindow], now: 0.8)
        var inbox = associations.described(window.tabs[0])
        XCTAssertEqual(inbox.siteIcon, icon)
        XCTAssertEqual(inbox.host, "mail.example.com")
        XCTAssertEqual(inbox.audio, .playing)
        XCTAssertNil(associations.described(window.tabs[1]).audio)

        var retitled = window
        retitled.tabs[0].title = "(1) Inbox"
        associations.update([.init(snapshot: retitled, observed: 2)], windows: [extensionWindow], now: 2)
        inbox = associations.described(retitled.tabs[0])
        XCTAssertEqual(inbox.siteIcon, icon, "A title changing in one report before the other keeps the icon")
        XCTAssertNil(inbox.audio, "Sound shows only while the window agrees")
        associations.update([.init(snapshot: retitled, observed: 13)], windows: [extensionWindow], now: 13)
        XCTAssertNil(associations.described(retitled.tabs[0]).siteIcon, "A lasting mismatch gives the app icon back")

        associations.update([.init(snapshot: window, observed: 14)], windows: [extensionWindow], now: 14)
        associations.update([.init(snapshot: window, observed: 15)], windows: [extensionWindow], now: 15)
        XCTAssertEqual(associations.described(window.tabs[0]).siteIcon, icon)
        let replacement = described(["Inbox", "Docs"], selected: 0, id: 20, source: "p:new", icon: String(repeating: "d", count: 64))
        associations.update([.init(snapshot: window, observed: 16)], windows: [replacement], now: 16)
        XCTAssertNil(associations.described(window.tabs[0]).siteIcon, "A pairing with another window replaces the old one at once")
        associations.update([.init(snapshot: window, observed: 17)], windows: [replacement], now: 17)
        XCTAssertEqual(associations.described(window.tabs[0]).siteIcon, String(repeating: "d", count: 64))
        associations.update([], windows: [replacement], now: 18)
        XCTAssertTrue(associations.tabs.isEmpty, "Closed windows' tabs are forgotten")
    }

    func testEverySafariWindowWithoutTabsIsAPossibleTwin() {
        // 1 was read; 2 isn't listed; 3's read failed or hasn't finished; 4 has no tab strip and
        // was read as its one tab (as is Safari's Settings, which pairs with nothing).
        XCTAssertEqual(safariExtensionUnreadWindows(live: [4, 3, 2, 1], read: [1, 4]), [2, 3])
        XCTAssertEqual(safariExtensionUnreadWindows(live: [1], read: [1]), [])
    }

    /// Two profiles each have a one-tab "Docs" window, and only one reports. If the other's read
    /// fails, it's unread, so the one read can't take the report without the frames settling it.
    func testAOneTabWindowWhoseReadFailedStillKeepsAnotherFromTakingItsReport() {
        let read = tabs(["Docs"], selected: 0, window: 1)
        let frame = CGRect(x: 0, y: 25, width: 900, height: 700)
        let elsewhere = frame.offsetBy(dx: 950, dy: 0)
        let report = described(["Docs"], selected: 0, id: 10, bounds: elsewhere, icon: String(repeating: "e", count: 64),
            sighting: [1: frame, 2: elsewhere])
        var associations = SafariExtensionAssociations()
        for time in [0.0, 1, 2] {
            associations.update([.init(snapshot: read, observed: time)], windows: [report], unread: [2], now: time)
        }
        XCTAssertNil(associations.described(read.tabs[0]).siteIcon, "The unread window is where the report says")
    }

    func testWhileASafariWindowIsUnreadANewPairingAlsoNeedsTheFramesToSettleItButAnEstablishedOneDoesNot() {
        // The window WinMux shows could be another profile's twin of a window it hasn't read (2).
        let window = tabs(["Inbox", "Docs"], selected: 0, window: 1)
        let frame = CGRect(x: 0, y: 25, width: 900, height: 700)
        let hidden = frame.offsetBy(dx: 950, dy: 0)
        let elsewhere = described(["Inbox", "Docs"], selected: 0, id: 10, bounds: hidden, icon: String(repeating: "e", count: 64),
            sighting: [1: frame, 2: hidden])
        var associations = SafariExtensionAssociations()
        for time in [0.0, 1, 2] {
            associations.update([.init(snapshot: window, observed: time)], windows: [elsewhere], unread: [2], now: time)
        }
        XCTAssertNil(associations.described(window.tabs[0]).siteIcon, "The unread window is where the extension's is")
        XCTAssertTrue(associations.awaitsReport)
        XCTAssertEqual(associations.resolution(of: 1), .unresolved)
        for time in [3.0, 4] {
            associations.update([.init(snapshot: window, observed: time)], windows: [elsewhere], now: time)
        }
        XCTAssertNotNil(associations.described(window.tabs[0]).siteIcon, "With every Safari window read, the tabs alone settle it")
        XCTAssertEqual(associations.resolution(of: 1), .resolved(elsewhere.key))

        var stacked = SafariExtensionAssociations()
        let here = described(["Inbox", "Docs"], selected: 0, id: 10, bounds: frame.offsetBy(dx: 1, dy: 2), icon: String(repeating: "e", count: 64),
            sighting: [1: frame, 2: frame])
        for time in [0.0, 1, 2] {
            stacked.update([.init(snapshot: window, observed: time)], windows: [here], unread: [2], now: time)
        }
        XCTAssertNil(stacked.described(window.tabs[0]).siteIcon, "An unread window in the same place, as in a stack, could be the one")
        var unplaced = here
        unplaced.sighting = [1: frame]
        for time in [3.0, 4] {
            stacked.update([.init(snapshot: window, observed: time)], windows: [unplaced], unread: [2], now: time)
        }
        XCTAssertNil(stacked.described(window.tabs[0]).siteIcon, "An unread window the report's arrival didn't see could be anywhere")
        XCTAssertTrue(stacked.awaitsReport)

        var fresh = SafariExtensionAssociations()
        let placed = described(["Inbox", "Docs"], selected: 0, id: 10, bounds: frame.offsetBy(dx: 1, dy: 2), icon: String(repeating: "e", count: 64),
            sighting: [1: frame, 2: hidden])
        for time in [0.0, 1] {
            fresh.update([.init(snapshot: window, observed: time)], windows: [placed], unread: [2], now: time)
        }
        XCTAssertNotNil(fresh.described(window.tabs[0]).siteIcon)
        XCTAssertFalse(fresh.awaitsReport)
        // Safari's next report finds the window moved, but the unread one wasn't seen in place.
        var moved = placed
        moved.sighting = [1: frame.offsetBy(dx: 300, dy: 0)]
        moved.bounds = frame.offsetBy(dx: 300, dy: 0)
        fresh.update([.init(snapshot: window, observed: 2)], windows: [moved], unread: [2], now: 2)
        XCTAssertNotNil(fresh.described(window.tabs[0]).siteIcon, "An established pairing holds on its tabs")
        XCTAssertFalse(fresh.awaitsReport)
    }

    @MainActor
    func testTheBridgeAsksOnlyForMissingIconsAndForgetsEverythingWhenOffOrSafariQuits() throws {
        var time = 100.0
        let icons = SafariExtensionIcons()
        let bridge = SafariExtensionBridge(configuration: { nil }, icons: icons, now: { time })
        let profile = UUID().uuidString
        let red = try png(.red)
        let redKey = key(red)
        let state: [String: Any] = ["v": 1, "type": "state", "session": "s", "time": 5, "allSites": false, "windows": [
            ["id": 1, "tabs": [["title": "A", "active": true, "icon": redKey], ["title": "B", "active": false, "icon": redKey]]],
        ]]
        func reply(_ message: [String: Any], profile: String? = profile) throws -> [String: Any] {
            let data = bridge.receive(SafariExtensionMessage.decode(try envelope(message, profile: profile)))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(try reply(state)["ok"] as? Bool, false, "Browser tabs are off")
        bridge.setEnabled(true)
        XCTAssertEqual(try reply(state)["want"] as? [String], [redKey])
        XCTAssertEqual(bridge.windows.count, 1)
        XCTAssertFalse(bridge.allSites)
        XCTAssertEqual(try reply(["v": 1, "type": "icons", "session": "other", "icons": [redKey: red.base64EncodedString()]])["ok"] as? Bool, true)
        XCTAssertTrue(icons.images.isEmpty, "Icons from a replaced session are ignored")
        _ = try reply(["v": 1, "type": "icons", "session": "s", "icons": [redKey: red.base64EncodedString()]])
        XCTAssertNotNil(icons.images[redKey])
        XCTAssertEqual(try reply(state)["want"] as? [String], [])
        XCTAssertEqual(try reply(state.merging(["time": 4, "windows": [] as [Any]]) { $1 })["ok"] as? Bool, true)
        XCTAssertEqual(bridge.windows.count, 1, "An older report from the same session never replaces a newer one")
        _ = try reply(state.merging(["session": "t", "time": 1, "windows": [] as [Any]]) { $1 })
        XCTAssertTrue(bridge.windows.isEmpty, "A new session replaces its profile's windows")
        XCTAssertEqual(try reply(["v": 9])["ok"] as? Bool, false)
        _ = try reply(state, profile: nil)
        _ = try reply(state.merging(["session": "u", "allSites": true]) { $1 }, profile: nil)
        XCTAssertEqual(bridge.windows.count, 2, "Without Safari's profile, one session never replaces another")
        XCTAssertFalse(bridge.allSites, "One profile without access to every site is enough to say so")
        bridge.clear()

        _ = try reply(state)
        time += SafariExtensionBridge.stateLifetime
        XCTAssertTrue(bridge.windows.isEmpty, "A profile that stopped reporting is gone")
        time -= SafariExtensionBridge.stateLifetime
        bridge.retain(safariIsRunning: false)
        XCTAssertTrue(bridge.windows.isEmpty)
        XCTAssertTrue(icons.images.isEmpty)
        _ = try reply(state)
        _ = try reply(["v": 1, "type": "icons", "session": "s", "icons": [redKey: red.base64EncodedString()]])
        time += SafariExtensionBridge.stateLifetime
        _ = try reply(["v": 1, "type": "icons", "session": "s", "icons": [redKey: red.base64EncodedString()]])
        XCTAssertFalse(bridge.allSites, "No profile reporting is no evidence of access to every site")
        bridge.setEnabled(false)
        XCTAssertTrue(bridge.windows.isEmpty)
        XCTAssertTrue(icons.images.isEmpty)
        XCTAssertNil(bridge.lastContact)
    }

    @MainActor
    func testIconsATabShowsAreNeverEvictedAndWinMuxAsksOnlyForWhatFits() throws {
        let icons = SafariExtensionIcons()
        let bridge = SafariExtensionBridge(configuration: { nil }, icons: icons, now: { 1 })
        bridge.setEnabled(true)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let shown = (0..<SafariExtensionBridge.maximumImages).map { String(format: "%064x", $0) }
        icons.images = Dictionary(uniqueKeysWithValues: shown.map { ($0, image) })
        let red = try png(.red)
        let tabs = (shown + [key(red)]).map { ["title": "T", "active": false, "icon": $0] as [String: Any] }
        var windows: [[String: Any]] = []
        for start in stride(from: 0, to: tabs.count, by: SafariExtensionMessage.maximumTabs) {
            var window = Array(tabs[start..<min(start + SafariExtensionMessage.maximumTabs, tabs.count)])
            if start == 0 { window[0]["active"] = true } else { window[0]["active"] = true }
            windows.append(["id": start, "tabs": window])
        }
        let state: [String: Any] = ["v": 1, "type": "state", "session": "s", "time": 1, "windows": windows]
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: bridge.receive(SafariExtensionMessage.decode(try envelope(state)))) as? [String: Any])
        XCTAssertEqual(answer["want"] as? [String], [], "With every icon a tab shows already kept, nothing more fits")
        _ = bridge.receive(SafariExtensionMessage.decode(try envelope(["v": 1, "type": "icons", "session": "s",
            "icons": [key(red): red.base64EncodedString()]])))
        XCTAssertEqual(Set(icons.images.keys), Set(shown), "An icon that doesn't fit never pushes out one a tab shows")
    }

    // MARK: The socket between the extension and WinMux

    private final class SocketTestAnswers: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [SafariExtensionMessage?] = []
        func record(_ message: SafariExtensionMessage?) { lock.withLock { messages.append(message) } }
        var received: [SafariExtensionMessage?] { lock.withLock { messages } }
    }

    private func socketPath() -> String { "/tmp/winmux-safari-test-\(getpid())-\(UUID().uuidString.prefix(8)).sock" }

    private func connect(_ path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    private func server(_ requirement: String, path: String, answers: SocketTestAnswers) throws -> SafariExtensionServer {
        try XCTUnwrap(SafariExtensionServer(configuration: .init(extensionId: "test", socketPath: path, peerRequirement: requirement, team: "TEAM")) { message in
            answers.record(message)
            return Data("{\"ok\":true}".utf8)
        })
    }

    func testTheSocketAnswersEachExchangeAndAStalledPeerHoldsUpNoOther() throws {
        let path = socketPath()
        let answers = SocketTestAnswers()
        let server = try self.server("always", path: path, answers: answers)
        let stalled = try connect(path)
        defer { close(stalled) }
        // Half a header, then nothing, as a stuck peer might send.
        XCTAssertEqual(write(stalled, [0, 0], 2), 2)
        let client = try connect(path)
        defer { close(client) }
        let request = try envelope(["v": 1, "type": "state", "session": "s", "time": 1, "windows": [] as [Any]])
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(writeSafariExtensionFrame(client, request, until: started + 2))
        let answer = try XCTUnwrap(readSafariExtensionFrame(client, until: started + 2))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1, "A stalled peer doesn't delay another's answer")
        XCTAssertEqual(String(data: answer, encoding: .utf8), "{\"ok\":true}")
        guard case .state(let state)? = answers.received.first else { return XCTFail("\(answers.received)") }
        XCTAssertEqual(state.session, "s")
        // The stalled peer is dropped at its deadline, without an answer.
        var byte: UInt8 = 0
        XCTAssertLessThanOrEqual(read(stalled, &byte, 1), 0)
        // Stopped as the bridge stops it: the last exchange can briefly outlive the reference.
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Stopping the server removes its socket")
    }

    func testAStoppedServerNeverRemovesTheSocketOfTheOneThatReplacedIt() throws {
        let path = socketPath()
        let answers = SocketTestAnswers()
        let old = try server("always", path: path, answers: answers)
        let stalled = try connect(path)
        defer { close(stalled) }
        XCTAssertEqual(write(stalled, [0, 0], 2), 2)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        // Browser tabs go off and on again while the old server still waits on that peer.
        old.stop()
        let replacement = try server("always", path: path, answers: answers)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.3))
        old.stop()
        _ = old
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let client = try connect(path)
        defer { close(client) }
        let request = try envelope(["v": 1, "type": "state", "session": "s", "time": 1, "windows": [] as [Any]])
        XCTAssertTrue(writeSafariExtensionFrame(client, request, until: ProcessInfo.processInfo.systemUptime + 2))
        XCTAssertNotNil(readSafariExtensionFrame(client, until: ProcessInfo.processInfo.systemUptime + 2), "The replacement still answers")
        replacement.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAWriteToAPeerThatStopsReadingEndsAtItsDeadline() {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(writeSafariExtensionFrame(pair[0], Data(count: SafariExtensionMessage.maximumBytes), until: started + 0.5),
            "Two megabytes don't fit in the socket's buffer")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5, "A write that can't finish never blocks past its deadline")
    }

    func testTheSocketReadsNothingFromAPeerThatIsntTheExtensionAndRefusesOversizedFrames() throws {
        let path = socketPath()
        let answers = SocketTestAnswers()
        var refusing: SafariExtensionServer? = try server("never", path: path, answers: answers)
        let stranger = try connect(path)
        let request = try envelope(["v": 1, "type": "state", "session": "s", "time": 1, "windows": [] as [Any]])
        _ = writeSafariExtensionFrame(stranger, request, until: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertNil(readSafariExtensionFrame(stranger, until: ProcessInfo.processInfo.systemUptime + 1))
        close(stranger)
        XCTAssertTrue(answers.received.isEmpty, "Nothing a stranger sends is read or answered")
        refusing = nil
        _ = refusing

        var accepting: SafariExtensionServer? = try server("always", path: path, answers: answers)
        let oversized = try connect(path)
        var length = UInt32(SafariExtensionMessage.maximumBytes + 1).bigEndian
        _ = withUnsafeBytes(of: &length) { write(oversized, $0.baseAddress!, 4) }
        XCTAssertNil(readSafariExtensionFrame(oversized, until: ProcessInfo.processInfo.systemUptime + 1))
        close(oversized)
        XCTAssertTrue(answers.received.isEmpty)
        accepting = nil
        _ = accepting
    }

    @MainActor
    func testSafariCanAnswerWhetherTheExtensionIsOnFromItsOwnQueue() async {
        // SafariServices calls back on its own queue; a callback that belonged to the main actor
        // trapped there, which took WinMux down as Settings opened.
        let answered = expectation(description: "Safari answers")
        _ = Task { @MainActor in
            let isOn = await safariExtensionIsOn("dev.winmux.tests.no-such-extension")
            XCTAssertFalse(isOn)
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 20)
    }

    func testSearchFindsSafariTabsByHostAndVoiceOverHearsTheirSound() {
        let window = WorkspaceSidebarWindowViewModel(windowId: 1, workspaceName: "1", appName: "Safari",
            appBundleId: safariBundleId, appBundlePath: nil, title: "Inbox", isFocused: true)
        let workspace = WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId,
            displayName: "1", sidebarLabel: "", isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil,
            isFocused: true, isVisible: true, items: [.init(kind: .window(window))])
        var snapshot = tabs(["Inbox", "Docs"], selected: 0, window: 1)
        snapshot.tabs[1].host = "docs.example.com"
        snapshot.tabs[0].audio = .playing
        XCTAssertEqual(workspaceSidebarMatchingBrowserTabs(snapshot, window: window, workspace: workspace, query: "example").map(\.title), ["Docs"])
        XCTAssertEqual(workspaceSidebarBrowserTabAccessibilityLabel(snapshot.tabs[0], appName: "Safari"),
            "Inbox, playing sound, browser tab in Safari")
        snapshot.tabs[0].audio = .muted
        XCTAssertEqual(workspaceSidebarBrowserTabAccessibilityLabel(snapshot.tabs[0], appName: "Safari"), "Inbox, muted, browser tab in Safari")
    }

    @MainActor
    func testASafariTabShowsItsWebsiteIconInPlaceOfSafarisIcon() throws {
        let red = try png(.red)
        let redKey = key(red)
        SafariExtensionIcons.shared.images[redKey] = try XCTUnwrap(NSImage(data: red))
        defer { SafariExtensionIcons.shared.images = [:] }
        var browser = tabs(["Inbox", "Docs"], selected: 0, window: 1)
        browser.tabs[1].siteIcon = redKey
        browser.tabs[1].audio = .playing
        let window = WorkspaceSidebarWindowViewModel(windowId: 1, workspaceName: "1", appName: "Safari",
            appBundleId: safariBundleId, appBundlePath: nil, title: "Inbox", isFocused: true)
        let row = WorkspaceSidebarBrowserTabRowView(tab: browser.tabs[1], window: window, isActive: true, isSearchSelected: false,
            onSelect: {}, onClose: {})
        let host = NSHostingView(rootView: row.frame(width: 260).environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: 260, height: workspaceSidebarTabRowHeight)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var reddest = 0
        for x in 0..<bitmap.pixelsWide / 4 {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8, color.greenComponent < 0.3, color.blueComponent < 0.3 { reddest += 1 }
            }
        }
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        XCTAssertGreaterThan(CGFloat(reddest), 0.8 * pow(workspaceSidebarTabIconSize * scale, 2), "The website icon fills the icon column")
    }
}
