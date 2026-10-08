import AppKit
@testable import AppBundle
import XCTest

/// Chrome selection through WinMux Tabs for Chrome, by the actual bridge, association and model
/// route. Two Chrome profiles report over separate connections, as the helper scopes them; only
/// the native AX endpoints and the extension's answers are synthetic.
@MainActor
final class ChromeExtensionSelectionTest: XCTestCase {
    @MainActor
    private final class Profile {
        let id = UUID().uuidString
        let session = UUID().uuidString.lowercased()
        let epoch = UUID().uuidString
        var sequence = 0
        var source: String { "\(id):\(session):\(epoch)" }
        func marker(window: Int, tab: Int) -> SafariExtensionMarker { .init(session: String(session.prefix(8)), window: window, tab: tab) }
    }

    @MainActor
    private final class Chrome {
        var now = 0.0
        let a = Profile(), b = Profile()
        var bridge: SafariExtensionBridge!
        var associations = SafariExtensionAssociations()
        var native: [UInt32: BrowserWindowTabs] = [:]
        var observed: [UInt32: Double] = [:]
        var commands: [(profile: String, message: [String: Any])] = []
        var axTargets: [BrowserTabTarget] = []
        var validations = 0

        init() {
            bridge = SafariExtensionBridge(browser: "chrome", configuration: { nil }, icons: SafariExtensionIcons(),
                now: { [unowned self] in now }, clock: { [unowned self] in now })
            bridge.sightSafariWindows = { _ in [:] }
            bridge.setEnabled(true)
            for profile in [a, b] {
                bridge.pushSenders[profile.id] = { [unowned self] data in
                    let command = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                    commands.append((profile.id, command))
                    let kind = command["kind"] as! String
                    for answer in kind == "probe" ? ["ready"] : kind == "select" ? ["result", "activated"] : [] {
                        _ = bridge.receive(.control(.init(profile: profile.id, session: profile.session, browser: "chrome",
                            epoch: profile.epoch, request: command["request"] as! String, kind: answer,
                            window: command["window"] as? Int, tab: command["tab"] as? Int)))
                    }
                }
            }
        }

        func snapshot(_ id: UInt32, titles: [String], marker: SafariExtensionMarker?) -> BrowserWindowTabs {
            let lifetime = UUID()
            return .init(windowId: id, pid: 42, windowSession: lifetime,
                tabs: titles.enumerated().map { index, title in
                    .init(target: .init(windowId: id, pid: 42, windowSession: lifetime, tabId: UUID()),
                        title: title, isSelected: index == 0)
                }, marker: marker)
        }

        /// Both profiles' windows sit maximized in the same place: bounds tell nothing apart.
        func window(_ profile: Profile, _ id: Int, titles: [String], tabs: [Int]) -> SafariExtensionWindow {
            .init(key: .init(source: profile.source, id: id), session: profile.session,
                bounds: CGRect(x: 0, y: 25, width: 1200, height: 800),
                tabs: zip(tabs, titles).enumerated().map { index, tab in
                    .init(id: tab.0, title: tab.1, isActive: index == 0)
                })
        }

        func report(_ profile: Profile, _ windows: [SafariExtensionWindow], at time: Double, order: Int = 0) {
            now = time
            profile.sequence += 1
            _ = bridge.receive(.state(.init(profile: profile.id, session: profile.session, time: time * 1000,
                measured: time * 1000, order: order, allSites: true, windows: windows,
                push: .init(browser: "chrome", epoch: profile.epoch, sequence: profile.sequence, snapshot: true, removed: []))))
            update()
        }

        func read(_ ids: [UInt32], at time: Double) {
            now = time
            for id in ids { observed[id] = time }
            update()
        }

        func update() {
            associations.update(native.values.map { .init(snapshot: $0, observed: observed[$0.windowId] ?? -.infinity) },
                windows: bridge.windows, now: now)
        }

        var selects: [(profile: String, message: [String: Any])] { commands.filter { $0.message["kind"] as? String == "select" } }

        func select(_ target: BrowserTabTarget) async -> BrowserTabActionResult {
            await BrowserTabsModel.routeSelection(target, browser: "chrome", bridge: bridge,
                snapshot: { self.native[target.windowId] }, associations: { self.associations },
                validateNative: { self.validations += 1; return nil },
                ax: { self.axTargets.append(target); return .dispatched(.confirmed) })
        }

        /// Reports, reads 0.75 s apart, then a report measured after those reads and a read
        /// begun after it arrived: what trusts a button and then corroborates its rows.
        func settle(_ reports: () -> Void, reads ids: [UInt32]) {
            reports()
            read(ids, at: now + 0.1)
            read(ids, at: now + 1)
            now += 1
            reports()
            read(ids, at: now + 0.1)
            now += 1
            reports()
            read(ids, at: now + 0.1)
        }
    }

    func testTwinWindowsInTwoProfilesEachSelectOnlyThroughTheirOwnProfilesConnection() async throws {
        let c = Chrome()
        c.native[1] = c.snapshot(1, titles: ["Inbox", "Docs"], marker: c.a.marker(window: 10, tab: 100))
        c.native[2] = c.snapshot(2, titles: ["Inbox", "Docs"], marker: c.b.marker(window: 20, tab: 200))
        c.settle({
            let time = c.now
            c.report(c.a, [c.window(c.a, 10, titles: ["Inbox", "Docs"], tabs: [100, 101])], at: time)
            c.report(c.b, [c.window(c.b, 20, titles: ["Inbox", "Docs"], tabs: [200, 201])], at: time)
        }, reads: [1, 2])
        let docsB = try XCTUnwrap(c.native[2]?.tabs[1].target)
        let result = await c.select(docsB)
        XCTAssertEqual(result, .dispatched(.confirmed))
        XCTAssertEqual(c.selects.count, 1)
        XCTAssertEqual(c.selects[0].profile, c.b.id, "B's click goes only to B's profile connection")
        XCTAssertEqual(c.selects[0].message["window"] as? Int, 20)
        XCTAssertEqual(c.selects[0].message["tab"] as? Int, 201)
        XCTAssertEqual(c.selects[0].message["session"] as? String, c.b.session)
        XCTAssertTrue(c.axTargets.isEmpty)
        let docsA = try XCTUnwrap(c.native[1]?.tabs[1].target)
        _ = await c.select(docsA)
        XCTAssertEqual(c.selects.count, 2)
        XCTAssertEqual(c.selects[1].profile, c.a.id)
        XCTAssertEqual(c.selects[1].message["window"] as? Int, 10)
        XCTAssertEqual(c.selects[1].message["tab"] as? Int, 101)
        XCTAssertEqual(c.validations, 2, "Each extension command first passes the exact native-control checks")

        // B's button leaves the toolbar (unpinned): the very next click is AX, whatever metadata holds.
        c.native[2]?.marker = nil
        c.read([2], at: c.now + 0.1)
        _ = await c.select(docsB)
        XCTAssertEqual(c.selects.count, 2)
        XCTAssertEqual(c.axTargets, [docsB])
    }

    func testTheReviewsTwoProfileSequenceStillSendsNothingWhenOnlyAReportsOrBsButtonIsUnpinned() async throws {
        // F1: A's stale read is Loading/Docs, its fresh report Inbox/Docs; B (another profile)
        // actually shows Inbox/Docs and is the only title-compatible window.
        for bShowsAMarkerOfItsOwn in [false, true] {
            let c = Chrome()
            c.native[1] = c.snapshot(1, titles: ["Loading", "Docs"], marker: nil)
            c.native[2] = c.snapshot(2, titles: ["Inbox", "Docs"],
                marker: bShowsAMarkerOfItsOwn ? c.b.marker(window: 20, tab: 200) : nil)
            c.settle({ c.report(c.a, [c.window(c.a, 10, titles: ["Inbox", "Docs"], tabs: [100, 101])], at: c.now) }, reads: [1, 2])
            let docsB = try XCTUnwrap(c.native[2]?.tabs[1].target)
            let result = await c.select(docsB)
            XCTAssertEqual(result, .dispatched(.confirmed))
            XCTAssertTrue(c.selects.isEmpty, "B never sends A's extension ids (B's own session: \(bShowsAMarkerOfItsOwn))")
            XCTAssertEqual(c.axTargets, [docsB])
            XCTAssertEqual(c.validations, 0)
        }
    }

    func testAMarkerTwoWindowsShowOrATabCarriesAcrossWindowsNamesNothing() async throws {
        // Both windows show A's marker at once: neither is trusted.
        let c = Chrome()
        let marker = c.a.marker(window: 10, tab: 100)
        c.native[1] = c.snapshot(1, titles: ["Inbox", "Docs"], marker: marker)
        c.native[2] = c.snapshot(2, titles: ["Inbox", "Docs"], marker: marker)
        c.settle({ c.report(c.a, [c.window(c.a, 10, titles: ["Inbox", "Docs"], tabs: [100, 101])], at: c.now) }, reads: [1, 2])
        for id: UInt32 in [1, 2] { _ = await c.select(try XCTUnwrap(c.native[id]?.tabs[1].target)) }
        XCTAssertTrue(c.selects.isEmpty)
        XCTAssertEqual(c.axTargets.count, 2)

        // A tab moved within profile A keeps its title naming its old window until restamped: the
        // named window no longer lists it as active, so the button names nothing.
        let m = Chrome()
        m.native[1] = m.snapshot(1, titles: ["Inbox"], marker: m.a.marker(window: 10, tab: 100))
        m.native[2] = m.snapshot(2, titles: ["Docs"], marker: m.a.marker(window: 10, tab: 101))
        m.settle({
            m.report(m.a, [m.window(m.a, 10, titles: ["Inbox"], tabs: [100]), m.window(m.a, 11, titles: ["Docs"], tabs: [101])],
                at: m.now, order: 1)
        }, reads: [1, 2])
        _ = await m.select(try XCTUnwrap(m.native[2]?.tabs[0].target))
        XCTAssertTrue(m.selects.isEmpty)
        XCTAssertEqual(m.axTargets.count, 1)
    }

    func testAReorderOrAButtonThatHasntCaughtUpWithdrawsChromeAuthority() async throws {
        let c = Chrome()
        c.native[1] = c.snapshot(1, titles: ["Inbox", "Docs"], marker: c.a.marker(window: 10, tab: 100))
        c.settle({ c.report(c.a, [c.window(c.a, 10, titles: ["Inbox", "Docs"], tabs: [100, 101])], at: c.now) }, reads: [1])
        let docs = try XCTUnwrap(c.native[1]?.tabs[1].target)
        XCTAssertNotNil(c.associations.actionBinding(for: docs, in: try XCTUnwrap(c.native[1])))
        // A move away and back: the same titles, in the same order, under a later reorder count.
        c.report(c.a, [c.window(c.a, 10, titles: ["Inbox", "Docs"], tabs: [100, 101])], at: c.now + 1, order: 2)
        c.read([1], at: c.now + 0.1)
        _ = await c.select(docs)
        XCTAssertTrue(c.selects.isEmpty)
        XCTAssertEqual(c.axTargets, [docs])
    }
}
