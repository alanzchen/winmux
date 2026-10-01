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
        /// The extension's count of tab moves, openings and closings; tests bump it with each.
        var order = 0
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
            // As the extension does: the count before and after Safari lists its windows.
            let orderBefore = order
            beforeCapture()
            elapse(capture)
            let measuredOrder = order == orderBefore ? orderBefore : nil
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
            if version >= 2 {
                message["measured"] = measuredStamp
                if let measuredOrder { message["order"] = measuredOrder }
            }
            let data = try! JSONSerialization.data(withJSONObject: ["message": message, "profile": "8A7B6C5D-0000-4000-8000-000000000001"])
            _ = bridge.receive(SafariExtensionMessage.decode(data))
            update()
        }

        /// The extension's toolbar button in native window `id` names extension window `window`
        /// and its tab `tab`, in this session unless another is given, from the next read on.
        func stamp(_ id: UInt32, window: Int, tab: Int, session: String? = nil) {
            reads[id]?.marker = .init(session: String((session ?? self.session).prefix(8)), window: window, tab: tab)
        }

        /// A new Accessibility read of each window in `ids`, then pairing with what's known.
        func read(_ ids: UInt32...) { read(ids) }

        func read(_ ids: [UInt32]) {
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

    /// Safari reports a window's tabs again, as when WinMux asks it to, WinMux reads the tab bar
    /// after that, and Safari reports again with nothing reordered.
    private func settle(_ harness: Harness, _ tabs: [SafariExtensionTab], window: UInt32 = 1, id: Int = 10) {
        harness.wait(1)
        harness.report([(id, window, tabs)])
        harness.wait(1)
        harness.read(window)
        harness.wait(1)
        harness.report([(id, window, tabs)])
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
        harness.order += 1
        harness.wait(1)
        harness.read(1)
        // Then Safari's report of it, and another read.
        harness.report([(10, 1, [reportedMail, reportedPlaying, reportedQuiet])])
        harness.wait(1)
        harness.read(1)
        XCTAssertEqual(Set(harness.timeline[before...]), ["1: other site mail.test | other site sound | site"])
        // Moved back: Safari reports it before WinMux reads the tab bar again.
        harness.order += 1
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
        harness.order += 2
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
        harness.order += 1
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
        XCTAssertEqual(track.appeared(1), -.infinity, "Open since before WinMux first looked, at some unknown time")
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
        // A window that opens while WinMux looks appeared then, and still did after a pause.
        let other = NativeWindow()
        var both = sample(Self.shown, writes: 4)
        both[2] = .init(frame: Self.parked, identity: ObjectIdentifier(other), generation: 0, writes: 0)
        track.observe(both, now: 17)
        XCTAssertEqual(track.appeared(2), 17)
        track.pause()
        track.observe(both, now: 18)
        XCTAssertEqual(track.appeared(2), 17)
        XCTAssertEqual(track.appeared(1), -.infinity)
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
            harness.order += 1
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

    /// Same-titled tabs swap, swap back and swap again around one report: Safari measured them
    /// swapped back, and the last swap is still unreported when WinMux reads the tab bar, in a read
    /// that began before the report arrived or one that began after. Neither settles a pairing.
    func testSwapsAroundAReportNeverSettleSameTitledTabsOnEachOthersSound() {
        for spanning in [true, false] {
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
            harness.order += 1
            harness.wait(1)
            harness.read(1)
            // Swapped back; Safari measures that. Then swapped again while the report is on its way.
            tabBar([mail, quiet, playing])
            harness.order += 1
            harness.wait(0.5)
            let started = harness.uptime
            harness.report([(10, 1, [reportedMail, reportedQuiet, reportedPlaying])], during: {
                tabBar([mail, playing, quiet])
                harness.order += 1
            })
            harness.elapse(0.1)
            if spanning { harness.read(1, startedAt: started) } else { harness.read(1) }
            // Safari's report of the last swap, and more reports and reads.
            for _ in 0..<3 {
                harness.wait(1)
                harness.report([(10, 1, [reportedMail, reportedPlaying, reportedQuiet])])
                harness.wait(1)
                harness.read(1)
            }
            let rows = harness.timeline
            XCTAssertFalse(rows.contains { $0.hasSuffix("| other site sound") }, "spanning: \(spanning): the quiet tab, last, never plays: \(rows)")
            XCTAssertEqual(rows.last, "1: other site mail.test | other site sound | site", "spanning: \(spanning)")
            XCTAssertEqual(harness.associations.described(quiet).extensionTab?.id, 100)
            XCTAssertEqual(harness.associations.described(playing).extensionTab?.id, 101)
        }
    }

    /// Same-titled tabs swap before each of two reads and swap back before each report, so both
    /// reports list them in the same order. Only the reports' count of reorderings says the tab
    /// bar moved while WinMux looked.
    func testReordersBetweenReportsWithTheSameTabsCantConfirmWhatAReadSawInBetween() {
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
        func swap(_ swapped: Bool) {
            tabBar(swapped ? [mail, playing, quiet] : [mail, quiet, playing])
            harness.order += 1
        }
        let tabs = [Self.tab("Mail", id: 99, icon: Self.otherIcon, host: "mail.test"), Self.tab(id: 100, active: false),
                    Self.tab(id: 101, icon: Self.otherIcon, audible: true, active: false)]
        tabBar([mail, quiet, playing])
        harness.wait(2)
        harness.report([(10, 1, tabs)])
        for _ in 0..<2 {
            swap(true)
            harness.wait(1)
            harness.read(1)
            swap(false)
            harness.wait(1)
            harness.report([(10, 1, tabs)])
        }
        for _ in 0..<3 {
            harness.wait(1)
            harness.read(1)
            harness.wait(1)
            harness.report([(10, 1, tabs)])
        }
        let rows = harness.timeline
        XCTAssertFalse(rows.contains { $0.contains("| other site sound | site") }, "The quiet tab, in the middle when swapped, never plays: \(rows)")
        XCTAssertEqual(rows.last, "1: other site mail.test | site | other site sound")
        XCTAssertEqual(harness.associations.described(playing).extensionTab?.id, 101)
    }

    /// Safari answers WinMux's request for a report quickly, measuring before the read that
    /// matched a proposal ends. With nothing reordered, that report leaves the match standing, and
    /// the next settles it.
    func testAReportMeasuredDuringTheMatchingReadDoesntUndoAnUnchangedMatch() {
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
        let tabs = [Self.tab("Mail", id: 99, icon: Self.otherIcon, host: "mail.test"), Self.tab(id: 100, active: false),
                    Self.tab(id: 101, icon: Self.otherIcon, audible: true, active: false)]
        harness.wait(2)
        harness.report([(10, 1, tabs)])
        XCTAssertTrue(harness.associations.awaitsAnotherReport(harness.bridge.windows),
            "Same-titled tabs in a window about to be paired need another report after a read")
        harness.wait(1)
        harness.read(1)
        harness.wait(1)
        harness.report([(10, 1, tabs)])
        harness.wait(0.5)
        // A read begins after that report arrived; Safari measures a quick reply before it ends.
        let started = harness.uptime
        harness.report([(10, 1, tabs)], transit: 0.3, during: {
            harness.elapse(0.1)
            harness.read(1, startedAt: started)
        })
        XCTAssertNil(harness.associations.described(playing).extensionTab)
        harness.wait(1)
        harness.report([(10, 1, tabs)])
        XCTAssertEqual(harness.associations.described(playing).extensionTab?.id, 101, "No extra round of reads and reports")
        XCTAssertEqual(harness.timeline.last, "1: other site mail.test | site | other site sound")
        XCTAssertFalse(harness.associations.awaitsAnotherReport(harness.bridge.windows), "Once paired for good, nothing waits")
        XCTAssertFalse(harness.associations.awaitsReport)
        // Safari reports the same-titled tabs swapped: their titles still agree with the last read,
        // but the window is read again at once, to show the new order. A report changing only an
        // icon isn't a reason to.
        harness.wait(1)
        harness.order += 1
        harness.report([(10, 1, [tabs[0], tabs[2], tabs[1]])])
        XCTAssertEqual(harness.associations.rereads, [1])
        harness.wait(1)
        harness.report([(10, 1, [tabs[0], tabs[2], Self.tab(id: 100, icon: Self.otherIcon, active: false)])])
        XCTAssertEqual(harness.associations.rereads, [])
        var other = SafariExtensionAssociations()
        other.update([], windows: harness.bridge.windows, now: harness.uptime)
        XCTAssertFalse(other.awaitsAnotherReport(harness.bridge.windows), "Nor for a window no read matches, such as one the sidebar doesn't list")
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

    /// A window's version never repeats, even after the ledger forgets it: a move and a move back
    /// right after it's forgotten still change it.
    func testTheWriteLedgersVersionsNeverRepeatAcrossForgetting() {
        let ledger = FrameWriteLedger()
        let window = NativeWindow()
        var track = SafariExtensionFrameTrack()
        func sample(at time: TimeInterval) {
            let state = ledger.state(1)
            track.observe([1: .init(frame: Self.shown, identity: ObjectIdentifier(window), generation: 0, writes: state.version,
                writing: state.writing)], now: time)
        }
        ledger.record(1) {}
        ledger.record(1) {}
        sample(at: 0)
        sample(at: 5)
        XCTAssertEqual(track.sighting(measured: 4), [1: Self.shown])
        let before = ledger.state(1).version
        for id in UInt32(10)..<1100 { ledger.record(id) {} }
        ledger.record(1) {}
        ledger.record(1) {}
        XCTAssertNotEqual(ledger.state(1).version, before)
        sample(at: 6)
        XCTAssertEqual(track.sighting(measured: 6), [:], "The out-and-back after forgetting still counts as a move")
    }

    func testTheWriteLedgerCountsWritesAsTheyRunAndForgetsOnlySettledOnes() {
        let ledger = FrameWriteLedger()
        XCTAssertEqual(ledger.state(1).version, 0)
        ledger.begin(1)
        let begun = ledger.state(1).version
        XCTAssertTrue(ledger.state(1).writing)
        ledger.end(1)
        XCTAssertNotEqual(ledger.state(1).version, begun)
        XCTAssertFalse(ledger.state(1).writing)
        struct Failed: Error {}
        XCTAssertThrowsError(try ledger.record(2) { throw Failed() })
        XCTAssertFalse(ledger.state(2).writing, "A write that fails still ends")
        ledger.begin(3)
        let running = ledger.state(3).version
        for id in UInt32(10)..<1100 { ledger.record(id) {} }
        XCTAssertTrue(ledger.state(3).writing, "A running write is never forgotten")
        XCTAssertEqual(ledger.state(3).version, running)
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

    // MARK: 6. The extension's toolbar button names each window

    private static let hexSession = "3f2a9c1e-0000-4000-8000-000000000001"

    /// Three twins: A shown, B and C parked in the same corner, which frames can't tell apart.
    private func parkedTriplets() -> Harness {
        let harness = Harness()
        harness.session = Self.hexSession
        harness.frames = [1: Self.shown, 2: Self.parked, 3: Self.parked]
        harness.reads = [1: Self.lone("Demo Page", window: 1), 2: Self.lone("Demo Page", window: 2), 3: Self.lone("Demo Page", window: 3)]
        harness.wait(2)
        return harness
    }

    private func triplets() -> [(id: Int, native: UInt32?, tabs: [SafariExtensionTab])] {
        twins() + [(12, 3, [Self.tab(id: 102, audible: true)])]
    }

    private func stampTriplets(_ harness: Harness) {
        harness.stamp(1, window: 10, tab: 100)
        harness.stamp(2, window: 11, tab: 101)
        harness.stamp(3, window: 12, tab: 102)
    }

    /// What makes the buttons count: Safari reports, WinMux reads the windows after it arrived,
    /// seeing their buttons, Safari reports again with nothing reordered (WinMux's answer asks it
    /// to), and a read confirms the pairing.
    private func trust(_ harness: Harness, _ windows: [(id: Int, native: UInt32?, tabs: [SafariExtensionTab])], reading ids: [UInt32]) {
        harness.report(windows)
        harness.wait(1)
        harness.read(ids)
        harness.wait(1)
        harness.report(windows)
        harness.wait(1)
        harness.read(ids)
    }

    func testTwinsInTheSamePlaceArePairedByWhatTheirToolbarButtonsName() {
        let harness = parkedTriplets()
        stampTriplets(harness)
        harness.wait(1)
        harness.read(1, 2, 3)
        harness.report(triplets())
        XCTAssertTrue(harness.associations.rereads.isSuperset(of: [2, 3]), "Buttons seen before a report count only from a read after it")
        XCTAssertTrue(harness.associations.awaitsReport, "and a report after that, which WinMux's answer asks for")
        harness.wait(1)
        harness.read(1, 2, 3)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: Safari, 3: Safari", "Not yet: the tabs may have moved since that report")
        harness.wait(1)
        harness.report(triplets())
        harness.wait(1)
        harness.read(1, 2, 3)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site, 3: site sound")
        XCTAssertEqual(harness.associations.resolution(of: 2), .resolved(.init(source: "8A7B6C5D-0000-4000-8000-000000000001:\(Self.hexSession)", id: 11)))
        XCTAssertFalse(harness.associations.awaitsReport)
        XCTAssertFalse(harness.timeline.contains { $0.contains("2: site sound") }, "B never shows another's sound")
        // WinMux switches them around; each button goes with its window.
        for _ in 0..<3 {
            let b = harness.frames[2]!
            harness.move(2, to: harness.frames[1]!)
            harness.move(1, to: b)
            harness.wait(1)
            harness.read(1, 2, 3)
            harness.report(triplets())
            harness.wait(1)
            harness.read(1, 2, 3)
        }
        XCTAssertEqual(Set(harness.timeline.suffix(6)), ["1: site sound, 2: site, 3: site sound"])
    }

    func testOneButtonAlsoSettlesItsOneTwin() {
        let harness = parkedTriplets()
        harness.close(1)
        harness.stamp(2, window: 11, tab: 101)
        trust(harness, [(11, 2, [Self.tab(id: 101)]), (12, 3, [Self.tab(id: 102, audible: true)])], reading: [2, 3])
        harness.wait(1)
        harness.read(2, 3)
        XCTAssertEqual(harness.timeline.last, "2: site, 3: site sound", "The report B's button names isn't C's, so C has the other")
    }

    /// A button outweighs frames and holds: should frames ever have paired twins the wrong way
    /// round, their buttons put them right, with neither showing the other's sound meanwhile.
    func testAButtonOutweighsWhatFramesSaidAndAHold() {
        let harness = pairedTwins()
        harness.session = Self.hexSession
        harness.report(twins())
        harness.wait(1)
        harness.read(1, 2)
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site")
        let before = harness.timeline.count
        harness.stamp(1, window: 11, tab: 101)
        harness.stamp(2, window: 10, tab: 100)
        trust(harness, twins(), reading: [1, 2])
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site, 2: site sound")
        XCTAssertFalse(harness.timeline[before...].contains { $0 == "1: site sound, 2: site sound" })
    }

    /// A window's button naming the report another window holds takes it from that one, which is
    /// then paired among what's left, never with both showing the same window's sound.
    func testAButtonNamingTheReportAnotherWindowHoldsTakesItFromThatOne() {
        let harness = pairedTwins()
        harness.session = Self.hexSession
        harness.report(twins())
        for _ in 0..<2 {
            harness.wait(1)
            harness.read(1, 2)
        }
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site")
        let before = harness.timeline.count
        harness.stamp(2, window: 10, tab: 100)
        trust(harness, twins(), reading: [1, 2])
        for _ in 0..<2 {
            harness.wait(1)
            harness.read(1, 2)
        }
        XCTAssertEqual(harness.timeline.last, "1: site, 2: site sound")
        XCTAssertEqual(harness.associations.resolution(of: 1), .resolved(.init(source: "8A7B6C5D-0000-4000-8000-000000000001:\(Self.hexSession)", id: 11)))
        XCTAssertFalse(harness.timeline[before...].contains { $0 == "1: site sound, 2: site sound" })
    }

    /// A window holding a report its tabs match, with nothing else to match (such as a Private
    /// Browsing window, which the extension doesn't report), lets it go once another window's
    /// button names that report: the two never both show its sound.
    func testAWindowsButtonTakesItsReportFromAHolderWithNoOtherMatch() {
        let harness = Harness()
        harness.session = Self.hexSession
        harness.frames = [1: Self.shown, 2: Self.parked]
        harness.reads = [1: Self.lone("Demo Page", window: 1), 2: Self.lone("Demo Page", window: 2)]
        harness.wait(2)
        // The report's bounds are where A is, so frames give A the one report.
        harness.report([(10, 1, [Self.tab(id: 100, audible: true)])])
        for _ in 0..<2 {
            harness.wait(1)
            harness.read(1, 2)
        }
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: Safari")
        let before = harness.timeline.count
        harness.stamp(2, window: 10, tab: 100)
        trust(harness, [(10, 1, [Self.tab(id: 100, audible: true)])], reading: [1, 2])
        harness.wait(1)
        harness.read(1, 2)
        XCTAssertEqual(harness.timeline.last, "1: site, 2: site sound", "A keeps its icon a few seconds, not the sound")
        XCTAssertFalse(harness.timeline[before...].contains { $0 == "1: site sound, 2: site sound" })
    }

    func testAButtonFromAnotherSessionOrNamingAWindowTheReportDoesntListNamesNothing() {
        let harness = parkedTriplets()
        harness.stamp(1, window: 10, tab: 100)
        harness.stamp(2, window: 11, tab: 101, session: "00000000-0000-4000-8000-000000000000")
        harness.stamp(3, window: 13, tab: 102)
        trust(harness, triplets(), reading: [1, 2, 3])
        harness.wait(1)
        harness.read(1, 2, 3)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: Safari, 3: Safari", "B and C are paired as if they had none")
        XCTAssertEqual(harness.associations.resolution(of: 3), .unresolved)
        // Safari titles them again, as for its new session or once the tab has moved.
        stampTriplets(harness)
        trust(harness, triplets(), reading: [1, 2, 3])
        harness.wait(1)
        harness.read(1, 2, 3)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site, 3: site sound")
    }

    func testTheSameButtonShownInTwoWindowsNamesNeither() {
        let harness = parkedTriplets()
        harness.stamp(1, window: 10, tab: 100)
        harness.stamp(2, window: 12, tab: 102)
        harness.stamp(3, window: 12, tab: 102)
        trust(harness, triplets(), reading: [1, 2, 3])
        harness.wait(1)
        harness.read(1, 2, 3)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: Safari, 3: Safari")
        XCTAssertFalse(harness.timeline.contains { $0.contains("2: site sound") })
    }

    /// Removing the button (or Safari hiding it) keeps what was settled while nothing contradicts
    /// it; a window opened after that is paired by what frames say, or not at all.
    func testWithoutItsButtonAWindowKeepsWhatItSettledAndNewOnesFallBackToFrames() {
        let harness = parkedTriplets()
        stampTriplets(harness)
        trust(harness, triplets(), reading: [1, 2, 3])
        harness.wait(1)
        harness.read(1, 2, 3)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site, 3: site sound")
        let before = harness.timeline.count
        for id: UInt32 in [1, 2, 3] { harness.reads[id]?.marker = nil }
        for _ in 0..<3 {
            harness.wait(1)
            harness.report(triplets())
            harness.wait(1)
            harness.read(1, 2, 3)
        }
        XCTAssertEqual(Set(harness.timeline[before...]), ["1: site sound, 2: site, 3: site sound"])
        harness.open(4, at: Self.parked)
        harness.report(triplets() + [(13, 4, [Self.tab(id: 103)])])
        for _ in 0..<2 {
            harness.wait(1)
            harness.read(1, 2, 3, 4)
        }
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site, 3: site sound, 4: Safari",
            "The parked ones keep their holds, and a fourth twin in the same place stays unpaired, as before buttons")
    }

    /// Safari reloads the extension: its new session reuses the same ids, and the buttons still
    /// show the old session's titles until it titles them again.
    func testAfterTheExtensionReconnectsOnlyItsNewSessionsButtonsCount() {
        let harness = parkedTriplets()
        stampTriplets(harness)
        trust(harness, triplets(), reading: [1, 2, 3])
        harness.wait(1)
        harness.read(1, 2, 3)
        let old = harness.session
        let key = { (id: Int, session: String) in SafariExtensionWindowKey(source: "8A7B6C5D-0000-4000-8000-000000000001:\(session)", id: id) }
        harness.session = "0b1c2d3e-0000-4000-8000-000000000002"
        harness.report(triplets())
        for _ in 0..<2 {
            harness.wait(1)
            harness.read(1, 2, 3)
        }
        XCTAssertEqual(harness.associations.resolution(of: 1), .resolved(key(10, harness.session)), "A's place still settles it")
        XCTAssertEqual(harness.associations.resolution(of: 2), .stale(key(11, old)), "The old session's titles name nothing now")
        XCTAssertEqual(harness.associations.resolution(of: 3), .stale(key(12, old)))
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site, 3: site", "B and C keep their icons a few seconds, without sound")
        harness.stamp(2, window: 11, tab: 101, session: old)
        harness.stamp(3, window: 12, tab: 102)
        trust(harness, triplets(), reading: [1, 2, 3])
        harness.wait(1)
        harness.read(1, 2, 3)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site, 3: site sound", "C's new title settles it, and B by elimination")
    }

    /// A new native window under a closed one's number starts over: the button it shows must
    /// name a window of the latest report, and two reads must agree, before it counts.
    func testANewWindowUnderAnOldNumberIsPairedOnlyByWhatItsOwnButtonNamesNow() {
        let harness = parkedTriplets()
        stampTriplets(harness)
        trust(harness, triplets(), reading: [1, 2, 3])
        harness.wait(1)
        harness.read(1, 2, 3)
        harness.close(2)
        harness.report([(10, 1, [Self.tab(id: 100, audible: true)]), (12, 3, [Self.tab(id: 102, audible: true)])])
        harness.open(2, at: Self.parked)
        // Safari still shows the closed window's title for a moment.
        harness.stamp(2, window: 11, tab: 101)
        harness.wait(1)
        harness.read(2)
        XCTAssertEqual(harness.associations.resolution(of: 2), .unresolved)
        // Safari reports the new window. A's and C's buttons name theirs, so it's the one left,
        // and once its own button names it too, that holds.
        harness.report([(10, 1, [Self.tab(id: 100, audible: true)]), (12, 3, [Self.tab(id: 102, audible: true)]), (14, 2, [Self.tab(id: 104)])])
        let key = SafariExtensionWindowKey(source: "8A7B6C5D-0000-4000-8000-000000000001:\(Self.hexSession)", id: 14)
        XCTAssertEqual(harness.associations.resolution(of: 2), .pending(key))
        harness.stamp(2, window: 14, tab: 104)
        harness.wait(1)
        harness.read(1, 2, 3)
        XCTAssertEqual(harness.associations.resolution(of: 2), .resolved(key))
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site, 3: site sound")
    }

    /// Two windows, each with an active Home tab and a Mail tab of its own site, paired by their
    /// buttons. Their Home tabs trade windows, still first and active, and each takes its button
    /// title with it, naming the window it left; Safari's report of the moves is late. Both
    /// windows' tabs still agree with both reports, and each title still matches its tab's old
    /// window, but no report since the read that saw them says the tabs stayed put: neither moves
    /// either window to the other's report, and neither Mail tab shows the other's site.
    func testTitlesTabsCarryToAnotherWindowDontMoveItsPairingBeforeSafariReportsTheMove() {
        let harness = Harness()
        harness.session = Self.hexSession
        harness.frames = [1: Self.shown, 2: Self.parked]
        func listed(_ native: UInt32, _ session: UUID) -> [BrowserTab] {
            [.init(target: .init(windowId: native, pid: 7, windowSession: session, tabId: UUID()), title: "Home", isSelected: true),
             .init(target: .init(windowId: native, pid: 7, windowSession: session, tabId: UUID()), title: "Mail", isSelected: false)]
        }
        let one = UUID(), two = UUID()
        harness.reads = [1: .init(windowId: 1, pid: 7, windowSession: one, tabs: listed(1, one)),
                         2: .init(windowId: 2, pid: 7, windowSession: two, tabs: listed(2, two))]
        let mailOne = Self.tab("Mail", id: 101, icon: Self.otherIcon, host: "one.test", active: false)
        let mailTwo = Self.tab("Mail", id: 111, icon: Self.otherIcon, audible: true, host: "two.test", active: false)
        let before: [(id: Int, native: UInt32?, tabs: [SafariExtensionTab])] =
            [(10, 1, [Self.tab("Home", id: 100), mailOne]), (11, 2, [Self.tab("Home", id: 110), mailTwo])]
        harness.wait(2)
        harness.stamp(1, window: 10, tab: 100)
        harness.stamp(2, window: 11, tab: 110)
        trust(harness, before, reading: [1, 2])
        harness.wait(1)
        harness.read(1, 2)
        let settled = "1: site | other site one.test, 2: site | other site sound two.test"
        XCTAssertEqual(harness.timeline.last, settled)
        let key = { SafariExtensionWindowKey(source: "8A7B6C5D-0000-4000-8000-000000000001:\(Self.hexSession)", id: $0) }

        // The Home tabs trade windows. Each window's button now shows the other's title.
        harness.order += 2
        harness.stamp(1, window: 11, tab: 110)
        harness.stamp(2, window: 10, tab: 100)
        let traded = harness.timeline.count
        for _ in 0..<4 {
            harness.wait(1)
            harness.read(1, 2)
        }
        XCTAssertEqual(harness.associations.resolution(of: 1), .resolved(key(10)))
        XCTAssertEqual(harness.associations.resolution(of: 2), .resolved(key(11)))
        XCTAssertEqual(Set(harness.timeline[traded...]), [settled], "No Mail tab ever shows the other's site or sound")
        XCTAssertTrue(harness.associations.awaitsReport, "WinMux asks Safari to report")

        // Safari reports the moves, and titles the buttons again.
        let after: [(id: Int, native: UInt32?, tabs: [SafariExtensionTab])] =
            [(10, 1, [Self.tab("Home", id: 110), mailOne]), (11, 2, [Self.tab("Home", id: 100), mailTwo])]
        harness.wait(1)
        harness.report(after)
        harness.stamp(1, window: 10, tab: 110)
        harness.stamp(2, window: 11, tab: 100)
        trust(harness, after, reading: [1, 2])
        harness.wait(1)
        harness.read(1, 2)
        // Until a read after that report pairs each Home tab with the one that came over, it shows nothing.
        for row in harness.timeline[traded...] {
            let parts = row.components(separatedBy: ", 2: ")
            XCTAssertFalse(parts[0].contains("two.test") || parts.last!.contains("one.test"), row)
        }
        XCTAssertEqual(harness.timeline.last, settled)
        XCTAssertEqual(harness.associations.described(harness.reads[1]!.tabs[0]).extensionTab?.id, 110, "A's Home is the tab that came over")
        XCTAssertEqual(harness.associations.described(harness.reads[2]!.tabs[1]).extensionTab?.id, 111)
    }

    /// A new native window shows a closed one's title, which the last report, from before it
    /// closed, still lists. The new window appeared after that report, and no later report says
    /// the title holds: it doesn't take the closed window's report.
    func testANewWindowShowingAClosedOnesTitleDoesntTakeItsReportBeforeSafariReportsAgain() {
        let harness = parkedTriplets()
        stampTriplets(harness)
        trust(harness, triplets(), reading: [1, 2, 3])
        harness.wait(1)
        harness.read(1, 2, 3)
        XCTAssertEqual(harness.timeline.last, "1: site sound, 2: site, 3: site sound")
        harness.close(2)
        harness.order += 2
        harness.open(4, at: Self.parked)
        harness.stamp(4, window: 11, tab: 101)
        for _ in 0..<4 {
            harness.wait(1)
            harness.read(1, 3, 4)
        }
        XCTAssertNotEqual(harness.associations.resolution(of: 4), .resolved(.init(source: "8A7B6C5D-0000-4000-8000-000000000001:\(Self.hexSession)", id: 11)))
        XCTAssertEqual(harness.timeline.last, "1: site sound, 3: site sound, 4: Safari")
        // Safari reports the change, with the new window, and titles it.
        let now: [(id: Int, native: UInt32?, tabs: [SafariExtensionTab])] =
            [(10, 1, [Self.tab(id: 100, audible: true)]), (12, 3, [Self.tab(id: 102, audible: true)]), (14, 4, [Self.tab(id: 104)])]
        harness.stamp(4, window: 14, tab: 104)
        trust(harness, now, reading: [1, 3, 4])
        harness.wait(1)
        harness.read(1, 3, 4)
        XCTAssertEqual(harness.associations.resolution(of: 4), .resolved(.init(source: "8A7B6C5D-0000-4000-8000-000000000001:\(Self.hexSession)", id: 14)))
    }

    /// A button counts once a report Safari measured after the read that saw it, which began after
    /// the report before arrived, still agrees with the same count of reorderings. B, a twin no
    /// frames tell apart, keeps anything else from pairing A.
    func testAButtonCountsOnlyOnceAReportFromAfterTheReadThatSawItAgreesWithNothingReordered() {
        let prefix = String(Self.hexSession.prefix(8))
        var a = Self.lone("Demo Page", window: 1)
        a.marker = .init(session: prefix, window: 10, tab: 100)
        let b = Self.lone("Demo Page", window: 2)
        func reports(received: TimeInterval, measured: TimeInterval, order: Int) -> [SafariExtensionWindow] {
            [SafariExtensionWindow(key: .init(source: "p:s", id: 10), session: Self.hexSession, tabs: [Self.tab(id: 100)],
                received: received, measured: measured, order: order),
             SafariExtensionWindow(key: .init(source: "p:s", id: 11), session: Self.hexSession, tabs: [Self.tab(id: 101)],
                received: received, measured: measured, order: order)]
        }
        var associations = SafariExtensionAssociations()
        func step(read: TimeInterval, _ windows: [SafariExtensionWindow]) {
            associations.update([.init(snapshot: a, observed: read, readStarted: read - 0.1), .init(snapshot: b, observed: read, readStarted: read - 0.1)],
                windows: windows, now: max(read, windows[0].received))
        }
        let key = SafariExtensionWindowKey(source: "p:s", id: 10)
        step(read: 0.5, reports(received: 1, measured: 0.9, order: 5))
        step(read: 0.5, reports(received: 3, measured: 2.5, order: 5))
        XCTAssertEqual(associations.resolution(of: 1), .unresolved, "No read after the first report saw the button")
        step(read: 4, reports(received: 3, measured: 2.5, order: 5))
        step(read: 4, reports(received: 5, measured: 3.9, order: 5))
        XCTAssertEqual(associations.resolution(of: 1), .unresolved, "A report measured while that read looked can't say the tab stayed")
        step(read: 4, reports(received: 6, measured: 5.5, order: 6))
        XCTAssertEqual(associations.resolution(of: 1), .unresolved, "Something was reordered since: it starts over")
        XCTAssertTrue(associations.awaitsReport)
        step(read: 7, reports(received: 6, measured: 5.5, order: 6))
        step(read: 7, reports(received: 8, measured: 7.5, order: 6))
        XCTAssertEqual(associations.resolution(of: 1), .pending(key))
        step(read: 9, reports(received: 8, measured: 7.5, order: 6))
        XCTAssertEqual(associations.resolution(of: 1), .resolved(key))
        XCTAssertEqual(associations.resolution(of: 2), .resolved(.init(source: "p:s", id: 11)), "and B is the one left")
    }

    /// What a button names must agree with the latest report: that window, from its session, with
    /// that tab active, and the same tabs as the read. Anything else names nothing.
    func testAButtonPairsItsWindowOnlyWhenTheReportListsThatWindowWithThatTabActive() {
        let source = "p:\(Self.hexSession)"
        func window(_ id: Int, active: Int, session: String = Self.hexSession, source: String = source, ids: Bool = true) -> SafariExtensionWindow {
            .init(key: .init(source: source, id: id), session: session, tabs: [
                .init(id: ids ? id * 10 : nil, title: "Mail", isActive: active == id * 10),
                .init(id: ids ? id * 10 + 1 : nil, title: "Demo Page", isActive: active == id * 10 + 1),
            ])
        }
        func read(_ native: UInt32, selected: Int = 1, marker: SafariExtensionMarker?) -> SafariExtensionCandidate {
            let session = UUID()
            var snapshot = BrowserWindowTabs(windowId: native, pid: 7, windowSession: session, tabs: ["Mail", "Demo Page"].enumerated().map {
                .init(target: .init(windowId: native, pid: 7, windowSession: session, tabId: UUID()), title: $1, isSelected: $0 == selected)
            })
            snapshot.marker = marker
            return .init(snapshot: snapshot, observed: 1)
        }
        let prefix = String(Self.hexSession.prefix(8))
        let windows = [window(1, active: 11), window(2, active: 21)]
        let a = SafariExtensionMarker(session: prefix, window: 1, tab: 11)
        let b = SafariExtensionMarker(session: prefix, window: 2, tab: 21)
        XCTAssertEqual(safariExtensionMarkedPairs([read(5, marker: a), read(6, marker: b)], windows),
            [5: windows[0].key, 6: windows[1].key])
        XCTAssertEqual(safariExtensionMarkedPairs([read(5, marker: a), read(6, marker: nil)], windows), [5: windows[0].key])
        for (marker, why) in [
            (SafariExtensionMarker(session: prefix, window: 1, tab: 10), "a tab not active there: the button hasn't caught up with a switch"),
            (SafariExtensionMarker(session: prefix, window: 1, tab: 21), "a tab the window doesn't have: it moved"),
            (SafariExtensionMarker(session: prefix, window: 3, tab: 11), "a window the report doesn't list"),
            (SafariExtensionMarker(session: "00000000", window: 1, tab: 11), "another session's"),
        ] {
            XCTAssertEqual(safariExtensionMarkedPairs([read(5, marker: marker)], windows), [:], why)
        }
        XCTAssertEqual(safariExtensionMarkedPairs([read(5, selected: 0, marker: a)], windows), [:], "A read whose tabs disagree")
        XCTAssertEqual(safariExtensionMarkedPairs([read(5, marker: a), read(6, marker: a)], windows), [:], "Two windows showing one button")
        XCTAssertEqual(safariExtensionMarkedPairs([read(5, marker: a), read(6, selected: 0, marker: a)], windows), [:],
            "even when only one of them agrees with the report")
        let otherProfile = window(1, active: 11, source: "q:\(Self.hexSession)")
        XCTAssertEqual(safariExtensionMarkedPairs([read(5, marker: a)], windows + [otherProfile]), [:],
            "Two reports, each with a session starting the same way, listing the window")
        XCTAssertEqual(safariExtensionMarkedPairs([read(5, marker: a)], [window(1, active: 11, ids: false)]), [:],
            "An older extension's report names no tabs")
        var twoActive = window(1, active: 11)
        twoActive = .init(key: twoActive.key, session: twoActive.session, tabs: [
            .init(id: 10, title: "Demo Page", isActive: true), .init(id: 11, title: "Demo Page", isActive: true),
        ])
        func readTwo(_ native: UInt32, marker: SafariExtensionMarker) -> SafariExtensionCandidate {
            let session = UUID()
            var snapshot = BrowserWindowTabs(windowId: native, pid: 7, windowSession: session, tabs: [0, 1].map {
                .init(target: .init(windowId: native, pid: 7, windowSession: session, tabId: UUID()), title: "Demo Page", isSelected: $0 == 0)
            })
            snapshot.tabs[1].isSelected = true
            snapshot.marker = marker
            return .init(snapshot: snapshot, observed: 1)
        }
        XCTAssertEqual(safariExtensionMarkedPairs([readTwo(5, marker: .init(session: prefix, window: 1, tab: 10)),
                                                   readTwo(6, marker: .init(session: prefix, window: 1, tab: 11))], [twoActive]), [:],
            "A report listing two active tabs in one window lets neither button name it")
    }

    /// While some Safari window is unread, a pairing needs frames to rule it out, unless the
    /// window's own button names its report: the unread one can't be showing that button.
    func testAButtonPairsItsWindowEvenWhileAnotherSafariWindowIsUnread() {
        let prefix = String(Self.hexSession.prefix(8))
        func report(received: TimeInterval) -> [SafariExtensionWindow] {
            [SafariExtensionWindow(key: .init(source: "p:s", id: 10), session: Self.hexSession, tabs: [Self.tab(id: 100, audible: true)],
                received: received, measured: received - 0.1, order: 5)]
        }
        for marked in [true, false] {
            var snapshot = Self.lone("Demo Page", window: 1)
            if marked { snapshot.marker = .init(session: prefix, window: 10, tab: 100) }
            var associations = SafariExtensionAssociations()
            // A report, a read after it, a report after that read, and another read.
            associations.update([.init(snapshot: snapshot, observed: 2, readStarted: 1.9)], windows: report(received: 1), unread: [5], now: 2)
            associations.update([.init(snapshot: snapshot, observed: 2, readStarted: 1.9)], windows: report(received: 3), unread: [5], now: 3)
            associations.update([.init(snapshot: snapshot, observed: 4, readStarted: 3.9)], windows: report(received: 3), unread: [5], now: 4)
            XCTAssertEqual(associations.resolution(of: 1), marked ? .resolved(report(received: 3)[0].key) : .unresolved, "marked: \(marked)")
        }
    }

    /// Windows the extension describes in full, by a recent report that lets it read every
    /// website, are read only now and then; any other is read as often as before.
    func testOnlyWindowsTheExtensionDescribesInFullAndLatelyAreSettled() {
        let harness = parkedTriplets()
        stampTriplets(harness)
        trust(harness, triplets(), reading: [1, 2, 3])
        harness.wait(1)
        harness.read(1, 2, 3)
        let snapshots = Array(harness.reads.values)
        XCTAssertEqual(safariExtensionSettledWindows(snapshots, harness.associations, windows: harness.bridge.windows, now: harness.uptime), [1, 2, 3])
        XCTAssertEqual(safariExtensionSettledWindows(snapshots, harness.associations, windows: harness.bridge.windows,
            now: harness.uptime + safariExtensionSettledReportAge), [], "Not once the extension stops checking in")
        // B's tab changes title before Safari reports it.
        harness.reads[2]!.tabs[0].title = "(1) Demo Page"
        harness.read(2)
        XCTAssertEqual(safariExtensionSettledWindows(Array(harness.reads.values), harness.associations, windows: harness.bridge.windows,
            now: harness.uptime), [1, 3])
        XCTAssertEqual(harness.associations.lapsed, [2], "B no longer agrees: a report saying so has it read again at once")
        harness.read(1, 3)
        XCTAssertEqual(harness.associations.lapsed, [])

        // A second tab with the same title opens in C: until a later report confirms which is
        // which, C isn't described in full.
        let c = harness.reads[3]!
        harness.reads[3] = .init(windowId: 3, pid: 7, windowSession: c.windowSession, tabs: [
            c.tabs[0], .init(target: .init(windowId: 3, pid: 7, windowSession: c.windowSession, tabId: UUID()), title: "Demo Page", isSelected: false),
        ], marker: c.marker)
        let cTabs = [Self.tab(id: 102, audible: true), Self.tab(id: 105, active: false)]
        harness.report([(10, 1, [Self.tab(id: 100, audible: true)]), (11, 2, [Self.tab("(1) Demo Page", id: 101)]), (12, 3, cTabs)])
        harness.wait(1)
        harness.read(1, 2, 3)
        XCTAssertEqual(harness.associations.resolution(of: 3), .resolved(.init(source: "8A7B6C5D-0000-4000-8000-000000000001:\(Self.hexSession)", id: 12)))
        XCTAssertFalse(safariExtensionSettledWindows(Array(harness.reads.values), harness.associations, windows: harness.bridge.windows,
            now: harness.uptime).contains(3))
    }

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
