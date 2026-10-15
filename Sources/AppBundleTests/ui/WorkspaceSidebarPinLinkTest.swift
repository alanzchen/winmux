@testable import AppBundle
import AppKit
import Common
import XCTest

/// Pin Page, Pin Message and Pin Link: a pin that keeps an address exactly as taken or typed, takes it
/// only from the tab's own window and never from a private one, and opens it again: a web page in a fresh
/// browser window that comes to the pin only when the browser's answer names it, any other link as a
/// launcher does, claiming nothing. Windows, the browsers' answers and the apps are stand-ins.
@MainActor
final class WorkspaceSidebarPinLinkTest: XCTestCase {
    private let safariId = "com.apple.Safari"
    private let chromeId = "com.google.Chrome"
    private let mailId = "com.apple.mail"
    private lazy var safari = TestApp(pid: 18401, bundleId: safariId, name: "Safari")
    private lazy var chrome = TestApp(pid: 18501, bundleId: chromeId, name: "Google Chrome")
    private lazy var mail = TestApp(pid: 18601, bundleId: mailId, name: "Mail")
    private lazy var editor = TestApp(pid: 18701, bundleId: "com.example.editor", name: "Editor")
    private let page = "https://example.com/report?Q=Case&utm_source=kept#Section-2"

    private var notices: [WinMuxToastNotice] = []
    private var reads: [UInt32: PinPageWindowRead] = [:]
    /// Reads given in turn before `reads` answers: a window that changes between two reads.
    private var readQueue: [UInt32: [PinPageWindowRead]] = [:]
    /// What each new window shows, read back once the browser names it.
    private var windowURLs: [UInt32: String] = [:]
    private var readCount = 0
    private var scripts: [(source: String, arguments: [String])] = []
    private var answers: [(result: NewWindowScriptResult, output: String)] = []
    private var axWindows: [Set<UInt32>?] = []
    private var running: [String: Int32] = [:]
    private var installed: Set<String> = []
    private var handlers: [String: (url: URL, bundleId: String?)] = [:]
    private var launched: [(url: URL, app: URL)] = []
    private var prompts: [(heading: String, entry: PinLinkEntry, problem: String?)] = []
    private var promptAnswers: [PinLinkEntry?] = []
    private let readGate = Gate()
    private let scriptGate = Gate()
    private var saved: Saved?

    private struct Saved {
        let read: @MainActor (Window) async -> PinPageWindowRead?
        let script: @MainActor (String, [String]) async -> (result: NewWindowScriptResult, output: String)
        let axWindows: @MainActor (Int32) async -> Set<UInt32>?
        let windowURL: @MainActor (Int32, UInt32, BrowserTabAdapter) async -> String?
        let running: @MainActor (String) -> Int32?
        let launch: @MainActor (String, URL) async -> Int32?
        let handler: @MainActor (URL) -> (url: URL, bundleId: String?)?
        let open: @MainActor (URL, URL) async throws -> Void
        let prompt: @MainActor (String, PinLinkEntry, String, String?) -> PinLinkEntry?
        let appURL: @MainActor (String) -> URL?
        let notice: @MainActor (WinMuxToastNotice) -> Void
        let decision: @MainActor (PinPageExpectation) async -> Void
        let adapters: [PinLinkAdapter]
        let savedStore: SavedWorkspaceStore
    }

    override func setUp() async throws {
        try await super.setUp()
        setUpWorkspacesForTests()
        resetWorkspaceTabsForTests()
        setSavedWorkspaceTestEnvironment()
        workspaceSidebarOrganizationStore = .init()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        NewWindowIntentRegistry.shared.resetForTests()
        WorkspaceSidebarTabUndo.shared.clear()
        resetPinLinkAppCacheForTests()
        saved = Saved(read: pinPageWindowRead, script: pinLinkScript, axWindows: pinPageAXWindows, windowURL: pinPageWindowURL,
            running: pinPageRunningPid,
            launch: pinPageLaunchBrowser, handler: pinLinkHandlerApp, open: openPinLinkURL, prompt: pinLinkPrompt,
            appURL: pinDocumentAppURL, notice: showWorkspaceSidebarNotice, decision: waitForPinPageDecision,
            adapters: pinLinkAdapters, savedStore: savedWorkspaceStore)
        installed = [safariId, chromeId, mailId, "com.apple.Notes"]
        handlers = [
            "https": (URL(fileURLWithPath: "/Applications/Safari.app"), safariId),
            "http": (URL(fileURLWithPath: "/Applications/Safari.app"), safariId),
            "notes": (URL(fileURLWithPath: "/System/Applications/Notes.app"), "com.apple.Notes"),
            "applenotes": (URL(fileURLWithPath: "/System/Applications/Notes.app"), "com.apple.Notes"),
            "message": (URL(fileURLWithPath: "/System/Applications/Mail.app"), mailId),
        ]
        pinPageWindowRead = { [unowned self] window in
            readCount += 1
            await readGate.pass()
            if var queued = readQueue[window.windowId], !queued.isEmpty {
                let read = queued.removeFirst()
                readQueue[window.windowId] = queued
                return read
            }
            return reads[window.windowId]
        }
        pinPageWindowURL = { [unowned self] _, windowId, _ in windowURLs[windowId] }
        pinLinkScript = { [unowned self] source, arguments in
            scripts.append((source, arguments))
            await scriptGate.pass()
            return answers.isEmpty ? (.success, "") : answers.removeFirst()
        }
        pinPageAXWindows = { [unowned self] _ in axWindows.count > 1 ? axWindows.removeFirst() : axWindows.first ?? nil }
        pinPageRunningPid = { [unowned self] bundleId in running[bundleId] }
        pinPageLaunchBrowser = { _, _ in nil }
        pinLinkHandlerApp = { [unowned self] url in url.scheme.flatMap { handlers[$0.lowercased()] } }
        openPinLinkURL = { [unowned self] url, app in launched.append((url, app)) }
        pinLinkPrompt = { [unowned self] heading, entry, _, problem in
            prompts.append((heading, entry, problem))
            return promptAnswers.isEmpty ? nil : promptAnswers.removeFirst()
        }
        pinDocumentAppURL = { [unowned self] bundleId in
            installed.contains(bundleId) ? URL(fileURLWithPath: "/Applications/\(bundleId).app") : nil
        }
        showWorkspaceSidebarNotice = { [unowned self] notice in notices.append(notice) }
        // Detection isn't under test here: it never waits.
        waitForPinPageDecision = { _ in }
    }

    override func tearDown() async throws {
        for gate in [readGate, scriptGate] { gate.open() }
        if let saved {
            pinPageWindowRead = saved.read
            pinLinkScript = saved.script
            pinPageAXWindows = saved.axWindows
            pinPageWindowURL = saved.windowURL
            pinPageRunningPid = saved.running
            pinPageLaunchBrowser = saved.launch
            pinLinkHandlerApp = saved.handler
            openPinLinkURL = saved.open
            pinLinkPrompt = saved.prompt
            pinDocumentAppURL = saved.appURL
            showWorkspaceSidebarNotice = saved.notice
            waitForPinPageDecision = saved.decision
            pinLinkAdapters = saved.adapters
            savedWorkspaceStore = saved.savedStore
        }
        WorkspaceSidebarTabUndo.shared.clear()
        NewWindowIntentRegistry.shared.resetForTests()
        workspaceSidebarOrganizationStore = .init()
        resetPinLinkAppCacheForTests()
        config = defaultConfig
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Holds whoever passes while it's closed, until it's opened.
    @MainActor
    final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var closed = false
        var waiting: Int { waiters.count }

        func close() { closed = true }

        func pass() async {
            guard closed else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            closed = false
            let resumed = waiters
            waiters = []
            for waiter in resumed { waiter.resume() }
        }
    }

    private func makeTab(_ name: String, windowId: UInt32, app: TestApp) -> (Workspace, Window) {
        let tab = Workspace.get(byName: name)
        return (tab, TestWindow.new(id: windowId, parent: tab.rootTilingContainer, app: app))
    }

    private func appearance(_ name: String) -> WorkspaceSidebarItemAppearance? {
        workspaceSidebarOrganizationStore.state.workspaces[name]
    }

    private var safariLink: WorkspaceSidebarPinLink {
        .init(url: page, title: "Report", adapter: "safari", bundleId: safariId, source: .window)
    }

    /// A pinned link with no window: a saved pin, its windows gone.
    private func emptyPinnedLink(_ name: String, _ link: WorkspaceSidebarPinLink) throws -> Workspace {
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: name))
        materializeSavedWorkspaceNames()
        let tab = try XCTUnwrap(Workspace.existing(byName: name))
        XCTAssertNil(commitWorkspaceSidebarPinResource(tab, .link(link), title: "Pin Link"))
        return tab
    }

    private func eventually(_ condition: () -> Bool, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func settle() async {
        for _ in 0 ..< 20 { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func viewModel(_ name: String, windows: [(UInt32, String?)], appearance: WorkspaceSidebarItemAppearance = .init())
        -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: name, projectId: workspaceProjectDefaultId, displayName: "Workspace \(name)", sidebarLabel: "",
            isGeneratedName: false, monitorScopeId: "monitor:0,0", monitorName: "Main", isFocused: false, isVisible: false,
            items: windows.map { id, bundleId in
                .init(kind: .window(.init(windowId: id, workspaceName: name, appName: bundleId ?? "Editor", appBundleId: bundleId,
                    appBundlePath: nil, title: "Window \(id)", isFocused: false)))
            }, appearance: appearance)
    }

    // MARK: - The kept link

    func testALinkRoundTripsAndANewerOrDamagedOneNeverStopsTheRestLoading() throws {
        var state = WorkspaceSidebarOrganization()
        var pinned = WorkspaceSidebarItemAppearance()
        pinned.setFavorite(true)
        pinned.link = safariLink
        state.workspaces["page"] = pinned
        let decoded = try JSONDecoder().decode(WorkspaceSidebarOrganization.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.workspaces["page"]?.link, safariLink, "The address exactly, query and fragment included")

        let file = #"""
            {"version":1,"collections":[],"workspaces":{
              "newer":{"isFavorite":true,"link":{"version":9,"url":"https://example.com/","title":"Later","adapter":"future"}},
              "damaged":{"isFavorite":true,"link":{"title":7}},
              "garbled":{"isFavorite":true,"link":"not a link"},
              "plain":{"isFavorite":true}}}
            """#
        let loaded = try JSONDecoder().decode(WorkspaceSidebarOrganization.self, from: Data(file.utf8))
        XCTAssertEqual(loaded.workspaces["newer"]?.link?.isReadable, false, "Kept, not opened")
        XCTAssertEqual(loaded.workspaces["damaged"]?.link?.isReadable, false)
        XCTAssertEqual(loaded.workspaces["garbled"]?.link?.isReadable, false)
        XCTAssertNil(loaded.workspaces["plain"]?.link)
        XCTAssertEqual(loaded.workspaces["plain"]?.isFavorite, true)
    }

    func testAPinHasOneResourceAndUnpinningForgetsIt() throws {
        var appearance = WorkspaceSidebarItemAppearance()
        appearance.setFavorite(true)
        appearance.resource = .file(WorkspaceSidebarPinDocument(bookmark: Data([1]), bundleId: "a", name: "a.txt", fileId: 1, volume: "v"))
        appearance.resource = .link(safariLink)
        XCTAssertNil(appearance.document, "A link replaces a document")
        XCTAssertEqual(appearance.link, safariLink)
        appearance.setFavorite(false)
        XCTAssertNil(appearance.link)
        XCTAssertNil(appearance.resource)
    }

    // MARK: - Taking a page or message from the tab's window

    func testPinPageKeepsTheSafariWindowsFullAddressAndOnlyThatWindowIsRead() async throws {
        let (tab, window) = makeTab("page", windowId: 21, app: safari)
        _ = makeTab("front", windowId: 22, app: safari)
        reads[21] = .init(url: page, title: "Report", privacy: .normal)
        reads[22] = .init(url: "https://example.com/elsewhere", title: "Elsewhere", privacy: .normal)

        pinLinkFromWindowFromSidebar(tab.name, updating: false)

        let pinned = await eventually { self.appearance("page")?.link != nil }
        XCTAssertTrue(pinned)
        XCTAssertEqual(appearance("page")?.isFavorite, true)
        XCTAssertEqual(appearance("page")?.link, .init(url: page, title: "Report", adapter: "safari", bundleId: safariId, source: .window))
        XCTAssertEqual(readCount, 1)
        XCTAssertTrue(window.nodeWorkspace === tab, "Pinning moves nothing")
        XCTAssertTrue(workspaceIsPinnedResource(tab))
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin Page")
        XCTAssertEqual(notices, [])
        XCTAssertTrue(scripts.isEmpty, "Safari is read, never scripted, to pin")
    }

    func testAPrivateOrUncertainOrAmbiguousSafariWindowPinsNothing() async throws {
        let cases: [(String, PinPageWindowRead?)] = [
            ("private", .init(url: page, title: "Report, Private Browsing", privacy: .private)),
            ("uncertain", .init(url: page, title: "Report", privacy: .unknown)),
            ("several", .init(url: nil, title: "Report", privacy: .normal, showsSeveralPages: true)),
            ("nopage", .init(url: nil, title: "Start Page", privacy: .normal)),
            ("notweb", .init(url: "file:///Users/someone/report.html", title: "report.html", privacy: .normal)),
            ("unreadable", nil),
        ]
        for (index, (name, read)) in cases.enumerated() {
            let (tab, window) = makeTab(name, windowId: UInt32(30 + index), app: safari)
            reads[window.windowId] = read
            notices = []

            pinLinkFromWindowFromSidebar(tab.name, updating: false)

            let refused = await eventually { !self.notices.isEmpty }
            XCTAssertTrue(refused, name)
            XCTAssertNil(appearance(name), "\(name): nothing kept")
        }
        XCTAssertEqual(notices.isEmpty, false)
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    func testAPrivateWindowsRefusalSaysNothingOfThePage() async throws {
        let (tab, window) = makeTab("private", windowId: 31, app: safari)
        reads[window.windowId] = .init(url: page, title: "Report, Private Browsing", privacy: .private)

        pinLinkFromWindowFromSidebar(tab.name, updating: false)

        let refused = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(refused)
        XCTAssertEqual(notices.first?.body, pinPagePrivateMessage)
        XCTAssertFalse(notices.contains { $0.body.contains("example.com") || $0.title.contains("Report") })
    }

    func testChromiumAsksTheBrowserWhetherAnyWindowShowingTheAddressIsIncognito() async throws {
        let cases: [(String, String, Bool)] = [
            ("normal", "normal\t\(page)", true),
            ("both", "incognito\t\(page)\nnormal\t\(page)", false),
            ("lettercase", "normal\t\(page.lowercased())", false),
            ("gone", "", false),
        ]
        for (index, (name, answer, pins)) in cases.enumerated() {
            let (tab, window) = makeTab(name, windowId: UInt32(40 + index), app: chrome)
            reads[window.windowId] = .init(url: page, title: "Report - Google Chrome", privacy: .unknown)
            answers = [(.success, answer)]
            scripts = []
            notices = []

            pinLinkFromWindowFromSidebar(tab.name, updating: false)

            let done = await eventually { self.appearance(name)?.link != nil || !self.notices.isEmpty }
            XCTAssertTrue(done, name)
            XCTAssertEqual(appearance(name)?.link != nil, pins, name)
            if name == "both" { XCTAssertEqual(notices.first?.body, pinPageIncognitoMessage, "Says why, without the page") }
            XCTAssertEqual(scripts.first?.arguments, [page], "\(name): the address goes as an argument")
            XCTAssertEqual(scripts.first?.source.contains(page), false, "\(name): never into the script")
            XCTAssertEqual(scripts.first?.source.contains(#"tell application id "com.google.Chrome""#), true)
        }
        XCTAssertEqual(appearance("normal")?.link?.title, "Report", "Without the browser's name")
        XCTAssertNil(appearance("both"))
        XCTAssertEqual(pinPageChromiumPrivacy("incognito\t\(page)\nnormal\t\(page)", url: page), .private)
        XCTAssertEqual(appearance("normal")?.link?.adapter, "chromium")
    }

    func testAnIncognitoTitleOrADeniedQuestionPinsNothing() async throws {
        let (incognito, window) = makeTab("incognito", windowId: 51, app: chrome)
        reads[window.windowId] = .init(url: page, title: "Report - Google Chrome (Incognito)", privacy: .private)
        pinLinkFromWindowFromSidebar(incognito.name, updating: false)
        let refused = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(refused)
        XCTAssertEqual(notices.first?.body, pinPagePrivateMessage)
        XCTAssertTrue(scripts.isEmpty, "Known private from its title: the browser isn't asked")

        let (denied, deniedWindow) = makeTab("denied", windowId: 52, app: chrome)
        reads[deniedWindow.windowId] = .init(url: page, title: "Report - Google Chrome", privacy: .unknown)
        answers = [(.notAuthorized, "")]
        notices = []
        pinLinkFromWindowFromSidebar(denied.name, updating: false)
        let told = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(told)
        XCTAssertTrue(notices.first?.body.contains("Privacy & Security → Automation") == true)
        XCTAssertNil(appearance("denied"))
    }

    func testPinMessageKeepsMailsOwnLinkToTheSelectedMessage() async throws {
        let (tab, window) = makeTab("mail", windowId: 61, app: mail)
        answers = [(.success, "message\t<abc.123+x@example.com>\tWeekly summary")]

        pinLinkFromWindowFromSidebar(tab.name, updating: false)

        let pinned = await eventually { self.appearance("mail")?.link != nil }
        XCTAssertTrue(pinned)
        XCTAssertEqual(scripts.first?.arguments, [String(window.windowId)], "Mail is asked about this window only")
        XCTAssertEqual(appearance("mail")?.link, .init(url: "message://%3Cabc.123+x@example.com%3E", title: "Weekly summary",
            adapter: "mail", bundleId: mailId, source: .window))
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin Message")

        XCTAssertEqual(pinMessageCapture("selected\t0"), .refused("Select the message in this Mail window first."))
        XCTAssertEqual(pinMessageCapture("selected\t3"), .refused("Select just one message in this Mail window."))
        if case .captured = pinMessageCapture("none") { XCTFail("Not a viewer: nothing") }
        if case .captured = pinMessageCapture("message\t\tNo id") { XCTFail("No Message-ID: nothing") }
    }

    func testACaptureAnsweredAfterTheTabChangedWritesNothing() async throws {
        let (tab, window) = makeTab("page", windowId: 21, app: safari)
        reads[window.windowId] = .init(url: page, title: "Report", privacy: .normal)
        readGate.close()

        pinLinkFromWindowFromSidebar(tab.name, updating: false)
        let reading = await eventually { self.readGate.waiting == 1 }
        XCTAssertTrue(reading)
        try setWorkspaceSidebarTabFavorite(tab, true)
        readGate.open()

        let told = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(told)
        XCTAssertEqual(notices.first?.body, pinDocumentChangedMessage)
        XCTAssertNil(appearance("page")?.link)
    }

    func testANavigatedWindowNeverRetargetsThePinUntilUpdateFromWindow() async throws {
        let (tab, window) = makeTab("page", windowId: 21, app: safari)
        reads[window.windowId] = .init(url: page, title: "Report", privacy: .normal)
        pinLinkFromWindowFromSidebar(tab.name, updating: false)
        let pinned = await eventually { self.appearance("page")?.link?.url == self.page }
        XCTAssertTrue(pinned)

        reads[window.windowId] = .init(url: "https://example.com/next", title: "Next", privacy: .normal)
        await settle()
        XCTAssertEqual(appearance("page")?.link?.url, page, "Kept as pinned")

        pinLinkFromWindowFromSidebar(tab.name, updating: true)
        let updated = await eventually { self.appearance("page")?.link?.url == "https://example.com/next" }
        XCTAssertTrue(updated)
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Update Page from Window")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(appearance("page")?.link?.url, page)
    }

    // MARK: - Typing or pasting a link

    func testAnEntryIsKeptAsTypedOrRefusedWithAReason() {
        func link(_ address: String, _ name: String = "") -> WorkspaceSidebarPinLink? { try? pinLinkFromEntry(.init(address: address, name: name)).get() }
        func refusal(_ address: String) -> String? {
            if case .failure(let refusal) = pinLinkFromEntry(.init(address: address, name: "")) { return refusal.message }
            return nil
        }
        XCTAssertEqual(link("  \(page)\n")?.url, page, "Trimmed, otherwise exact")
        XCTAssertEqual(link(page)?.title, "example.com")
        XCTAssertEqual(link("example.com/a?b=C")?.url, "https://example.com/a?b=C", "As an address field takes it")
        XCTAssertEqual(link("notes://showNote?identifier=ABC", "Plan")?.title, "Plan")
        XCTAssertEqual(link("applenotes:note/ABC")?.title, "Notes", "Named after the app that opens it")
        XCTAssertEqual(link("message://%3Cid@example.com%3E")?.adapter, "link")
        XCTAssertNil(link("message://%3Cid@example.com%3E")?.bundleId, "Opened by whichever app opens such links")
        XCTAssertNotNil(refusal(""))
        XCTAssertNotNil(refusal("https://example.com/a b"))
        XCTAssertTrue(refusal("file:///tmp/report.txt")?.contains("Pin Document") == true)
        XCTAssertNotNil(refusal("javascript:alert(1)"))
        XCTAssertNotNil(refusal("data:text/html,hi"))
        XCTAssertEqual(refusal("obsidian://open?vault=Work"), "No app on this Mac opens “obsidian:” links.")
        XCTAssertNotNil(refusal("https:///nohost"))
        XCTAssertEqual(link(page, String(repeating: "n", count: 500))?.title.count, 200)
    }

    func testEditingAPageKeepsItsBrowserWhileItStaysAPage() throws {
        let edited = try pinLinkFromEntry(.init(address: "https://example.com/other", name: ""), editing: safariLink).get()
        XCTAssertEqual(edited.bundleId, safariId)
        XCTAssertEqual(edited.source, .manual)
        let renamed = try pinLinkFromEntry(.init(address: page, name: "Renamed"), editing: safariLink).get()
        XCTAssertEqual(renamed.source, .window, "Same address: still the one taken from the window")
        XCTAssertEqual(renamed.title, "Renamed")
        let note = try pinLinkFromEntry(.init(address: "notes://showNote?identifier=ABC", name: ""), editing: safariLink).get()
        XCTAssertNil(note.bundleId)
        XCTAssertEqual(note.adapter, "link")
    }

    func testPinLinkAsksAgainWithTheProblemAndCancelWritesNothing() async throws {
        let (tab, _) = makeTab("tab", windowId: 71, app: editor)
        promptAnswers = [.init(address: "javascript:void(0)", name: ""), .init(address: "notes://showNote?identifier=ABC", name: "Plan")]

        editPinLinkFromSidebar(tab.name)

        XCTAssertEqual(prompts.count, 2)
        XCTAssertNil(prompts[0].problem)
        XCTAssertEqual(prompts[1].problem, "WinMux doesn't pin “javascript:” addresses.")
        XCTAssertEqual(prompts[1].entry.address, "javascript:void(0)", "What was typed stays, to fix")
        let pinned = await eventually { self.appearance("tab")?.link != nil }
        XCTAssertTrue(pinned)
        XCTAssertEqual(appearance("tab")?.isFavorite, true)
        XCTAssertEqual(appearance("tab")?.link?.url, "notes://showNote?identifier=ABC")
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin Link")

        let (other, _) = makeTab("other", windowId: 72, app: editor)
        promptAnswers = [nil]
        editPinLinkFromSidebar(other.name)
        await settle()
        XCTAssertNil(appearance("other"))
    }

    func testNewLinkPinMakesAPinHoldingOnlyItsLinkAndUndoTakesItBack() async throws {
        let before = Set(Workspace.all.map(\.name))
        promptAnswers = [.init(address: page, name: "Report")]

        newLinkPinFromSidebar(projectId: workspaceProjectDefaultId, monitorScopeId: workspaceSidebarDefaultScopeId)

        let made = await eventually { workspaceSidebarOrganizationStore.state.workspaces.values.contains { $0.link?.url == self.page } }
        XCTAssertTrue(made)
        let name = try XCTUnwrap(workspaceSidebarOrganizationStore.state.workspaces.first { $0.value.link?.url == page }?.key)
        XCTAssertFalse(before.contains(name), "A new tab")
        let pin = try XCTUnwrap(Workspace.existing(byName: name))
        XCTAssertTrue(pin.allLeafWindowsRecursive.isEmpty, "Holding nothing until clicked")
        XCTAssertEqual(appearance(name)?.isFavorite, true)
        XCTAssertNotNil(savedWorkspaceStore.record(named: name), "Kept when empty")
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo New Link Pin")

        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertNil(appearance(name)?.link)
    }

    func testForgetLinkKeepsThePin() async throws {
        let tab = try emptyPinnedLink("page", safariLink)
        forgetPinLinkFromSidebar(tab.name)
        let forgot = await eventually { self.appearance("page")?.link == nil }
        XCTAssertTrue(forgot)
        XCTAssertEqual(appearance("page")?.isFavorite, true)
        XCTAssertFalse(workspaceIsPinnedResource(tab))
    }

    // MARK: - Opening

    func testAPinnedPageOpensAFreshSafariWindowAndTakesOnlyTheWindowSafariNames() async throws {
        let tab = try emptyPinnedLink("page", safariLink)
        running[safariId] = safari.pid
        answers = [(.success, "77;77")]
        windowURLs[77] = page

        openSavedTabApps(tab) { _, _ in XCTFail("The app alone is never asked for a window") }

        let asked = await eventually { self.scripts.count == 1 }
        XCTAssertTrue(asked)
        XCTAssertEqual(scripts[0].source, pinPageSafariOpenScript)
        XCTAssertEqual(scripts[0].arguments, [page], "The kept address, exactly")
        let registry = NewWindowIntentRegistry.shared
        let decided = await eventually {
            registry.pendingPageExpectation(windowId: 77, pid: self.safari.pid, bundleId: self.safariId,
                firstSeenUptime: registry.now())?.isDecided == true
        }
        XCTAssertTrue(decided)
        XCTAssertNil(registry.claim(windowId: 76, pid: safari.pid, bundleId: safariId, firstSeenUptime: registry.now()),
            "Another new Safari window, even one showing the same page, isn't it")
        XCTAssertTrue(registry.claim(windowId: 77, pid: safari.pid, bundleId: safariId, firstSeenUptime: registry.now()) === tab)
        XCTAssertTrue(launched.isEmpty, "Never opened as a launcher would, which lets Safari switch to another window")
        XCTAssertEqual(notices, [])
    }

    func testASafariAnswerNamingNoSingleNewWindowClaimsNothing() async throws {
        for (index, answer) in ["77,78;77", "77;78", ";77", "garbled"].enumerated() {
            let tab = try emptyPinnedLink("page\(index)", safariLink)
            running[safariId] = safari.pid
            answers = [(.success, answer)]
            notices = []

            openSavedTabApps(tab) { _, _ in }

            let told = await eventually { !self.notices.isEmpty }
            XCTAssertTrue(told, answer)
            XCTAssertTrue(notices.first?.body.contains("couldn't tell which window") == true, answer)
            let registry = NewWindowIntentRegistry.shared
            XCTAssertFalse(registry.hasPendingIntents, answer)
            XCTAssertNil(registry.claim(windowId: 77, pid: safari.pid, bundleId: safariId, firstSeenUptime: registry.now()), answer)
        }
    }

    func testChromiumTakesTheOneWindowItGainedForAccessibilityOnly() async throws {
        let link = WorkspaceSidebarPinLink(url: page, title: "Report", adapter: "chromium", bundleId: chromeId, source: .window)
        let tab = try emptyPinnedLink("page", link)
        running[chromeId] = chrome.pid
        axWindows = [[9], [9]]
        windowURLs[9] = page.replacingOccurrences(of: "example.com", with: "EXAMPLE.com")

        openSavedTabApps(tab) { _, _ in }

        let registry = NewWindowIntentRegistry.shared
        let decided = await eventually {
            registry.pendingPageExpectation(windowId: 9, pid: self.chrome.pid, bundleId: self.chromeId,
                firstSeenUptime: registry.now())?.windowId == 9
        }
        XCTAssertTrue(decided)
        XCTAssertEqual(scripts.first?.source, pinPageChromiumOpenScript(bundleId: chromeId))
        XCTAssertTrue(registry.claim(windowId: 9, pid: chrome.pid, bundleId: chromeId, firstSeenUptime: registry.now()) === tab)

        // Two new windows, as when someone opens another meanwhile: neither is taken.
        let other = try emptyPinnedLink("other", link)
        axWindows = [[11, 12], [11, 12]]
        notices = []
        openSavedTabApps(other) { _, _ in }
        let told = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(told)
        XCTAssertNil(registry.claim(windowId: 11, pid: chrome.pid, bundleId: chromeId, firstSeenUptime: registry.now()))
        XCTAssertNil(registry.claim(windowId: 12, pid: chrome.pid, bundleId: chromeId, firstSeenUptime: registry.now()))
    }

    func testAChangeToThePinWhileTheBrowserIsAskedWithdrawsTheRequest() async throws {
        let tab = try emptyPinnedLink("page", safariLink)
        running[safariId] = safari.pid
        answers = [(.success, "77;77")]
        scriptGate.close()

        openSavedTabApps(tab) { _, _ in }
        let asking = await eventually { self.scriptGate.waiting == 1 }
        XCTAssertTrue(asking)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertNil(appearance("page")?.link)
        scriptGate.open()
        await settle()

        let registry = NewWindowIntentRegistry.shared
        XCTAssertFalse(registry.hasPendingIntents)
        XCTAssertNil(registry.claim(windowId: 77, pid: safari.pid, bundleId: safariId, firstSeenUptime: registry.now()),
            "Its window goes the usual way")
        XCTAssertEqual(notices, [])
    }

    func testOtherLinksOpenAsALauncherAndClaimNothing() async throws {
        let note = WorkspaceSidebarPinLink(url: "notes://showNote?identifier=ABC", title: "Plan", adapter: "link")
        let tab = try emptyPinnedLink("note", note)

        openSavedTabApps(tab) { _, _ in XCTFail("The app alone is never asked for a window") }

        let opened = await eventually { !self.launched.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(launched.first?.url.absoluteString, "notes://showNote?identifier=ABC")
        XCTAssertEqual(launched.first?.app.path, "/System/Applications/Notes.app")
        XCTAssertFalse(NewWindowIntentRegistry.shared.hasPendingIntents, "Nothing waits for, claims or moves a window")
        XCTAssertTrue(scripts.isEmpty)
    }

    func testAPageOpensInTheDefaultBrowserWhenItsOwnIsGoneAndANewerOrAppLessLinkOpensNothing() async throws {
        installed.remove(safariId)
        handlers["https"] = (URL(fileURLWithPath: "/Applications/Firefox.app"), "org.mozilla.firefox")
        XCTAssertEqual(try pinLinkOpening(safariLink).get(), .launcher(appURL: URL(fileURLWithPath: "/Applications/Firefox.app")),
            "A browser that can't say which window it made only opens it")
        handlers["https"] = (URL(fileURLWithPath: "/Applications/Chrome.app"), chromeId)
        XCTAssertEqual(try pinLinkOpening(safariLink).get(),
            .freshWindow(bundleId: chromeId, appURL: URL(fileURLWithPath: "/Applications/Chrome.app"), browser: .chromium))

        var newer = safariLink
        newer.version = 2
        let newerPin = try emptyPinnedLink("newer", newer)
        openSavedTabApps(newerPin) { _, _ in XCTFail() }
        XCTAssertTrue(notices.last?.body.contains("newer WinMux") == true)

        let orphan = try emptyPinnedLink("orphan", .init(url: "obsidian://open?vault=Work", title: "Work", adapter: "link"))
        openSavedTabApps(orphan) { _, _ in XCTFail() }
        XCTAssertEqual(notices.last?.body, "No app on this Mac opens “obsidian:” links.")
        await settle()
        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(scripts.isEmpty)
    }

    func testAWindowOfTheBrowserDoesntGoIntoAnEmptyPinnedLink() throws {
        var record = SavedWorkspaceRecord(workspaceName: "page")
        record.launchApps = [SavedLaunchApp(bundleId: safariId)]
        savedWorkspaceStore.insert(record)
        materializeSavedWorkspaceNames()
        let pin = try XCTUnwrap(Workspace.existing(byName: "page"))
        XCTAssertNil(commitWorkspaceSidebarPinResource(pin, .link(safariLink), title: "Pin Page"))
        let work = Workspace.get(byName: "work")
        _ = TestWindow.new(id: 40, parent: work.rootTilingContainer, app: editor)
        XCTAssertTrue(work.focusWorkspace())
        let window = TestWindow.new(id: 81, parent: work.rootTilingContainer, app: safari)

        XCTAssertFalse(moveNewWindowToEmptyPinIfNeeded(window, detectedIn: work, isNewRegularWindow: true))
        XCTAssertTrue(pin.allLeafWindowsRecursive.isEmpty, "Its page is proven only by its own click")

        XCTAssertNil(commitWorkspaceSidebarPinResource(pin, nil, title: "Forget Link"))
        XCTAssertTrue(moveNewWindowToEmptyPinIfNeeded(window, detectedIn: work, isNewRegularWindow: true), "An ordinary pin again")
    }

    func testDetectionWaitsOnlyForANewWindowOfTheProcessAsked() throws {
        let tab = Workspace.get(byName: "page")
        let registry = NewWindowIntentRegistry.shared
        let expectation = PinPageExpectation(url: page)
        XCTAssertNotNil(registry.register(bundleId: safariId, pid: safari.pid, targetWorkspace: tab, preexistingWindowIds: [5],
            focusGeneration: focusChangeGeneration, page: expectation))
        let now = registry.now()
        XCTAssertTrue(registry.pendingPageExpectation(windowId: 6, pid: safari.pid, bundleId: safariId, firstSeenUptime: now) === expectation)
        XCTAssertNil(registry.pendingPageExpectation(windowId: 5, pid: safari.pid, bundleId: safariId, firstSeenUptime: now), "There before")
        XCTAssertNil(registry.pendingPageExpectation(windowId: 6, pid: 1, bundleId: safariId, firstSeenUptime: now), "Another process")
        XCTAssertNil(registry.pendingPageExpectation(windowId: 6, pid: safari.pid, bundleId: chromeId, firstSeenUptime: now))
        XCTAssertNil(registry.claim(windowId: 6, pid: safari.pid, bundleId: safariId, firstSeenUptime: now), "Undecided: not taken")
        expectation.decide(6)
        expectation.decide(7)
        XCTAssertEqual(expectation.windowId, 6, "Decided once")
        XCTAssertTrue(registry.claim(windowId: 6, pid: safari.pid, bundleId: safariId, firstSeenUptime: now) === tab)
    }

    // MARK: - Answers and menus

    func testTheBrowsersAnswersAreReadStrictly() {
        XCTAssertEqual(pinPageSafariMadeWindow("55;55"), 55)
        XCTAssertEqual(pinPageSafariMadeWindow(" 55 ; 55\n"), 55)
        XCTAssertNil(pinPageSafariMadeWindow("55,56;55"))
        XCTAssertNil(pinPageSafariMadeWindow("55;56"))
        XCTAssertNil(pinPageSafariMadeWindow(";55"))
        XCTAssertNil(pinPageSafariMadeWindow("55"))
        XCTAssertEqual(pinPageChromiumPrivacy("normal\t\(page)", url: page), .normal)
        XCTAssertEqual(pinPageChromiumPrivacy("normal\t\(page)\nnormal\t\(page)", url: page), .normal)
        XCTAssertEqual(pinPageChromiumPrivacy("normal\t\(page)\nincognito\t\(page)", url: page), .private)
        XCTAssertEqual(pinPageChromiumPrivacy("normal\thttps://example.com/other", url: page), .unknown)
        XCTAssertEqual(pinPageDisplayTitle("Report - Google Chrome", appName: "Google Chrome"), "Report")
        XCTAssertEqual(pinPageDisplayTitle("Report, Private Browsing", appName: "Safari"), "Report")
        XCTAssertEqual(pinMessageURL(messageId: "<a/b c@example.com>"), "message://%3Ca%2Fb%20c@example.com%3E")
    }

    func testTheMenuOffersWhatTheTabsWindowCanBePinnedTo() {
        func titles(_ model: WorkspaceSidebarWorkspaceViewModel) -> [String] {
            workspaceSidebarPinResourceMenuEntries(model, send: { _ in }).map(\.title)
        }
        XCTAssertEqual(titles(viewModel("a", windows: [(1, safariId)])), ["Pin Page", "Pin Document", "Pin Link…"])
        XCTAssertEqual(titles(viewModel("b", windows: [(1, chromeId)])), ["Pin Page", "Pin Document", "Pin Link…"],
            "A browser can show a file: Pin Document stays")
        XCTAssertEqual(titles(viewModel("c", windows: [(1, mailId)])), ["Pin Message", "Pin Document", "Pin Link…"])
        XCTAssertEqual(titles(viewModel("d", windows: [(1, "com.example.editor")])), ["Pin Document", "Pin Link…"])
        XCTAssertEqual(titles(viewModel("e", windows: [(1, safariId), (2, safariId)])), ["Pin Document", "Pin Link…"])
        var pinned = WorkspaceSidebarItemAppearance()
        pinned.setFavorite(true)
        pinned.link = safariLink
        XCTAssertEqual(titles(viewModel("f", windows: [(1, safariId)], appearance: pinned)),
            ["Update Page from Window", "Edit Link…", "Forget Link"])
        XCTAssertEqual(titles(viewModel("g", windows: [], appearance: pinned)), ["Edit Link…", "Forget Link"])
        var split = WorkspaceSidebarItemAppearance()
        split.setFavorite(true)
        split.composition = .init(layout: .split(.h, weight: 1, children: []))
        let splitEntries = workspaceSidebarPinResourceMenuEntries(viewModel("h", windows: [(1, safariId), (2, chromeId)], appearance: split),
            send: { _ in })
        XCTAssertEqual(splitEntries.last?.title, "Pin Link…")
        XCTAssertEqual(splitEntries.last?.enabled, false, "A pinned split brings back its own windows")
    }

    func testAnAdapterAddedToTheRegistryIsOfferedAndUsedWithoutAnythingElseChanging() async throws {
        pinLinkAdapters.append(PinLinkAdapter(id: "example-tasks", itemName: "Task", takesWindows: { $0 == "com.example.tasks" },
            capture: { _ in .captured(url: "x-example-tasks://task/42", title: "Ship it") }))
        let tasks = TestApp(pid: 18801, bundleId: "com.example.tasks", name: "Tasks")
        XCTAssertEqual(workspaceSidebarPinResourceMenuEntries(viewModel("t", windows: [(1, "com.example.tasks")]), send: { _ in })
            .map(\.title), ["Pin Task", "Pin Document", "Pin Link…"])
        let (tab, _) = makeTab("t", windowId: 91, app: tasks)

        pinLinkFromWindowFromSidebar(tab.name, updating: false)

        let pinned = await eventually { self.appearance("t")?.link != nil }
        XCTAssertTrue(pinned)
        XCTAssertEqual(appearance("t")?.link, .init(url: "x-example-tasks://task/42", title: "Ship it", adapter: "example-tasks",
            bundleId: "com.example.tasks", source: .window))
    }

    func testAnEmptyLinkPinShowsTheAppThatOpensItAndItsTitle() throws {
        let note = WorkspaceSidebarPinLink(url: "notes://showNote?identifier=ABC", title: "Plan", adapter: "link")
        let tab = try emptyPinnedLink("note", note)
        let app = try XCTUnwrap(workspaceSidebarPinnedLinkApp(tab))
        XCTAssertEqual(app.bundleId, "com.apple.Notes")
        XCTAssertEqual(app.name, "Notes")
        var pinned = WorkspaceSidebarItemAppearance()
        pinned.setFavorite(true)
        pinned.link = note
        XCTAssertEqual(workspaceSidebarTabListTitle(viewModel("note", windows: [], appearance: pinned)), "Plan")
        XCTAssertEqual(WorkspaceSidebarPinResource.link(note).symbolName, "link")
        XCTAssertEqual(WorkspaceSidebarPinResource.link(safariLink).symbolName, "globe")
    }

    // MARK: - Identity and privacy evidence, read fail-closed

    func testANamedWindowThatDoesntShowThePageIsntTaken() async throws {
        let registry = NewWindowIntentRegistry.shared
        // Safari names window 77, but 77 shows another page: a window that took its place.
        let tab = try emptyPinnedLink("page", safariLink)
        running[safariId] = safari.pid
        answers = [(.success, "77;77")]
        windowURLs[77] = "https://example.com/elsewhere"
        openSavedTabApps(tab) { _, _ in }
        let told = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(told)
        XCTAssertTrue(notices.first?.body.contains("couldn't tell which window") == true)
        XCTAssertNil(registry.claim(windowId: 77, pid: safari.pid, bundleId: safariId, firstSeenUptime: registry.now()))

        // A Chromium window gained that shows nothing WinMux can read isn't taken either.
        let link = WorkspaceSidebarPinLink(url: page, title: "Report", adapter: "chromium", bundleId: chromeId, source: .window)
        let other = try emptyPinnedLink("other", link)
        running[chromeId] = chrome.pid
        axWindows = [[9], [9]]
        notices = []
        openSavedTabApps(other) { _, _ in }
        let toldAgain = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(toldAgain)
        XCTAssertNil(registry.claim(windowId: 9, pid: chrome.pid, bundleId: chromeId, firstSeenUptime: registry.now()))
    }

    func testAnIncompleteListOfTheBrowsersWindowsDecidesNothing() async {
        axWindows = [nil, nil, nil]
        let made = await pinPageChromiumMadeWindow(pid: chrome.pid, before: [])
        XCTAssertNil(made, "A list missing a window's number is no list")
        axWindows = [[9], [9, 10], [9, 10]]
        let several = await pinPageChromiumMadeWindow(pid: chrome.pid, before: [])
        XCTAssertNil(several, "Two looks that disagree, then two windows: nothing")
    }

    func testAChromiumWindowThatChangedWhileTheBrowserWasAskedPinsNothing() async throws {
        let cases: [(String, PinPageWindowRead, String)] = [
            ("navigated", .init(url: "https://example.com/next", title: "Next - Google Chrome", privacy: .unknown),
             "This window changed while WinMux checked it, so it pins nothing. Try again."),
            ("incognito", .init(url: page, title: "Report - Google Chrome (Incognito)", privacy: .private), pinPagePrivateMessage),
        ]
        for (index, (name, after, message)) in cases.enumerated() {
            let (tab, window) = makeTab(name, windowId: UInt32(140 + index), app: chrome)
            readQueue[window.windowId] = [.init(url: page, title: "Report - Google Chrome", privacy: .unknown), after]
            answers = [(.success, "normal\t\(page)")]
            notices = []

            pinLinkFromWindowFromSidebar(tab.name, updating: false)

            let refused = await eventually { !self.notices.isEmpty }
            XCTAssertTrue(refused, name)
            XCTAssertEqual(notices.first?.body, message, name)
            XCTAssertNil(appearance(name), name)
        }
    }

    func testSafariIsNormalOnlyWhenEverythingAroundThePageWasRead() {
        let page = FakeNode(attributes: [kAXRoleAttribute: "AXWebArea", "AXURL": self.page])
        func window(toolbar: FakeNode?, extra: [FakeNode] = [], title: String = "Report") -> FakeNode {
            FakeNode(attributes: [kAXRoleAttribute: kAXWindowRole, kAXTitleAttribute: title],
                kids: (toolbar.map { [$0] } ?? []) + [FakeNode(attributes: [kAXRoleAttribute: "AXGroup"], kids: [page])] + extra)
        }
        let button = FakeNode(attributes: [kAXRoleAttribute: kAXButtonRole, kAXIdentifierAttribute: "Back"])
        let toolbar = FakeNode(attributes: [kAXRoleAttribute: kAXToolbarRole], kids: [button])
        func read(_ node: FakeNode) -> PinPageWindowRead { readPinPageWindow(node, adapter: .safari) }

        XCTAssertEqual(read(window(toolbar: toolbar)), .init(url: self.page, title: "Report", privacy: .normal))
        let marker = FakeNode(attributes: [kAXRoleAttribute: kAXStaticTextRole, kAXIdentifierAttribute: "Private"])
        XCTAssertEqual(read(window(toolbar: FakeNode(attributes: [kAXRoleAttribute: kAXToolbarRole], kids: [button, marker]),
            title: "Rapport, Navigation privée")).privacy, .private, "Whatever the title's language")
        XCTAssertEqual(read(window(toolbar: nil)).privacy, .unknown, "No toolbar: nothing says it's normal")
        XCTAssertEqual(read(window(toolbar: FakeNode(attributes: [kAXRoleAttribute: kAXToolbarRole], kids: nil))).privacy, .unknown,
            "The toolbar's contents couldn't be read")
        var unreadableId = button
        unreadableId.unreadable = [kAXIdentifierAttribute]
        XCTAssertEqual(read(window(toolbar: FakeNode(attributes: [kAXRoleAttribute: kAXToolbarRole], kids: [unreadableId]))).privacy,
            .unknown, "An identifier in the toolbar couldn't be read")
        var unreadableRole = FakeNode(attributes: [:])
        unreadableRole.unreadable = [kAXRoleAttribute]
        XCTAssertEqual(read(window(toolbar: toolbar, extra: [unreadableRole])).privacy, .unknown, "An element couldn't be read")
        let crowd = (0 ..< pinPageReadLimit).map { _ in FakeNode(attributes: [kAXRoleAttribute: "AXGroup"]) }
        XCTAssertEqual(read(window(toolbar: toolbar, extra: crowd)).privacy, .unknown, "The search was cut short")
        let second = FakeNode(attributes: [kAXRoleAttribute: "AXWebArea", "AXURL": "https://example.com/other"])
        let several = read(window(toolbar: toolbar, extra: [second]))
        XCTAssertTrue(several.showsSeveralPages)
        XCTAssertNil(several.url)
    }

    func testACancelledDetectionStopsWaitingForTheBrowsersAnswer() async throws {
        let wait = try XCTUnwrap(saved?.decision)
        let pending = PinPageExpectation(url: page)
        let start = ProcessInfo.processInfo.systemUptime
        let task = Task { @MainActor in await wait(pending) }
        task.cancel()
        await task.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1, "Not a spin until the deadline")
        XCTAssertFalse(pending.isDecided)

        let decided = PinPageExpectation(url: page)
        let started = ProcessInfo.processInfo.systemUptime
        let waiting = Task { @MainActor in await wait(decided) }
        try await Task.sleep(for: .milliseconds(100))
        decided.decide(7)
        await waiting.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1, "Done once the answer is in")
    }

    func testAddressesMatchAsBrowsersReportThemBackButQueriesCountInFull() {
        XCTAssertTrue(pinLinkAddressesMatch("https://Example.COM", "https://example.com/"))
        XCTAssertTrue(pinLinkAddressesMatch(page, page))
        XCTAssertFalse(pinLinkAddressesMatch(page, page.replacingOccurrences(of: "Q=Case", with: "q=case")))
        XCTAssertFalse(pinLinkAddressesMatch(page, page.replacingOccurrences(of: "#Section-2", with: "")))
        XCTAssertFalse(pinLinkAddressesMatch("https://example.com/a", "http://example.com/a"))
    }
}

/// A browser window's element, for the page reader.
private struct FakeNode: PinPageAXNode {
    var attributes: [String: String] = [:]
    var unreadable: Set<String> = []
    var kids: [FakeNode]? = []

    func text(_ attribute: String) -> (value: String?, unreadable: Bool) {
        unreadable.contains(attribute) ? (nil, true) : (attributes[attribute], false)
    }

    func children() -> [FakeNode]? { kids }
}
