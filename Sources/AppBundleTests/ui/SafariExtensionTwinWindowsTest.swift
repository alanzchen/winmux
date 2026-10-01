import AppKit
@testable import AppBundle
import XCTest

/// Two Safari windows, each with one tab showing the same page. WinMux reads each as one tab
/// named by its window's title, so they're twins: only where they were when Safari reported
/// tells them apart. In Tabs mode each is its own tab, and the one not shown is parked in the
/// display's corner, where any other parked window of the same size is too. Safari reports where
/// its windows are only with its tabs, so after a switch its bounds are the switch's mirror
/// image until its next report.
@MainActor
final class SafariExtensionTwinWindowsTest: XCTestCase {
    private static let icon = String(repeating: "a", count: 64)
    private static let otherIcon = String(repeating: "b", count: 64)
    /// The workspace's frame on a 1024x768 display, and where hideInCorner parks a window that size.
    private static let shown = CGRect(x: 0, y: 25, width: 1024, height: 743)
    private static let parked = CGRect(x: 1023, y: 767, width: 1024, height: 743)

    /// What BrowserTabsModel joins, driven step by step: where Safari's windows are as WinMux
    /// samples them, the bridge receiving Safari's reports and recording where windows were
    /// then, and the associations, updated at each Accessibility read.
    @MainActor
    private final class Harness {
        var uptime: TimeInterval = 1000
        var wall: TimeInterval = 1_790_000_000
        /// Where each window is now.
        var frames: [UInt32: CGRect] = [:]
        var reads: [UInt32: BrowserWindowTabs] = [:]
        var observed: [UInt32: TimeInterval] = [:]
        var track = SafariExtensionFrameTrack()
        var associations = SafariExtensionAssociations()
        var bridge: SafariExtensionBridge!
        var session = "s1"
        /// Each window's row after every read, as "id: site|other site|Safari [sound] [host]".
        var timeline: [String] = []

        init() {
            bridge = SafariExtensionBridge(configuration: { nil }, icons: SafariExtensionIcons(),
                now: { [unowned self] in uptime }, clock: { [unowned self] in wall })
            bridge.sightSafariWindows = { [unowned self] measured in
                sample()
                return track.sighting(measured: measured)
            }
            bridge.setEnabled(true)
        }

        /// WinMux samples frames a few times a second.
        func sample() { track.observe(frames.mapValues { Optional($0) }, now: uptime) }

        func wait(_ seconds: TimeInterval) {
            var left = seconds
            while left > 0 {
                let step = min(0.25, left)
                uptime += step
                wall += step
                left -= step
                sample()
            }
        }

        func move(_ id: UInt32, to frame: CGRect) {
            frames[id] = frame
            sample()
        }

        /// Safari measures its windows, and the report arrives `transit` later. `bounds` default
        /// to where windows are as Safari measures them.
        func report(_ windows: [(id: Int, native: UInt32?, tabs: [SafariExtensionTab])], bounds: [Int: CGRect] = [:],
                    transit: TimeInterval = 0.05, during: () -> Void = {}) {
            let measured = windows.map { window -> [String: Any] in
                let frame = bounds[window.id] ?? window.native.flatMap { frames[$0] }
                var raw: [String: Any] = ["id": window.id, "tabs": window.tabs.map { tab -> [String: Any] in
                    var raw: [String: Any] = ["title": tab.title, "active": tab.isActive, "audible": tab.isAudible, "muted": tab.isMuted]
                    if let id = tab.id { raw["id"] = id }
                    if let host = tab.host { raw["host"] = host }
                    if let icon = tab.icon { raw["icon"] = icon }
                    return raw
                }]
                if let frame { raw["bounds"] = [frame.minX, frame.minY, frame.width, frame.height] }
                return raw
            }
            let stamp = wall * 1000
            during()
            uptime += transit
            wall += transit
            sample()
            let version = windows.allSatisfy { $0.tabs.allSatisfy { $0.id != nil } } ? 2 : 1
            let message: [String: Any] = ["v": version, "type": "state", "session": session, "time": stamp, "windows": measured]
            let data = try! JSONSerialization.data(withJSONObject: ["message": message, "profile": "8A7B6C5D-0000-4000-8000-000000000001"])
            _ = bridge.receive(SafariExtensionMessage.decode(data))
            update()
        }

        /// A new Accessibility read of each window in `ids`, then pairing with what's known.
        func read(_ ids: UInt32...) {
            for id in ids { observed[id] = uptime }
            update()
        }

        func update() {
            associations.update(reads.keys.sorted().map { .init(snapshot: reads[$0]!, observed: observed[$0] ?? 0) },
                windows: bridge.windows, now: uptime)
            timeline.append(reads.keys.sorted().map(row).joined(separator: ", "))
        }

        func row(_ id: UInt32) -> String {
            guard let snapshot = reads[id] else { return "\(id): closed" }
            return "\(id): " + snapshot.tabs.map { tab in
                let tab = associations.described(tab)
                var text = tab.siteIcon.map { $0 == SafariExtensionTwinWindowsTest.icon ? "site" : "other site" } ?? "Safari"
                if tab.audio == .playing { text += " sound" }
                if let host = tab.host, host != "demo.test" { text += " " + host }
                return text
            }.joined(separator: " | ")
        }
    }

    private static func lone(_ title: String, window: UInt32, session: UUID = UUID()) -> BrowserWindowTabs {
        .init(windowId: window, pid: 7, windowSession: session, tabs: [
            .init(target: .init(windowId: window, pid: 7, windowSession: session, tabId: UUID()), title: title, isSelected: true),
        ])
    }

    private static func tab(_ title: String = "Demo Page", id: Int?, icon: String? = icon, audible: Bool = false, host: String = "demo.test",
                            active: Bool = true) -> SafariExtensionTab {
        .init(id: id, title: title, host: host, isActive: active, isAudible: audible, icon: icon)
    }

    /// Twins A (window 1, playing sound) and B (window 2), A shown and B parked, paired.
    private func pairedTwins(ids: Bool = true) -> Harness {
        let harness = Harness()
        harness.frames = [1: Self.shown, 2: Self.parked]
        harness.reads = [1: Self.lone("Demo Page", window: 1), 2: Self.lone("Demo Page", window: 2)]
        harness.wait(2)
        harness.report(twins(ids: ids))
        harness.wait(1)
        harness.read(1, 2)
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site")
        return harness
    }

    private func twins(ids: Bool = true, audibleA: Bool = true) -> [(id: Int, native: UInt32?, tabs: [SafariExtensionTab])] {
        [(10, 1, [Self.tab(id: ids ? 100 : nil, audible: audibleA)]), (11, 2, [Self.tab(id: ids ? 101 : nil)])]
    }

    private func switchTabs(_ harness: Harness) {
        let a = harness.frames[1]!
        harness.move(1, to: harness.frames[2]!)
        harness.move(2, to: a)
    }

    // MARK: 1. Switching moves twins; nothing reported in between, then a fresh report

    func testTwinsKeepTheirIconsAndSoundThroughSwitchesAndAFreshReportWithStaggeredReads() {
        for ids in [true, false] {
            let harness = pairedTwins(ids: ids)
            let before = harness.timeline.count
            for _ in 0..<4 {
                switchTabs(harness)
                // The shown window is read every second, the parked one every four.
                for second in 1...4 {
                    harness.wait(1)
                    if second == 4 { harness.read(1, 2) } else { harness.read(harness.frames[1] == Self.shown ? 1 : 2) }
                }
            }
            // Safari's heartbeat: fresh bounds, the mirror image of the first report's.
            harness.report(twins(ids: ids))
            harness.wait(1)
            harness.read(2)
            harness.wait(1)
            harness.read(1)
            XCTAssertEqual(Set(harness.timeline[before...]), ["1: site sound, 2: site"], "ids: \(ids)")
            XCTAssertEqual(harness.associations.resolution(of: 1), .resolved(.init(source: "8A7B6C5D-0000-4000-8000-000000000001:s1", id: 10)))
        }
    }

    // MARK: 2. A first pairing never comes from frames taken at another moment

    func testAFirstPairingFromAReportOlderThanASwitchStillPairsEachTwinWithItsOwnReport() {
        let harness = Harness()
        harness.frames = [1: Self.shown, 2: Self.parked]
        harness.reads = [1: Self.lone("Demo Page", window: 1), 2: Self.lone("Demo Page", window: 2)]
        harness.wait(2)
        harness.report(twins())
        // WinMux switches before either window is read, and again between the reads that confirm.
        switchTabs(harness)
        harness.wait(1)
        harness.read(1, 2)
        switchTabs(harness)
        harness.wait(1)
        harness.read(1, 2)
        switchTabs(harness)
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site", "Each twin is paired with the report of where it was then")
        harness.report(twins())
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site")
        XCTAssertFalse(harness.timeline.contains { $0.contains("2: site sound") }, "B never shows A's sound")
    }

    func testAReportWhoseWindowsMovedWhileItWasOnItsWayPairsNothingUntilSafariReportsAgain() {
        let harness = Harness()
        harness.frames = [1: Self.shown, 2: Self.parked]
        harness.reads = [1: Self.lone("Demo Page", window: 1), 2: Self.lone("Demo Page", window: 2)]
        harness.wait(2)
        // Safari measures, then WinMux switches while the report is on its way.
        harness.report(twins(), transit: 0.2) { switchTabs(harness) }
        for _ in 0..<3 {
            harness.wait(1)
            harness.read(1, 2)
        }
        XCTAssertEqual(Set(harness.timeline), ["1: Safari, 2: Safari"], "Where the twins were when Safari measured is unknown")
        XCTAssertTrue(harness.associations.awaitsFrames, "WinMux asks Safari to report again")
        XCTAssertEqual(harness.associations.resolution(of: 1), .unresolved)
        // The reply to that request comes seconds later, with the windows where they are now.
        harness.wait(3)
        harness.report(twins())
        harness.wait(1)
        harness.read(1, 2)
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site")
        XCTAssertFalse(harness.timeline.contains { $0.contains("2: site sound") })
        XCTAssertFalse(harness.associations.awaitsFrames)
    }

    func testTwinsSeenInTheSamePlaceStayUnresolvedWithoutAskingSafariAgain() {
        // Three twins: A shown, B and C both parked in the same corner.
        let harness = Harness()
        harness.frames = [1: Self.shown, 2: Self.parked, 3: Self.parked]
        harness.reads = [1: Self.lone("Demo Page", window: 1), 2: Self.lone("Demo Page", window: 2), 3: Self.lone("Demo Page", window: 3)]
        harness.wait(2)
        harness.report(twins() + [(12, 3, [Self.tab(id: 102)])])
        for _ in 0..<2 {
            harness.wait(1)
            harness.read(1, 2, 3)
        }
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: Safari, 3: Safari", "Only A's place settles which report is A")
        XCTAssertEqual(harness.associations.resolution(of: 2), .unresolved)
        XCTAssertFalse(harness.associations.awaitsFrames, "Another report from the same places wouldn't settle it")
    }

    // MARK: 3. A held twin keeps getting its own window's updates, and only those

    func testAHeldTwinGetsItsReportsUpdatesAndLetsGoOfThemWhenItsTabsDisagree() {
        let harness = pairedTwins()
        switchTabs(harness)
        func report(_ a: SafariExtensionTab) {
            harness.report([(10, 1, [a]), (11, 2, [Self.tab(id: 101)])])
            harness.wait(1)
            harness.read(2)
        }
        report(Self.tab(id: 100, icon: Self.otherIcon, audible: true))
        XCTAssertEqual(harness.timeline.last, "1: other site sound, 2: site")
        report(Self.tab(id: 100, audible: true, host: "news.test"))
        XCTAssertEqual(harness.timeline.last, "1: site sound news.test, 2: site")
        report(Self.tab(id: 100, audible: false))
        XCTAssertEqual(harness.timeline.last, "1: site, 2: site")
        report(Self.tab(id: 100, icon: nil))
        XCTAssertEqual(harness.timeline.last, "1: Safari, 2: site", "A report without an icon takes it away")
        report(Self.tab(id: 100, audible: true))
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site")

        // A's title changes in its read before Safari reports it: sound goes at once, the icon after the grace period.
        harness.reads[1] = .init(windowId: 1, pid: 7, windowSession: harness.reads[1]!.windowSession, tabs: [
            .init(target: harness.reads[1]!.tabs[0].target, title: "(1) Demo Page", isSelected: true),
        ])
        harness.read(1)
        XCTAssertEqual(harness.timeline.last, "1: site, 2: site")
        XCTAssertEqual(harness.associations.resolution(of: 1), .stale(.init(source: "8A7B6C5D-0000-4000-8000-000000000001:s1", id: 10)))
        harness.wait(SafariExtensionAssociations.grace + 1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: Safari, 2: site")
        // Safari reports the new title too: A pairs again, by where it was when Safari measured.
        harness.report([(10, 1, [Self.tab("(1) Demo Page", id: 100, audible: true)]), (11, 2, [Self.tab(id: 101)])])
        harness.wait(1)
        harness.read(1, 2)
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site")
        // Both sides change together, as when A goes to another page: the pairing holds throughout.
        let before = harness.timeline.count
        harness.reads[1] = .init(windowId: 1, pid: 7, windowSession: harness.reads[1]!.windowSession, tabs: [
            .init(target: harness.reads[1]!.tabs[0].target, title: "Other Page", isSelected: true),
        ])
        harness.report([(10, 1, [Self.tab("Other Page", id: 100, icon: Self.otherIcon, audible: true)]), (11, 2, [Self.tab(id: 101)])])
        harness.wait(1)
        harness.read(1)
        XCTAssertEqual(harness.timeline.last, "1: other site sound, 2: site")
        XCTAssertFalse(harness.timeline[before...].contains { $0.hasPrefix("1: Safari") })
    }

    // MARK: 4. Closing twins, new sessions, and a window number reused

    func testClosingATwinOnEitherSideFirstLeavesTheOtherPairedAndItsReportCantBeAdopted() {
        for safariFirst in [true, false] {
            let harness = pairedTwins()
            switchTabs(harness)
            let closeNative = {
                harness.reads[1] = nil
                harness.frames[1] = nil
                harness.read(2)
            }
            let closeReport = { harness.report([(11, 2, [Self.tab(id: 101)])]) }
            if safariFirst { closeReport(); closeNative() } else { closeNative(); closeReport() }
            XCTAssertEqual(harness.timeline.last, "2: site")
            // A new twin opens where A was.
            harness.wait(1)
            harness.frames[3] = Self.parked
            harness.reads[3] = Self.lone("Demo Page", window: 3)
            harness.read(3)
            harness.wait(1)
            harness.read(2, 3)
            XCTAssertEqual(harness.timeline.last, "2: site, 3: Safari", "safariFirst: \(safariFirst)")
            harness.wait(1)
            harness.report([(11, 2, [Self.tab(id: 101)]), (12, 3, [Self.tab(id: 102, audible: true)])])
            harness.wait(1)
            harness.read(2, 3)
            harness.wait(1)
            harness.read(2, 3)
            XCTAssertEqual(harness.timeline.last, "2: site, 3: site sound")
        }
    }

    func testANewExtensionSessionReusingIdsAndANewWindowUnderAnOldNumberStartOver() {
        let harness = pairedTwins()
        // Safari relaunches, or reloads the extension: a new session reuses the same ids, with B playing now.
        harness.session = "s2"
        harness.report([(10, 1, [Self.tab(id: 100)]), (11, 2, [Self.tab(id: 101, audible: true)])])
        XCTAssertEqual(harness.timeline.last, "1: Safari, 2: Safari", "Nothing carries over from the old session's windows")
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site, 2: site sound")
        // A closes, and a new window gets its number before WinMux sees it gone, somewhere else.
        harness.reads[1] = Self.lone("Demo Page", window: 1)
        harness.frames[1] = Self.shown.offsetBy(dx: 0, dy: 0)
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: Safari, 2: site sound", "The new window doesn't inherit the old one's pairing")
        XCTAssertEqual(harness.associations.resolution(of: 1), .unresolved, "Nor where the old one was when Safari last reported")
        XCTAssertTrue(harness.associations.awaitsFrames)
        harness.wait(1)
        harness.report([(10, 1, [Self.tab(id: 100)]), (11, 2, [Self.tab(id: 101, audible: true)])])
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site, 2: site sound")
    }

    /// Should a pairing ever be wrong, a later report whose frames settle it otherwise corrects
    /// it; a hold never keeps a wrong window's sound for good.
    func testALaterReportWhoseFramesPairATwinOtherwiseOverrulesItsHold() {
        let key = { SafariExtensionWindowKey(source: "p:s", id: $0) }
        let a = Self.lone("Demo Page", window: 1)
        let b = Self.lone("Demo Page", window: 2)
        func report(a aSeen: CGRect, b bSeen: CGRect, received: TimeInterval) -> [SafariExtensionWindow] {
            [.init(key: key(10), bounds: Self.shown, tabs: [Self.tab(id: 100, audible: true)], received: received, sighting: [1: aSeen, 2: bSeen]),
             .init(key: key(11), bounds: Self.parked, tabs: [Self.tab(id: 101)], received: received, sighting: [1: aSeen, 2: bSeen])]
        }
        var associations = SafariExtensionAssociations()
        // Say a report once put B where Safari's playing window was.
        for time in [0.0, 1] {
            associations.update([.init(snapshot: a, observed: time), .init(snapshot: b, observed: time)],
                windows: report(a: Self.parked, b: Self.shown, received: 0), now: time)
        }
        XCTAssertEqual(associations.described(b.tabs[0]).audio, .playing)
        // A report without frames to go by changes nothing.
        var unseen = report(a: Self.parked, b: Self.shown, received: 2)
        for index in unseen.indices { unseen[index].sighting = [:] }
        associations.update([.init(snapshot: a, observed: 2), .init(snapshot: b, observed: 2)], windows: unseen, now: 2)
        XCTAssertEqual(associations.described(b.tabs[0]).audio, .playing)
        // One whose frames say otherwise wins.
        for time in [3.0, 4] {
            associations.update([.init(snapshot: a, observed: time), .init(snapshot: b, observed: time)],
                windows: report(a: Self.shown, b: Self.parked, received: 3), now: time)
        }
        XCTAssertEqual(associations.described(a.tabs[0]).audio, .playing)
        XCTAssertNil(associations.described(b.tabs[0]).audio)
        XCTAssertEqual(associations.resolution(of: 2), .resolved(key(11)))
    }

    // MARK: 5. A report two windows were paired with

    func testAReportTwoWindowsWerePairedWithIsHeldByNeitherAndOnlyAMatchGetsItsSound() {
        for order in [[UInt32(1), 2], [2, 1]] {
            let key = SafariExtensionWindowKey(source: "p:s", id: 10)
            let a = Self.lone("Demo Page", window: 1)
            let b = Self.lone("Demo Page", window: 2)
            func window(_ sighting: [UInt32: CGRect], audible: Bool = true) -> SafariExtensionWindow {
                .init(key: key, bounds: Self.shown, tabs: [Self.tab(id: 100, audible: audible)], sighting: sighting)
            }
            var retitled = a
            retitled.tabs[0].title = "(1) Demo Page"
            var associations = SafariExtensionAssociations()
            func update(_ a: BrowserWindowTabs?, _ b: BrowserWindowTabs, _ windows: [SafariExtensionWindow], at time: TimeInterval) {
                let candidates = [a.map { SafariExtensionCandidate(snapshot: $0, observed: time) }, SafariExtensionCandidate(snapshot: b, observed: time)]
                    .compactMap { $0 }.sorted { order.firstIndex(of: $0.snapshot.windowId)! < order.firstIndex(of: $1.snapshot.windowId)! }
                associations.update(candidates, windows: windows, now: time)
            }
            // A pairs with the report; then its title changes, and B, seen where Safari says, pairs with it.
            update(a, b, [window([1: Self.shown, 2: Self.parked])], at: 0)
            update(a, b, [window([1: Self.shown, 2: Self.parked])], at: 1)
            XCTAssertEqual(associations.resolution(of: 1), .resolved(key))
            update(retitled, b, [window([2: Self.shown])], at: 2)
            update(retitled, b, [window([2: Self.shown])], at: 3)
            XCTAssertEqual(associations.resolution(of: 1), .stale(key))
            XCTAssertEqual(associations.resolution(of: 2), .resolved(key))
            // A's title is back within the grace period: both were paired with that report.
            update(a, b, [window([1: Self.shown, 2: Self.shown])], at: 4)
            XCTAssertEqual(associations.described(a.tabs[0]).audio, nil, "order \(order)")
            XCTAssertEqual(associations.described(b.tabs[0]).audio, nil, "Where the report came from doesn't settle it, so neither plays")
            // A newer report settles it: A was where Safari says.
            update(a, b, [window([1: Self.shown, 2: Self.parked])], at: 5)
            XCTAssertEqual(associations.described(a.tabs[0]).audio, .playing, "order \(order)")
            XCTAssertEqual(associations.described(b.tabs[0]).audio, nil)
            XCTAssertEqual(associations.resolution(of: 2), .stale(key))
            update(a, b, [window([1: Self.shown, 2: Self.parked])], at: 5 + SafariExtensionAssociations.grace + 1)
            XCTAssertEqual(associations.resolution(of: 2), .unresolved)
            XCTAssertNil(associations.described(b.tabs[0]).siteIcon)
        }
    }

    // MARK: Tabs inside a window, by Safari's ids

    func testTabsWithTheSameTitleKeepTheirOwnSoundWhenReorderedBeforeWinMuxRereadsThem() {
        let harness = Harness()
        harness.frames = [1: Self.shown]
        let session = UUID()
        func listed(_ title: String, selected: Bool = false) -> BrowserTab {
            .init(target: .init(windowId: 1, pid: 7, windowSession: session, tabId: UUID()), title: title, isSelected: selected)
        }
        let mail = listed("Mail", selected: true)
        let quiet = listed("Demo Page")
        let playing = listed("Demo Page")
        harness.reads = [1: .init(windowId: 1, pid: 7, windowSession: session, tabs: [mail, quiet, playing])]
        harness.wait(2)
        let reportedMail = Self.tab("Mail", id: 99, icon: Self.otherIcon, host: "mail.test")
        let reportedQuiet = Self.tab(id: 100, active: false)
        let reportedPlaying = Self.tab(id: 101, icon: Self.otherIcon, audible: true, active: false)
        harness.report([(10, 1, [reportedMail, reportedQuiet, reportedPlaying])])
        harness.wait(1)
        harness.read(1)
        harness.wait(1)
        harness.read(1)
        XCTAssertEqual(harness.timeline.last, "1: other site mail.test | site | other site sound")
        XCTAssertEqual(harness.associations.described(playing).extensionTab, .init(source: "8A7B6C5D-0000-4000-8000-000000000001:s1", id: 101))
        // The playing tab is dragged before the quiet one. Safari reports the new order before
        // WinMux reads the tab bar again, and the titles still agree place by place.
        harness.report([(10, 1, [reportedMail, reportedPlaying, reportedQuiet])])
        XCTAssertEqual(harness.timeline.last, "1: other site mail.test | site | other site sound",
            "Each listed tab keeps its own Safari tab until a read sees the new order")
        harness.wait(1)
        harness.reads[1] = .init(windowId: 1, pid: 7, windowSession: session, tabs: [mail, playing, quiet])
        harness.read(1)
        XCTAssertEqual(harness.timeline.last, "1: other site mail.test | other site sound | site")
        XCTAssertEqual(harness.associations.described(playing).extensionTab?.id, 101)
        XCTAssertEqual(harness.associations.described(quiet).extensionTab?.id, 100)
        // An older extension doesn't name tabs: by position, the same report would have swapped them.
        var positional = SafariExtensionAssociations()
        let stale = BrowserWindowTabs(windowId: 1, pid: 7, windowSession: session, tabs: [mail, quiet, playing])
        let unnamed = [reportedMail, reportedPlaying, reportedQuiet].map { tab -> SafariExtensionTab in
            var tab = tab
            tab.id = nil
            return tab
        }
        for time in [0.0, 1] {
            positional.update([.init(snapshot: stale, observed: time)], windows: [.init(key: .init(source: "p:s", id: 10), tabs: unnamed)], now: time)
        }
        XCTAssertEqual(positional.described(quiet).audio, .playing, "What protocol 1 does, and why tabs now carry ids")
    }

    func testATabMovedToAnotherWindowTakesItsDetailsWithItOnceBothWindowsAgree() {
        let harness = Harness()
        harness.frames = [1: Self.shown, 2: Self.parked]
        let one = UUID()
        let two = UUID()
        let inbox = BrowserTab(target: .init(windowId: 1, pid: 7, windowSession: one, tabId: UUID()), title: "Inbox", isSelected: true)
        let radio = BrowserTab(target: .init(windowId: 1, pid: 7, windowSession: one, tabId: UUID()), title: "Radio", isSelected: false)
        let docs = BrowserTab(target: .init(windowId: 2, pid: 7, windowSession: two, tabId: UUID()), title: "Docs", isSelected: true)
        harness.reads = [1: .init(windowId: 1, pid: 7, windowSession: one, tabs: [inbox, radio]), 2: .init(windowId: 2, pid: 7, windowSession: two, tabs: [docs])]
        harness.wait(2)
        harness.report([(10, 1, [Self.tab("Inbox", id: 100), Self.tab("Radio", id: 101, icon: Self.otherIcon, audible: true, active: false)]),
                        (11, 2, [Self.tab("Docs", id: 102)])])
        harness.wait(1)
        harness.read(1, 2)
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site | other site sound, 2: site")
        // Radio moves to the second window. Safari reports first.
        harness.report([(10, 1, [Self.tab("Inbox", id: 100)]),
                        (11, 2, [Self.tab("Docs", id: 102, active: false), Self.tab("Radio", id: 101, icon: Self.otherIcon, audible: true)])])
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site | other site, 2: site", "Until WinMux reads them again, neither window plays")
        var radioThere = BrowserTab(target: .init(windowId: 2, pid: 7, windowSession: two, tabId: UUID()), title: "Radio", isSelected: true)
        radioThere.isSelected = true
        var docsThere = docs
        docsThere.isSelected = false
        harness.reads = [1: .init(windowId: 1, pid: 7, windowSession: one, tabs: [inbox]), 2: .init(windowId: 2, pid: 7, windowSession: two, tabs: [docsThere, radioThere])]
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site, 2: site | other site sound")
        XCTAssertEqual(harness.associations.described(radioThere).extensionTab?.id, 101)
    }

    // MARK: Comparisons, which held before too

    func testOneWindowAndWindowsOnDifferentPagesNeedNoFrames() {
        let harness = Harness()
        harness.frames = [1: Self.shown, 2: Self.parked]
        harness.reads = [1: Self.lone("Demo Page", window: 1), 2: Self.lone("Other Page", window: 2)]
        // Reported while both were moving: no frames, and none needed.
        harness.report([(10, 1, [Self.tab(id: 100, audible: true)]), (11, 2, [Self.tab("Other Page", id: 101, icon: Self.otherIcon)])])
        harness.wait(1)
        harness.read(1, 2)
        for _ in 0..<3 {
            switchTabs(harness)
            harness.wait(1)
            harness.read(1, 2)
        }
        XCTAssertEqual(Set(harness.timeline.dropFirst()), ["1: site sound, 2: other site"])
    }

    func testTwinsPairByFreshFramesAndHoldWhileNothingMoves() {
        let harness = pairedTwins()
        let before = harness.timeline.count - 1
        for _ in 0..<5 {
            harness.wait(1)
            harness.read(1, 2)
        }
        harness.report(twins())
        harness.read(1, 2)
        XCTAssertEqual(Set(harness.timeline[before...]), ["1: site sound, 2: site"])
    }
}
