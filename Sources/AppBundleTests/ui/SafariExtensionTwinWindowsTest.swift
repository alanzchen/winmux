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

    /// Stands for one native window's lifetime: a later window under the same number is another.
    private final class NativeWindow {}

    /// What BrowserTabsModel joins, driven step by step: where Safari's windows are as WinMux
    /// samples them, the bridge receiving Safari's reports and recording where windows were
    /// then, and the associations, updated at each Accessibility read.
    @MainActor
    private final class Harness {
        var uptime: TimeInterval = 1000
        var wall: TimeInterval = 1_790_000_000
        /// Where each window is now, how many frame writes WinMux queued for it, and how many
        /// moves it heard about.
        var frames: [UInt32: CGRect] = [:]
        var writes: [UInt32: UInt64] = [:]
        var writing: Set<UInt32> = []
        var heard: [UInt32: UInt64] = [:]
        var natives: [UInt32: NativeWindow] = [:]
        var reads: [UInt32: BrowserWindowTabs] = [:]
        var observed: [UInt32: TimeInterval] = [:]
        var readStarted: [UInt32: TimeInterval] = [:]
        var track = SafariExtensionFrameTrack()
        var associations = SafariExtensionAssociations()
        var bridge: SafariExtensionBridge!
        var session = "s1"
        /// Each window's row after every update, as "id: site|other site|Safari [sound] [host]".
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
        func sample() {
            for id in frames.keys where natives[id] == nil { natives[id] = NativeWindow() }
            track.observe(Dictionary(uniqueKeysWithValues: frames.map { id, frame in
                (id, SafariExtensionFrameSample(frame: frame, identity: ObjectIdentifier(natives[id]!), generation: heard[id] ?? 0,
                    writes: writes[id] ?? 0, writing: writing.contains(id)))
            }), now: uptime)
        }

        func wait(_ seconds: TimeInterval) {
            var left = seconds
            while left > 0 {
                let step = min(0.25, left)
                elapse(step)
                left -= step
                sample()
            }
        }

        func elapse(_ seconds: TimeInterval) {
            uptime += seconds
            wall += seconds
        }

        /// WinMux moves a window, its write beginning and ending as it runs; its notification, if
        /// any, comes later. `sampled: false` is a move no sample sees before the next.
        func move(_ id: UInt32, to frame: CGRect, sampled: Bool = true) {
            beginWrite(id)
            endWrite(id, at: frame)
            if sampled { sample() }
        }

        /// A write that has begun to run on the app's AX thread, and one that ends, moving the window.
        func beginWrite(_ id: UInt32) {
            writes[id, default: 0] += 1
            writing.insert(id)
        }

        func endWrite(_ id: UInt32, at frame: CGRect) {
            frames[id] = frame
            writes[id, default: 0] += 1
            writing.remove(id)
        }

        /// A new native window under `id`, read as one tab.
        func open(_ id: UInt32, at frame: CGRect, title: String = "Demo Page") {
            natives[id] = NativeWindow()
            frames[id] = frame
            reads[id] = SafariExtensionTwinWindowsTest.lone(title, window: id)
            sample()
        }

        func close(_ id: UInt32) {
            frames[id] = nil
            natives[id] = nil
            reads[id] = nil
            observed[id] = nil
            sample()
        }

        /// Safari's report. The extension notes when it begins measuring; Safari's windows are
        /// read `capture` later, then the extension waits `pause` (asking about permissions)
        /// before stamping it, and it arrives `transit` after that. `whileMeasuring` and
        /// `during` run in the pause and in transit. Bounds default to where the windows are when
        /// Safari reads them. Version 2 unless a tab has no id.
        func report(_ windows: [(id: Int, native: UInt32?, tabs: [SafariExtensionTab])], bounds: [Int: CGRect] = [:],
                    capture: TimeInterval = 0, pause: TimeInterval = 0, transit: TimeInterval = 0.05,
                    beforeCapture: () -> Void = {}, whileMeasuring: () -> Void = {}, during: () -> Void = {}) {
            let measuredStamp = wall * 1000
            beforeCapture()
            elapse(capture)
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
            whileMeasuring()
            elapse(pause)
            let stamp = wall * 1000
            during()
            elapse(transit)
            sample()
            let version = windows.allSatisfy { $0.tabs.allSatisfy { $0.id != nil } } ? 2 : 1
            var message: [String: Any] = ["v": version, "type": "state", "session": session, "time": stamp, "windows": measured]
            if version >= 2 { message["measured"] = measuredStamp }
            let data = try! JSONSerialization.data(withJSONObject: ["message": message, "profile": "8A7B6C5D-0000-4000-8000-000000000001"])
            _ = bridge.receive(SafariExtensionMessage.decode(data))
            update()
        }

        /// A new Accessibility read of each window in `ids`, then pairing with what's known.
        func read(_ ids: UInt32...) {
            for id in ids {
                observed[id] = uptime
                readStarted[id] = uptime
            }
            update()
        }

        /// A read that began at `started` and ends now, having seen the tab bar as it is now.
        func read(_ id: UInt32, startedAt started: TimeInterval) {
            observed[id] = uptime
            readStarted[id] = started
            update()
        }

        func update() {
            associations.update(reads.keys.sorted().map {
                .init(snapshot: reads[$0]!, observed: observed[$0] ?? 0, readStarted: readStarted[$0], appeared: track.appeared($0) ?? .infinity)
            }, windows: bridge.windows, now: uptime)
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

    /// Safari reports a window's tabs again, as when WinMux asks it to, and WinMux reads the tab
    /// bar after that.
    private func settle(_ harness: Harness, _ tabs: [SafariExtensionTab], window: UInt32 = 1, id: Int = 10) {
        harness.wait(1)
        harness.report([(id, window, tabs)])
        harness.wait(1)
        harness.read(window)
    }

    private func switchTabs(_ harness: Harness) {
        let a = harness.frames[1]!
        harness.move(1, to: harness.frames[2]!)
        harness.move(2, to: a)
    }

    // MARK: 1. Switching moves twins; nothing reported in between, then a fresh report

    func testTwinsKeepTheirIconsAndSoundThroughSwitchesAndAFreshReportWithStaggeredReads() {
        for ids in [true] {
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
        XCTAssertTrue(harness.associations.awaitsReport, "WinMux asks Safari to report again")
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
        XCTAssertFalse(harness.associations.awaitsReport)
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
        XCTAssertFalse(harness.associations.awaitsReport, "Another report from the same places wouldn't settle it")
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
                harness.close(1)
                harness.read(2)
            }
            let closeReport = { harness.report([(11, 2, [Self.tab(id: 101)])]) }
            if safariFirst { closeReport(); closeNative() } else { closeNative(); closeReport() }
            XCTAssertEqual(harness.timeline.last, "2: site")
            // A new twin opens where A was.
            harness.wait(1)
            harness.open(3, at: Self.parked)
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
        // A closes, and a new window gets its number, in the same place, before WinMux sees A gone.
        harness.open(1, at: Self.shown)
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: Safari, 2: site sound", "The new window doesn't inherit the old one's pairing")
        XCTAssertEqual(harness.associations.resolution(of: 1), .unresolved, "Nor where the old one was when Safari last reported")
        XCTAssertTrue(harness.associations.awaitsReport)
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


    // MARK: Review round 1: evidence a report's arrival can't vouch for

    /// Only one report, X, and twins A and B. B was once paired with it; a report whose frames put
    /// A where X is, and B elsewhere, gives X to A, with no other report for B to take.
    func testAFreshReportThatGivesAHeldReportToAnotherTwinWins() {
        for order in [[UInt32(1), 2], [2, 1]] {
            let key = SafariExtensionWindowKey(source: "p:s", id: 10)
            let a = Self.lone("Demo Page", window: 1)
            let b = Self.lone("Demo Page", window: 2)
            func x(_ sighting: [UInt32: CGRect]) -> [SafariExtensionWindow] {
                [.init(key: key, bounds: Self.shown, tabs: [Self.tab(id: 100, audible: true)], sighting: sighting)]
            }
            var associations = SafariExtensionAssociations()
            func update(_ windows: [SafariExtensionWindow], at time: TimeInterval) {
                let candidates = [a, b].map { SafariExtensionCandidate(snapshot: $0, observed: time) }
                    .sorted { order.firstIndex(of: $0.snapshot.windowId)! < order.firstIndex(of: $1.snapshot.windowId)! }
                associations.update(candidates, windows: windows, now: time)
            }
            update(x([1: Self.parked, 2: Self.shown]), at: 0)
            update(x([1: Self.parked, 2: Self.shown]), at: 1)
            XCTAssertEqual(associations.resolution(of: 2), .resolved(key), "order \(order)")
            update(x([1: Self.shown, 2: Self.parked]), at: 2)
            XCTAssertNil(associations.described(b.tabs[0]).audio, "B lets go at once")
            XCTAssertEqual(associations.resolution(of: 1), .pending(key))
            update(x([1: Self.shown, 2: Self.parked]), at: 3)
            XCTAssertEqual(associations.described(a.tabs[0]).audio, .playing, "order \(order)")
            XCTAssertNil(associations.described(b.tabs[0]).audio)
            XCTAssertEqual(associations.resolution(of: 2), .stale(key))
        }
    }

    /// One twin wasn't seen when a report arrived; the other was seen where the report says. The
    /// unseen one could have been there just as well, so neither pairs.
    func testATwinTheReportsArrivalDidntSeeStandsInTheWay() {
        let a = Self.lone("Demo Page", window: 1)
        let b = Self.lone("Demo Page", window: 2)
        let x = SafariExtensionWindow(key: .init(source: "p:s", id: 10), bounds: Self.shown, tabs: [Self.tab(id: 100, audible: true)],
            sighting: [2: Self.shown])
        let backward = safariExtensionMatches([.init(snapshot: a), .init(snapshot: b)], [x])
        XCTAssertEqual(backward.pairs, [:])
        XCTAssertEqual(backward.needsFrames, [1, 2], "Safari's next report may settle it")
        // A in two profiles' reports: seen where one says, unseen by the other.
        let y = SafariExtensionWindow(key: .init(source: "q:s", id: 20), bounds: Self.parked, tabs: [Self.tab(id: 200)])
        let forward = safariExtensionMatches([.init(snapshot: a)], [.init(key: x.key, bounds: Self.shown, tabs: x.tabs, sighting: [1: Self.shown]), y])
        XCTAssertEqual(forward.pairs, [:])
        XCTAssertEqual(forward.needsFrames, [1])
        // A window that appeared after the report was measured wasn't what it saw under that number.
        var late = SafariExtensionCandidate(snapshot: a)
        late.appeared = 5
        var measured = x
        measured.sighting = [1: Self.shown, 2: Self.parked]
        measured.measured = 4
        XCTAssertEqual(safariExtensionPairs([late, .init(snapshot: b)], [measured]), [:])
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: a), .init(snapshot: b)], [measured]), [1: x.key])
    }

    /// The extension notes when it begins measuring, before Safari lists its windows and before it
    /// waits on other questions. A switch in that pause leaves the report's bounds unusable.
    func testASwitchWhileTheExtensionIsStillMeasuringPairsNothing() {
        let harness = Harness()
        harness.frames = [1: Self.shown, 2: Self.parked]
        harness.reads = [1: Self.lone("Demo Page", window: 1), 2: Self.lone("Demo Page", window: 2)]
        harness.wait(2)
        harness.report(twins(), capture: 0.05, pause: 0.6, whileMeasuring: { switchTabs(harness) })
        for _ in 0..<2 {
            harness.wait(1)
            harness.read(1, 2)
        }
        XCTAssertEqual(Set(harness.timeline), ["1: Safari, 2: Safari"])
        XCTAssertTrue(harness.associations.awaitsReport)
        harness.report(twins())
        harness.wait(1)
        harness.read(1, 2)
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site")
        XCTAssertFalse(harness.timeline.contains { $0.contains("2: site sound") })
    }

    /// WinMux switches and switches back between two samples, and Safari measures in between.
    /// Every sample sees the same frames; the windows' move counts say they moved.
    func testAMoveAndAMoveBackNoSampleSawStillCount() {
        let harness = Harness()
        harness.frames = [1: Self.shown, 2: Self.parked]
        harness.reads = [1: Self.lone("Demo Page", window: 1), 2: Self.lone("Demo Page", window: 2)]
        harness.wait(2)
        harness.report(twins(), capture: 0.05, beforeCapture: {
            harness.move(1, to: Self.parked, sampled: false)
            harness.move(2, to: Self.shown, sampled: false)
        }, whileMeasuring: {
            harness.move(1, to: Self.shown, sampled: false)
            harness.move(2, to: Self.parked, sampled: false)
        })
        for _ in 0..<2 {
            harness.wait(1)
            harness.read(1, 2)
        }
        XCTAssertEqual(Set(harness.timeline), ["1: Safari, 2: Safari"], "Safari measured them swapped; neither is paired with the other's")
    }

    func testAWindowUnderAClosedOnesNumberDoesntInheritWhereThatOneWas() {
        // A closes and WinMux sees it gone; a new window gets its number, in its place, before Safari reports again.
        let harness = pairedTwins()
        harness.close(1)
        harness.wait(1)
        harness.read(2)
        harness.open(1, at: Self.shown)
        harness.wait(1)
        harness.read(1, 2)
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: Safari, 2: site")
        XCTAssertEqual(harness.associations.resolution(of: 1), .unresolved)
        harness.report([(11, 2, [Self.tab(id: 101)]), (12, 1, [Self.tab(id: 102, audible: true)])])
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site")

        // A report measured before a window under the same number appeared arrives after it.
        let crossing = pairedTwins()
        crossing.report(twins(audibleA: false), transit: 0.2, during: {
            crossing.close(1)
            crossing.open(1, at: Self.shown)
        })
        for _ in 0..<2 {
            crossing.wait(1)
            crossing.read(1, 2)
        }
        XCTAssertEqual(crossing.associations.resolution(of: 1), .unresolved)
        XCTAssertEqual(crossing.timeline.last, "1: Safari, 2: site")
    }

    /// Same-titled tabs reordered in the tab bar, WinMux reading it before Safari reports.
    func testSameTitledTabsKeepTheirSoundWhenWinMuxReadsAReorderBeforeSafariReportsIt() {
        let harness = Harness()
        harness.frames = [1: Self.shown]
        let session = UUID()
        func listed(_ title: String, selected: Bool = false) -> BrowserTab {
            .init(target: .init(windowId: 1, pid: 7, windowSession: session, tabId: UUID()), title: title, isSelected: selected)
        }
        let mail = listed("Mail", selected: true)
        let quiet = listed("Demo Page")
        let playing = listed("Demo Page")
        func tabBar(_ tabs: [BrowserTab]) { harness.reads[1] = .init(windowId: 1, pid: 7, windowSession: session, tabs: tabs) }
        tabBar([mail, quiet, playing])
        harness.wait(2)
        let reportedMail = Self.tab("Mail", id: 99, icon: Self.otherIcon, host: "mail.test")
        let reportedQuiet = Self.tab(id: 100, active: false)
        let reportedPlaying = Self.tab(id: 101, icon: Self.otherIcon, audible: true, active: false)
        harness.report([(10, 1, [reportedMail, reportedQuiet, reportedPlaying])])
        harness.wait(1)
        harness.read(1)
        harness.wait(1)
        harness.read(1)
        settle(harness, [reportedMail, reportedQuiet, reportedPlaying])
        let before = harness.timeline.count
        // Read first, in the new order.
        tabBar([mail, playing, quiet])
        harness.wait(1)
        harness.read(1)
        // Then Safari's report of it, and another read.
        harness.report([(10, 1, [reportedMail, reportedPlaying, reportedQuiet])])
        harness.wait(1)
        harness.read(1)
        XCTAssertEqual(Set(harness.timeline[before...]), ["1: other site mail.test | other site sound | site"])
        // Moved back: Safari reports it before WinMux reads the tab bar again.
        harness.report([(10, 1, [reportedMail, reportedQuiet, reportedPlaying])])
        XCTAssertEqual(harness.timeline.last, "1: other site mail.test | other site sound | site")
        tabBar([mail, quiet, playing])
        harness.wait(1)
        harness.read(1)
        XCTAssertEqual(harness.timeline.last, "1: other site mail.test | site | other site sound")
        XCTAssertEqual(harness.associations.described(playing).extensionTab?.id, 101)
    }

    /// The playing tab closes and a new silent one with the same title opens, the count staying
    /// the same, and Safari reports it before WinMux reads the tab bar again.
    func testATabWhoseSafariTabIsGoneShowsNothingFromTheExtension() {
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
        let first = [reportedMail, Self.tab(id: 100, active: false), Self.tab(id: 101, icon: Self.otherIcon, audible: true, active: false)]
        harness.report([(10, 1, first)])
        harness.wait(1)
        harness.read(1)
        harness.wait(1)
        harness.read(1)
        settle(harness, first)
        XCTAssertEqual(harness.timeline.last, "1: other site mail.test | site | other site sound")
        harness.report([(10, 1, [reportedMail, Self.tab(id: 102, icon: Self.otherIcon, active: false), Self.tab(id: 100, active: false)])])
        XCTAssertEqual(harness.timeline.last, "1: other site mail.test | site | Safari", "The quiet tab follows its id; the gone tab shows nothing")
        XCTAssertNil(harness.associations.described(playing).extensionTab)
        // WinMux reads the tab bar: the new tab is a new control there.
        let opened = listed("Demo Page")
        harness.reads = [1: .init(windowId: 1, pid: 7, windowSession: session, tabs: [mail, opened, quiet])]
        harness.wait(1)
        harness.read(1)
        XCTAssertEqual(harness.timeline.last, "1: other site mail.test | other site | site")
        settle(harness, [reportedMail, Self.tab(id: 102, icon: Self.otherIcon, active: false), Self.tab(id: 100, active: false)])
        XCTAssertEqual(harness.associations.described(opened).extensionTab?.id, 102)
    }

    /// An extension from before protocol 2 doesn't say when it measured: its bounds tell twins
    /// apart for nothing, though windows with different tabs still pair.
    func testAnOlderExtensionsReportCantTellTwinsApart() {
        let harness = Harness()
        harness.frames = [1: Self.shown, 2: Self.parked, 3: Self.parked.offsetBy(dx: -500, dy: 0)]
        harness.reads = [1: Self.lone("Demo Page", window: 1), 2: Self.lone("Demo Page", window: 2), 3: Self.lone("Other Page", window: 3)]
        harness.wait(2)
        harness.report(twins(ids: false) + [(12, 3, [Self.tab("Other Page", id: nil, icon: Self.otherIcon)])])
        for _ in 0..<2 {
            harness.wait(1)
            harness.read(1, 2, 3)
        }
        XCTAssertEqual(harness.timeline.last, "1: Safari, 2: Safari, 3: other site")
    }


    // MARK: Review round 2

    /// Same-titled tabs are swapped just before the read that confirms the window, while
    /// Safari's report of the swap is still on its way. That read and the older report agree
    /// place by place, but they describe different moments.
    func testSameTitledTabsSwappedBeforeTheFirstPairingNeverSettleOnEachOthersSound() {
        let harness = Harness()
        harness.frames = [1: Self.shown]
        let session = UUID()
        func listed(_ title: String, selected: Bool = false) -> BrowserTab {
            .init(target: .init(windowId: 1, pid: 7, windowSession: session, tabId: UUID()), title: title, isSelected: selected)
        }
        let mail = listed("Mail", selected: true)
        let quiet = listed("Demo Page")
        let playing = listed("Demo Page")
        func tabBar(_ tabs: [BrowserTab]) { harness.reads[1] = .init(windowId: 1, pid: 7, windowSession: session, tabs: tabs) }
        let reportedMail = Self.tab("Mail", id: 99, icon: Self.otherIcon, host: "mail.test")
        let reportedQuiet = Self.tab(id: 100, active: false)
        let reportedPlaying = Self.tab(id: 101, icon: Self.otherIcon, audible: true, active: false)
        tabBar([mail, quiet, playing])
        harness.wait(2)
        harness.report([(10, 1, [reportedMail, reportedQuiet, reportedPlaying])])
        harness.wait(1)
        harness.read(1)
        // The swap, read before Safari's report of it.
        tabBar([mail, playing, quiet])
        harness.wait(1)
        harness.read(1)
        harness.report([(10, 1, [reportedMail, reportedPlaying, reportedQuiet])])
        for _ in 0..<3 {
            harness.wait(1)
            harness.read(1)
            harness.report([(10, 1, [reportedMail, reportedPlaying, reportedQuiet])])
        }
        harness.wait(1)
        harness.read(1)
        let rows = harness.timeline
        XCTAssertFalse(rows.contains { $0.hasSuffix("| other site sound") }, "The quiet tab, last in the tab bar, never plays: \(rows)")
        XCTAssertEqual(rows.last, "1: other site mail.test | other site sound | site")
        XCTAssertEqual(harness.associations.described(playing).extensionTab?.id, 101)
        XCTAssertEqual(harness.associations.described(quiet).extensionTab?.id, 100)
    }

    /// A report that doesn't say where its window is rules nothing out.
    func testAReportWithoutBoundsDoesntPlaceItsWindowElsewhere() {
        let a = Self.lone("Demo Page", window: 1)
        let x = SafariExtensionWindow(key: .init(source: "p:s", id: 10), bounds: Self.shown, tabs: [Self.tab(id: 100)], sighting: [1: Self.shown])
        let y = SafariExtensionWindow(key: .init(source: "q:s", id: 20), bounds: nil, tabs: [Self.tab(id: 200, audible: true)], sighting: [1: Self.shown])
        for windows in [[x, y], [y, x]] {
            let found = safariExtensionMatches([.init(snapshot: a)], windows)
            XCTAssertEqual(found.pairs, [:])
            XCTAssertEqual(found.needsFrames, [1])
        }
    }

    /// An unread window that appeared after a report was measured wasn't what the report saw
    /// under its number, so its old place proves nothing.
    func testAnUnreadWindowNewerThanAReportCantBeRuledOutByIt() {
        let a = Self.lone("Demo Page", window: 1)
        let x = SafariExtensionWindow(key: .init(source: "p:s", id: 10), bounds: Self.shown, tabs: [Self.tab(id: 100)],
            measured: 10, sighting: [1: Self.shown, 3: Self.parked])
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: a)], [x], unread: [3], unreadAppeared: [3: 5]), [1: x.key])
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: a)], [x], unread: [3], unreadAppeared: [3: 12]), [:])
    }

    func testFramesTrackedWhileHiddenStartCountingAgainButKeepWhenTheirWindowsAppeared() {
        var track = SafariExtensionFrameTrack()
        let window = NativeWindow()
        func sample(_ frame: CGRect, writes: UInt64 = 0) -> [UInt32: SafariExtensionFrameSample] {
            [1: .init(frame: frame, identity: ObjectIdentifier(window), generation: 0, writes: writes)]
        }
        track.observe(sample(Self.shown), now: 0)
        track.observe(sample(Self.shown), now: 5)
        XCTAssertEqual(track.sighting(measured: 4), [1: Self.shown])
        track.pause()
        XCTAssertEqual(track.sighting(measured: 4), [:], "Nothing says where it was while no one looked")
        track.observe(sample(Self.shown), now: 9)
        XCTAssertEqual(track.appeared(1), 0)
        XCTAssertEqual(track.sighting(measured: 9.2), [:])
        XCTAssertEqual(track.sighting(measured: 9.4), [1: Self.shown])
        // A write WinMux ran counts at once, before any notification of the move.
        track.observe(sample(Self.shown, writes: 2), now: 11)
        XCTAssertEqual(track.sighting(measured: 11.2), [:])
        // A write still running, however long, leaves the window unknown.
        var running = sample(Self.shown, writes: 3)
        running[1]?.writing = true
        for time in [12.0, 13, 14] { track.observe(running, now: time) }
        XCTAssertEqual(track.sighting(measured: 13.9), [:])
        track.observe(sample(Self.shown, writes: 4), now: 15)
        track.observe(sample(Self.shown, writes: 4), now: 16)
        XCTAssertEqual(track.sighting(measured: 15.4), [1: Self.shown])
    }


    // MARK: Review round 3

    /// A report Safari measured before same-titled tabs swapped arrives only after the read that
    /// proposed their pairing, and a later read still sees them swapped.
    func testAReportMeasuredBeforeAProposalNeverConfirmsIt() {
        let harness = Harness()
        harness.frames = [1: Self.shown]
        let session = UUID()
        func listed(_ title: String, selected: Bool = false) -> BrowserTab {
            .init(target: .init(windowId: 1, pid: 7, windowSession: session, tabId: UUID()), title: title, isSelected: selected)
        }
        let mail = listed("Mail", selected: true)
        let quiet = listed("Demo Page")
        let playing = listed("Demo Page")
        func tabBar(_ tabs: [BrowserTab]) { harness.reads[1] = .init(windowId: 1, pid: 7, windowSession: session, tabs: tabs) }
        let reportedMail = Self.tab("Mail", id: 99, icon: Self.otherIcon, host: "mail.test")
        let reportedQuiet = Self.tab(id: 100, active: false)
        let reportedPlaying = Self.tab(id: 101, icon: Self.otherIcon, audible: true, active: false)
        tabBar([mail, quiet, playing])
        harness.wait(2)
        harness.report([(10, 1, [reportedMail, reportedQuiet, reportedPlaying])])
        harness.wait(1)
        // Safari measures the old order, then waits; meanwhile the tabs swap and WinMux first reads them.
        harness.report([(10, 1, [reportedMail, reportedQuiet, reportedPlaying])], pause: 1.2, whileMeasuring: {
            tabBar([mail, playing, quiet])
            harness.elapse(0.2)
            harness.read(1)
        })
        harness.wait(1)
        harness.read(1)
        // Then Safari's report of the swap, and more reads and reports.
        for _ in 0..<3 {
            harness.wait(1)
            harness.report([(10, 1, [reportedMail, reportedPlaying, reportedQuiet])])
            harness.wait(1)
            harness.read(1)
        }
        let rows = harness.timeline
        XCTAssertFalse(rows.contains { $0.hasSuffix("| other site sound") }, "The quiet tab, last in the tab bar, never plays: \(rows)")
        XCTAssertEqual(rows.last, "1: other site mail.test | other site sound | site")
        XCTAssertEqual(harness.associations.described(quiet).extensionTab?.id, 100)
    }

    /// Same-titled tabs swap, swap back and swap again around one read and one report: the read
    /// began before the report arrived and ended after it, having seen the last swap, which the
    /// report doesn't have. Such a read can't settle a pairing against that report.
    func testAReadThatBeganBeforeAReportArrivedCantConfirmAPairingAgainstIt() {
        let harness = Harness()
        harness.frames = [1: Self.shown]
        let session = UUID()
        func listed(_ title: String, selected: Bool = false) -> BrowserTab {
            .init(target: .init(windowId: 1, pid: 7, windowSession: session, tabId: UUID()), title: title, isSelected: selected)
        }
        let mail = listed("Mail", selected: true)
        let quiet = listed("Demo Page")
        let playing = listed("Demo Page")
        func tabBar(_ tabs: [BrowserTab]) { harness.reads[1] = .init(windowId: 1, pid: 7, windowSession: session, tabs: tabs) }
        let reportedMail = Self.tab("Mail", id: 99, icon: Self.otherIcon, host: "mail.test")
        let reportedQuiet = Self.tab(id: 100, active: false)
        let reportedPlaying = Self.tab(id: 101, icon: Self.otherIcon, audible: true, active: false)
        tabBar([mail, quiet, playing])
        harness.wait(2)
        harness.report([(10, 1, [reportedMail, reportedQuiet, reportedPlaying])])
        // The first swap, read before Safari reports it: the proposals are wrong.
        tabBar([mail, playing, quiet])
        harness.wait(1)
        harness.read(1)
        // Swapped back; Safari measures that. Then swapped again while a read is under way and
        // the report arrives.
        tabBar([mail, quiet, playing])
        harness.wait(0.5)
        let started = harness.uptime
        harness.report([(10, 1, [reportedMail, reportedQuiet, reportedPlaying])], during: { tabBar([mail, playing, quiet]) })
        harness.elapse(0.1)
        harness.read(1, startedAt: started)
        // Safari's report of the last swap, and more reports and reads.
        for _ in 0..<3 {
            harness.wait(1)
            harness.report([(10, 1, [reportedMail, reportedPlaying, reportedQuiet])])
            harness.wait(1)
            harness.read(1)
        }
        let rows = harness.timeline
        XCTAssertFalse(rows.contains { $0.hasSuffix("| other site sound") }, "The quiet tab, last in the tab bar, never plays: \(rows)")
        XCTAssertEqual(rows.last, "1: other site mail.test | other site sound | site")
    }

    /// One of WinMux's writes is still running past the margin, then lands; Safari measures the
    /// window there and WinMux's next write puts it back before any sample or notification.
    func testAWriteStillRunningOrLandingBetweenSamplesLeavesTheWindowUnseen() {
        let harness = Harness()
        harness.frames = [1: Self.shown, 2: Self.parked]
        harness.reads = [1: Self.lone("Demo Page", window: 1), 2: Self.lone("Demo Page", window: 2)]
        harness.wait(2)
        harness.beginWrite(1)
        harness.wait(1)
        harness.report(twins(), capture: 0.05, beforeCapture: {
            harness.endWrite(1, at: Self.parked)
            harness.beginWrite(2)
            harness.endWrite(2, at: Self.shown)
        }, whileMeasuring: {
            harness.move(1, to: Self.shown, sampled: false)
            harness.move(2, to: Self.parked, sampled: false)
        })
        for _ in 0..<2 {
            harness.wait(1)
            harness.read(1, 2)
        }
        XCTAssertEqual(Set(harness.timeline), ["1: Safari, 2: Safari"], "Safari measured them swapped; WinMux can't vouch for either place")
        XCTAssertTrue(harness.associations.awaitsReport)
    }

    func testTheWriteLedgerCountsWritesAsTheyRunAndForgetsOnlySettledOnes() {
        let ledger = FrameWriteLedger()
        XCTAssertEqual(ledger.state(1).steps, 0)
        ledger.begin(1)
        XCTAssertEqual(ledger.state(1).steps, 1)
        XCTAssertTrue(ledger.state(1).writing)
        ledger.end(1)
        XCTAssertEqual(ledger.state(1).steps, 2)
        XCTAssertFalse(ledger.state(1).writing)
        struct Failed: Error {}
        XCTAssertThrowsError(try ledger.record(2) { throw Failed() })
        XCTAssertEqual(ledger.state(2).steps, 2, "A write that fails still ends")
        XCTAssertFalse(ledger.state(2).writing)
        ledger.begin(3)
        for id in UInt32(10)..<1100 { ledger.record(id) {} }
        XCTAssertTrue(ledger.state(3).writing, "A running write is never forgotten")
        XCTAssertEqual(ledger.state(3).steps, 1)
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
        XCTAssertEqual(harness.timeline.last, "1: other site mail.test | site | other site", "Same-titled tabs are only proposed: no sound yet")
        XCTAssertNil(harness.associations.described(playing).extensionTab)
        XCTAssertTrue(harness.associations.awaitsReport, "WinMux asks Safari to report again")
        settle(harness, [reportedMail, reportedQuiet, reportedPlaying])
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
