import JavaScriptCore
import XCTest

/// Exercises the shipped scripts with synthetic browser APIs; never opens a browser.
final class BrowserPushBackgroundTest: XCTestCase {
    static let stand = #"""
    var now = 1790000000000, timers = [], serial = 0, uuid = 0;
    Date.now = () => now;
    function setTimeout(callback, delay) { const id = ++serial; timers.push({id, callback, at: now + (delay || 0)}); return id; }
    function clearTimeout(id) { timers = timers.filter(t => t.id !== id); }
    function tick(limit) {
        timers.sort((a,b) => a.at-b.at || a.id-b.id);
        if (!timers.length || timers[0].at > limit) return false;
        const t = timers.shift(); now = t.at; t.callback(); return true;
    }
    function event() { const listeners=[]; return { addListener: f => listeners.push(f), fire: (...args) => listeners.forEach(f => f(...args)) }; }
    const copy = x => JSON.parse(JSON.stringify(x));
    // Each page load's ids differ after the first 8 characters, as random ones would.
    const load = () => Math.floor(Math.random() * 0x10000).toString(16).padStart(4, '0');
    const loadMark = load() + '-4' + load().slice(1);
    var crypto = { randomUUID: () => 'aaaaaaaa-' + loadMark + '-8aaa-' + String(++uuid).padStart(12,'0'), subtle: {} };
    var storage = {}, sent = [], listings = 0, updates = 0, connections = 0, emitActivation = true, throwAfterUpdate = false;
    // While set, session storage refuses every write and removal, as an unavailable storage service would.
    var failWrites = false;
    var reply = {v:2, ok:true, events:1, want:[]}, oldApp = false;
    function answer(message) { return oldApp ? (message.type === 'events' ? {v:2,ok:false,reason:'invalid'} : {v:2,ok:true,want:[]}) : copy(reply); }
    var windows = [1,2,3].map(id => ({id, type:'normal', incognito:id===3, left:id*100, top:25, width:900, height:700,
        tabs:[{id:id*10, windowId:id, index:0, title:'Synthetic '+id, url:'https://example.test/', active:false, incognito:id===3}]}));
    var fakePort = {onMessage:event(), onDisconnect:event(), postMessage: message => {
        sent.push(copy(message));
        if (message.push) Promise.resolve().then(() => fakePort.onMessage.fire({reply:copy(reply), seq:message.push.seq}));
    }, disconnect: () => fakePort.onDisconnect.fire()};
    var browser = {
        storage:{session:{get:async keys => Object.fromEntries(keys.filter(k=>k in storage).map(k=>[k,copy(storage[k])])),
            set:async values => { if (failWrites) throw Error('unavailable'); Object.assign(storage,copy(values)); },
            remove:async keys => { if (failWrites) throw Error('unavailable'); [].concat(keys).forEach(k => delete storage[k]); }}},
        tabs:Object.assign({query:async()=>[], get:async id=>copy(windows.flatMap(w=>w.tabs).find(t=>t.id===id)),
            update:async(id,change)=>{ updates++; const tab=windows.flatMap(w=>w.tabs).find(t=>t.id===id); Object.assign(tab,change);
                if(emitActivation) browser.tabs.onActivated.fire({windowId:tab.windowId,tabId:id});
                if(throwAfterUpdate) throw Error('uncertain'); return copy(tab); }},
            Object.fromEntries(['onUpdated','onRemoved','onReplaced','onCreated','onActivated','onMoved','onAttached','onDetached'].map(n=>[n,event()]))),
        windows:{WINDOW_ID_NONE:-1,onCreated:event(),onRemoved:event(),onFocusChanged:event(),
            getAll:async()=>{listings++; return copy(windows);}, get:async id=>{const w=windows.find(w=>w.id===id); if(!w)throw Error('gone');return copy(w);}},
        runtime:{lastError:null,connectNative:()=>{ connections++; return fakePort; },onMessage:event(),onInstalled:event(),onStartup:event(),
            sendNativeMessage:async(_,message)=>{sent.push(copy(message));return answer(message);}},
        permissions:{contains:async()=>true}, action:{setTitle:async()=>{}}, scripting:{executeScript:async()=>{}},
        alarms:{get:async()=>({}),create:()=>{},onAlarm:event()}
    };
    var chrome = browser;
    function importScripts() {}
    function prepareCommand(browserName, overrides={}) {
        const state = sent.filter(m=>(m.type==='state'||m.type==='events')).at(-1);
        return Object.assign({protocol:1, browser:browserName, kind:'select', request:'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
            session:state.session, epoch:state.push.epoch, seq:state.push.seq, window:1, tab:10, expires:now+1500},overrides);
    }
    """#

    private func page(_ browser: String) throws -> JSContext { try Self.page(browser) }

    private func advance(_ context: JSContext, _ seconds: Double = 0.5) throws { try Self.advance(context, seconds) }

    /// The browser's extension page, loaded after `before` runs in the stand (to seed its storage).
    static func page(_ browser: String, before: String = "") throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail(error?.toString() ?? "JavaScript error") }
        context.evaluateScript(stand)
        context.evaluateScript(before)
        let resources = projectRoot.appendingPathComponent("Sources/SafariExtension/Resources")
        context.evaluateScript(try String(contentsOf: resources.appendingPathComponent("shared.js"), encoding: .utf8))
        let script = browser == "safari" ? resources.appendingPathComponent("background.js")
            : projectRoot.appendingPathComponent("Sources/ChromeExtension/background.js")
        context.evaluateScript(try String(contentsOf: script, encoding: .utf8))
        try advance(context)
        return context
    }

    static func advance(_ context: JSContext, _ seconds: Double = 0.5) throws {
        context.evaluateScript("var limit = now + \(Int(seconds * 1000));")
        var count = 0
        while context.evaluateScript("tick(limit)")?.toBool() == true {
            count += 1
            if count > 2000 { XCTFail("Timer loop"); break }
        }
        context.evaluateScript("now = limit;")
    }

    private func number(_ context: JSContext, _ js: String) -> Int { Int(context.evaluateScript(js)?.toInt32() ?? -1) }

    func testBothStartWithFullSnapshotExcludePrivateAndUpdateOnlyChangedWindow() throws {
        for name in ["safari", "chrome"] {
            let c = try page(name)
            XCTAssertEqual(number(c, "sent.filter(m=>(m.type==='state'||m.type==='events'))[0].windows.length"), 2, name)
            XCTAssertEqual(c.evaluateScript("sent.find(m=>(m.type==='state'||m.type==='events')).push.kind")?.toString(), "snapshot")
            c.evaluateScript("listings=0; sent=[]; windows[0].tabs[0].title='Changed'; browser.tabs.onUpdated.fire(10,{title:'Changed'},windows[0].tabs[0]);")
            try advance(c)
            XCTAssertEqual(number(c, "listings"), 0, name)
            XCTAssertEqual(number(c, "sent.filter(m=>(m.type==='state'||m.type==='events')).length"), 1, name)
            XCTAssertEqual(c.evaluateScript("sent.find(m=>(m.type==='state'||m.type==='events')).push.kind")?.toString(), "delta")
            XCTAssertEqual(number(c, "sent.find(m=>(m.type==='state'||m.type==='events')).windows.length"), 1)
            XCTAssertEqual(number(c, "sent.find(m=>(m.type==='state'||m.type==='events')).windows[0].id"), 1)
        }
    }

    func testConsecutiveWindowRemovalsAreNeverContentDeduplicatedAway() throws {
        for name in ["safari", "chrome"] {
            let c = try page(name)
            for id in [1,2] {
                c.evaluateScript("sent=[]; windows=windows.filter(w=>w.id!==\(id)); browser.windows.onRemoved.fire(\(id));")
                try advance(c)
                XCTAssertEqual(number(c, "sent.find(m=>(m.type==='state'||m.type==='events')).push.removed[0]"), id, name)
            }
        }
    }

    func testSnapshotRecoveryAndMinuteReconciliationDoNotBecomeFastPolling() throws {
        for name in ["safari", "chrome"] {
            let c = try page(name)
            c.evaluateScript("listings=0; sent=[];")
            try advance(c, 10)
            XCTAssertEqual(number(c, "listings"), 0, name)
            let alarm = name == "chrome" ? "winmux-reconcile" : "winmux-tabs-heartbeat"
            // Safari's actual alarm name is read from its registered script constant.
            c.evaluateScript(name == "chrome" ? "browser.alarms.onAlarm.fire({name:'\(alarm)'});" : "browser.alarms.onAlarm.fire({name:heartbeat});")
            try advance(c)
            XCTAssertEqual(number(c, "listings"), 1, name)
            c.evaluateScript("var recovery=prepareCommand('\(name)',{kind:'snapshot'}); fakePort.onMessage.fire(\(name == "chrome" ? "{command:recovery}" : "recovery"));")
            try advance(c)
            XCTAssertEqual(number(c, "listings"), 2, name)
        }
    }

    func testSelectionHasResultAndActivationAndDuplicateRequestNeverRunsTwice() throws {
        for name in ["safari", "chrome"] {
            let c = try page(name)
            c.evaluateScript("var cmd=prepareCommand('\(name)'); fakePort.onMessage.fire(\(name == "chrome" ? "{command:cmd}" : "cmd"));")
            try advance(c, 0.1)
            XCTAssertEqual(number(c, "updates"), 1, name)
            XCTAssertEqual(number(c, "sent.filter(m=>m.kind==='result').length"), 1, name)
            XCTAssertEqual(number(c, "sent.filter(m=>m.kind==='activated').length"), 1, name)
            c.evaluateScript("fakePort.onMessage.fire(\(name == "chrome" ? "{command:cmd}" : "cmd"));")
            try advance(c)
            XCTAssertEqual(number(c, "updates"), 1, name)
        }
    }

    func testMissingActivationAndPostDispatchErrorDoNotInventSuccessOrRetry() throws {
        for name in ["safari", "chrome"] {
            let c = try page(name)
            c.evaluateScript("emitActivation=false; var cmd=prepareCommand('\(name)'); fakePort.onMessage.fire(\(name == "chrome" ? "{command:cmd}" : "cmd"));")
            try advance(c)
            XCTAssertEqual(number(c, "updates"), 1, name)
            XCTAssertEqual(number(c, "sent.filter(m=>m.kind==='activated').length"), 0, name)
            c.evaluateScript("windows[0].tabs[0].active=false; throwAfterUpdate=true; cmd=prepareCommand('\(name)',{request:'bbbbbbbb-bbbb-4bbb-8bbb-000000000002'}); fakePort.onMessage.fire(\(name == "chrome" ? "{command:cmd}" : "cmd"));")
            try advance(c)
            XCTAssertEqual(number(c, "updates"), 2, name)
            XCTAssertEqual(number(c, "sent.filter(m=>m.request===cmd.request && m.kind==='refused').length"), 0, name)
        }
    }

    func testExpiredWrongSessionMovedAndPrivateTargetsNeverDispatch() throws {
        for name in ["safari", "chrome"] {
            for overrides in ["{expires:now-1}", "{session:'old'}", "{window:2}", "{window:3,tab:30}", "{seq:999}"] {
                let c = try page(name)
                c.evaluateScript("var cmd=prepareCommand('\(name)',\(overrides)); fakePort.onMessage.fire(\(name == "chrome" ? "{command:cmd}" : "cmd"));")
                try advance(c)
                XCTAssertEqual(number(c, "updates"), 0, "\(name): \(overrides)")
            }
        }
    }

    func testCancelledRequestCannotExecuteEvenIfDeliveredAfterItsCancellation() throws {
        for name in ["safari", "chrome"] {
            let c = try page(name)
            c.evaluateScript("var cmd=prepareCommand('\(name)'); var cancel=Object.assign({},cmd,{kind:'cancel'}); fakePort.onMessage.fire(\(name == "chrome" ? "{command:cancel}" : "cancel"));")
            try advance(c, 0.01)
            c.evaluateScript("fakePort.onMessage.fire(\(name == "chrome" ? "{command:cmd}" : "cmd"));")
            try advance(c)
            XCTAssertEqual(number(c, "updates"), 0, name)
        }
    }

    func testSafariDowngradeCannotSendPartialStateAsFullToOlderApp() throws {
        let c = try page("safari")
        c.evaluateScript("oldApp=true; sent=[]; windows[0].tabs[0].title='Old app'; browser.tabs.onUpdated.fire(10,{title:'Old app'},windows[0].tabs[0]);")
        try advance(c, 1)
        XCTAssertEqual(c.evaluateScript("sent[0].type")?.toString(), "events")
        XCTAssertEqual(c.evaluateScript("sent.at(-1).type")?.toString(), "state")
        XCTAssertEqual(c.evaluateScript("sent.at(-1).push.kind")?.toString(), "snapshot")
        XCTAssertEqual(number(c, "sent.at(-1).windows.length"), 2)
    }

    func testBothReportEachTabsOriginAndAPageRevisionThatChangesOnlyWithItsAddress() throws {
        for name in ["safari", "chrome"] {
            let c = try page(name)
            c.evaluateScript("""
                function tab10() {
                    const report = sent.filter(m => (m.type === 'state' || m.type === 'events') && m.windows.some(w => w.id === 1)).at(-1);
                    return report.windows.find(w => w.id === 1).tabs[0];
                }
                function update(change) { Object.assign(windows[0].tabs[0], change); browser.tabs.onUpdated.fire(10, change, windows[0].tabs[0]); }
                """)
            func tab() -> (origin: String?, revision: String?) {
                (c.evaluateScript("tab10().origin")?.toString(), c.evaluateScript("tab10().rev")?.toString())
            }
            let first = tab()
            XCTAssertEqual(first.origin, "https://example.test", name)
            XCTAssertNotNil(first.revision)

            XCTAssertEqual(c.evaluateScript("JSON.stringify(Object.keys(tab10()).filter(k => /url|path/i.test(k)))")?.toString(), "[]",
                           "No address leaves the browser")
            c.evaluateScript("update({title: 'Renamed'})")
            try advance(c)
            XCTAssertEqual(tab().revision, first.revision, "\(name): a title change isn't another page")
            c.evaluateScript("update({url: 'https://example.test/'})")
            try advance(c)
            XCTAssertEqual(tab().revision, first.revision, "\(name): an address repeated unchanged, as Safari does, isn't either")
            c.evaluateScript("update({url: 'https://example.test:8443/next'})")
            try advance(c)
            let moved = tab()
            XCTAssertEqual(moved.origin, "https://example.test:8443", name)
            XCTAssertNotEqual(moved.revision, first.revision)

            c.evaluateScript("update({url: 'https://example.test/'})")
            try advance(c)
            XCTAssertNotEqual(tab().revision, first.revision, "\(name): coming back to an address is still a new page")
            XCTAssertNotEqual(tab().revision, moved.revision)
        }
    }

    func testSafariStartsEveryPageOverWhenItsPageReloadsAndNeverMakesARevisionTwice() throws {
        let c = try page("safari")
        let first = try XCTUnwrap(c.evaluateScript("sent.find(m => m.type === 'state').windows[0].tabs[0].rev")?.toString())
        XCTAssertFalse(c.evaluateScript("JSON.stringify(sent)")?.toString()?.contains(#""first""#) ?? true, "No page is called a tab's first")
        // Safari unloads the page; a new one starts with the same session storage, the tab unchanged.
        let stored = try XCTUnwrap(c.evaluateScript("JSON.stringify(storage)")?.toString())
        let reloaded = try Self.page("safari", before: """
            storage = \(stored);
            var asked = [];
            browser.tabs.query = async () => windows.flatMap(w => w.tabs).map(copy);
            browser.tabs.sendMessage = async (id, message) => { asked.push([id, message.type]); };
            """)
        let again = try XCTUnwrap(reloaded.evaluateScript("sent.find(m => m.type === 'state').windows[0].tabs[0].rev")?.toString())
        XCTAssertNotEqual(again, first, "Nothing about the page is restored: it's a new page, with a revision no load made before")
        XCTAssertEqual(reloaded.evaluateScript("JSON.stringify(asked)")?.toString(),
                       #"[[10,"winmux-icon-request"],[20,"winmux-icon-request"]]"#,
                       "Each open page of a normal window is asked to name its icons again")
        XCTAssertEqual(reloaded.evaluateScript("""
            JSON.stringify(Object.keys(storage).filter(k => !['session', 'order', 'unavailableUntil', 'icons', 'iconAddresses'].includes(k)))
            """)?.toString(), "[]", "No page, revision, pending report or icon binding is kept")
    }

    func testAnAddressHeardBeforeAnyReportIsANewPageToo() throws {
        let c = try page("safari")
        c.evaluateScript("""
            var revisions = [];
            function note() { loaded.then(d => revisions.push(d.tabs.get(40)?.revision)); }
            windows[0].tabs.push({id: 40, windowId: 1, index: 1, title: 'New', url: 'about:blank', active: false, incognito: false});
            browser.tabs.onCreated.fire(windows[0].tabs[1]);
            for (const url of ['https://a.test/', 'https://b.test/']) {
                windows[0].tabs[1].url = url;
                browser.tabs.onUpdated.fire(40, {url}, windows[0].tabs[1]);
                note();
            }
            """)
        try advance(c)
        XCTAssertEqual(c.evaluateScript("revisions.length")?.toInt32(), 2)
        XCTAssertNotEqual(c.evaluateScript("revisions[0]")?.toString(), c.evaluateScript("revisions[1]")?.toString(),
                          "The tab's first address, heard before any report, had its own revision")
        XCTAssertEqual(c.evaluateScript("sent.filter(m => m.type === 'state' || m.type === 'events').at(-1).windows[0].tabs[1].rev")?.toString(),
                       c.evaluateScript("revisions[1]")?.toString())
    }

    func testSafarisPageNamesItsIconsWithItsAddressAgainWhenItsAddressChangesOrWhenAsked() throws {
        let c = try XCTUnwrap(JSContext())
        c.exceptionHandler = { _, error in XCTFail(error?.toString() ?? "JavaScript error") }
        c.evaluateScript(Self.stand)
        c.evaluateScript("""
            var messages = [], heard = {}, pageListeners = {};
            var location = { href: 'https://example.test/a' };
            var window = { addEventListener: (type, f) => (heard[type] ??= []).push(f) };
            window.top = window;
            var document = { head: {}, querySelectorAll: () => [{ rel: 'icon', href: 'https://example.test/icon.png', type: '',
                getAttribute: () => null }] };
            class MutationObserver { observe() {} }
            browser.runtime.sendMessage = async (message) => { messages.push(copy(message)); };
            """)
        let resources = projectRoot.appendingPathComponent("Sources/SafariExtension/Resources")
        c.evaluateScript(try String(contentsOf: resources.appendingPathComponent("shared.js"), encoding: .utf8))
        c.evaluateScript(try String(contentsOf: resources.appendingPathComponent("content.js"), encoding: .utf8))
        try Self.advance(c, 2)
        XCTAssertEqual(c.evaluateScript("JSON.stringify(messages.map(m => [m.report, m.address]))")?.toString(),
                       #"[[1,"https://example.test/a"]]"#)
        // A script changes the address: the page names the same icons again, with its new address.
        c.evaluateScript("location.href = 'https://example.test/b'; heard.popstate.forEach(f => f());")
        try Self.advance(c, 2)
        c.evaluateScript("location.href = 'https://example.test/b#c'; heard.hashchange.forEach(f => f());")
        try Self.advance(c, 2)
        // The extension asks after an address change it heard of.
        c.evaluateScript("browser.runtime.onMessage.fire({ type: 'winmux-icon-request' });")
        try Self.advance(c, 0.1)
        XCTAssertEqual(c.evaluateScript("JSON.stringify(messages.map(m => [m.report, m.address]))")?.toString(),
            #"[[1,"https://example.test/a"],[2,"https://example.test/b"],[3,"https://example.test/b#c"],[4,"https://example.test/b#c"]]"#)
        XCTAssertEqual(c.evaluateScript("JSON.stringify(messages[3].candidates)")?.toString(), #"["https://example.test/icon.png","https://example.test/favicon.ico"]"#)
    }

    func testChromeTitlesEachNormalWindowsActiveTabButtonWithItsMarkerAndAgainAfterANavigation() throws {
        let c = try page("chrome")
        c.evaluateScript("""
            var titles = []; browser.action.setTitle = async (o) => { titles.push(copy(o)); };
            windows.forEach(w => { w.tabs[0].active = true; });
            [1,2,3].forEach(id => browser.tabs.onActivated.fire({windowId:id, tabId:id*10}));
            """)
        try advance(c)
        XCTAssertEqual(c.evaluateScript("JSON.stringify(titles.map(t => [t.tabId, t.title]).sort())")?.toString(),
            #"[[10,"WinMux Tabs · aaaaaaaa-1-10"],[20,"WinMux Tabs · aaaaaaaa-2-20"]]"#,
            "Each normal window's active tab, by this worker's session; never the Incognito window")
        c.evaluateScript("titles = []; windows[0].tabs[0].title = 'Renamed'; browser.tabs.onUpdated.fire(10,{title:'Renamed'},windows[0].tabs[0]);")
        try advance(c)
        XCTAssertEqual(number(c, "titles.length"), 0, "A title it already has isn't set again")
        c.evaluateScript("browser.tabs.onUpdated.fire(10,{url:'https://example.test/next'},windows[0].tabs[0]);")
        try advance(c)
        XCTAssertEqual(c.evaluateScript("JSON.stringify(titles)")?.toString(), #"[{"tabId":10,"title":"WinMux Tabs · aaaaaaaa-1-10"}]"#,
            "Chrome may reset it as the tab navigates, so it's set again")
        // Moved to another window, the tab's button names its new window.
        c.evaluateScript("""
            titles = []; const moved = windows[0].tabs.shift(); moved.windowId = 2; windows[1].tabs.forEach(t => { t.active = false; });
            windows[1].tabs.push(moved); browser.tabs.onAttached.fire(10, {newWindowId:2});
            """)
        try advance(c)
        XCTAssertEqual(c.evaluateScript("JSON.stringify(titles)")?.toString(), #"[{"tabId":10,"title":"WinMux Tabs · aaaaaaaa-2-10"}]"#)
    }

    func testChromeOffReplyBacksOffAndReconnectStartsWithSnapshot() throws {
        let c = try page("chrome")
        c.evaluateScript("reply={v:2,ok:false,reason:'off'}; listings=0; windows[0].tabs[0].title='Off'; browser.tabs.onUpdated.fire(10,{title:'Off'},windows[0].tabs[0]);")
        try advance(c, 0.5)
        XCTAssertEqual(number(c, "listings"), 0)
        for _ in 0..<3 {
            c.evaluateScript("browser.tabs.onUpdated.fire(10,{audible:true},windows[0].tabs[0]);")
            try advance(c, 0.1)
        }
        XCTAssertEqual(number(c, "connections"), 1, "Events while off cannot bypass native-host restart backoff")
        c.evaluateScript("reply={v:2,ok:true,events:1,want:[]};")
        try advance(c, 2)
        XCTAssertEqual(number(c, "listings"), 1)
        XCTAssertEqual(c.evaluateScript("sent.filter(m=>(m.type==='state'||m.type==='events')).at(-1).push.kind")?.toString(), "snapshot")
    }
}
