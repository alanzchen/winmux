import AppKit
@testable import AppBundle
import XCTest

/// Review counterexamples through the actual bridge, association, model address/route and
/// publication functions. Only the native AX/browser endpoints are synthetic.
@MainActor
final class BrowserPushReviewTest: XCTestCase {
    @MainActor
    private final class Harness {
        var now = 0.0
        let browser: String
        let profile = UUID().uuidString
        let session = UUID().uuidString
        let epoch = UUID().uuidString
        var sequence = 0
        var bridge: SafariExtensionBridge!
        var associations = SafariExtensionAssociations()
        var native: [UInt32: BrowserWindowTabs] = [:]
        var observed: [UInt32: Double] = [:]
        var frames: [UInt32: CGRect] = [:]
        var messages: [[String: Any]] = []
        var axTargets: [BrowserTabTarget] = []
        var validations = 0
        var source: String { "\(profile):\(session):\(epoch)" }

        init(_ browser: String = "safari") {
            self.browser = browser
            bridge = SafariExtensionBridge(browser: browser, configuration: { nil }, icons: SafariExtensionIcons(),
                now: { [unowned self] in now }, clock: { [unowned self] in now })
            bridge.sightSafariWindows = { [unowned self] _ in frames }
            bridge.setEnabled(true)
            bridge.pushSenders[profile] = { [unowned self] data in
                let command = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                messages.append(command)
                let kind = command["kind"] as! String
                for answer in kind == "probe" ? ["ready"] : kind == "select" ? ["result", "activated"] : [] {
                    _ = bridge.receive(.control(.init(profile: profile, session: session, browser: browser, epoch: epoch,
                        request: command["request"] as! String, kind: answer,
                        window: command["window"] as? Int, tab: command["tab"] as? Int)))
                }
            }
        }

        func snapshot(_ id: UInt32, titles: [String], audio: BrowserTabAudio? = nil, marker: Bool = false) -> BrowserWindowTabs {
            let lifetime = UUID()
            return .init(windowId: id, pid: 42, windowSession: lifetime,
                tabs: titles.enumerated().map { index, title in
                    .init(target: .init(windowId: id, pid: 42, windowSession: lifetime, tabId: UUID()),
                        title: title, isSelected: index == 0, audio: index == 0 ? audio : nil)
                }, marker: marker ? .init(session: String(session.prefix(8)), window: 10, tab: 100) : nil)
        }

        func window(_ id: Int, titles: [String], audio: BrowserTabAudio? = nil, order: [Int]? = nil) -> SafariExtensionWindow {
            .init(key: .init(source: source, id: id), session: session,
                bounds: CGRect(x: 0, y: 25, width: 800, height: 600),
                tabs: titles.enumerated().map { index, title in
                    .init(id: order?[index] ?? id * 10 + index, title: title, isActive: index == 0,
                        isAudible: index == 0 && audio == .playing, isMuted: index == 0 && audio == .muted)
                })
        }

        func report(_ windows: [SafariExtensionWindow], at time: Double, full: Bool = true, order: Int = 0) {
            now = time
            sequence += 1
            _ = bridge.receive(.state(.init(profile: profile, session: session, time: time * 1000,
                measured: time * 1000, order: order, allSites: true, windows: windows,
                push: .init(browser: browser, epoch: epoch, sequence: sequence, snapshot: full, removed: []))))
            update()
        }

        func read(_ id: UInt32, at time: Double) { now = time; observed[id] = time; update() }
        func update() {
            associations.update(native.values.map { .init(snapshot: $0, observed: observed[$0.windowId] ?? -.infinity) },
                windows: bridge.windows, now: now)
        }
        var selects: [[String: Any]] { messages.filter { $0["kind"] as? String == "select" } }
        var resyncs: [[String: Any]] { messages.filter { $0["kind"] as? String == "snapshot" } }

        func select(_ target: BrowserTabTarget) async -> BrowserTabActionResult {
            await BrowserTabsModel.routeSelection(target, browser: browser, bridge: bridge,
                snapshot: { self.native[target.windowId] }, associations: { self.associations },
                validateNative: { self.validations += 1; return nil },
                ax: { self.axTargets.append(target); return .dispatched(.confirmed) })
        }
    }

    func testTwoProfileLoadingSequenceCannotTurnMetadataForAIntoACommandFromB() async throws {
        for browser in ["chrome", "safari"] {
            let h = Harness(browser)
            h.native[1] = h.snapshot(1, titles: ["Loading", "Docs"])
            h.native[2] = h.snapshot(2, titles: ["Inbox", "Docs"])
            h.frames = [1: CGRect(x: 0, y: 25, width: 800, height: 600),
                        2: CGRect(x: 900, y: 25, width: 800, height: 600)]
            h.read(1, at: 0)
            h.read(2, at: 0)
            h.report([h.window(10, titles: ["Inbox", "Docs"])], at: 0.1)
            h.read(2, at: 1)
            h.read(2, at: 2)
            let clicked = try XCTUnwrap(h.native[2]?.tabs[1].target)
            let snapshot = try XCTUnwrap(h.native[2])
            XCTAssertTrue(h.associations.settles(snapshot), "Reproduces the review's metadata pairing despite contradictory bounds")
            XCTAssertEqual(h.associations.resolution(of: 2), .resolved(.init(source: h.source, id: 10)))
            let tab = try XCTUnwrap(h.associations.bound[clicked])
            XCTAssertNotNil(h.bridge.pushTarget(window: .init(source: h.source, id: 10), tab: tab), "Capability and result scope alone would allow A")
            let result = await h.select(clicked)
            XCTAssertEqual(result, .dispatched(.confirmed))
            XCTAssertEqual(h.axTargets, [clicked])
            XCTAssertTrue(h.selects.isEmpty, "B must never send A's extension ids")
            XCTAssertEqual(h.validations, 0, "Absent ownership proof takes AX before any extension dispatch preparation")
        }
    }

    private func markerOwnedSafari() -> Harness {
        let h = Harness()
        h.native[1] = h.snapshot(1, titles: ["Inbox", "Docs"], marker: true)
        h.report([h.window(10, titles: ["Inbox", "Docs"])], at: 0)
        h.read(1, at: 0.1)
        h.read(1, at: 1)
        h.report([h.window(10, titles: ["Inbox", "Docs"])], at: 2)
        h.read(1, at: 2.1)
        return h
    }

    func testSafariCommandNeedsMarkerOwnershipAndLaterNoReorderRowCorroboration() async throws {
        let h = markerOwnedSafari()
        let target = try XCTUnwrap(h.native[1]?.tabs[1].target)
        XCTAssertTrue(h.associations.settles(try XCTUnwrap(h.native[1])))
        _ = await h.select(target)
        XCTAssertTrue(h.selects.isEmpty, "Window ownership alone does not yet prove the clicked row")
        XCTAssertEqual(h.axTargets, [target])
        h.report([h.window(10, titles: ["Inbox", "Docs"])], at: 3)
        XCTAssertNil(h.associations.actionBinding(for: target, in: try XCTUnwrap(h.native[1])), "Need the post-report AX read too")
        h.read(1, at: 3.1)
        let result = await h.select(target)
        XCTAssertEqual(result, .dispatched(.confirmed))
        XCTAssertEqual(h.selects.count, 1)
        XCTAssertEqual(h.selects[0]["window"] as? Int, 10)
        XCTAssertEqual(h.selects[0]["tab"] as? Int, 101)
        XCTAssertEqual(h.validations, 1)
        XCTAssertEqual(h.axTargets, [target])
        h.native[1]?.marker = nil
        h.read(1, at: 3.2)
        _ = await h.select(target)
        XCTAssertEqual(h.selects.count, 1, "Metadata may hold, but a missing marker removes action authority immediately")
        XCTAssertEqual(h.axTargets, [target, target])
    }

    func testAReorderInvalidatesAnOtherwiseMarkerOwnedActionBinding() async throws {
        let h = markerOwnedSafari()
        h.report([h.window(10, titles: ["Inbox", "Docs"])], at: 3)
        h.read(1, at: 3.1)
        let target = try XCTUnwrap(h.native[1]?.tabs[1].target)
        XCTAssertNotNil(h.associations.actionBinding(for: target, in: try XCTUnwrap(h.native[1])))
        // A move away and back keeps titles/order identical but advances the event ledger.
        h.report([h.window(10, titles: ["Inbox", "Docs"])], at: 4, order: 2)
        h.read(1, at: 4.1)
        _ = await h.select(target)
        XCTAssertTrue(h.selects.isEmpty)
        XCTAssertEqual(h.axTargets, [target])
    }

    func testChromeOldSilenceCannotOverrideNewPlayingAXRead() throws {
        try chromeSound(old: nil, current: .playing)
    }

    func testChromeOldPlayingCannotOverrideNewSilentAXRead() throws {
        try chromeSound(old: .playing, current: nil)
    }

    private func chromeSound(old: BrowserTabAudio?, current: BrowserTabAudio?) throws {
        let h = Harness("chrome")
        h.native[1] = h.snapshot(1, titles: ["Same", "Docs"], audio: current)
        h.report([h.window(10, titles: ["Same", "Docs"], audio: old)], at: 0)
        h.read(1, at: 1)
        h.read(1, at: 2)
        let native = try XCTUnwrap(h.native[1])
        XCTAssertTrue(h.associations.settles(native))
        XCTAssertEqual(h.associations.described(native.tabs[0]).audio, old, "Reproduces the metadata sound contradiction")
        let shown = browserTabsShown(native, read: 2, now: 2.1, safari: h.associations, iconOrigins: [:], useExtensionSound: false)
        XCTAssertEqual(shown.tabs[0].audio, current)
        XCTAssertFalse(shown.knowsSound, "An extension's old silence never becomes authoritative Chrome silence")
    }

    func testChromeAXSoundExpiresAtTenSecondsWithoutExtensionResurrection() throws {
        let h = Harness("chrome")
        h.native[1] = h.snapshot(1, titles: ["Same", "Docs"], audio: .playing)
        h.report([h.window(10, titles: ["Same", "Docs"], audio: .playing)], at: 0)
        h.read(1, at: 1)
        h.read(1, at: 2)
        let native = try XCTUnwrap(h.native[1])
        for (time, expected) in [(11.999, BrowserTabAudio.playing as BrowserTabAudio?), (12.0, nil), (150.0, nil)] {
            let shown = browserTabsShown(native, read: 2, now: time, safari: h.associations, iconOrigins: [:], useExtensionSound: false)
            XCTAssertEqual(shown.tabs[0].audio, expected)
            XCTAssertFalse(shown.knowsSound)
        }
    }

    func testAOnlyDeltasDoNotRenewBCommandFreshnessOrItsOwnExpiry() throws {
        let h = Harness("chrome")
        let a = h.window(10, titles: ["A"]), b = h.window(20, titles: ["B"])
        h.report([a, b], at: 0)
        h.report([a], at: 50, full: false)
        h.now = 89.999
        XCTAssertNotNil(h.bridge.pushTarget(window: b.key, tab: try XCTUnwrap(b.tabKey(b.tabs[0]))))
        h.report([a], at: 90, full: false) // Refreshes the stream's capability, not B's observation.
        XCTAssertNil(h.bridge.pushTarget(window: b.key, tab: try XCTUnwrap(b.tabKey(b.tabs[0]))))
        XCTAssertNotNil(h.bridge.pushTarget(window: a.key, tab: try XCTUnwrap(a.tabKey(a.tabs[0]))))
        h.report([a], at: 100, full: false)
        h.report([a], at: 149, full: false)
        h.now = 149.999
        XCTAssertEqual(h.bridge.windows.count, 2)
        let generation = h.bridge.generation
        h.now = 150
        XCTAssertEqual(h.bridge.windows.map(\.key), [a.key], "The getter also enforces the exact boundary before maintenance")
        h.bridge.retain(safariIsRunning: true)
        XCTAssertGreaterThan(h.bridge.generation, generation, "Association evidence must advance when only a retained window expires")
        for time in [151.0, 200, 250, 300] {
            h.report([a], at: time, full: false)
            XCTAssertEqual(h.bridge.windows.map(\.key), [a.key])
            XCTAssertNil(h.bridge.pushTarget(window: b.key, tab: try XCTUnwrap(b.tabKey(b.tabs[0]))))
        }
    }

    func testDeltaPrunesExpiredWindowEvenBeforeMaintenanceRuns() {
        let h = Harness("chrome")
        let a = h.window(10, titles: ["A"]), b = h.window(20, titles: ["B"])
        h.report([a, b], at: 0)
        h.report([a], at: 100, full: false)
        let generation = h.bridge.generation
        h.report([a], at: 150, full: false)
        XCTAssertEqual(h.bridge.windows.map(\.key), [a.key])
        XCTAssertGreaterThan(h.bridge.generation, generation)
    }

    func testChromeResyncUsesScopedSenderAndHonorsRateLimitAndDisconnect() {
        let h = Harness("chrome")
        h.report([h.window(10, titles: ["A"])], at: 0)
        h.bridge.requestResync(atMostEvery: 10)
        XCTAssertEqual(h.resyncs.count, 1)
        XCTAssertEqual(h.resyncs[0]["profile"] as? String, h.profile)
        XCTAssertEqual(h.resyncs[0]["session"] as? String, h.session)
        XCTAssertEqual(h.resyncs[0]["epoch"] as? String, h.epoch)
        h.now = 9.999
        h.bridge.requestResync(atMostEvery: 10)
        XCTAssertEqual(h.resyncs.count, 1)
        h.now = 10
        h.bridge.requestResync(atMostEvery: 10)
        XCTAssertEqual(h.resyncs.count, 2)
        h.bridge.disconnect(h.profile)
        h.now = 20
        h.bridge.requestResync(atMostEvery: 10)
        XCTAssertEqual(h.resyncs.count, 2)
        h.bridge.setEnabled(false)
        h.bridge.requestResync()
        XCTAssertEqual(h.resyncs.count, 2)
    }
}
