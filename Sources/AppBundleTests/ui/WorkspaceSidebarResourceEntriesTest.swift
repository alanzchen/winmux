@testable import AppBundle
import AppKit
import Common
import XCTest

/// The two ways to keep a resource a tab's window shows. A pin with a home keeps its window: a click shows
/// that window, whatever it shows; Return to Home opens the home again, a separate action; and only a fresh
/// reading of the pin's own window, by a file's identity or a browser's own address, says it shows
/// something else. A shortcut holds no window: the tab it was taken from stays as it was, and a click goes
/// to the resource, to a window proven to show it, which only a file's identity proves, or opens it as a
/// launcher does, claiming nothing. Files are real temporary files; windows, reads, scripts and apps are
/// stand-ins.
@MainActor
final class WorkspaceSidebarResourceEntriesTest: XCTestCase {
    private let viewerId = "com.example.viewer"
    private let safariId = "com.apple.Safari"
    private let chromeId = "com.google.Chrome"
    private let notebookId = "com.example.Notebook"
    private lazy var viewer = TestApp(pid: 18301, bundleId: viewerId, name: "Viewer")
    private lazy var safari = TestApp(pid: 18401, bundleId: safariId, name: "Safari")
    private lazy var chrome = TestApp(pid: 18501, bundleId: chromeId, name: "Google Chrome")
    private lazy var notebook = TestApp(pid: 19101, bundleId: notebookId, name: "Notebook")
    private let page = "https://example.com/report?Q=Case#Section-2"
    private var folder: URL!

    private var notices: [WinMuxToastNotice] = []
    private var axDocuments: [UInt32: String] = [:]
    private var candidates: [Window] = []
    private var reads: [UInt32: PinPageWindowRead] = [:]
    private var scripts: [(source: String, arguments: [String])] = []
    private var launched: [(url: URL, app: URL)] = []
    private var openedFiles: [(file: URL, app: URL)] = []
    private var ran: [(source: String, values: HookmarkPlaceholderValues)] = []
    private var scriptAnswers: [HookmarkScriptResult] = []
    private var promptAnswers: [PinLinkEntry?] = []
    private var now: TimeInterval = 1000
    private let hookmarkGate = Gate()
    private var saved: Saved?

    private struct Saved {
        let ax: @MainActor (Window) async -> String?
        let candidates: @MainActor (String) -> [Window]
        let appURL: @MainActor (String) -> URL?
        let openDocument: @MainActor (URL, URL) async throws -> Int32
        let openShortcutFile: @MainActor (URL, URL) async throws -> Void
        let read: @MainActor (Window) async -> PinPageWindowRead?
        let script: @MainActor (String, [String]) async -> (result: NewWindowScriptResult, output: String)
        let running: @MainActor (String) -> Int32?
        let handler: @MainActor (URL) -> (url: URL, bundleId: String?)?
        let open: @MainActor (URL, URL) async throws -> Void
        let prompt: @MainActor (String, PinLinkEntry, String, String?) -> PinLinkEntry?
        let hookmark: @MainActor (String, HookmarkPlaceholderValues) async -> HookmarkScriptResult
        let integrations: LinkIntegrationStore
        let notice: @MainActor (WinMuxToastNotice) -> Void
        let decision: @MainActor (PinPageExpectation) async -> Void
        let homeNow: @MainActor () -> TimeInterval
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
        resetWorkspaceSidebarPinHomeReadingsForTests()
        resetResourceShortcutReadingsForTests()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-resource-entries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saved = Saved(ax: pinDocumentAXDocument, candidates: pinDocumentCandidateWindows, appURL: pinDocumentAppURL,
            openDocument: openPinDocumentFile, openShortcutFile: openResourceShortcutFile, read: pinPageWindowRead,
            script: pinLinkScript, running: pinPageRunningPid, handler: pinLinkHandlerApp, open: openPinLinkURL,
            prompt: pinLinkPrompt, hookmark: runHookmarkScript, integrations: linkIntegrationStore,
            notice: showWorkspaceSidebarNotice, decision: waitForPinPageDecision, homeNow: workspaceSidebarPinHomeNow,
            savedStore: savedWorkspaceStore)
        pinDocumentAXDocument = { [unowned self] window in axDocuments[window.windowId] }
        pinDocumentCandidateWindows = { [unowned self] bundleId in candidates.filter { $0.app.rawAppBundleId == bundleId } }
        pinDocumentAppURL = { URL(fileURLWithPath: "/Applications/\($0).app") }
        openPinDocumentFile = { [unowned self] file, app in
            openedFiles.append((file, app))
            return 18301
        }
        openResourceShortcutFile = { [unowned self] file, app in openedFiles.append((file, app)) }
        pinPageWindowRead = { [unowned self] window in reads[window.windowId] }
        pinLinkScript = { [unowned self] source, arguments in
            scripts.append((source, arguments))
            return (.success, "77")
        }
        pinPageRunningPid = { [unowned self] bundleId in bundleId == safariId ? safari.pid : nil }
        pinLinkHandlerApp = { url in
            switch url.scheme?.lowercased() {
                case "https", "http": (URL(fileURLWithPath: "/Applications/Safari.app"), "com.apple.Safari")
                case "notes": (URL(fileURLWithPath: "/System/Applications/Notes.app"), "com.apple.Notes")
                default: nil
            }
        }
        openPinLinkURL = { [unowned self] url, app in launched.append((url, app)) }
        pinLinkPrompt = { [unowned self] _, _, _, _ in promptAnswers.isEmpty ? nil : promptAnswers.removeFirst() }
        linkIntegrationStore = LinkIntegrationStore()
        runHookmarkScript = { [unowned self] source, values in
            ran.append((source, values))
            await hookmarkGate.pass()
            return scriptAnswers.isEmpty ? .success("") : scriptAnswers.removeFirst()
        }
        showWorkspaceSidebarNotice = { [unowned self] notice in notices.append(notice) }
        waitForPinPageDecision = { _ in }
        workspaceSidebarPinHomeNow = { [unowned self] in now }
    }

    override func tearDown() async throws {
        hookmarkGate.open()
        if let saved {
            pinDocumentAXDocument = saved.ax
            pinDocumentCandidateWindows = saved.candidates
            pinDocumentAppURL = saved.appURL
            openPinDocumentFile = saved.openDocument
            openResourceShortcutFile = saved.openShortcutFile
            pinPageWindowRead = saved.read
            pinLinkScript = saved.script
            pinPageRunningPid = saved.running
            pinLinkHandlerApp = saved.handler
            openPinLinkURL = saved.open
            pinLinkPrompt = saved.prompt
            runHookmarkScript = saved.hookmark
            linkIntegrationStore = saved.integrations
            showWorkspaceSidebarNotice = saved.notice
            waitForPinPageDecision = saved.decision
            workspaceSidebarPinHomeNow = saved.homeNow
            savedWorkspaceStore = saved.savedStore
        }
        WorkspaceSidebarTabUndo.shared.clear()
        NewWindowIntentRegistry.shared.resetForTests()
        workspaceSidebarOrganizationStore = .init()
        resetPinLinkAppCacheForTests()
        resetWorkspaceSidebarPinHomeReadingsForTests()
        resetResourceShortcutReadingsForTests()
        try? FileManager.default.removeItem(at: folder)
        config = defaultConfig
        try await super.tearDown()
    }

    // MARK: - Helpers

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

    private func file(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try "synthetic test document\n".write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func document(_ url: URL) throws -> WorkspaceSidebarPinDocument {
        try XCTUnwrap(makeWorkspaceSidebarPinDocument(url, bundleId: viewerId))
    }

    private func makeTab(_ name: String, windowId: UInt32, app: TestApp) -> (Workspace, Window) {
        let tab = Workspace.get(byName: name)
        return (tab, TestWindow.new(id: windowId, parent: tab.rootTilingContainer, app: app))
    }

    private func pin(_ tab: Workspace, _ resource: WorkspaceSidebarPinResource) {
        XCTAssertNil(commitWorkspaceSidebarPinResource(tab, resource, title: "Pin"))
    }

    private func appearance(_ name: String) -> WorkspaceSidebarItemAppearance? {
        workspaceSidebarOrganizationStore.state.workspaces[name]
    }

    private var shortcuts: [WorkspaceSidebarResourceShortcut] {
        workspaceSidebarOrganizationStore.state.resourceShortcuts ?? []
    }

    private var safariLink: WorkspaceSidebarPinLink {
        .init(url: page, title: "Report", adapter: "safari", bundleId: safariId, source: .window)
    }

    /// Adds a shortcut, as the menu does, and waits for its write.
    private func shortcut(_ resource: WorkspaceSidebarPinResource, pinScope: WorkspaceSidebarPinScope? = nil) async -> String {
        let before = shortcuts.count
        commitResourceShortcutWrite(resource, projectId: workspaceProjectDefaultId, pinScope: pinScope, title: "Add Shortcut")
        let added = await eventually { self.shortcuts.count > before }
        XCTAssertTrue(added)
        return shortcuts.last?.id ?? ""
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

    @discardableResult
    private func install(on: Bool = true) -> LinkIntegration {
        var integration = LinkIntegration(bundleId: notebookId, appName: "Notebook",
            getAddress: "tell application \"Notebook\" to return URL of front note",
            getName: "tell application \"Notebook\" to return name of front note",
            openItem: "tell application \"Notebook\" to open location \"$0\"", scheme: "x-notebook", source: .init(kind: .pasted))
        integration.isEnabled = on
        integration.trustedDigest = on ? integration.digest : nil
        linkIntegrationStore = LinkIntegrationStore(integrations: linkIntegrationStore.integrations + [integration])
        return integration
    }

    // MARK: - A pin with a home: what its window shows instead

    func testAPinShowsWhatItsWindowShowsInsteadOnlyOnAFreshReadingOfThatOneWindow() async throws {
        let (tab, _) = makeTab("page", windowId: 21, app: safari)
        pin(tab, .link(safariLink))
        reads[21] = .init(url: "https://example.com/elsewhere", title: "Elsewhere", privacy: .normal)
        XCTAssertEqual(workspaceSidebarPinHome(for: tab), .init(homeName: "Report", showsInstead: nil), "Unread: nothing said")

        let changed = await refreshWorkspaceSidebarPinHomeReadings()
        XCTAssertTrue(changed)
        XCTAssertEqual(workspaceSidebarPinHome(for: tab)?.showsInstead, "Elsewhere")
        XCTAssertEqual(appearance("page")?.link, safariLink, "The home never follows the window")

        now += workspaceSidebarPinHomeReadingFreshness + 1
        XCTAssertNil(workspaceSidebarPinHome(for: tab)?.showsInstead, "An old reading says nothing")

        reads[21] = .init(url: page, title: "Report", privacy: .normal)
        await refreshWorkspaceSidebarPinHomeReadings()
        XCTAssertNil(workspaceSidebarPinHome(for: tab)?.showsInstead, "Back home: nothing to say")
        XCTAssertEqual(workspaceSidebarPinHomeFreshEvidence(tab, home: .link(safariLink)), .showsHome)

        now += workspaceSidebarPinHomeReadInterval
        reads[21] = .init(url: "https://example.com/private", title: "Secret", privacy: .private)
        await refreshWorkspaceSidebarPinHomeReadings()
        XCTAssertNil(workspaceSidebarPinHome(for: tab)?.showsInstead, "A private window is never read as anything")

        now += workspaceSidebarPinHomeReadInterval
        reads[21] = .init(url: "https://example.com/a", title: "Two", privacy: .normal, showsSeveralPages: true)
        await refreshWorkspaceSidebarPinHomeReadings()
        XCTAssertNil(workspaceSidebarPinHome(for: tab)?.showsInstead, "A window with several pages can't be told")

        now += workspaceSidebarPinHomeReadInterval
        reads[21] = .init(url: "https://example.com/other", title: "Other", privacy: .unknown)
        await refreshWorkspaceSidebarPinHomeReadings()
        XCTAssertEqual(workspaceSidebarPinHome(for: tab)?.showsInstead, "another page", "Not known normal: no title")

        _ = TestWindow.new(id: 22, parent: tab.rootTilingContainer, app: safari)
        XCTAssertNil(workspaceSidebarPinHome(for: tab)?.showsInstead, "A reading is of the pin's one window only")
    }

    func testAnotherAppsWindowOrALinkNoBrowserShowsIsNeverReadAsTheHome() async throws {
        let (tab, _) = makeTab("note", windowId: 31, app: notebook)
        let note = WorkspaceSidebarPinLink(url: "x-notebook://note/1", title: "Plan", adapter: "integration", bundleId: notebookId,
            source: .window)
        pin(tab, .link(note))
        reads[31] = .init(url: "https://example.com/", title: "Page", privacy: .normal)
        await refreshWorkspaceSidebarPinHomeReadings()
        XCTAssertEqual(workspaceSidebarPinHome(for: tab), .init(homeName: "Plan", showsInstead: nil), "Unknown is neither")

        let (chromeTab, _) = makeTab("chrome", windowId: 32, app: chrome)
        pin(chromeTab, .link(safariLink))
        reads[32] = .init(url: "https://example.com/elsewhere", title: "Elsewhere", privacy: .normal)
        await refreshWorkspaceSidebarPinHomeReadings()
        XCTAssertNil(workspaceSidebarPinHome(for: chromeTab)?.showsInstead, "Safari's page, read in Chrome: not compared")
    }

    func testADocumentPinsWindowIsComparedByTheFilesIdentityNotItsPath() async throws {
        let home = try file("report.txt")
        let other = try file("notes.txt")
        let (tab, _) = makeTab("doc", windowId: 41, app: viewer)
        pin(tab, .file(try document(home)))

        let renamed = folder.appendingPathComponent("report renamed.txt")
        try FileManager.default.moveItem(at: home, to: renamed)
        axDocuments[41] = renamed.absoluteString
        await refreshWorkspaceSidebarPinHomeReadings()
        XCTAssertEqual(workspaceSidebarPinHomeFreshEvidence(tab, home: try XCTUnwrap(appearance("doc")?.resource)), .showsHome,
            "The same file, renamed")

        now += workspaceSidebarPinHomeReadInterval
        axDocuments[41] = other.absoluteString
        await refreshWorkspaceSidebarPinHomeReadings()
        XCTAssertEqual(workspaceSidebarPinHome(for: tab)?.showsInstead, "notes.txt")

        now += workspaceSidebarPinHomeReadInterval
        axDocuments[41] = nil
        await refreshWorkspaceSidebarPinHomeReadings()
        XCTAssertNil(workspaceSidebarPinHome(for: tab)?.showsInstead, "No file reported: unknown")
    }

    // MARK: - A pin with a home: clicking it, and Return to Home

    func testClickingAPinWhoseWindowShowsSomethingElseShowsThatWindowAndOpensNothing() async throws {
        let (tab, window) = makeTab("page", windowId: 21, app: safari)
        pin(tab, .link(safariLink))
        reads[21] = .init(url: "https://example.com/elsewhere", title: "Elsewhere", privacy: .normal)
        await refreshWorkspaceSidebarPinHomeReadings()

        handleWorkspaceSidebarAction(.selectWindow(21))
        await settle()

        XCTAssertEqual(focus.windowOrNil?.windowId, window.windowId)
        XCTAssertTrue(scripts.isEmpty)
        XCTAssertTrue(launched.isEmpty)
        XCTAssertEqual(appearance("page")?.link, safariLink)
    }

    func testReturnToHomeShowsTheWindowFreshlyReadToShowItAndOpensNothing() async throws {
        let (tab, window) = makeTab("page", windowId: 21, app: safari)
        _ = makeTab("other", windowId: 22, app: safari).1.focusWindow()
        pin(tab, .link(safariLink))
        reads[21] = .init(url: page, title: "Report", privacy: .normal)
        await refreshWorkspaceSidebarPinHomeReadings()

        handleWorkspaceSidebarAction(.returnPinToHome("page"))
        await settle()

        XCTAssertEqual(focus.windowOrNil?.windowId, window.windowId)
        XCTAssertTrue(scripts.isEmpty)
        XCTAssertTrue(launched.isEmpty)
    }

    func testReturnToHomeOpensTheHomeBesideWhatTheWindowShowsNowWhichStays() async throws {
        let (tab, window) = makeTab("page", windowId: 21, app: safari)
        pin(tab, .link(safariLink))
        reads[21] = .init(url: "https://example.com/elsewhere", title: "Elsewhere", privacy: .normal)
        await refreshWorkspaceSidebarPinHomeReadings()

        returnPinToHomeFromSidebar("page")

        let asked = await eventually { !self.scripts.isEmpty }
        XCTAssertTrue(asked, "Safari is asked for a fresh window for the home")
        XCTAssertEqual(scripts.first?.arguments.first, page)
        XCTAssertTrue(window.nodeWorkspace === tab, "The window showing something else stays in the pin")
        XCTAssertEqual(appearance("page")?.link, safariLink, "And the home stays the home")
        XCTAssertEqual(notices, [])

        // An app's link opens as a launcher opens it, in a window of the app's choosing.
        let (noteTab, _) = makeTab("note", windowId: 51, app: TestApp(pid: 19301, bundleId: "com.apple.Notes", name: "Notes"))
        let note = WorkspaceSidebarPinLink(url: "notes://showNote?identifier=ABC", title: "Plan", adapter: "link")
        pin(noteTab, .link(note))
        returnPinToHomeFromSidebar("note")
        let opened = await eventually { !self.launched.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(launched.map(\.url.absoluteString), [note.url])
    }

    func testReturnToHomeForADocumentOpensThatFileBesideTheOtherOneTheWindowShows() async throws {
        let home = try file("report.txt")
        let other = try file("notes.txt")
        let (tab, window) = makeTab("doc", windowId: 41, app: viewer)
        pin(tab, .file(try document(home)))
        axDocuments[41] = other.absoluteString
        candidates = [window]

        returnPinToHomeFromSidebar("doc")

        let opened = await eventually { !self.openedFiles.isEmpty }
        XCTAssertTrue(opened, "With a window, the pin's home still opens when it's asked for")
        XCTAssertEqual(openedFiles.first?.file.standardizedFileURL, home.standardizedFileURL)
        XCTAssertTrue(window.nodeWorkspace === tab)
        XCTAssertTrue(NewWindowIntentRegistry.shared.hasDocumentIntent(bundleId: viewerId), "Its window comes to the pin")
    }

    // MARK: - The menu

    func testThePinMenuOffersReturnToHomeAndBothWaysToKeepWhatTheWindowShows() {
        func model(_ name: String, _ bundleId: String, appearance: WorkspaceSidebarItemAppearance = .init())
            -> WorkspaceSidebarWorkspaceViewModel {
            .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: "", isGeneratedName: false,
                monitorScopeId: "monitor:0,0", monitorName: "Main", isFocused: false, isVisible: false,
                items: [.init(kind: .window(.init(windowId: 1, workspaceName: name, appName: "App", appBundleId: bundleId,
                    appBundlePath: nil, title: "Window", isFocused: false)))], appearance: appearance)
        }
        var sent: [WorkspaceSidebarAction] = []
        let send: @MainActor (WorkspaceSidebarAction) -> Void = { sent.append($0) }
        let unpinned = workspaceSidebarPinResourceMenuEntries(model("a", safariId), send: send)
        XCTAssertEqual(unpinned.last?.title, "Add Shortcut")
        XCTAssertEqual(unpinned.last?.children.map(\.title), ["Page in Window", "Document in Window", "Link…"])
        unpinned.last?.children.first?.perform?()
        XCTAssertEqual(sent.last, .addResourceShortcut("a", source: .window))

        var pinned = WorkspaceSidebarItemAppearance()
        pinned.setFavorite(true)
        pinned.link = safariLink
        let entries = workspaceSidebarPinResourceMenuEntries(model("b", safariId, appearance: pinned), send: send)
        XCTAssertEqual(entries.first?.title, "Return to “Report”")
        entries.first?.perform?()
        XCTAssertEqual(sent.last, .returnPinToHome("b"))
        let add = try? XCTUnwrap(entries.last)
        XCTAssertEqual(add?.children.first?.title, "This Pin's Home, “Report”")
        add?.children.first?.perform?()
        XCTAssertEqual(sent.last, .addResourceShortcutToPinHome("b"))
        entries.first { $0.title == "Set Current Page as Home" }?.perform?()
        XCTAssertEqual(sent.last, .updatePinLinkFromWindow("b"), "Setting the home is the only way it changes, with Undo")
    }

    // MARK: - Shortcuts: adding and removing

    func testAShortcutTakenFromATabsWindowLeavesTheTabAndItsWindowAsTheyWere() async throws {
        let (tab, window) = makeTab("page", windowId: 21, app: safari)
        reads[21] = .init(url: page, title: "Report", privacy: .normal)

        addResourceShortcutFromSidebar("page", source: .window)

        let added = await eventually { !self.shortcuts.isEmpty }
        XCTAssertTrue(added)
        XCTAssertEqual(shortcuts.first?.link?.url, page, "The address exactly")
        XCTAssertEqual(shortcuts.first?.name, "Report")
        XCTAssertEqual(shortcuts.first?.projectId, tab.projectId)
        XCTAssertNotEqual(appearance("page")?.isFavorite, true, "The tab isn't pinned")
        XCTAssertNil(appearance("page")?.resource)
        XCTAssertTrue(window.nodeWorkspace === tab, "Its window stays in its tab")
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Add Shortcut")

        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(shortcuts.isEmpty)
        XCTAssertTrue(window.nodeWorkspace === tab)
    }

    func testAShortcutFromAPrivateWindowOrAFileTheAppDoesntReportIsRefused() async throws {
        _ = makeTab("private", windowId: 21, app: safari)
        reads[21] = .init(url: page, title: "Report", privacy: .private)
        addResourceShortcutFromSidebar("private", source: .window)
        let told = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(told)
        XCTAssertEqual(notices.first?.body, pinPagePrivateMessage)

        _ = makeTab("doc", windowId: 41, app: viewer)
        addResourceShortcutFromSidebar("doc", source: .document)
        let toldAgain = await eventually { self.notices.count == 2 }
        XCTAssertTrue(toldAgain)
        XCTAssertTrue(shortcuts.isEmpty)
    }

    func testAShortcutToAPinsHomeLeavesThePinAndIsAddedOnce() async throws {
        let home = try file("report.txt")
        let (tab, window) = makeTab("doc", windowId: 41, app: viewer)
        pin(tab, .file(try document(home)))

        addResourceShortcutToPinHomeFromSidebar("doc")
        let added = await eventually { self.shortcuts.count == 1 }
        XCTAssertTrue(added)
        XCTAssertEqual(shortcuts.first?.document?.name, "report.txt")
        XCTAssertEqual(appearance("doc")?.document?.name, "report.txt", "The pin keeps its home")
        XCTAssertTrue(window.nodeWorkspace === tab)

        addResourceShortcutToPinHomeFromSidebar("doc")
        let told = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(told)
        XCTAssertEqual(shortcuts.count, 1, "One shortcut to a resource in a place")
        XCTAssertTrue(notices.last?.body.contains("already a shortcut") == true)

        var again = try document(home)
        again.bookmark = Data([9, 9, 9])
        commitResourceShortcutWrite(.file(again), projectId: tab.projectId, title: "Add Shortcut")
        let toldAgain = await eventually { self.notices.count == 2 }
        XCTAssertTrue(toldAgain)
        XCTAssertEqual(shortcuts.count, 1, "The same file, whatever its bookmark's bytes")
    }

    func testRemovingAShortcutIsUndoneAndClosesNothing() async throws {
        let (_, window) = makeTab("page", windowId: 21, app: safari)
        let id = await shortcut(.link(safariLink))
        WorkspaceSidebarTabUndo.shared.clear()

        removeResourceShortcutFromSidebar(id)

        let removed = await eventually { self.shortcuts.isEmpty }
        XCTAssertTrue(removed)
        XCTAssertTrue(window.isBound)
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Remove Shortcut")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(shortcuts.map(\.id), [id])
    }

    func testAShortcutMovesBetweenAllProjectsAndAProject() async {
        let id = await shortcut(.link(safariLink))
        let other = WorkspaceProjectId(rawValue: "other")
        setResourceShortcutScopeFromSidebar(id, allProjects: true, projectId: workspaceProjectDefaultId)
        let everywhere = await eventually {
            workspaceSidebarOrganizationStore.state.resourceShortcuts(projectId: other).allProjects.map(\.id) == [id]
        }
        XCTAssertTrue(everywhere)
        setResourceShortcutScopeFromSidebar(id, allProjects: false, projectId: other)
        let back = await eventually { workspaceSidebarOrganizationStore.state.resourceShortcuts(projectId: other).project.map(\.id) == [id] }
        XCTAssertTrue(back, "Back among the pins of the project the sidebar shows")
        XCTAssertTrue(workspaceSidebarOrganizationStore.state.resourceShortcuts(projectId: workspaceProjectDefaultId).project.isEmpty)
    }

    // MARK: - Shortcuts: going to them

    func testADocumentShortcutGoesToTheWindowProvenToShowItWhereverItIs() async throws {
        let home = try file("report.txt")
        let id = await shortcut(.file(try document(home)))
        let (elsewhere, window) = makeTab("elsewhere", windowId: 41, app: viewer)
        _ = makeTab("front", windowId: 42, app: safari).1.focusWindow()
        axDocuments[41] = home.absoluteString
        candidates = [window]

        goToResourceShortcutFromSidebar(id, bringHere: false, targetMonitorScopeId: nil)

        let shown = await eventually { focus.windowOrNil?.windowId == 41 }
        XCTAssertTrue(shown)
        XCTAssertTrue(window.nodeWorkspace === elsewhere, "Shown in its own tab, never moved into another")
        XCTAssertTrue(openedFiles.isEmpty)
    }

    func testADocumentShortcutWithNoWindowShowingItOpensItAsALauncherWouldAndClaimsNothing() async throws {
        let home = try file("report.txt")
        let other = try file("notes.txt")
        let id = await shortcut(.file(try document(home)))
        let (_, window) = makeTab("b", windowId: 41, app: viewer)
        axDocuments[41] = other.absoluteString
        candidates = [window]

        goToResourceShortcutFromSidebar(id, bringHere: false, targetMonitorScopeId: nil)

        let opened = await eventually { !self.openedFiles.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(openedFiles.first?.file.standardizedFileURL, home.standardizedFileURL)
        XCTAssertNotEqual(focus.windowOrNil?.windowId, 41, "The window showing another file is never taken for it")
        XCTAssertFalse(NewWindowIntentRegistry.shared.hasDocumentIntent(bundleId: viewerId), "No window is claimed for anything")

        openedFiles = []
        goToResourceShortcutFromSidebar(id, bringHere: true, targetMonitorScopeId: nil)
        let told = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(told)
        XCTAssertTrue(notices.last?.body.contains("none to bring here") == true)
        XCTAssertTrue(openedFiles.isEmpty, "⌘-click with no window known brings nothing and opens nothing")
    }

    func testADocumentShortcutToAFileGoneOrReplacedSaysSoAndOpensNothing() async throws {
        let home = try file("report.txt")
        let id = await shortcut(.file(try document(home)))
        try FileManager.default.removeItem(at: home)
        _ = try file("report.txt")

        goToResourceShortcutFromSidebar(id, bringHere: false, targetMonitorScopeId: nil)
        await settle()

        XCTAssertTrue(openedFiles.isEmpty, "A replacement isn't taken for it")
        XCTAssertTrue(notices.last?.body.contains("Remove this shortcut") == true)
    }

    func testALinkShortcutOpensAsALauncherAndNeverTakesAWindowShowingTheSameAddress() async throws {
        let (_, window) = makeTab("b", windowId: 21, app: safari)
        _ = makeTab("front", windowId: 22, app: viewer).1.focusWindow()
        reads[21] = .init(url: page, title: "Report", privacy: .normal)
        let id = await shortcut(.link(safariLink))

        goToResourceShortcutFromSidebar(id, bringHere: false, targetMonitorScopeId: nil)

        let opened = await eventually { !self.launched.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(launched.first?.url.absoluteString, page)
        XCTAssertNotEqual(focus.windowOrNil?.windowId, window.windowId, "The same address elsewhere proves nothing")
        XCTAssertTrue(scripts.isEmpty, "No window is asked for or claimed")
        XCTAssertFalse(workspaceSidebarResourceShortcutIsActive(try XCTUnwrap(shortcuts.first)))

        launched = []
        goToResourceShortcutFromSidebar(id, bringHere: true, targetMonitorScopeId: nil)
        await settle()
        XCTAssertTrue(launched.isEmpty, "⌘-click can't promise to bring an unknown window here")
        XCTAssertTrue(notices.last?.body.contains("can't tell which window") == true)
    }

    func testAnIntegrationShortcutRunsItsOpenItemOnceAndRefusesWhenOffChangedOrRemoved() async throws {
        let integration = install()
        let note = WorkspaceSidebarPinLink(url: "x-notebook://note/1", title: "Plan", adapter: "integration", bundleId: notebookId,
            source: .window, integration: integration.id)
        let id = await shortcut(.link(note))

        hookmarkGate.close()
        goToResourceShortcutFromSidebar(id, bringHere: false, targetMonitorScopeId: nil)
        let running = await eventually { self.hookmarkGate.waiting == 1 }
        XCTAssertTrue(running)
        goToResourceShortcutFromSidebar(id, bringHere: false, targetMonitorScopeId: nil)
        await settle()
        XCTAssertEqual(ran.count, 1, "A second click while it opens does nothing")
        scriptAnswers = [.timedOut]
        hookmarkGate.open()
        let told = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(told)
        XCTAssertTrue(notices.last?.body.contains("doesn't run it again") == true)
        XCTAssertEqual(ran.count, 1, "A script that may have run is never run again on its own")
        XCTAssertEqual(ran.first?.values.address, note.url)
        XCTAssertTrue(launched.isEmpty)

        linkIntegrationStore = LinkIntegrationStore()
        install(on: false)
        let offId = linkIntegrationStore.integrations[0].id
        var offNote = note
        offNote.integration = offId
        let off = await shortcut(.link(offNote))
        goToResourceShortcutFromSidebar(off, bringHere: false, targetMonitorScopeId: nil)
        await settle()
        XCTAssertTrue(notices.last?.body.contains("which is off") == true)

        var changed = linkIntegrationStore.integrations[0]
        changed.isEnabled = true
        changed.trustedDigest = "an older digest"
        linkIntegrationStore = LinkIntegrationStore(integrations: [changed])
        goToResourceShortcutFromSidebar(off, bringHere: false, targetMonitorScopeId: nil)
        await settle()
        XCTAssertTrue(notices.last?.body.contains("scripts changed") == true)

        linkIntegrationStore = LinkIntegrationStore()
        goToResourceShortcutFromSidebar(off, bringHere: false, targetMonitorScopeId: nil)
        await settle()
        XCTAssertTrue(notices.last?.body.contains("since been removed") == true)
        XCTAssertEqual(ran.count, 1)
        XCTAssertTrue(launched.isEmpty, "Never anything else in its place")
    }

    func testAShortcutANewerWinMuxMadeIsKeptButNotOpened() async throws {
        var newer = WorkspaceSidebarResourceShortcut(projectId: workspaceProjectDefaultId, resource: .link(safariLink))
        newer.version = WorkspaceSidebarResourceShortcut.currentVersion + 1
        try workspaceSidebarOrganizationStore.update { $0.resourceShortcuts = [newer] }

        goToResourceShortcutFromSidebar(newer.id, bringHere: false, targetMonitorScopeId: nil)
        await settle()

        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(notices.last?.body.contains("newer WinMux") == true)
        XCTAssertFalse(workspaceSidebarResourceShortcutViewModel(newer).isReadable)
    }

    // MARK: - Shortcuts: shown among the pins

    func testADocumentShortcutIsLitOnlyWhileAWindowProvenToShowItIsInFront() async throws {
        let home = try file("report.txt")
        let id = await shortcut(.file(try document(home)))
        let linkId = await shortcut(.link(safariLink))
        let (_, window) = makeTab("a", windowId: 41, app: viewer)
        axDocuments[41] = home.absoluteString
        _ = window.focusWindow()

        await refreshResourceShortcutFrontReading()
        let models = workspaceSidebarResourceShortcutViewModels()
        XCTAssertEqual(models.first { $0.id == id }?.isActive, true)
        XCTAssertEqual(models.first { $0.id == linkId }?.isActive, false, "A shortcut WinMux can only open is never lit")

        let (_, page) = makeTab("b", windowId: 21, app: safari)
        reads[21] = .init(url: self.page, title: "Report", privacy: .normal)
        _ = page.focusWindow()
        await refreshResourceShortcutFrontReading()
        XCTAssertEqual(workspaceSidebarResourceShortcutViewModels().map(\.isActive), [false, false])
    }

    func testShortcutsReachTheSidebarInTabsModeAmongTheirProjectsPins() async throws {
        let everywhere = await shortcut(.link(safariLink), pinScope: .allProjects)
        let own = await shortcut(.link(.init(url: "notes://showNote?identifier=ABC", title: "Plan", adapter: "link")))
        let state = await buildWorkspaceSidebarModelState()
        XCTAssertEqual(state.resourceShortcuts.map(\.id), [everywhere, own])
        let shown = state.resourceShortcuts.shown(in: workspaceProjectDefaultId)
        XCTAssertEqual(shown.allProjects.map(\.id), [everywhere])
        XCTAssertEqual(shown.project.map(\.id), [own])
        XCTAssertTrue(state.resourceShortcuts.shown(in: WorkspaceProjectId(rawValue: "other")).project.isEmpty)
        XCTAssertEqual(state.resourceShortcuts.first { $0.id == own }?.name, "Plan", "Named after its resource")

        config.workspaceSidebar.mode = .sidebar
        let otherMode = await buildWorkspaceSidebarModelState()
        XCTAssertTrue(otherMode.resourceShortcuts.isEmpty)
    }

    func testShortcutTilesFollowThePinsInTheGridAndTakeNoDrop() {
        let empty = WorkspaceSidebarPinnedGridLayout(workspaces: [], shortcuts: 0, width: 240)
        XCTAssertEqual(empty.height, 0)
        let onlyShortcuts = WorkspaceSidebarPinnedGridLayout(workspaces: [], shortcuts: 2, width: 240)
        XCTAssertEqual(onlyShortcuts.height, 54, "One row")
        let manyShortcuts = WorkspaceSidebarPinnedGridLayout(workspaces: [], shortcuts: onlyShortcuts.columns + 1, width: 240)
        XCTAssertEqual(manyShortcuts.height, 116, "Two rows")
    }

    func testAShortcutsMenuOffersWhatItCanDo() {
        var sent: [WorkspaceSidebarAction] = []
        let document = WorkspaceSidebarResourceShortcutViewModel(id: "d", projectId: workspaceProjectDefaultId, name: "report.txt",
            symbolName: "doc.text", app: nil, isInAllProjects: false, findsItsWindow: true, isLink: false, isReadable: true, help: "")
        let link = WorkspaceSidebarResourceShortcutViewModel(id: "l", projectId: workspaceProjectDefaultId, name: "Report",
            symbolName: "link", app: nil, isInAllProjects: true, findsItsWindow: false, isLink: true, isReadable: true, help: "")
        func titles(_ model: WorkspaceSidebarResourceShortcutViewModel) -> [String] {
            workspaceSidebarResourceShortcutMenuEntries(model, contextProjectId: workspaceProjectDefaultId, contextProjectName: "Work",
                send: { sent.append($0) }).map(\.title)
        }
        XCTAssertEqual(titles(document), ["Shortcut to “report.txt”", "Go to “report.txt”", "Bring Window Here", "",
            "Show in All Projects", "", "Remove Shortcut"])
        XCTAssertEqual(titles(link), ["Shortcut to “Report”", "Open “Report”", "", "Edit Link…", "Show in “Work” Only", "",
            "Remove Shortcut"], "It can only open it: nothing to bring")
        workspaceSidebarResourceShortcutMenuEntries(document, contextProjectId: workspaceProjectDefaultId, contextProjectName: "Work",
            send: { sent.append($0) }).first { $0.title == "Bring Window Here" }?.perform?()
        XCTAssertEqual(sent, [.goToResourceShortcut("d", bringHere: true)])
    }

    // MARK: - Kept as they were

    func testALegacyPinAndOrganizationLoadUnchangedWithNoShortcuts() throws {
        let file = #"""
            {"version":1,"collections":[],"workspaces":{
              "page":{"isFavorite":true,"link":{"version":1,"url":"https://example.com/report","title":"Report","adapter":"safari",
                "bundleId":"com.apple.Safari","source":"window"}}}}
            """#
        let url = folder.appendingPathComponent("organization.json")
        try Data(file.utf8).write(to: url)
        let store = WorkspaceSidebarOrganizationStore.load(url: url)
        XCTAssertNil(store.readOnlyReason)
        XCTAssertNil(store.state.resourceShortcuts, "Nothing converted")
        XCTAssertEqual(store.state.workspaces["page"]?.link?.url, "https://example.com/report")
        XCTAssertEqual(store.state.workspaces["page"]?.isFavorite, true)
        let written = String(decoding: try JSONEncoder().encode(store.state), as: UTF8.self)
        XCTAssertFalse(written.contains("resourceShortcuts"), "A file without shortcuts is written without them")
    }

    func testShortcutsLoadEvenWhenOneIsNewerDamagedOrRepeated() throws {
        let file = #"""
            {"version":1,"collections":[],"workspaces":{},"resourceShortcuts":[
              {"id":"a","version":1,"projectId":"default","link":{"version":1,"url":"https://example.com/","title":"Example","adapter":"link"}},
              {"id":"a","version":1,"projectId":"default","link":{"version":1,"url":"https://example.com/2","title":"Twice","adapter":"link"}},
              {"id":"b","version":7,"projectId":"default","somethingNew":{"x":1}},
              {"id":"c","link":{"title":7}},
              "not a shortcut"]}
            """#
        let url = folder.appendingPathComponent("organization.json")
        try Data(file.utf8).write(to: url)
        let store = WorkspaceSidebarOrganizationStore.load(url: url)
        XCTAssertNil(store.readOnlyReason, "One shortcut never keeps the rest of the organization from loading")
        let loaded = store.state.resourceShortcuts ?? []
        XCTAssertEqual(loaded.first?.name, "Example")
        XCTAssertEqual(loaded.filter { $0.id == "a" }.count, 1, "An id once")
        XCTAssertEqual(loaded.map(\.isReadable), [true, false, false, false])
        XCTAssertEqual(loaded.first { $0.id == "b" }?.version, 7, "Kept as a newer WinMux wrote it, not opened")
    }
}
