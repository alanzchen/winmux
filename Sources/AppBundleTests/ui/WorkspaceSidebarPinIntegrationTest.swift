@testable import AppBundle
import AppKit
import Common
import XCTest

/// Pin with Integration: the user's Hookmark-compatible scripts for an app read the item the tab's own
/// window shows, run only once that window is in front and kept only if it still is, and their links open
/// with the integration's Open Item, claiming nothing. Windows, scripts, the front window and the clipboard
/// are stand-ins; the scripts are written for these tests.
@MainActor
final class WorkspaceSidebarPinIntegrationTest: XCTestCase {
    private let notebookId = "com.example.Notebook"
    private let safariId = "com.apple.Safari"
    private lazy var notebook = TestApp(pid: 19101, bundleId: notebookId, name: "Notebook")
    private lazy var safari = TestApp(pid: 19201, bundleId: safariId, name: "Safari")
    private lazy var editor = TestApp(pid: 19301, bundleId: "com.example.editor", name: "Editor")
    private let getAddress = "tell application \"Notebook\" to return URL of front note"
    private let getName = "tell application \"Notebook\" to return name of front note"
    private let openItem = "tell application \"Notebook\" to open location \"$0\""

    private var notices: [WinMuxToastNotice] = []
    private var ran: [(source: String, values: HookmarkPlaceholderValues)] = []
    private var answers: [HookmarkScriptResult] = []
    /// Runs while a script runs: the world changing under it.
    private var duringScript: (@MainActor () -> Void)?
    private var front: (pid: Int32, windowId: UInt32)?
    private var focused: [UInt32] = []
    private var focusBringsFront = true
    /// Native focus changes macOS reported, as the stand-in counts them.
    private var focusEvents: UInt64 = 0
    private var reads: [UInt32: PinPageWindowRead] = [:]
    private var handlers: [String: (url: URL, bundleId: String?)] = [:]
    private var launched: [(url: URL, app: URL)] = []
    private let clipboard = FakeClipboard()
    private var saved: Saved?

    private struct Saved {
        let run: @MainActor (String, HookmarkPlaceholderValues) async -> HookmarkScriptResult
        let focus: @MainActor (Window) async -> Void
        let front: @MainActor () async -> (pid: Int32, windowId: UInt32)?
        let focusEvents: @MainActor () -> UInt64
        let clipboard: LinkIntegrationClipboard
        let store: LinkIntegrationStore
        let read: @MainActor (Window) async -> PinPageWindowRead?
        let modes: @MainActor (Int32) async -> Result<[String], PinPageAskFailure>
        let handler: @MainActor (URL) -> (url: URL, bundleId: String?)?
        let open: @MainActor (URL, URL) async throws -> Void
        let appURL: @MainActor (String) -> URL?
        let notice: @MainActor (WinMuxToastNotice) -> Void
        let savedStore: SavedWorkspaceStore
    }

    @MainActor
    final class FakeClipboard: LinkIntegrationClipboard {
        var changeCount = 0
        var items: [[String: Data]] = [["public.utf8-plain-text": Data("mine".utf8)]]
        var snapshots = 0
        var restored: [[[String: Data]]] = []
        var string: String? { items.first?["public.utf8-plain-text"].map { String(decoding: $0, as: UTF8.self) } }

        func snapshot() -> [[String: Data]] {
            snapshots += 1
            return items
        }

        func restore(_ items: [[String: Data]]) {
            restored.append(items)
            self.items = items
            changeCount += 1
        }

        func copy(_ text: String) {
            items = [["public.utf8-plain-text": Data(text.utf8)]]
            changeCount += 1
        }
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
        saved = Saved(run: runHookmarkScript, focus: linkIntegrationFocusWindow, front: linkIntegrationFrontWindow,
            focusEvents: linkIntegrationFocusEvents, clipboard: linkIntegrationClipboard, store: linkIntegrationStore, read: pinPageWindowRead, modes: pinPageChromiumModesOf,
            handler: pinLinkHandlerApp, open: openPinLinkURL, appURL: pinDocumentAppURL, notice: showWorkspaceSidebarNotice,
            savedStore: savedWorkspaceStore)
        linkIntegrationStore = LinkIntegrationStore()
        runHookmarkScript = { [unowned self] source, values in
            ran.append((source, values))
            duringScript?()
            return answers.isEmpty ? .success("") : answers.removeFirst()
        }
        linkIntegrationFocusWindow = { [unowned self] window in
            focused.append(window.windowId)
            if focusBringsFront { front = (window.app.pid, window.windowId) }
        }
        linkIntegrationFrontWindow = { [unowned self] in front }
        linkIntegrationFocusEvents = { [unowned self] in focusEvents }
        linkIntegrationClipboard = clipboard
        pinPageWindowRead = { [unowned self] window in reads[window.windowId] }
        pinPageChromiumModesOf = { _ in .success(["normal"]) }
        pinLinkHandlerApp = { [unowned self] url in url.scheme.flatMap { handlers[$0.lowercased()] } }
        openPinLinkURL = { [unowned self] url, app in launched.append((url, app)) }
        pinDocumentAppURL = { URL(fileURLWithPath: "/Applications/\($0).app") }
        showWorkspaceSidebarNotice = { [unowned self] notice in notices.append(notice) }
    }

    override func tearDown() async throws {
        if let saved {
            runHookmarkScript = saved.run
            linkIntegrationFocusWindow = saved.focus
            linkIntegrationFrontWindow = saved.front
            linkIntegrationFocusEvents = saved.focusEvents
            linkIntegrationClipboard = saved.clipboard
            linkIntegrationStore = saved.store
            pinPageWindowRead = saved.read
            pinPageChromiumModesOf = saved.modes
            pinLinkHandlerApp = saved.handler
            openPinLinkURL = saved.open
            pinDocumentAppURL = saved.appURL
            showWorkspaceSidebarNotice = saved.notice
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

    /// An integration, on and trusted as it is unless `on` is false.
    @discardableResult
    private func install(_ bundleId: String? = nil, appName: String = "Notebook", getAddress: String? = nil,
                         getName: String?? = nil, openItem: String?? = nil, scheme: String? = "x-notebook", on: Bool = true)
        -> LinkIntegration {
        var integration = LinkIntegration(bundleId: bundleId ?? notebookId, appName: appName, getAddress: getAddress ?? self.getAddress,
            getName: getName ?? self.getName, openItem: openItem ?? self.openItem, scheme: scheme, source: .init(kind: .pasted))
        integration.isEnabled = on
        integration.trustedDigest = on ? integration.digest : nil
        linkIntegrationStore = LinkIntegrationStore(integrations: linkIntegrationStore.integrations + [integration])
        return integration
    }

    private func makeTab(_ name: String, windowId: UInt32, app: TestApp) -> (Workspace, Window) {
        let tab = Workspace.get(byName: name)
        return (tab, TestWindow.new(id: windowId, parent: tab.rootTilingContainer, app: app))
    }

    private func appearance(_ name: String) -> WorkspaceSidebarItemAppearance? {
        workspaceSidebarOrganizationStore.state.workspaces[name]
    }

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

    /// Pins `name` with the integration and waits for the outcome: a link, or a notice.
    private func pin(_ name: String, _ integration: LinkIntegration, updating: Bool = false) async {
        let before = appearance(name)?.resource
        pinLinkWithIntegrationFromSidebar(name, integrationId: integration.id, updating: updating)
        _ = await eventually { !self.notices.isEmpty || self.appearance(name)?.resource != before }
        await settle()
    }

    // MARK: - Taking a link

    func testTheScriptsReadTheTabsOwnWindowBroughtToTheFrontFirst() async throws {
        let integration = install()
        let (tab, window) = makeTab("note", windowId: 41, app: notebook)
        let (_, other) = makeTab("other", windowId: 42, app: notebook)
        front = (notebook.pid, other.windowId)
        answers = [.success("x-notebook://note/7?q=Case"), .success("Plan\nB")]

        await pin(tab.name, integration)

        XCTAssertEqual(focused, [41], "The tab's own window, as a click on it would")
        XCTAssertEqual(ran.map(\.source), [getAddress, getName])
        XCTAssertEqual(ran.first?.values, .init(address: nil, appName: "Notebook"), "Get Address is given no address")
        XCTAssertEqual(appearance("note")?.isFavorite, true)
        XCTAssertEqual(appearance("note")?.link, .init(url: "x-notebook://note/7?q=Case", title: "Plan B", adapter: "integration",
            bundleId: notebookId, source: .window, integration: integration.id))
        XCTAssertTrue(window.nodeWorkspace === tab, "Nothing moves")
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin with Notebook Integration")
        XCTAssertEqual(notices, [])
        XCTAssertEqual(clipboard.snapshots, 0, "Scripts that don't use the clipboard leave it alone")
    }

    func testANameInTheAnswerSkipsGetNameAndAFailingGetNameStillPins() async throws {
        let integration = install()
        let (tab, _) = makeTab("note", windowId: 41, app: notebook)
        answers = [.success("[Plan](x-notebook://note/7)")]
        await pin(tab.name, integration)
        XCTAssertEqual(ran.count, 1)
        XCTAssertEqual(appearance("note")?.link?.title, "Plan")

        let (second, _) = makeTab("second", windowId: 43, app: notebook)
        ran = []
        answers = [.success("x-notebook://note/8"), .failed("No note.")]
        await pin(second.name, integration)
        XCTAssertEqual(ran.count, 2)
        XCTAssertEqual(appearance("second")?.link?.title, "x-notebook://note/8", "Named by its address, as Hookmark does")
        XCTAssertEqual(notices, [])
    }

    func testNothingRunsUnlessTheTabsWindowIsInFrontAndNothingIsKeptIfItStopsBeing() async throws {
        // No Get Name: what Get Address read is checked on its own.
        let integration = install(getName: .some(nil))
        let (tab, _) = makeTab("note", windowId: 41, app: notebook)
        let (_, other) = makeTab("other", windowId: 42, app: notebook)
        front = (notebook.pid, other.windowId)
        focusBringsFront = false

        await pin(tab.name, integration)

        XCTAssertTrue(ran.isEmpty, "Never on whatever else is in front")
        XCTAssertTrue(notices.last?.body.contains("couldn't bring this tab's window to the front") == true)
        XCTAssertNil(appearance("note")?.link)

        focusBringsFront = true
        notices = []
        answers = [.success("x-notebook://note/7")]
        duringScript = { [unowned self] in front = (notebook.pid, other.windowId) }

        await pin(tab.name, integration)

        XCTAssertEqual(ran.count, 1)
        XCTAssertTrue(notices.last?.body.contains("The front window changed") == true)
        XCTAssertNil(appearance("note")?.link, "What it read may be another window's")

        // Get Name's answer is checked the same way: read once the window left the front, it isn't kept. The
        // address, read and checked before, is, named by itself.
        linkIntegrationStore = LinkIntegrationStore()
        let named = install()
        ran = []
        notices = []
        front = nil
        answers = [.success("x-notebook://note/7"), .success("Another window's note")]
        var runs = 0
        duringScript = { [unowned self] in
            runs += 1
            if runs == 2 { front = (notebook.pid, other.windowId) }
        }
        await pin(tab.name, named)
        XCTAssertEqual(ran.map(\.source), [getAddress, getName])
        XCTAssertEqual(appearance("note")?.link?.url, "x-notebook://note/7")
        XCTAssertEqual(appearance("note")?.link?.title, "x-notebook://note/7")
    }

    func testAFocusChangeWhileAScriptRunsVoidsItEvenIfTheWindowComesBack() async throws {
        let integration = install(getName: .some(nil))
        let (tab, window) = makeTab("note", windowId: 41, app: notebook)
        front = (notebook.pid, window.windowId)
        answers = [.success("x-notebook://note/7")]
        // Away to another window and back while it ran: macOS reported the changes, the front is as it was.
        duringScript = { [unowned self] in focusEvents += 2 }

        await pin(tab.name, integration)

        XCTAssertEqual(ran.count, 1)
        XCTAssertEqual(notices.last?.body, linkIntegrationFrontChangedMessage)
        XCTAssertNil(appearance("note")?.link)
    }

    func testTurningAnIntegrationOffOrEditingItStopsACaptureBeforeItsNextScript() async throws {
        let integration = install(getName: .some(nil))
        let (tab, other) = makeTab("note", windowId: 41, app: notebook)
        _ = other
        front = nil
        // Turned off while WinMux brings the window forward: Get Address never runs.
        linkIntegrationFocusWindow = { [unowned self] window in
            front = (window.app.pid, window.windowId)
            try? linkIntegrationStore.setEnabled(id: integration.id, false)
        }
        await pin(tab.name, integration)
        XCTAssertTrue(ran.isEmpty)
        XCTAssertEqual(notices.last?.body, linkIntegrationWithdrawnMessage)

        // Edited while Get Address runs: Get Name never runs, and nothing is kept.
        linkIntegrationStore = LinkIntegrationStore()
        let named = install()
        notices = []
        front = (notebook.pid, 41)
        answers = [.success("x-notebook://note/7"), .success("Plan")]
        duringScript = { [unowned self] in
            var edited = named
            edited.getName = "return \"Other\""
            edited.trustedDigest = edited.digest
            linkIntegrationStore = LinkIntegrationStore(integrations: [edited])
            duringScript = nil
        }
        await pin(tab.name, named)
        XCTAssertEqual(ran.map(\.source), [getAddress])
        XCTAssertNil(appearance("note")?.link)
    }

    func testAnIntegrationThatsOffChangedUnsupportedOrForAnotherAppRunsNothing() async throws {
        let off = install(on: false)
        let (tab, _) = makeTab("note", windowId: 41, app: notebook)
        await pin(tab.name, off)
        XCTAssertTrue(notices.last?.body.contains("is off") == true)

        var changed = off
        changed.getAddress = "return \"x-notebook://other\""
        changed.isEnabled = true
        changed.trustedDigest = off.digest
        linkIntegrationStore = LinkIntegrationStore(integrations: [changed])
        notices = []
        await pin(tab.name, changed)
        XCTAssertTrue(notices.last?.body.contains("changed since you turned it on") == true)

        linkIntegrationStore = LinkIntegrationStore()
        let unsupported = install(getAddress: "tell application \"Hookmark\" to return address of current node")
        notices = []
        await pin(tab.name, unsupported)
        XCTAssertTrue(notices.last?.body.contains("Hookmark itself") == true)

        linkIntegrationStore = LinkIntegrationStore()
        let forEditor = install("com.example.editor", appName: "Editor")
        let (otherApp, _) = makeTab("notebook2", windowId: 44, app: notebook)
        notices = []
        await pin(otherApp.name, forEditor)
        XCTAssertTrue(notices.last?.body.contains("isn't Editor's") == true)

        XCTAssertTrue(ran.isEmpty)
        XCTAssertTrue(focused.isEmpty, "Nothing is even brought forward")
        XCTAssertNil(appearance("note")?.link)
    }

    func testWhatGetAddressAnswersDecidesWhatsKept() async throws {
        let integration = install(getName: .some(nil))
        let cases: [(HookmarkScriptResult, String)] = [
            (.success(""), "found no item in this window"),
            (.success("hook://x-callback-url/setCurrentNode?x=1"), "only Hookmark receives"),
            (.success("hook://file/ABC"), "only Hookmark opens"),
            (.success("javascript:alert(1)"), "doesn't keep"),
            (.success("two words"), "doesn't keep"),
            (.notAuthorized, "Privacy & Security → Automation"),
            (.failed("Notebook got an error: No note."), "failed: Notebook got an error: No note."),
            (.timedOut, "didn't answer within 30 seconds"),
        ]
        for (index, (answer, message)) in cases.enumerated() {
            let (tab, _) = makeTab("case\(index)", windowId: UInt32(50 + index), app: notebook)
            notices = []
            answers = [answer]
            await pin(tab.name, integration)
            XCTAssertTrue(notices.last?.body.contains(message) == true, "\(answer): \(notices.last?.body ?? "no notice")")
            XCTAssertNil(appearance(tab.name)?.resource, "\(answer)")
        }
    }

    func testAFilePathAnswerPinsTheFileItself() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-integration-\(UUID().uuidString).txt")
        try Data("plan".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let integration = install()
        let (tab, _) = makeTab("file", windowId: 61, app: notebook)
        answers = [.success(file.path)]

        await pin(tab.name, integration)

        let document = try XCTUnwrap(appearance("file")?.document)
        XCTAssertEqual(document.name, file.lastPathComponent)
        XCTAssertEqual(document.bundleId, notebookId)
        XCTAssertEqual(resolvePinDocument(document).url, file.standardizedFileURL)
    }

    func testTheClipboardIsPutBackWhenTheScriptChangedIt() async throws {
        let integration = install(getAddress: "tell application \"System Events\" to keystroke \"c\" using command down\nreturn the clipboard",
            getName: .some(nil))
        let (tab, _) = makeTab("note", windowId: 41, app: notebook)
        answers = [.success("x-notebook://note/7")]
        duringScript = { [unowned self] in clipboard.copy("x-notebook://note/7") }

        await pin(tab.name, integration)

        XCTAssertEqual(clipboard.restored.count, 1)
        XCTAssertEqual(clipboard.items, [["public.utf8-plain-text": Data("mine".utf8)]], "What the user had")
        XCTAssertEqual(appearance("note")?.link?.url, "x-notebook://note/7")

        let (second, _) = makeTab("second", windowId: 43, app: notebook)
        answers = [.success("x-notebook://note/8")]
        duringScript = nil
        await pin(second.name, integration)
        XCTAssertEqual(clipboard.restored.count, 1, "Unchanged: nothing is written to it")

        // Something else on it afterwards may be the user's, copied meanwhile: it stays.
        let (third, _) = makeTab("third", windowId: 44, app: notebook)
        answers = [.success("x-notebook://note/9")]
        duringScript = { [unowned self] in clipboard.copy("x-notebook://note/9"); clipboard.copy("the user's own copy") }
        await pin(third.name, integration)
        XCTAssertEqual(clipboard.restored.count, 1)
        XCTAssertEqual(clipboard.string, "the user's own copy")
        XCTAssertEqual(appearance("third")?.link?.url, "x-notebook://note/9")
    }

    func testAnOpenItemThatCopiesTheAddressGetsTheClipboardPutBack() async throws {
        let integration = install(openItem: "set the clipboard to \"$0\"\ntell application \"System Events\" to keystroke \"v\" using command down")
        let link = WorkspaceSidebarPinLink(url: "x-notebook://note/7", title: "Plan", adapter: "integration", bundleId: notebookId,
            source: .window, integration: integration.id)
        let tab = try emptyPinnedLink("note", link)
        duringScript = { [unowned self] in clipboard.copy("x-notebook://note/7") }

        openSavedTabApps(tab) { _, _ in XCTFail() }

        let opened = await eventually { !self.clipboard.restored.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(clipboard.string, "mine")
    }

    func testAPrivateOrUncertainBrowserWindowRunsNothing() async throws {
        let integration = install(safariId, appName: "Safari", scheme: nil)
        let (privateTab, privateWindow) = makeTab("private", windowId: 71, app: safari)
        reads[privateWindow.windowId] = .init(url: "https://example.com/", title: "Example", privacy: .private)
        await pin(privateTab.name, integration)
        XCTAssertEqual(notices.last?.body, pinPagePrivateMessage)

        let (unsure, unsureWindow) = makeTab("unsure", windowId: 72, app: safari)
        reads[unsureWindow.windowId] = .init(url: "https://example.com/", title: "Example", privacy: .unknown)
        notices = []
        await pin(unsure.name, integration)
        XCTAssertTrue(notices.last?.body.contains("Private Browsing") == true)

        XCTAssertTrue(ran.isEmpty)
        XCTAssertTrue(focused.isEmpty)
    }

    func testASafariWindowReadBeforeItsToolbarIsBuiltIsReadAgain() async throws {
        let integration = install(safariId, appName: "Safari", getName: .some(nil), scheme: nil)
        let (tab, window) = makeTab("page", windowId: 73, app: safari)
        var reads = [PinPageWindowRead(url: nil, title: "HM", privacy: .unknown),
                     PinPageWindowRead(url: "https://example.com/", title: "HM", privacy: .normal)]
        pinPageWindowRead = { _ in reads.count > 1 ? reads.removeFirst() : reads[0] }
        answers = [.success("https://example.com/a?Q=Case#Part")]

        await pin(tab.name, integration)

        XCTAssertEqual(notices, [])
        XCTAssertEqual(appearance("page")?.link?.url, "https://example.com/a?Q=Case#Part")
        XCTAssertTrue(window.nodeWorkspace === tab)
    }

    func testAChangeToTheTabWhileTheScriptRunsWritesNothing() async throws {
        let integration = install(getName: .some(nil))
        let (tab, _) = makeTab("note", windowId: 41, app: notebook)
        answers = [.success("x-notebook://note/7")]
        duringScript = { try? workspaceSidebarOrganizationStore.update { $0.workspaces["note", default: .init()].emoji = "🙂" } }

        await pin(tab.name, integration)

        XCTAssertEqual(notices.last?.body, pinDocumentChangedMessage)
        XCTAssertNil(appearance("note")?.link)
    }

    func testUpdateFromWindowReplacesTheLinkAndUndoPutsItBack() async throws {
        let integration = install(getName: .some(nil))
        let (tab, _) = makeTab("note", windowId: 41, app: notebook)
        let first = WorkspaceSidebarPinLink(url: "x-notebook://note/1", title: "One", adapter: "integration", bundleId: notebookId,
            source: .window, integration: integration.id)
        XCTAssertNil(commitWorkspaceSidebarPinResource(tab, .link(first), title: "Pin"))
        answers = [.success("[Two](x-notebook://note/2)")]

        await pin(tab.name, integration, updating: true)

        XCTAssertEqual(appearance("note")?.link?.url, "x-notebook://note/2")
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Update from Window")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(appearance("note")?.link, first)
    }

    // MARK: - Opening

    func testALinkAnIntegrationTookOpensWithItsOpenItemGivenTheAddressAsData() async throws {
        let integration = install()
        let address = "x-notebook://note/7?q=\" & (do shell script \"echo\") & \""
        let tab = try emptyPinnedLink("note", .init(url: address, title: "Plan", adapter: "integration", bundleId: notebookId,
            source: .window, integration: integration.id))

        openSavedTabApps(tab) { _, _ in XCTFail("The app alone is never asked for a window") }

        let opened = await eventually { !self.ran.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(ran.first?.source, openItem)
        XCTAssertEqual(ran.first?.values, .init(address: address, appName: "Notebook"))
        XCTAssertTrue(launched.isEmpty)
        XCTAssertFalse(NewWindowIntentRegistry.shared.hasPendingIntents, "Nothing waits for, claims or moves a window")
        XCTAssertTrue(focused.isEmpty)

        // Scripts changed and trusted again between the click and the run: not the ones clicked, so nothing runs.
        ran = []
        openSavedTabApps(tab) { _, _ in XCTFail() }
        var edited = integration
        edited.openItem = "tell application \"Notebook\" to activate"
        edited.trustedDigest = edited.digest
        linkIntegrationStore = LinkIntegrationStore(integrations: [edited])
        await settle()
        XCTAssertTrue(ran.isEmpty)
    }

    func testALinkWhoseIntegrationIsOffChangedOrGoneSaysSoAndOpensNothingElse() async throws {
        handlers["x-notebook"] = (URL(fileURLWithPath: "/Applications/Other.app"), "com.example.Other")
        let off = install(on: false)
        let link = WorkspaceSidebarPinLink(url: "x-notebook://note/7", title: "Plan", adapter: "integration", bundleId: notebookId,
            source: .window, integration: off.id)
        XCTAssertTrue(pinLinkOpening(link).failureMessage?.contains("which is off") == true)

        var changed = off
        changed.isEnabled = true
        changed.trustedDigest = "old"
        linkIntegrationStore = LinkIntegrationStore(integrations: [changed])
        XCTAssertTrue(pinLinkOpening(link).failureMessage?.contains("changed since you turned it on") == true)

        linkIntegrationStore = LinkIntegrationStore()
        XCTAssertTrue(pinLinkOpening(link).failureMessage?.contains("since been removed") == true, "No other app stands in")

        let tab = try emptyPinnedLink("gone", link)
        openSavedTabApps(tab) { _, _ in XCTFail() }
        await settle()
        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(ran.isEmpty)
        XCTAssertTrue(notices.last?.body.contains("since been removed") == true)
    }

    func testAnIntegrationOffWithoutAnOpenItemStillStandsForItsLinks() throws {
        handlers["x-notebook"] = (URL(fileURLWithPath: "/Applications/Notebook.app"), notebookId)
        let off = install(openItem: .some(nil), on: false)
        let link = WorkspaceSidebarPinLink(url: "x-notebook://note/7", title: "Plan", adapter: "integration", bundleId: notebookId,
            source: .window, integration: off.id)
        XCTAssertTrue(pinLinkOpening(link).failureMessage?.contains("which is off") == true, "Not macOS's handler instead")
    }

    func testWithoutAnOpenItemItCanRunMacOSOpensTheLink() throws {
        handlers["x-notebook"] = (URL(fileURLWithPath: "/Applications/Notebook.app"), notebookId)
        let none = install(openItem: .some(nil))
        let link = WorkspaceSidebarPinLink(url: "x-notebook://note/7", title: "Plan", adapter: "integration", bundleId: notebookId,
            source: .window, integration: none.id)
        XCTAssertEqual(try pinLinkOpening(link).get(), .launcher(appURL: URL(fileURLWithPath: "/Applications/Notebook.app")))

        linkIntegrationStore = LinkIntegrationStore()
        let template = install(openItem: "//JavaScript\nApplication('Notebook').open(`$0`)")
        var templated = link
        templated.integration = template.id
        XCTAssertEqual(try pinLinkOpening(templated).get(), .launcher(appURL: URL(fileURLWithPath: "/Applications/Notebook.app")),
            "An Open Item WinMux can't run leaves the link to macOS, as the integration says")
    }

    func testATypedLinkGoesToAnIntegrationOnlyWhenNoAppOpensItsScheme() throws {
        let integration = install()
        let typed = try pinLinkFromEntry(.init(address: "x-notebook://note/9", name: "")).get()
        XCTAssertEqual(typed.integration, integration.id)
        XCTAssertEqual(typed.bundleId, notebookId)
        XCTAssertEqual(typed.title, "Notebook")
        XCTAssertEqual(try pinLinkOpening(typed).get(), .integration(integration))

        let edited = try pinLinkFromEntry(.init(address: "x-notebook://note/9", name: "Renamed"), editing: typed).get()
        XCTAssertEqual(edited.integration, integration.id, "Same address, same opener")

        handlers["x-notebook"] = (URL(fileURLWithPath: "/Applications/Notebook.app"), notebookId)
        XCTAssertNil(try pinLinkFromEntry(.init(address: "x-notebook://note/9", name: "")).get().integration,
            "An app that opens it does, as before: no built-in is replaced")
        handlers = [:]

        install("com.example.Notebook2", appName: "Notebook 2")
        guard case .failure(let refusal) = pinLinkFromEntry(.init(address: "x-notebook://note/9", name: "")) else {
            return XCTFail("Two integrations: WinMux doesn't choose")
        }
        XCTAssertTrue(refusal.message.contains("doesn't choose"))

        linkIntegrationStore = LinkIntegrationStore()
        install(on: false)
        guard case .failure(let none) = pinLinkFromEntry(.init(address: "x-notebook://note/9", name: "")) else { return XCTFail() }
        XCTAssertEqual(none.message, "No app on this Mac opens “x-notebook:” links.")
    }

    // MARK: - Menu

    func testTheMenuOffersTheIntegrationBesideTheBuiltIns() {
        func entries(_ model: WorkspaceSidebarWorkspaceViewModel) -> [WorkspaceSidebarAppMenuEntry] {
            workspaceSidebarPinResourceMenuEntries(model, send: { _ in })
        }
        XCTAssertEqual(entries(viewModel("a", windows: [(1, notebookId)])).map(\.title), ["Pin Document", "Pin Link…"],
            "No integration, nothing new")
        let integration = install()
        let safariIntegration = install(safariId, appName: "Safari", scheme: nil)
        XCTAssertEqual(entries(viewModel("a", windows: [(1, notebookId)])).map(\.title),
            ["Pin with Notebook Integration", "Pin Document", "Pin Link…"])
        XCTAssertEqual(entries(viewModel("b", windows: [(1, safariId)])).map(\.title),
            ["Pin Page", "Pin with Safari Integration", "Pin Document", "Pin Link…"], "Beside the built-in, never instead")
        XCTAssertEqual(entries(viewModel("c", windows: [(1, notebookId), (2, notebookId)])).map(\.title), ["Pin Document", "Pin Link…"])
        var pinned = WorkspaceSidebarItemAppearance()
        pinned.setFavorite(true)
        pinned.link = .init(url: "x-notebook://note/1", title: "One", adapter: "integration", bundleId: notebookId, source: .window,
            integration: integration.id)
        XCTAssertEqual(entries(viewModel("d", windows: [(1, notebookId)], appearance: pinned)).map(\.title),
            ["Update from Window (Notebook Integration)", "Edit Link…", "Forget Link"])

        var sent: [WorkspaceSidebarAction] = []
        workspaceSidebarPinResourceMenuEntries(viewModel("a", windows: [(1, notebookId)]), send: { sent.append($0) }).first?.perform?()
        XCTAssertEqual(sent, [.pinLinkWithIntegration("a", integrationId: integration.id, updating: false)])
        _ = safariIntegration

        linkIntegrationStore = LinkIntegrationStore()
        install(on: false)
        let offEntry = entries(viewModel("a", windows: [(1, notebookId)])).first
        XCTAssertEqual(offEntry?.title, "Pin with Notebook Integration")
        XCTAssertEqual(offEntry?.enabled, false)
        XCTAssertTrue(offEntry?.help?.contains("Settings → Integrations") == true)
    }
}

private extension Result where Failure == PinLinkEntryRefusal {
    var failureMessage: String? { if case .failure(let refusal) = self { refusal.message } else { nil } }
}
