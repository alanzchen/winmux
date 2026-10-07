@testable import AppBundle
@testable import Cli
import Common
import XCTest

final class BrowserPushTest: XCTestCase {
    private let profile = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let epoch = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let session = "session"

    private func envelope(_ sequence: Int, snapshot: Bool = false, epoch: String? = nil, removed: [Int] = []) -> BrowserPushEnvelope {
        .init(browser: "chrome", epoch: epoch ?? self.epoch, sequence: sequence, snapshot: snapshot, removed: removed)
    }

    private func window(_ id: Int, tab: Int? = nil) -> SafariExtensionWindow {
        .init(key: .init(source: "\(profile):\(session)", id: id), session: session,
              tabs: [.init(id: tab ?? id * 10, title: "Synthetic", isActive: true)])
    }

    private func state(_ sequence: Int, snapshot: Bool = false, windows: [SafariExtensionWindow], removed: [Int] = []) -> SafariExtensionMessage {
        .state(.init(profile: profile, session: session, time: Double(sequence * 1000), measured: Double(sequence * 1000),
                     order: 0, allSites: true, windows: windows, push: envelope(sequence, snapshot: snapshot, removed: removed)))
    }

    func testProtocolRejectsUnknownVersionsFractionsBooleansAndConflictingRemovals() throws {
        let push: [String: Any] = ["v": 1, "browser": "chrome", "epoch": epoch, "seq": 1, "kind": "snapshot", "removed": []]
        XCTAssertNotNil(BrowserPushEnvelope.decode(push))
        for invalid in [["v": 2], ["seq": true], ["seq": 1.5], ["seq": 0], ["browser": "other"], ["epoch": "bad"],
                        ["removed": [1]], ["kind": "delta", "removed": [1, 1]]] as [[String: Any]] {
            XCTAssertNil(BrowserPushEnvelope.decode(push.merging(invalid) { $1 }))
        }
        var message: [String: Any] = ["v": 2, "type": "state", "session": session, "time": 1000, "push": push,
                                     "windows": [["id": 1, "tabs": [["id": 10, "title": "Synthetic", "active": true]]]]]
        func decode() throws -> SafariExtensionMessage? {
            SafariExtensionMessage.decode(try JSONSerialization.data(withJSONObject: ["profile": profile, "message": message]))
        }
        XCTAssertNotNil(try decode())
        message["push"] = push.merging(["kind": "delta", "removed": [1]]) { $1 }
        XCTAssertNil(try decode())
        message["push"] = push
        message["windows"] = [["id": 1, "incognito": true, "tabs": []]]
        XCTAssertNil(try decode())
        message["windows"] = [["id": 1, "tabs": [["id": 10, "title": "Synthetic", "active": true, "incognito": true]]]]
        XCTAssertNil(try decode())
    }

    func testRestartWithRetainedSessionAndReusedIdsGetsEntirelyNewBindingKeys() throws {
        func decode(_ epoch: String) throws -> SafariExtensionWindow {
            let raw: [String: Any] = ["v": 2, "type": "state", "session": session, "time": 1000,
                "push": ["v": 1, "browser": "safari", "epoch": epoch, "seq": 1, "kind": "snapshot", "removed": []],
                "windows": [["id": 1, "tabs": [["id": 10, "title": "Synthetic", "active": true]]]]]
            let data = try JSONSerialization.data(withJSONObject: ["profile": profile, "message": raw])
            guard case .state(let state) = SafariExtensionMessage.decode(data) else { return try XCTUnwrap(nil as SafariExtensionWindow?) }
            return try XCTUnwrap(state.windows.first)
        }
        let first = try decode(epoch)
        let restarted = try decode(UUID().uuidString)
        XCTAssertEqual(first.session, restarted.session)
        XCTAssertNotEqual(first.key, restarted.key)
        XCTAssertNotEqual(first.tabKey(first.tabs[0]), restarted.tabKey(restarted.tabs[0]))
    }

    func testGapPoisonsDeltasUntilSnapshotAndOldEpochCannotReturn() {
        var sequence = BrowserPushSequence()
        XCTAssertEqual(sequence.receive(session: session, envelope: envelope(1)), .snapshotRequired)
        XCTAssertEqual(sequence.receive(session: session, envelope: envelope(2, snapshot: true)), .accept)
        XCTAssertEqual(sequence.receive(session: session, envelope: envelope(2)), .duplicate)
        XCTAssertEqual(sequence.receive(session: session, envelope: envelope(4)), .snapshotRequired)
        XCTAssertEqual(sequence.receive(session: session, envelope: envelope(3)), .snapshotRequired)
        XCTAssertEqual(sequence.receive(session: session, envelope: envelope(5, snapshot: true)), .accept)
        XCTAssertEqual(sequence.receive(session: session, envelope: envelope(1, snapshot: true, epoch: UUID().uuidString)), .accept)
        XCTAssertEqual(sequence.receive(session: session, envelope: envelope(6, snapshot: true)), .duplicate)
    }

    @MainActor
    func testDeltaRetainsUnchangedWindowsOriginalEvidenceAndGapClearsTrust() throws {
        var now = 1.0
        let bridge = SafariExtensionBridge(browser: "chrome", configuration: { nil }, icons: SafariExtensionIcons(), now: { now }, clock: { now })
        bridge.setEnabled(true)
        bridge.sightSafariWindows = { _ in [1: CGRect(x: 1, y: 2, width: 3, height: 4)] }
        _ = bridge.receive(state(1, snapshot: true, windows: [window(1), window(2)]))
        let original = try XCTUnwrap(bridge.windows.first { $0.key.id == 2 })
        now = 2
        _ = bridge.receive(state(2, windows: [window(1)]))
        XCTAssertEqual(bridge.windows.first { $0.key.id == 2 }, original)
        XCTAssertEqual(bridge.windows.first { $0.key.id == 1 }?.received, 2)
        now = 3
        _ = bridge.receive(state(3, windows: [], removed: [1]))
        XCTAssertEqual(bridge.windows.map(\.key.id), [2])
        let reply = try JSONSerialization.jsonObject(with: bridge.receive(state(5, windows: []))) as? [String: Any]
        XCTAssertEqual(reply?["snapshot"] as? Bool, true)
        XCTAssertTrue(bridge.windows.isEmpty)
        _ = bridge.receive(state(6, snapshot: true, windows: [window(1)]))
        XCTAssertEqual(bridge.windows.map(\.key.id), [1])
        now += 151
        bridge.retain(safariIsRunning: true)
        XCTAssertTrue(bridge.windows.isEmpty, "Independent report expiry remains active without events")
    }

    @MainActor
    func testMovedTabNeedsBothWindowsInDeltaAndNeverExistsTwice() {
        let bridge = SafariExtensionBridge(browser: "chrome", configuration: { nil }, icons: SafariExtensionIcons())
        bridge.setEnabled(true)
        _ = bridge.receive(state(1, snapshot: true, windows: [window(1), window(2)]))
        _ = bridge.receive(state(2, windows: [window(2, tab: 10)]))
        XCTAssertTrue(bridge.windows.isEmpty, "An incomplete move cannot bind a tab to two windows")
        _ = bridge.receive(state(3, snapshot: true, windows: [window(2, tab: 10)]))
        XCTAssertEqual(bridge.windows.map(\.key.id), [2])
    }

    @MainActor
    private func readyBridge() throws -> (SafariExtensionBridge, BrowserPushTarget) {
        let bridge = SafariExtensionBridge(browser: "chrome", configuration: { nil }, icons: SafariExtensionIcons())
        bridge.setEnabled(true)
        bridge.pushSenders[profile] = { data in
            let message = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            if message["kind"] as? String == "probe" {
                _ = bridge.receive(.control(.init(profile: self.profile, session: self.session, browser: "chrome", epoch: self.epoch,
                    request: message["request"] as! String, kind: "ready", window: nil, tab: nil)))
            }
        }
        _ = bridge.receive(state(1, snapshot: true, windows: [window(1)]))
        let target = try XCTUnwrap(bridge.pushTarget(window: window(1).key, tab: .init(source: window(1).key.source, id: 10)))
        return (bridge, target)
    }

    @MainActor
    func testUnconfirmedAndLegacyExtensionsUseFallbackEligibility() throws {
        var now = 1.0
        let bridge = SafariExtensionBridge(browser: "chrome", configuration: { nil }, icons: SafariExtensionIcons(), now: { now })
        bridge.setEnabled(true)
        _ = bridge.receive(state(1, snapshot: true, windows: [window(1)]))
        XCTAssertNil(bridge.pushTarget(window: window(1).key, tab: .init(source: window(1).key.source, id: 10)))
        var probes = 0
        bridge.pushSenders[profile] = { _ in probes += 1 }
        now = 62
        _ = bridge.receive(state(2, snapshot: true, windows: [window(1)]))
        XCTAssertEqual(probes, 1, "An unanswered capability probe is retried only at a later report")
        _ = bridge.receive(.state(.init(profile: profile, session: session, time: 3000, allSites: true, windows: [window(1)])))
        XCTAssertNil(bridge.pushTarget(window: window(1).key, tab: .init(source: window(1).key.source, id: 10)))
    }

    @MainActor
    func testCommandRequiresBothExactScopedAcknowledgementsInEitherOrder() async throws {
        for kinds in [["result", "activated"], ["activated", "result"]] {
            let (bridge, target) = try readyBridge()
            bridge.pushSenders[profile] = { data in
                let command = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                for kind in kinds {
                    _ = bridge.receive(.control(.init(profile: self.profile, session: self.session, browser: "chrome", epoch: self.epoch,
                        request: command["request"] as! String, kind: kind, window: 1, tab: 10)))
                }
            }
            let result = await bridge.select(target)
            XCTAssertEqual(result, .dispatched(.confirmed))
        }
    }

    func testWrongProfileSessionEpochRequestWindowOrTabNeverConfirms() {
        let target = BrowserPushTarget(browser: "chrome", profile: profile, session: session, epoch: epoch, window: 1, tab: 10, sequence: 1)
        let request = UUID().uuidString
        var confirmation = BrowserPushConfirmation(request: request, target: target)
        for wrong in 0..<7 {
            for kind in ["result", "activated"] {
                confirmation.receive(.init(profile: wrong == 0 ? "wrong" : profile, session: wrong == 1 ? "wrong" : session,
                    browser: wrong == 2 ? "safari" : "chrome", epoch: wrong == 3 ? "wrong" : epoch,
                    request: wrong == 4 ? "wrong" : request, kind: kind, window: wrong == 5 ? 2 : 1, tab: wrong == 6 ? 20 : 10))
            }
        }
        XCTAssertNil(confirmation.outcome)
    }

    @MainActor
    func testMissingActivationTimesOutUnknownWithoutRetryAndLateResultCannotReviveIt() async throws {
        let (bridge, target) = try readyBridge()
        var sends = 0
        var late: BrowserPushControl?
        bridge.pushSenders[profile] = { data in
            sends += 1
            let command = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            let request = command["request"] as! String
            _ = bridge.receive(.control(.init(profile: self.profile, session: self.session, browser: "chrome", epoch: self.epoch,
                request: request, kind: "result", window: 1, tab: 10)))
            late = .init(profile: self.profile, session: self.session, browser: "chrome", epoch: self.epoch,
                request: request, kind: "activated", window: 1, tab: 10)
        }
        let result = await bridge.select(target)
        XCTAssertEqual(result, .dispatched(.unknown))
        _ = bridge.receive(.control(try XCTUnwrap(late)))
        XCTAssertEqual(sends, 1)
        let followUp = BrowserTabActionFollowUp(result, kind: .select, browser: "Chrome")
        XCTAssertNotNil(followUp.message, "An unknown outcome has user-visible feedback")
    }

    @MainActor
    func testCancellationAndDisconnectReturnUnknownWithoutAXRetry() async throws {
        let (bridge, target) = try readyBridge()
        var sends = 0
        bridge.pushSenders[profile] = { data in
            let message = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            if message["kind"] as? String == "select" { sends += 1 }
        }
        let request = Task { await bridge.select(target) }
        while sends == 0 { await Task.yield() }
        request.cancel()
        let result = await request.value
        XCTAssertEqual(result, .dispatched(.unknown))
        let other = Task { await bridge.select(target) }
        while sends < 2 { await Task.yield() }
        bridge.disconnect(profile)
        let disconnected = await other.value
        XCTAssertEqual(disconnected, .dispatched(.unknown))
        XCTAssertEqual(sends, 2)
        XCTAssertNil(bridge.pushTarget(window: window(1).key, tab: .init(source: window(1).key.source, id: 10)))
    }

    @MainActor
    func testProductionFallbackRunsForAbsentOrRefusedButNeverPossiblyExecutedCommand() async {
        var calls = 0
        let ax = { @MainActor in calls += 1; return BrowserTabActionResult.dispatched(.confirmed) }
        _ = await browserTabSelectWithFallback(push: nil, ax: ax)
        _ = await browserTabSelectWithFallback(push: { .notDispatched(.changed) }, ax: ax)
        XCTAssertEqual(calls, 2)
        for result in [BrowserTabActionResult.dispatched(.unknown), .dispatched(.confirmed), .failed(.timedOut), .notDispatched(.cancelled)] {
            let actual = await browserTabSelectWithFallback(push: { result }, ax: ax)
            XCTAssertEqual(actual, result)
        }
        XCTAssertEqual(calls, 2)
    }

    func testNativeFramesRejectOversizedInputAndRoundTripWithoutBrowser() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let data = Data("{\"synthetic\":true}".utf8)
        XCTAssertTrue(BrowserPushIO.write(data, to: fds[0]))
        XCTAssertEqual(BrowserPushIO.read(fds[1]), data)
        var oversized = UInt32(BrowserPushIO.maximumBytes + 1)
        _ = withUnsafeBytes(of: &oversized) { Darwin.write(fds[0], $0.baseAddress, 4) }
        XCTAssertNil(BrowserPushIO.read(fds[1]))
    }

    func testExplicitHostInstallerUsesOnlyGivenHomeAndStableOrigin() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = URL(fileURLWithPath: "/Synthetic/WinMux.app/Contents/Helpers/winmux")
        let file = try ChromeNativeHost.install(helper: helper, home: home)
        XCTAssertTrue(file.path.hasPrefix(home.path + "/Library/Application Support/Google/Chrome/NativeMessagingHosts/"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(manifest["path"] as? String, helper.path)
        XCTAssertEqual(manifest["allowed_origins"] as? [String], [BrowserPushIdentity.origin])
    }
}
