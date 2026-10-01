@testable import AppBundle
import JavaScriptCore
import XCTest

/// Runs the extension's own background page, `shared.js` and `background.js`, in JavaScriptCore
/// against a stand-in for Safari's `browser` API and a clock the test moves. JavaScriptCore runs
/// promise jobs as each evaluation ends, so each timer runs in an evaluation of its own.
final class SafariExtensionBackgroundTest: XCTestCase {
    private static let resources = projectRoot.appendingPathComponent("Sources/SafariExtension/Resources")
    private static let session = "3f2a9c1e-0000-4000-8000-000000000001"

    /// Safari as the page sees it: its windows (`safariWindows`), what the page sent WinMux
    /// (`sent`) and the toolbar titles it set (`titles`), and WinMux's next answers (`replies`).
    private static let stand = """
        var now = 1790000000000;
        var timers = [];
        var timerCount = 0;
        function setTimeout(callback, delay) {
            timerCount += 1;
            timers.push({ id: timerCount, callback, at: now + Math.max(0, delay || 0) });
            return timerCount;
        }
        function clearTimeout(id) { timers = timers.filter((timer) => timer.id !== id); }
        function runNext(limit) {
            timers.sort((left, right) => left.at - right.at || left.id - right.id);
            const timer = timers[0];
            if (!timer || timer.at > limit) return false;
            timers.shift();
            now = Math.max(now, timer.at);
            timer.callback();
            return true;
        }
        Date.now = () => now;
        function event() {
            const listeners = [];
            return { listeners, addListener: (listener) => listeners.push(listener), fire: (...values) => listeners.forEach((listener) => listener(...values)) };
        }
        var sent = [];
        var titles = [];
        var replies = [];
        var listings = 0;
        var duringListing = null;
        var safariWindows = [];
        var port = { onMessage: event() };
        var copy = (value) => JSON.parse(JSON.stringify(value));
        var crypto = { randomUUID: () => "\(session)", subtle: {} };
        var browser = {
            storage: { session: {
                get: async (keys) => Object.fromEntries(keys.filter((key) => key in storage).map((key) => [key, copy(storage[key])])),
                set: async (values) => { Object.assign(storage, copy(values)); },
            } },
            tabs: Object.assign({ query: async () => [], get: async (id) => safariWindows.flatMap((window) => window.tabs).find((tab) => tab.id === id) },
                Object.fromEntries(["onUpdated", "onRemoved", "onReplaced", "onCreated", "onActivated", "onMoved", "onAttached", "onDetached"]
                    .map((name) => [name, event()]))),
            windows: { WINDOW_ID_NONE: -1, onCreated: event(), onRemoved: event(), onFocusChanged: event(), getAll: async () => {
                listings += 1;
                if (duringListing) {
                    const change = duringListing;
                    duringListing = null;
                    change();
                    await new Promise((resolve) => setTimeout(resolve, 5));
                }
                return copy(safariWindows);
            } },
            permissions: { contains: async () => true },
            runtime: {
                sendNativeMessage: async (_, message) => {
                    sent.push(copy(message));
                    const reply = replies.length ? replies.shift() : { v: 2, ok: true, want: [] };
                    if (reply === "unreachable") throw new Error("WinMux isn't listening");
                    return reply;
                },
                onMessage: event(), onInstalled: event(), onStartup: event(), connectNative: () => port,
            },
            alarms: { get: async () => ({}), create: () => {}, onAlarm: event() },
            scripting: { executeScript: async () => {} },
            action: { setTitle: async (details) => { titles.push(copy(details)); } },
        };
        """

    /// Two one-tab windows on the same page and a Private Browsing one.
    private static let windows = """
        [
            {id: 1, type: 'normal', left: 0, top: 25, width: 1024, height: 743, tabs: [
                {id: 7, index: 0, title: 'Demo Page', url: 'https://demo.test/', active: true}]},
            {id: 2, type: 'normal', left: 1023, top: 767, width: 1024, height: 743, tabs: [
                {id: 8, index: 0, title: 'Demo Page', url: 'https://demo.test/', active: true}]},
            {id: 3, type: 'normal', incognito: true, left: 0, top: 25, width: 1024, height: 743, tabs: [
                {id: 9, index: 0, title: 'Secret', url: 'https://secret.test/', active: true}]},
        ]
        """

    /// The page as Safari loads it, with what session storage kept from a page before it.
    private func page(storage: String = "{}", windows: String = windows, replies: String = "[]") throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        context.evaluateScript("var storage = \(storage);\n" + Self.stand)
        context.evaluateScript("safariWindows = \(windows); replies = \(replies);")
        for file in ["shared.js", "background.js"] {
            context.evaluateScript(try String(contentsOf: Self.resources.appendingPathComponent(file), encoding: .utf8))
        }
        XCTAssertNil(failure)
        try settle(context)
        return context
    }

    /// Lets `seconds` pass, running each timer due meanwhile.
    private func settle(_ context: JSContext, seconds: Double = 1) throws {
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        context.evaluateScript("var limit = now + \(Int(seconds * 1000));")
        while context.evaluateScript("runNext(limit)")?.toBool() == true {}
        context.evaluateScript("now = limit;")
        if let failure { XCTFail(failure) }
    }

    private func run(_ context: JSContext, _ source: String, seconds: Double = 1) throws {
        context.evaluateScript(source)
        try settle(context, seconds: seconds)
    }

    private func value(_ context: JSContext, _ source: String) throws -> Any? {
        let json = context.evaluateScript("JSON.stringify(\(source))")?.toString()
        return try json.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
    }

    private func reports(_ context: JSContext) throws -> [[String: Any]] {
        try XCTUnwrap(try value(context, "sent.filter((message) => message.type === 'state')") as? [[String: Any]])
    }

    private func titles(_ context: JSContext) throws -> [(tab: Int, title: String)] {
        try XCTUnwrap(try value(context, "titles") as? [[String: Any]]).map { (($0["tabId"] as? Int) ?? -1, ($0["title"] as? String) ?? "") }
    }

    func testEachWindowsActiveTabsButtonNamesItsWindowForWinMuxWhichReadsItBack() throws {
        let context = try page()
        let report = try XCTUnwrap(try reports(context).last)
        let stamps = try titles(context)
        XCTAssertEqual(stamps.map(\.tab), [7, 8], "A Private Browsing window's button says nothing")
        let markers = stamps.compactMap { SafariExtensionMarker($0.title) }
        XCTAssertEqual(markers, [.init(session: "3f2a9c1e", window: 1, tab: 7), .init(session: "3f2a9c1e", window: 2, tab: 8)])
        XCTAssertTrue(try XCTUnwrap(report["session"] as? String).hasPrefix(markers[0].session))
        XCTAssertEqual((report["windows"] as? [[String: Any]])?.compactMap { $0["id"] as? Int }, [1, 2])

        // Another tab opens and is active: only its button is titled.
        try run(context, """
            safariWindows[0].tabs[0].active = false;
            safariWindows[0].tabs.push({id: 10, index: 1, title: 'Mail', url: 'https://mail.test/', active: true});
            browser.tabs.onCreated.fire({id: 10}); browser.tabs.onActivated.fire({tabId: 10, windowId: 1});
            """)
        XCTAssertEqual(try titles(context).dropFirst(2).map(\.title), [WinMuxTabsTitle(window: 1, tab: 10)])
        // It moves to the other window: titled again, with that window.
        try run(context, """
            safariWindows[0].tabs = [safariWindows[0].tabs[0]]; safariWindows[0].tabs[0].active = true;
            safariWindows[1].tabs[0].active = false; safariWindows[1].tabs.push({id: 10, index: 1, title: 'Mail', url: 'https://mail.test/', active: true});
            browser.tabs.onDetached.fire(10, {}); browser.tabs.onAttached.fire(10, {newWindowId: 2});
            """)
        XCTAssertEqual(try titles(context).dropFirst(3).map(\.title), [WinMuxTabsTitle(window: 2, tab: 10)],
            "Tab 7, active again, keeps the title it was given")
        // A page loading may lose its title, so it's titled again, but WinMux hears nothing new.
        let sent = try reports(context).count
        try run(context, "browser.tabs.onUpdated.fire(7, {status: 'loading', url: 'https://demo.test/'}); browser.tabs.onUpdated.fire(7, {status: 'complete'});")
        XCTAssertEqual(try titles(context).dropFirst(4).map(\.title), [WinMuxTabsTitle(window: 1, tab: 7)])
        XCTAssertEqual(try reports(context).count, sent)
        // Safari unloads the page and loads it again: it titles each button again.
        let storage = try XCTUnwrap(context.evaluateScript("JSON.stringify(storage)")?.toString())
        let reloaded = try page(storage: storage, windows: try XCTUnwrap(context.evaluateScript("JSON.stringify(safariWindows)")?.toString()))
        XCTAssertEqual(try titles(reloaded).map(\.title), [WinMuxTabsTitle(window: 1, tab: 7), WinMuxTabsTitle(window: 2, tab: 10)])
    }

    func testOnlyAReportThatSaysSomethingNewIsSentUnlessWinMuxOrTheHeartbeatAsks() throws {
        let context = try page()
        XCTAssertEqual(try reports(context).count, 1, "The whole picture as the page loads")
        // A page reloads with the same title, and the user switches between Safari's windows,
        // which moves none: nothing new.
        try run(context, "browser.tabs.onUpdated.fire(7, {url: 'https://demo.test/'}); browser.windows.onFocusChanged.fire(2);")
        XCTAssertEqual(try reports(context).count, 1)
        // Safari's own windows losing focus doesn't even list them.
        let listings = try XCTUnwrap(try value(context, "listings") as? Int)
        try run(context, "browser.windows.onFocusChanged.fire(browser.windows.WINDOW_ID_NONE);")
        XCTAssertEqual(try value(context, "listings") as? Int, listings)
        // WinMux switching them moves them: the focus change reports where they are now.
        try run(context, "safariWindows[0].left = 1023; safariWindows[0].top = 767; safariWindows[1].left = 0; safariWindows[1].top = 25; browser.windows.onFocusChanged.fire(2);")
        XCTAssertEqual(try reports(context).count, 2)
        XCTAssertEqual(((try reports(context).last?["windows"] as? [[String: Any]])?.first?["bounds"] as? [Int])?.first, 1023)
        // The heartbeat and WinMux asking always send it, so a WinMux that lost it catches up.
        try run(context, "browser.alarms.onAlarm.fire({name: 'winmux-heartbeat'});")
        XCTAssertEqual(try reports(context).count, 3)
        try run(context, "port.onMessage.fire({name: 'resync'});")
        XCTAssertEqual(try reports(context).count, 4)
        // Until WinMux has every icon it asked for, the same report goes again.
        try run(context, "replies.push({v: 2, ok: true, want: ['\(String(repeating: "a", count: 64))']}); browser.alarms.onAlarm.fire({name: 'winmux-heartbeat'});")
        try run(context, "browser.tabs.onUpdated.fire(7, {title: 'Demo Page'});")
        XCTAssertEqual(try reports(context).count, 6)
        // WinMux turned browser tabs off: it's asked again 5 s on, and once it's back, it hears
        // the same report again.
        try run(context, "replies.push({v: 2, ok: false, reason: 'off'}); safariWindows[0].tabs[0].title = 'Demo'; browser.tabs.onUpdated.fire(7, {title: 'Demo'});")
        XCTAssertEqual(try reports(context).count, 7)
        try run(context, "browser.tabs.onUpdated.fire(7, {title: 'Demo'});", seconds: 3)
        XCTAssertEqual(try reports(context).count, 7, "While WinMux is away, changes wait")
        try settle(context, seconds: 2)
        XCTAssertEqual(try reports(context).count, 8, "and once it's back, it hears the same report again")
        try run(context, "browser.tabs.onUpdated.fire(7, {title: 'Demo'});")
        XCTAssertEqual(try reports(context).count, 8)
    }

    /// WinMux's answer can ask for another report a moment later, which goes even though it would
    /// say nothing new; one such request waits at a time, and anything but a few seconds is ignored.
    /// A window gaining focus reports a second later, once WinMux has moved its windows.
    func testWinMuxCanAskForAnotherReportAndAFocusChangeReportsOnceWindowsSettle() throws {
        let context = try page()
        XCTAssertEqual(try reports(context).count, 1)
        try run(context, "replies.push({v: 2, ok: true, want: [], again: 2}); browser.alarms.onAlarm.fire({name: 'winmux-heartbeat'});", seconds: 0.5)
        XCTAssertEqual(try reports(context).count, 2)
        try run(context, "browser.tabs.onUpdated.fire(7, {title: 'Demo Page'});", seconds: 1)
        XCTAssertEqual(try reports(context).count, 2, "The same report, unasked, isn't sent")
        try settle(context, seconds: 1)
        XCTAssertEqual(try reports(context).count, 3, "WinMux asked for it two seconds on")
        for again in ["0", "61", "'2'", "1.5"] {
            try run(context, "replies.push({v: 2, ok: true, want: [], again: \(again)}); browser.alarms.onAlarm.fire({name: 'winmux-heartbeat'});", seconds: 40)
        }
        XCTAssertEqual(try reports(context).count, 7, "Only the heartbeats")
        try run(context, "replies.push({v: 2, ok: true, want: [], again: 3}, {v: 2, ok: true, want: [], again: 3}); browser.alarms.onAlarm.fire({name: 'winmux-heartbeat'});", seconds: 1)
        try run(context, "browser.alarms.onAlarm.fire({name: 'winmux-heartbeat'});", seconds: 2.5)
        XCTAssertEqual(try reports(context).count, 10, "Two asked within one wait bring one more report")
        try settle(context, seconds: 5)
        XCTAssertEqual(try reports(context).count, 10)

        try run(context, "safariWindows[0].left = 1023; browser.windows.onFocusChanged.fire(1);", seconds: 0.5)
        XCTAssertEqual(try reports(context).count, 10, "Not while WinMux may still be moving windows")
        try settle(context, seconds: 1)
        XCTAssertEqual(try reports(context).count, 11)
    }

    /// Safari reloads the extension as WinMux starts, so its first report can come before WinMux
    /// listens. A report WinMux didn't take is tried again 5 s on, then 10, 20 and 40, then each
    /// minute, and from 5 s again once WinMux answers.
    func testAReportWinMuxDidntTakeIsTriedAgainSoonThenLessOften() throws {
        let context = try page(replies: "['unreachable', 'unreachable', 'unreachable']")
        XCTAssertEqual(try reports(context).count, 1, "The first, before WinMux listens")
        var attempts: [Double] = []
        for second in 1...40 {
            let before = try reports(context).count
            try settle(context, seconds: 1)
            if try reports(context).count > before { attempts.append(Double(second)) }
        }
        XCTAssertEqual(attempts, [5, 15, 35], "5 s, then 10, then 20 later; the last one is taken")
        try run(context, "replies.push('unreachable'); browser.alarms.onAlarm.fire({name: 'winmux-heartbeat'});")
        let failed = try reports(context).count
        try settle(context, seconds: 3)
        XCTAssertEqual(try reports(context).count, failed, "The heartbeat's attempt was a second ago")
        try settle(context, seconds: 1)
        XCTAssertEqual(try reports(context).count, failed + 1, "From 5 s again after WinMux answered")
    }

    /// Safari unloads the page while it waits to try WinMux again, and loads it again with what
    /// session storage kept: the attempt still comes when the wait ends, without any tab event or
    /// heartbeat, and titles the buttons.
    func testAPageReloadedWhileWaitingToTryWinMuxAgainStillTriesWhenTheWaitEnds() throws {
        let context = try page(replies: "['unreachable']")
        XCTAssertEqual(try reports(context).count, 1)
        let storage = try XCTUnwrap(context.evaluateScript("JSON.stringify(storage)")?.toString())
        let reloaded = try page(storage: storage)
        XCTAssertEqual(try reports(reloaded).count, 0, "Still waiting")
        XCTAssertEqual(try titles(reloaded).count, 0)
        // The new page's clock starts where the first one's did: the wait has about 4.25 s left.
        try settle(reloaded, seconds: 3.5)
        XCTAssertEqual(try reports(reloaded).count, 0)
        try settle(reloaded, seconds: 1.5)
        XCTAssertEqual(try reports(reloaded).count, 1, "The attempt comes when the wait ends")
        XCTAssertEqual(try titles(reloaded).filter { !$0.title.isEmpty }.map(\.tab), [7, 8], "and titles the buttons")
    }

    /// A button put back in the toolbar shows just the extension's name, and nothing says it came
    /// back: the heartbeat, and any other forced report, titles every window's button again,
    /// first resetting it to the name, as Safari ignores a title the tab already has.
    func testAForcedReportTitlesEveryWindowsButtonAgain() throws {
        let context = try page()
        XCTAssertEqual(try titles(context).map(\.tab), [7, 8])
        try run(context, "browser.tabs.onUpdated.fire(7, {title: 'Demo Page'});")
        XCTAssertEqual(try titles(context).count, 2, "An ordinary report doesn't title them again")
        try run(context, "browser.alarms.onAlarm.fire({name: 'winmux-heartbeat'});")
        let again = try titles(context).dropFirst(2)
        XCTAssertEqual(again.filter { $0.title.isEmpty }.map(\.tab), [7, 8], "Each reset to the name")
        XCTAssertEqual(again.filter { !$0.title.isEmpty }.map(\.title),
            [WinMuxTabsTitle(window: 1, tab: 7), WinMuxTabsTitle(window: 2, tab: 8)])
        for tab in [7, 8] {
            XCTAssertEqual(again.filter { $0.tab == tab }.map(\.title.isEmpty), [true, false], "then titled, tab \(tab)")
        }
    }

    /// The count of tab moves, openings and closings: once per event, not for activations or
    /// titles, left out when a move lands while Safari lists its windows, and kept across reloads.
    func testTheReorderCountCountsEachEventLeavesOutAMoveMidListingAndSurvivesAReload() throws {
        let context = try page()
        let start = try XCTUnwrap(try reports(context).last?["order"] as? Int)
        try run(context, "browser.tabs.onMoved.fire(7, {}); browser.tabs.onCreated.fire({id: 11});")
        XCTAssertEqual(try reports(context).last?["order"] as? Int, start + 2)
        try run(context, "browser.tabs.onActivated.fire({tabId: 7}); browser.tabs.onUpdated.fire(7, {title: 'Demo Page'});")
        XCTAssertEqual(try reports(context).last?["order"] as? Int, start + 2)
        let sent = try reports(context).count
        try run(context, "duringListing = () => browser.tabs.onMoved.fire(7, {}); browser.tabs.onUpdated.fire(7, {title: 'Demo Page'});")
        let after = try reports(context)
        XCTAssertEqual(after.count, sent + 2)
        XCTAssertNil(after[sent]["order"], "A count that changed while Safari listed its windows isn't sent")
        XCTAssertEqual(after.last?["order"] as? Int, start + 3, "The move's own report counts it")
        let storage = try XCTUnwrap(context.evaluateScript("JSON.stringify(storage)")?.toString())
        XCTAssertEqual(try reports(try page(storage: storage)).last?["order"] as? Int, start + 3, "Kept while Safari unloads the page")
    }

    private func WinMuxTabsTitle(window: Int, tab: Int) -> String { "WinMux Tabs \u{00B7} 3f2a9c1e-\(window)-\(tab)" }
}
