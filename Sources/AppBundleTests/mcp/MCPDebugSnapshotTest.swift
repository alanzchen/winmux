@testable import AppBundle
import AppKit
import Common
import XCTest

/// `winmux_debug_snapshot`: one bounded JSON document of displays, the sidebar as drawn and each member's window
/// state, read without running anything. Synthetic windows only: the split rows of the reports it's for,
/// [Telegram | Mail] with Mail parked, and [Chrome | Untitled] whose Untitled Chrome no longer lists.
@MainActor
final class MCPDebugSnapshotTest: XCTestCase {
    private var savedRead: (@MainActor ([Window], Bool) async -> [UInt32: DebugSnapshotNativeRead])!
    private var savedLimit = 0
    private var reads: [UInt32: DebugSnapshotNativeRead] = [:]

    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        WindowLifecycleLog.shared.reset()
        AxWindowErrorLog.shared.reset()
        savedRead = debugSnapshotNativeReads
        savedLimit = mcpDebugSnapshotByteLimit
        reads = [:]
        debugSnapshotNativeReads = { [unowned self] windows, includeTitles in
            Dictionary(uniqueKeysWithValues: windows.compactMap { window in
                reads[window.windowId].map { read in
                    var read = read
                    if includeTitles { read.title = "Native title \(window.windowId)" }
                    return (window.windowId, read)
                }
            })
        }
    }

    override func tearDown() async throws {
        debugSnapshotNativeReads = savedRead
        mcpDebugSnapshotByteLimit = savedLimit
        WindowLifecycleLog.shared.reset()
        AxWindowErrorLog.shared.reset()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
    }

    private let secretTitles = ["Synthetic secret chat", "Synthetic inbox subject", "Synthetic search results", "Untitled synthetic draft"]

    private struct Scene {
        let telegram: SnapshotTestWindow
        let mail: SnapshotTestWindow
        let chrome: SnapshotTestWindow
        let untitled: SnapshotTestWindow
    }

    /// Two displays. `chat` [Telegram | Mail] is on the built-in one, focused, with Mail still parked in a corner;
    /// `web` [Chrome | Untitled] is on the external one, and Chrome's own list no longer has Untitled, whose last
    /// read said it's gone. `notes` is an empty pin.
    private func scene() async throws -> Scene {
        let builtIn = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Built-in Retina Display",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1512, height: 982),
            visibleRect: Rect(topLeftX: 0, topLeftY: 33, width: 1512, height: 949), isMain: true)
        let external = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Studio Display",
            rect: Rect(topLeftX: 1512, topLeftY: 0, width: 2560, height: 1440),
            visibleRect: Rect(topLeftX: 1512, topLeftY: 25, width: 2560, height: 1415), isMain: false)
        setMonitorsForTests([builtIn, external])
        let chat = Workspace.get(byName: "chat")
        chat.seedMonitorIfNeeded(builtIn)
        let web = Workspace.get(byName: "web")
        web.seedMonitorIfNeeded(external)
        let notes = Workspace.get(byName: "notes")
        let telegram = SnapshotTestWindow(id: 11, parent: chat.rootTilingContainer,
            app: TestApp(pid: 601, bundleId: "ru.keepcoder.Telegram", name: "Telegram", bundlePath: "/Applications/Telegram.app"),
            title: "Synthetic secret chat", frame: Rect(topLeftX: 0, topLeftY: 33, width: 756, height: 949))
        let mail = SnapshotTestWindow(id: 12, parent: chat.rootTilingContainer,
            app: TestApp(pid: 602, bundleId: "com.apple.mail", name: "Mail", bundlePath: "/System/Applications/Mail.app"),
            title: "Synthetic inbox subject", frame: Rect(topLeftX: 756, topLeftY: 33, width: 756, height: 949))
        let chromeApp = TestApp(pid: 603, bundleId: "com.google.Chrome", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app")
        let chrome = SnapshotTestWindow(id: 21, parent: web.rootTilingContainer, app: chromeApp,
            title: "Synthetic search results", frame: Rect(topLeftX: 1512, topLeftY: 25, width: 1280, height: 1415))
        let untitled = SnapshotTestWindow(id: 22, parent: web.rootTilingContainer, app: chromeApp,
            title: "Untitled synthetic draft", frame: Rect(topLeftX: 2792, topLeftY: 25, width: 1280, height: 1415))
        try setWorkspaceSidebarTabFavorite(notes, true)
        XCTAssertTrue(web.focusWorkspace())
        XCTAssertTrue(telegram.focusWindow())
        XCTAssertTrue(chat.isVisible && web.isVisible, "One tab on each display")
        // Mail's window should be shown with its tab and isn't: parked as if its tab were hidden.
        try await mail.hideInCorner(.bottomRightCorner, reassert: false, ifStillValid: { true })
        XCTAssertTrue(mail.isHiddenInCorner)
        AxWindowErrorLog.shared.record(windowId: 22, error: .invalidUIElement)
        reads = [
            11: DebugSnapshotNativeRead(axFrame: telegram.frame, appListsWindow: true),
            12: DebugSnapshotNativeRead(axFrame: mail.frame, appListsWindow: true),
            21: DebugSnapshotNativeRead(axFrame: chrome.frame, appListsWindow: true),
            22: DebugSnapshotNativeRead(axFrameError: "invalidUIElement", appListsWindow: false),
        ]
        await updateWorkspaceSidebarModel()
        return Scene(telegram: telegram, mail: mail, chrome: chrome, untitled: untitled)
    }

    private func snapshot(_ arguments: String = "{}", _ context: MCPRequestContext = MCPRequestContext(peer: "127.0.0.1", token: nil))
        async throws -> (document: MCPJSON, text: String)
    {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"winmux_debug_snapshot","arguments":\#(arguments)}}"#
        let host = context.access == .tailnet ? "alans-macbook-pro.tail1234.ts.net" : "127.0.0.1:41740"
        let response = await handleMCPHTTPRequest(MCPHTTPRequest(method: "POST", target: "/mcp", version: "HTTP/1.1",
            headers: [MCPHTTPHeader(name: "Host", value: host), MCPHTTPHeader(name: "Content-Type", value: "application/json")],
            body: Data(body.utf8)), context)
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        let result = try XCTUnwrap(MCPJSON.decode(response.body)?["result"], String(decoding: response.body, as: UTF8.self))
        XCTAssertEqual(result["isError"], .bool(false), "\(result)")
        let text = try XCTUnwrap(result["content"]?.array?.first?["text"]?.string)
        return (try XCTUnwrap(MCPJSON.decode(Data(text.utf8)), text), text)
    }

    private func row(_ document: MCPJSON, _ workspace: String) -> MCPJSON? {
        document["sidebar"]?["rows"]?.array?.first { $0["workspace"] == .string(workspace) }
    }

    /// A row's members, in order: its windows and its groups' windows.
    private func members(_ row: MCPJSON?) -> [MCPJSON] {
        (row?["items"]?.array ?? []).flatMap { item -> [MCPJSON] in
            item["kind"] == .string("group") ? item["members"]?.array ?? [] : [item["member"] ?? .null]
        }
    }

    private func member(_ document: MCPJSON, _ windowId: Int) -> MCPJSON? {
        document["sidebar"]?["rows"]?.array?.flatMap { members($0) }.first { $0["windowId"] == .int(windowId) }
    }

    func testTheSnapshotNamesWinMuxMacOSAndEveryDisplayWithWhatItShows() async throws {
        _ = try await scene()
        let (document, _) = try await snapshot()
        XCTAssertEqual(document["schema"], .string("winmux-debug-snapshot/1"))
        XCTAssertEqual(document["winmux"]?["version"], .string(winMuxAppVersion))
        XCTAssertEqual(document["winmux"]?["commit"], .string(gitHash))
        XCTAssertFalse(document["macOS"]?.string?.isEmpty ?? true)
        let displays = try XCTUnwrap(document["monitors"]?.array)
        XCTAssertEqual(displays.count, 2)
        let builtIn = try XCTUnwrap(displays.first { $0["name"] == .string("Built-in Retina Display") })
        XCTAssertEqual(builtIn["id"], .int(1))
        XCTAssertEqual(builtIn["frame"], .object(["x": .int(0), "y": .int(0), "width": .int(1512), "height": .int(982)]))
        XCTAssertEqual(builtIn["visibleFrame"], .object(["x": .int(0), "y": .int(33), "width": .int(1512), "height": .int(949)]))
        XCTAssertEqual(builtIn["shownWorkspace"], .string("chat"))
        XCTAssertEqual(builtIn["focused"], .bool(true))
        XCTAssertEqual(builtIn["main"], .bool(true))
        let external = try XCTUnwrap(displays.first { $0["name"] == .string("Studio Display") })
        XCTAssertEqual(external["shownWorkspace"], .string("web"))
        XCTAssertEqual(external["focused"], .bool(false))
        XCTAssertEqual(document["focus"]?["windowId"], .int(11))
        XCTAssertEqual(document["focus"]?["workspace"], .string("chat"))
    }

    /// The case reported: a split row whose second member doesn't show, because it's still parked.
    func testASplitRowsParkedMemberIsShownAsParkedWhileItsRowIsOnScreen() async throws {
        _ = try await scene()
        let (document, _) = try await snapshot()
        let chat = try XCTUnwrap(row(document, "chat"))
        XCTAssertEqual(chat["kind"], .string("ordinary"))
        XCTAssertEqual(chat["visible"], .bool(true))
        XCTAssertEqual(members(chat).compactMap { $0["windowId"] }, [.int(11), .int(12)])
        let mail = try XCTUnwrap(member(document, 12))
        XCTAssertEqual(mail["appBundleId"], .string("com.apple.mail"))
        XCTAssertEqual(mail["appPathKind"], .string("app"))
        XCTAssertEqual(mail["live"], .bool(true))
        XCTAssertEqual(mail["workspace"], .string("chat"))
        XCTAssertEqual(mail["placement"], .string("tiling"))
        XCTAssertEqual(mail["parent"]?["kind"], .string("tilingContainer"))
        XCTAssertEqual(mail["parent"]?["layout"], .string("tiles"))
        XCTAssertEqual(mail["state"]?["parkedInCorner"], .bool(true))
        XCTAssertEqual(mail["state"]?["park"]?["corner"], .string("bottomRightCorner"))
        XCTAssertNotNil(mail["frames"]?["ax"]?.object, "\(mail)")
        XCTAssertEqual(mail["appListsWindow"], .bool(true))
        let telegram = try XCTUnwrap(member(document, 11))
        XCTAssertEqual(telegram["state"]?["parkedInCorner"], .bool(false))
        XCTAssertEqual(telegram["focused"], .bool(true))
    }

    /// The other case: a member whose app no longer lists its window, with the AX error that said so.
    func testAMemberTheAppNoLongerListsCarriesTheAppsAnswerAndItsLastAXError() async throws {
        _ = try await scene()
        let (document, _) = try await snapshot()
        let web = try XCTUnwrap(row(document, "web"))
        XCTAssertEqual(members(web).compactMap { $0["windowId"] }, [.int(21), .int(22)])
        let untitled = try XCTUnwrap(member(document, 22))
        XCTAssertEqual(untitled["appListsWindow"], .bool(false))
        XCTAssertEqual(untitled["frames"]?["axError"], .string("invalidUIElement"))
        XCTAssertEqual(untitled["lastAxError"]?["error"], .string("invalidUIElement"))
        XCTAssertNotNil(untitled["lastAxError"]?["at"]?.string)
        XCTAssertEqual(member(document, 21)?["appListsWindow"], .bool(true))
        XCTAssertEqual(member(document, 21)?["lastAxError"], .null)
    }

    func testAnEmptyPinIsFlaggedAsOne() async throws {
        _ = try await scene()
        let (document, _) = try await snapshot()
        let notes = try XCTUnwrap(row(document, "notes"), "\(document["sidebar"] ?? .null)")
        XCTAssertEqual(notes["kind"], .string("pinned"))
        XCTAssertEqual(notes["emptyPin"], .bool(true))
        XCTAssertEqual(members(notes), [])
        XCTAssertEqual(row(document, "chat")?["emptyPin"], .bool(false))
    }

    /// Titles, document paths, URLs and app paths are left out unless asked for; ids, bundle ids, frames and
    /// roles are kept.
    func testTitlesAreLeftOutUnlessAskedFor() async throws {
        _ = try await scene()
        let (document, text) = try await snapshot()
        for title in secretTitles { XCTAssertFalse(text.contains(title), title) }
        XCTAssertFalse(text.contains("/Applications/"), "No app paths by default")
        XCTAssertEqual(document["redaction"]?["titles"], .string("omitted"))
        XCTAssertTrue(text.contains("com.apple.mail"))
        XCTAssertEqual(member(document, 12)?["title"], nil)

        let (shown, shownText) = try await snapshot(#"{"include_titles":true}"#)
        for title in secretTitles { XCTAssertTrue(shownText.contains(title), title) }
        XCTAssertEqual(shown["redaction"]?["titles"], .string("included"))
        XCTAssertEqual(member(shown, 12)?["title"], .string("Synthetic inbox subject"))
    }

    func testWindowIdsKeepOnlyTheRowsAndEventsOfThoseWindows() async throws {
        _ = try await scene()
        let (document, _) = try await snapshot(#"{"window_ids":[22]}"#)
        XCTAssertEqual(document["sidebar"]?["rows"]?.array?.compactMap { $0["workspace"]?.string }, ["web"])
        XCTAssertEqual(document["filter"]?["windowIds"], .array([.int(22)]))
        let events = try XCTUnwrap(document["events"]?.array)
        XCTAssertTrue(events.allSatisfy { $0["windowId"] == .int(22) }, "\(events)")
        XCTAssertEqual(document["monitors"]?.array?.count, 2, "Displays are always described")

        let unfiltered = try await snapshot().document
        XCTAssertTrue(unfiltered["events"]?.array?.contains { $0["kind"] == .string("parked") && $0["windowId"] == .int(12) } == true,
            "\(unfiltered["events"] ?? .null)")
    }

    // Carbon's review, 2026-11-13: a window no row lists has its title too when titles are asked for.
    func testCarbonAnUnlistedWindowHasItsTitleWhenTitlesAreAskedFor() async throws {
        _ = try await scene()
        let popup = SnapshotTestWindow(id: 31, parent: macosPopupWindowsContainer, app: TestApp(pid: 604, bundleId: "com.example.popup"),
            title: "Synthetic popup", frame: Rect(topLeftX: 10, topLeftY: 40, width: 200, height: 100))
        reads[31] = DebugSnapshotNativeRead(axFrame: popup.frame, appListsWindow: true)
        let (redacted, _) = try await snapshot()
        let hidden = redacted["unlistedWindows"]?.array?.first { $0["windowId"] == .int(31) }
        XCTAssertNotNil(hidden)
        XCTAssertNil(hidden?["title"])
        let (shown, _) = try await snapshot(#"{"include_titles":true}"#)
        let unlisted = shown["unlistedWindows"]?.array?.first { $0["windowId"] == .int(31) }
        XCTAssertEqual(unlisted?["title"], .string("Native title 31"))
    }

    /// Astra's review: an app that hasn't answered an earlier snapshot isn't asked again until it does, and one app's
    /// windows are read together.
    func testAnAppStillAnsweringIsntAskedAgainAndItsWindowsAreReadTogether() async throws {
        _ = try await scene()
        let savedTimeout = mcpDebugSnapshotReadTimeout
        defer { mcpDebugSnapshotReadTimeout = savedTimeout }
        mcpDebugSnapshotReadTimeout = .milliseconds(100)
        var batches: [[UInt32]] = []
        var pending: [CheckedContinuation<Void, Never>] = []
        debugSnapshotNativeReads = { [unowned self] windows, _ in
            batches.append(windows.map(\.windowId).sorted())
            if windows.contains(where: { $0.windowId == 21 }) { await withCheckedContinuation { pending.append($0) } }
            return Dictionary(uniqueKeysWithValues: windows.compactMap { window in reads[window.windowId].map { (window.windowId, $0) } })
        }
        let (first, _) = try await snapshot()
        XCTAssertEqual(batches.sorted { $0.first ?? 0 < $1.first ?? 0 }, [[11], [12], [21, 22]], "Chrome's two windows in one read")
        XCTAssertEqual(member(first, 21)?["nativeRead"], .string("timedOut"))
        XCTAssertEqual(member(first, 11)?["nativeRead"], .string("ok"))
        let (second, _) = try await snapshot()
        XCTAssertEqual(pending.count, 1, "No second read is queued behind the first")
        XCTAssertEqual(member(second, 22)?["nativeRead"], .string("busy"))
        XCTAssertEqual(member(second, 12)?["nativeRead"], .string("ok"))
        for continuation in pending { continuation.resume() }
        pending = []
        for _ in 0 ..< 20 { await Task.yield() }
        let (third, _) = try await snapshot()
        XCTAssertEqual(member(third, 21)?["nativeRead"], .string("timedOut"), "Asked again once it answered")
        for continuation in pending { continuation.resume() }
    }

    // Carbon's review, 2026-11-13: a frame that isn't a number must not turn the whole snapshot into "null".
    func testCarbonANonFiniteFrameLeavesTheSnapshotReadable() async throws {
        _ = try await scene()
        reads[11] = DebugSnapshotNativeRead(axFrame: Rect(topLeftX: .nan, topLeftY: .infinity, width: 756, height: 949), appListsWindow: true)
        let (document, _) = try await snapshot()
        XCTAssertEqual(document["schema"], .string("winmux-debug-snapshot/1"))
        XCTAssertEqual(member(document, 11)?["frames"]?["ax"]?["x"], .null)
        XCTAssertEqual(member(document, 11)?["frames"]?["ax"]?["width"], .int(756))
    }

    func testBadArgumentsAreRefused() async throws {
        for arguments in [#"{"window_ids":"22"}"#, #"{"window_ids":[-1]}"#, #"{"window_ids":["a"]}"#, #"{"include_titles":"yes"}"#,
                          #"{"window_id":22}"#] {
            let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"winmux_debug_snapshot","arguments":\#(arguments)}}"#
            let response = await handleMCPHTTPRequest(MCPHTTPRequest(method: "POST", target: "/mcp", version: "HTTP/1.1",
                headers: [MCPHTTPHeader(name: "Host", value: "127.0.0.1:41740"), MCPHTTPHeader(name: "Content-Type", value: "application/json")],
                body: Data(body.utf8)), MCPRequestContext(peer: "127.0.0.1", token: nil))
            XCTAssertEqual(MCPJSON.decode(response.body)?["error"]?["code"], .int(-32602), arguments)
        }
    }

    /// Over its limit, a snapshot drops what matters least first, oldest events first, and says what it left out.
    func testTheSnapshotStaysWithinItsLimitAndSaysWhatItLeftOut() async throws {
        _ = try await scene()
        let base = try await snapshot().text.utf8.count
        for index in 0 ..< 200 { WindowLifecycleLog.shared.record(.moved, windowId: 9000 + UInt32(index), ["to": "w\(index)"]) }
        let limit = base + 2000
        mcpDebugSnapshotByteLimit = limit
        let (document, text) = try await snapshot()
        XCTAssertLessThanOrEqual(text.utf8.count, limit)
        XCTAssertEqual(document["schema"], .string("winmux-debug-snapshot/1"))
        XCTAssertEqual(document["truncated"]?["limitBytes"], .int(limit))
        XCTAssertGreaterThan(document["truncated"]?["omitted"]?["events"]?.int ?? 0, 0, "\(document["truncated"] ?? .null)")
        XCTAssertEqual(document["truncated"]?["omitted"]?["rows"]?.int ?? 0, 0, "Events go before rows")
        XCTAssertEqual(document["monitors"]?.array?.count, 2)
        XCTAssertNotNil(row(document, "chat"))
        XCTAssertEqual(document["events"]?.array?.last?["windowId"], .int(9199), "The newest are kept")

        mcpDebugSnapshotByteLimit = 1500
        let (tiny, tinyText) = try await snapshot()
        XCTAssertLessThanOrEqual(tinyText.utf8.count, 1500)
        XCTAssertEqual(tiny["schema"], .string("winmux-debug-snapshot/1"))
        XCTAssertNotNil(tiny["truncated"]?.object, "Says it's cut, however small the limit")

        mcpDebugSnapshotByteLimit = 1_000_000
        let (whole, _) = try await snapshot()
        XCTAssertNil(whole["truncated"], "Nothing left out")
    }

    /// Reading changes nothing: no window moves or gets focus, the tree and the sidebar stay as they were, and no
    /// refresh is asked for.
    func testTakingASnapshotChangesNothing() async throws {
        let scene = try await scene()
        let windows = [scene.telegram, scene.mail, scene.chrome, scene.untitled]
        let writes = windows.map(\.frameWrites)
        let tree = Workspace.all.map { "\($0.name):\($0.allLeafWindowsRecursive.map(\.windowId))" }
        let sidebar = TrayMenuModel.shared.workspaceSidebarWorkspaces
        let focused = focus.windowOrNil?.windowId
        let focusRequests = windows.map(\.focusRequests)
        let events = WindowLifecycleLog.shared.events.count
        _ = try await snapshot(#"{"include_titles":true}"#)
        _ = try await snapshot(#"{"window_ids":[12,22]}"#)
        XCTAssertEqual(windows.map(\.frameWrites), writes)
        XCTAssertEqual(windows.map(\.focusRequests), focusRequests)
        XCTAssertEqual(Workspace.all.map { "\($0.name):\($0.allLeafWindowsRecursive.map(\.windowId))" }, tree)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarWorkspaces, sidebar)
        XCTAssertEqual(focus.windowOrNil?.windowId, focused)
        XCTAssertTrue(scene.mail.isHiddenInCorner, "Still parked")
        XCTAssertEqual(WindowLifecycleLog.shared.events.count, events)
    }

    func testTheTailnetPortServesTheSnapshotToo() async throws {
        _ = try await scene()
        let (document, text) = try await snapshot("{}", MCPRequestContext(peer: "127.0.0.1", token: nil, access: .tailnet,
            tailnetName: "alans-macbook-pro"))
        XCTAssertEqual(document["schema"], .string("winmux-debug-snapshot/1"))
        for title in secretTitles { XCTAssertFalse(text.contains(title), title) }
    }

    // MARK: - The event log

    func testTheEventLogKeepsTheNewestEventsUpToItsCapacity() {
        let log = WindowLifecycleLog.shared
        for index in 0 ..< WindowLifecycleLog.capacity + 10 { log.record(.registered, windowId: UInt32(index), [:]) }
        XCTAssertEqual(log.events.count, WindowLifecycleLog.capacity)
        XCTAssertEqual(log.events.first?.windowId ?? nil, 10)
        XCTAssertEqual(log.events.last?.windowId ?? nil, UInt32(WindowLifecycleLog.capacity + 9))
        XCTAssertEqual(log.overwritten, 10)
    }

    func testParkingUnparkingAndMovingAWindowAreLogged() async throws {
        let scene = try await scene()
        WindowLifecycleLog.shared.reset()
        scene.mail.unhideFromCorner()
        scene.untitled.bind(to: Workspace.get(byName: "chat").rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        let events = WindowLifecycleLog.shared.events
        XCTAssertEqual(events.map(\.kind), [.unparked, .moved], "\(events)")
        XCTAssertEqual(events.map(\.windowId), [12, 22])
        XCTAssertEqual(events.last?.detail["from"], "web")
        XCTAssertEqual(events.last?.detail["to"], "chat")
    }

    func testTheAXErrorLogIsBounded() {
        let log = AxWindowErrorLog.shared
        for index in 0 ..< AxWindowErrorLog.capacity + 20 { log.record(windowId: UInt32(index), error: .cannotComplete) }
        XCTAssertNil(log.last(windowId: 0), "The oldest went")
        XCTAssertEqual(log.last(windowId: UInt32(AxWindowErrorLog.capacity + 19))?.error, "cannotComplete")
        XCTAssertLessThanOrEqual(log.count, AxWindowErrorLog.capacity)
        // Astra's review: a new window with a reused id doesn't inherit an earlier one's error.
        log.forget(windowId: UInt32(AxWindowErrorLog.capacity + 19))
        XCTAssertNil(log.last(windowId: UInt32(AxWindowErrorLog.capacity + 19)))
    }

    func testTheAppPathKindTellsAppsNestedHelpersAndXPCServicesApart() {
        XCTAssertEqual(debugSnapshotAppPathKind(nil), "unknown")
        XCTAssertEqual(debugSnapshotAppPathKind("/Applications/Telegram.app"), "app")
        XCTAssertEqual(debugSnapshotAppPathKind("/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app", isHelper: false),
            "nestedApp")
        XCTAssertEqual(debugSnapshotAppPathKind("/Applications/Example.app/Contents/Library/LoginItems/Helper.app", isHelper: true),
            "nestedHelper")
        XCTAssertEqual(debugSnapshotAppPathKind("/System/Library/Frameworks/Example.framework/XPCServices/Viewer.xpc"), "xpc")
    }
}

/// A test window that parks as MacWindow does and counts what it's asked to do.
final class SnapshotTestWindow: Window {
    private let parking = CornerParkingState()
    private let fixedTitle: String
    @MainActor var frame: Rect
    @MainActor private(set) var frameWrites = 0
    @MainActor private(set) var focusRequests = 0

    @MainActor
    init(id: UInt32, parent: NonLeafTreeNodeObject, app: TestApp, title: String, frame: Rect) {
        self.frame = frame
        fixedTitle = title
        super.init(id: id, app, lastFloatingSize: nil, parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        recordAuthoritativeActualRect(frame)
    }

    @MainActor override var title: String { get async { fixedTitle } }
    override var isHiddenInCorner: Bool { parking.isHiddenInCorner }
    override var cornerParkingForDebug: CornerParkingState? { parking }

    @MainActor override func getAxRect() async throws -> Rect? {
        recordObservedActualRect(frame, token: nativeStateObservationToken())
        return frame
    }

    @MainActor override func getAxSize() async throws -> CGSize? { CGSize(width: frame.width, height: frame.height) }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        // Layout runs on the main actor, as MacWindow's writes are queued from it.
        nonisolated(unsafe) let window = self
        MainActor.assumeIsolated {
            window.frameWrites += 1
            let frame = window.frame
            window.frame = Rect(topLeftX: topLeft?.x ?? frame.minX, topLeftY: topLeft?.y ?? frame.minY,
                                width: size?.width ?? frame.width, height: size?.height ?? frame.height)
        }
    }

    @MainActor override func nativeFocus() { focusRequests += 1 }
}

extension SnapshotTestWindow: WorkspaceWindowVisibility {
    func hideInCorner(_ corner: OptimalHideCorner, reassert: Bool, ifStillValid: () -> Bool) async throws {
        try await parkInCorner(corner, parking, reassert: reassert, onePixelOffset: true, ifStillValid: ifStillValid)
    }

    func unhideFromCorner() {
        restoreFromCorner(parking)
    }
}
