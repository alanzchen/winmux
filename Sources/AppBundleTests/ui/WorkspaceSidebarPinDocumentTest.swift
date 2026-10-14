@testable import AppBundle
import AppKit
import Common
import XCTest

/// Pin Document: a pin that keeps the file its one window showed, opens that very file again, and
/// takes only a window proven to show it. Files are real temporary files; windows and the app's
/// answers are stand-ins, some held mid-way to change the pin while they wait.
@MainActor
final class WorkspaceSidebarPinDocumentTest: XCTestCase {
    private let appId = "com.example.viewer"
    private lazy var app = TestApp(pid: 18301, bundleId: appId, launchDate: savedTestNow.addingTimeInterval(-86400))
    private var folder: URL!
    private var notices: [WinMuxToastNotice] = []
    private var axDocuments: [UInt32: String] = [:]
    private var axReads: [UInt32] = []
    private var candidates: [Window] = []
    private var opened: [(file: URL, app: URL)] = []
    private var openFailure: Error?
    /// Holds the next AX read, the open of a file, the queued write, or the focus of an open window.
    private let axGate = Gate()
    private let openGate = Gate()
    private let commitGate = Gate()
    private let focusGate = Gate()

    private var saved: (ax: @MainActor (Window) async -> String?, candidates: @MainActor (String) -> [Window],
                        appURL: @MainActor (String) -> URL?, open: @MainActor (URL, URL) async throws -> Int32,
                        notice: @MainActor (WinMuxToastNotice) -> Void, commit: @MainActor () async -> Void,
                        focus: @MainActor () async -> Void, savedStore: SavedWorkspaceStore)?

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
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-pin-document-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saved = (pinDocumentAXDocument, pinDocumentCandidateWindows, pinDocumentAppURL, openPinDocumentFile,
                 showWorkspaceSidebarNotice, pinDocumentWillCommit, pinDocumentWillFocusOpenWindow, savedWorkspaceStore)
        pinDocumentAXDocument = { [unowned self] window in
            axReads.append(window.windowId)
            await axGate.pass()
            return axDocuments[window.windowId]
        }
        pinDocumentCandidateWindows = { [unowned self] bundleId in candidates.filter { $0.app.rawAppBundleId == bundleId } }
        pinDocumentAppURL = { _ in URL(fileURLWithPath: "/Applications/Viewer.app") }
        openPinDocumentFile = { [unowned self] file, app in
            opened.append((file, app))
            await openGate.pass()
            if let openFailure { throw openFailure }
            return 18301
        }
        showWorkspaceSidebarNotice = { [unowned self] notice in notices.append(notice) }
        pinDocumentWillCommit = { [unowned self] in await commitGate.pass() }
        pinDocumentWillFocusOpenWindow = { [unowned self] in await focusGate.pass() }
    }

    override func tearDown() async throws {
        for gate in [axGate, openGate, commitGate, focusGate] { gate.open() }
        if let saved {
            pinDocumentAXDocument = saved.ax
            pinDocumentCandidateWindows = saved.candidates
            pinDocumentAppURL = saved.appURL
            openPinDocumentFile = saved.open
            showWorkspaceSidebarNotice = saved.notice
            pinDocumentWillCommit = saved.commit
            pinDocumentWillFocusOpenWindow = saved.focus
            savedWorkspaceStore = saved.savedStore
        }
        pinDocumentBeforeOrganizationWriteForTests = nil
        WorkspaceSidebarTabUndo.shared.clear()
        NewWindowIntentRegistry.shared.resetForTests()
        workspaceSidebarOrganizationStore = .init()
        try? FileManager.default.removeItem(at: folder)
        config = defaultConfig
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Holds whoever passes while it's closed, until it's opened. With `once`, only the first.
    @MainActor
    final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var closed = false
        private var once = false
        var waiting: Int { waiters.count }

        func close(once: Bool = false) {
            closed = true
            self.once = once
        }

        func pass() async {
            guard closed else { return }
            if once { closed = false }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            closed = false
            let resumed = waiters
            waiters = []
            for waiter in resumed { waiter.resume() }
        }
    }

    private func file(_ name: String, _ text: String = "synthetic test document\n") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    /// A tab with one window of the viewer app, which reports `document` as its file.
    private func makeTab(_ name: String, windowId: UInt32, showing document: URL?) -> (Workspace, Window) {
        let tab = Workspace.get(byName: name)
        let window = TestWindow.new(id: windowId, parent: tab.rootTilingContainer, app: app)
        if let document { axDocuments[windowId] = document.absoluteString }
        return (tab, window)
    }

    private func document(_ url: URL) throws -> WorkspaceSidebarPinDocument {
        try XCTUnwrap(makeWorkspaceSidebarPinDocument(url, bundleId: appId))
    }

    private func commit(_ tab: Workspace, _ document: WorkspaceSidebarPinDocument?, title: String = "Pin Document") {
        XCTAssertNil(commitWorkspaceSidebarPinDocument(tab, document, title: title))
    }

    /// A pinned document with no window: its saved place held the viewer's window, now closed.
    private func emptyPinnedDocument(_ name: String, file: URL) throws -> (Workspace, WorkspaceSidebarPinDocument) {
        var record = SavedWorkspaceRecord(workspaceName: name)
        record.launchApps = [SavedLaunchApp(bundleId: appId)]
        savedWorkspaceStore.insert(record)
        materializeSavedWorkspaceNames()
        let tab = try XCTUnwrap(Workspace.existing(byName: name))
        let pinned = try document(file)
        commit(tab, pinned)
        return (tab, pinned)
    }

    private func appearance(_ name: String) -> WorkspaceSidebarItemAppearance? {
        workspaceSidebarOrganizationStore.state.workspaces[name]
    }

    private func eventually(_ condition: () -> Bool, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Lets queued tasks and sessions run.
    private func settle() async {
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// A path no store can write: its parent is a file.
    private func unwritable(_ name: String) throws -> URL {
        let blocker = folder.appendingPathComponent("blocker-\(name)")
        try Data("x".utf8).write(to: blocker)
        return blocker.appendingPathComponent("\(name).json")
    }

    // MARK: - Identity

    func testADocumentRequestTakesOnlyAWindowShowingThatVeryFile() throws {
        let registry = NewWindowIntentRegistry.shared
        let pinned = try file("report.txt")
        let other = try file("other.txt")
        let target = Workspace.get(byName: "doc")
        XCTAssertNotNil(registry.register(bundleId: appId, pid: 7, targetWorkspace: target, preexistingWindowIds: [],
            focusGeneration: focusChangeGeneration, document: PinDocumentIdentity(fileURL: pinned)))
        XCTAssertTrue(registry.hasDocumentIntent(bundleId: appId))

        XCTAssertNil(registry.claim(windowId: 11, pid: 7, bundleId: appId, firstSeenUptime: registry.now()),
            "A new window that hasn't said what it shows isn't the document's, however new")
        XCTAssertNil(registry.claim(windowId: 11, pid: 7, bundleId: appId, firstSeenUptime: registry.now(),
            document: other.absoluteString), "Another file of the same app")
        XCTAssertNil(registry.claim(windowId: 11, pid: 7, bundleId: appId, firstSeenUptime: registry.now(),
            document: "https://example.com/report.txt"), "A page isn't a file")
        XCTAssertTrue(registry.claim(windowId: 11, pid: 7, bundleId: appId, firstSeenUptime: registry.now(),
            document: pinned.absoluteString) === target)
    }

    func testAFileReplacedAtTheSamePathIsAnotherFile() throws {
        let pinned = try file("report.txt")
        let kept = try document(pinned)
        let identity = try XCTUnwrap(PinDocumentIdentity(fileURL: pinned))

        try FileManager.default.removeItem(at: pinned)
        _ = try file("report.txt", "an unrelated file with the same name\n")

        XCTAssertNotEqual(PinDocumentIdentity(fileURL: pinned), identity, "Same path, same name: still another file")
        XCTAssertNil(resolvePinDocument(kept).url, "The bookmark doesn't stand for whatever is at its path now")
    }

    func testARenamedOrMovedFileIsStillThePinnedFile() throws {
        let pinned = try file("report.txt")
        let identity = try XCTUnwrap(PinDocumentIdentity(fileURL: pinned))
        let kept = try document(pinned)
        let sub = folder.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let moved = sub.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: pinned, to: moved)

        let url = try XCTUnwrap(resolvePinDocument(kept).url)
        XCTAssertEqual(PinDocumentIdentity(fileURL: url), identity)
        XCTAssertEqual(url.lastPathComponent, "renamed.txt")
    }

    func testARecordWithoutFileNumberOrVolumeIsNeverOpened() async throws {
        let pinned = try file("report.txt")
        let (tab, kept) = try emptyPinnedDocument("doc", file: pinned)
        var unverifiable = kept
        unverifiable.volume = nil
        workspaceSidebarOrganizationStore = .init(state: {
            var state = workspaceSidebarOrganizationStore.state
            state.workspaces["doc"]?.document = unverifiable
            return state
        }())
        guard case .unverifiable = resolvePinDocument(unverifiable) else { return XCTFail("Checked by half is not checked") }

        openSavedTabApps(tab) { _, _ in XCTFail("No fallback to the app") }

        XCTAssertTrue(notices.first?.body.contains("can't check that “report.txt” is still the same file") == true)
        await settle()
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: - Pin, update, forget

    func testPinDocumentPinsTheTabWithItsWindowsFile() async throws {
        let pinned = try file("report.txt")
        let (tab, _) = makeTab("doc", windowId: 21, showing: pinned)

        pinDocumentFromSidebar(tab.name, updating: false)

        let pinnedNow = await eventually { self.appearance("doc")?.document != nil }
        XCTAssertTrue(pinnedNow)
        XCTAssertEqual(appearance("doc")?.isFavorite, true)
        XCTAssertEqual(appearance("doc")?.document?.name, "report.txt")
        XCTAssertEqual(appearance("doc")?.document?.bundleId, appId)
        XCTAssertTrue(workspaceIsPinnedDocument(tab))
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin Document")
        XCTAssertEqual(notices, [])
    }

    func testPinDocumentRefusesWhatIsntASavedFileAndChangesNothing() async throws {
        let missing = folder.appendingPathComponent("never-saved.txt")
        let cases: [(String, String?)] = [("none", nil), ("page", "https://example.com/"), ("unsaved", missing.absoluteString)]
        for (index, (name, document)) in cases.enumerated() {
            let (tab, window) = makeTab(name, windowId: UInt32(30 + index), showing: nil)
            if let document { axDocuments[window.windowId] = document }
            notices = []

            pinDocumentFromSidebar(tab.name, updating: false)

            let refused = await eventually { !self.notices.isEmpty }
            XCTAssertTrue(refused, name)
            XCTAssertNil(appearance(name), "\(name): not pinned, nothing stored")
        }
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    func testPinDocumentNeedsATabWithOneWindowAndAsksNoApp() throws {
        let tab = Workspace.get(byName: "two")
        _ = TestWindow.new(id: 41, parent: tab.rootTilingContainer, app: app)
        _ = TestWindow.new(id: 42, parent: tab.rootTilingContainer, app: app)

        pinDocumentFromSidebar(tab.name, updating: false)

        XCTAssertEqual(notices.map(\.body), [PinDocumentRefusal.severalWindows.message])
        XCTAssertEqual(axReads, [], "Refused before any app is asked")
        XCTAssertNil(appearance("two"))
    }

    func testUpdateKeepsTheOldDocumentWhenTheWindowShowsNoFile() async throws {
        let pinned = try file("report.txt")
        let (tab, window) = makeTab("doc", windowId: 21, showing: pinned)
        let kept = try document(pinned)
        commit(tab, kept)
        axDocuments[window.windowId] = nil

        pinDocumentFromSidebar(tab.name, updating: true)

        let refused = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(refused)
        XCTAssertEqual(appearance("doc")?.document, kept)
    }

    func testForgetDocumentKeepsThePinAndUnpinForgetsItToo() async throws {
        let first = try file("first.txt")
        let (forgotten, _) = try emptyPinnedDocument("forgotten", file: first)
        forgetPinDocumentFromSidebar(forgotten.name)
        let forgot = await eventually { self.appearance("forgotten")?.document == nil }
        XCTAssertTrue(forgot)
        XCTAssertEqual(appearance("forgotten")?.isFavorite, true, "Still pinned, as an ordinary pin")

        var unpinned = WorkspaceSidebarItemAppearance()
        unpinned.setFavorite(true)
        unpinned.document = try document(first)
        unpinned.setFavorite(false)
        XCTAssertNil(unpinned.document)
    }

    func testFilesWithoutDocumentsStillLoadAndDocumentsRoundTrip() throws {
        let old = #"{"version":1,"collections":[],"workspaces":{"a":{"isFavorite":true}}}"#
        let loaded = try JSONDecoder().decode(WorkspaceSidebarOrganization.self, from: Data(old.utf8))
        XCTAssertNil(loaded.workspaces["a"]?.document)

        var state = WorkspaceSidebarOrganization()
        state.workspaces["a", default: .init()].setFavorite(true)
        state.workspaces["a"]?.document = try document(try file("report.txt"))
        let decoded = try JSONDecoder().decode(WorkspaceSidebarOrganization.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }

    // MARK: - F5: one outcome across both stores

    func testAFailedOrganizationWriteTakesBackTheSavedIdentity() throws {
        let pinned = try file("report.txt")
        let (tab, _) = makeTab("fresh", windowId: 22, showing: pinned)
        let savedURL = folder.appendingPathComponent("saved-workspaces.json")
        savedWorkspaceStore = SavedWorkspaceStore(url: savedURL)
        workspaceSidebarOrganizationStore = WorkspaceSidebarOrganizationStore(url: try unwritable("organization"))
        XCTAssertNil(savedWorkspaceStore.record(named: "fresh"))
        let lifecycle = tab.lifecycle
        var savedOnDiskBeforeOrganization = false
        pinDocumentBeforeOrganizationWriteForTests = {
            savedOnDiskBeforeOrganization = (try? String(contentsOf: savedURL, encoding: .utf8))?.contains("\"fresh\"") == true
        }

        let message = commitWorkspaceSidebarPinDocument(tab, try document(pinned), title: "Pin Document")

        XCTAssertTrue(message?.hasPrefix("Couldn't pin document") == true, message ?? "nil")
        XCTAssertFalse(message?.contains("stays saved") == true)
        XCTAssertTrue(savedOnDiskBeforeOrganization, "The saved identity was written first")
        XCTAssertNil(savedWorkspaceStore.record(named: "fresh"), "Taken back in memory")
        XCTAssertFalse((try String(contentsOf: savedURL, encoding: .utf8)).contains("\"fresh\""), "And on disk")
        XCTAssertEqual(tab.lifecycle, lifecycle)
        XCTAssertNil(appearance("fresh"))
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title, "No success, no Undo")
    }

    func testAFailedSavedIdentityWritePinsNothing() throws {
        let pinned = try file("report.txt")
        let (tab, _) = makeTab("fresh", windowId: 22, showing: pinned)
        savedWorkspaceStore = SavedWorkspaceStore(url: try unwritable("saved"))
        let lifecycle = tab.lifecycle

        let message = commitWorkspaceSidebarPinDocument(tab, try document(pinned), title: "Pin Document")

        XCTAssertTrue(message?.hasPrefix("Couldn't pin document") == true, message ?? "nil")
        XCTAssertNil(appearance("fresh"), "No pin and no document without its saved identity")
        XCTAssertNil(savedWorkspaceStore.record(named: "fresh"))
        XCTAssertEqual(tab.lifecycle, lifecycle)
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    func testAFailedWriteFromTheMenuSaysSoAndLeavesNoUndo() async throws {
        let pinned = try file("report.txt")
        let (tab, _) = makeTab("fresh", windowId: 22, showing: pinned)
        workspaceSidebarOrganizationStore = WorkspaceSidebarOrganizationStore(url: try unwritable("organization"))

        pinDocumentFromSidebar(tab.name, updating: false)

        let told = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(told)
        XCTAssertTrue(notices.first?.body.hasPrefix("Couldn't pin document") == true)
        XCTAssertNil(appearance("fresh"))
        XCTAssertNil(savedWorkspaceStore.record(named: "fresh"))
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    // MARK: - F2: an answer for an older state of the tab writes nothing

    func testACaptureAnsweredAfterForgetWritesNothing() async throws {
        let first = try file("first.txt")
        let (tab, window) = makeTab("doc", windowId: 21, showing: first)
        commit(tab, try document(first))
        axDocuments[window.windowId] = try file("second.txt").absoluteString
        axGate.close()
        pinDocumentFromSidebar(tab.name, updating: true)
        let asked = await eventually { self.axGate.waiting == 1 }
        XCTAssertTrue(asked)

        forgetPinDocumentFromSidebar(tab.name)
        let forgot = await eventually { self.appearance("doc")?.document == nil }
        XCTAssertTrue(forgot)
        axGate.open()
        await settle()

        XCTAssertNil(appearance("doc")?.document, "The forgotten document isn't brought back by the older Update")
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Forget Document")
        XCTAssertEqual(notices.map(\.body), [pinDocumentChangedMessage])
    }

    func testAnOlderUpdateNeverOverwritesANewerOne() async throws {
        let first = try file("first.txt")
        let (tab, window) = makeTab("doc", windowId: 21, showing: first)
        commit(tab, try document(first))
        let second = try file("second.txt")
        let third = try file("third.txt")
        axDocuments[window.windowId] = second.absoluteString
        axGate.close(once: true)
        pinDocumentFromSidebar(tab.name, updating: true)
        let held = await eventually { self.axGate.waiting == 1 }
        XCTAssertTrue(held)

        axDocuments[window.windowId] = third.absoluteString
        pinDocumentFromSidebar(tab.name, updating: true)
        let newer = await eventually { self.appearance("doc")?.document?.name == "third.txt" }
        XCTAssertTrue(newer)
        axDocuments[window.windowId] = second.absoluteString
        axGate.open()
        await settle()

        XCTAssertEqual(appearance("doc")?.document?.name, "third.txt")
    }

    func testAPinAnsweredAfterPinAndUnpinDoesntPinAgain() async throws {
        let pinned = try file("report.txt")
        let (tab, _) = makeTab("doc", windowId: 21, showing: pinned)
        axGate.close()
        pinDocumentFromSidebar(tab.name, updating: false)
        let held = await eventually { self.axGate.waiting == 1 }
        XCTAssertTrue(held)

        try setWorkspaceSidebarTabFavorite(tab, true)
        try setWorkspaceSidebarTabFavorite(tab, false)
        axGate.open()
        await settle()

        XCTAssertNotEqual(appearance("doc")?.isFavorite, true, "Unpinned stays unpinned")
        XCTAssertNil(appearance("doc")?.document)
    }

    func testUndoWhileACaptureWaitsWritesNothing() async throws {
        let first = try file("first.txt")
        let (tab, window) = makeTab("doc", windowId: 21, showing: first)
        pinDocumentFromSidebar(tab.name, updating: false)
        let pinned = await eventually { self.appearance("doc")?.document != nil }
        XCTAssertTrue(pinned)
        axDocuments[window.windowId] = try file("second.txt").absoluteString
        axGate.close()
        pinDocumentFromSidebar(tab.name, updating: true)
        let held = await eventually { self.axGate.waiting == 1 }
        XCTAssertTrue(held)

        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertNil(appearance("doc")?.document)
        axGate.open()
        await settle()

        XCTAssertNil(appearance("doc")?.document, "Undone stays undone")
        XCTAssertNotEqual(appearance("doc")?.isFavorite, true)
    }

    func testAQueuedWriteChecksAgainRightBeforeWriting() async throws {
        let pinned = try file("report.txt")
        let (tab, window) = makeTab("doc", windowId: 21, showing: pinned)
        commitGate.close()
        pinDocumentFromSidebar(tab.name, updating: false)
        let queued = await eventually { self.commitGate.waiting == 1 }
        XCTAssertTrue(queued, "Captured, and waiting for its session's turn")

        // The window leaves the tab while the write waits for its turn.
        let other = Workspace.get(byName: "other")
        _ = window.unbindFromParent()
        window.bind(to: other.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        commitGate.open()
        await settle()

        XCTAssertNil(appearance("doc"), "Nothing pinned for a tab that changed")
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title, "And no Undo")
        XCTAssertEqual(notices.map(\.body), [pinDocumentChangedMessage])
    }

    // MARK: - F1: a replacement is never adopted on its own

    func testAReplacementWhileItsWindowStaysOpenIsNeverAdopted() async throws {
        let pinned = try file("report.txt")
        let (tab, window) = makeTab("doc", windowId: 21, showing: pinned)
        let kept = try document(pinned)
        commit(tab, kept)
        // Replaced at its path, by a safe save or by anything else: the window still reports that path.
        _ = try FileManager.default.replaceItemAt(pinned, withItemAt: try file("replacement.tmp", "replacement\n"))

        refreshPinDocument(tab.name)
        XCTAssertEqual(appearance("doc")?.document, kept, "Not adopted, however the window looks")

        window.closeAxWindow()
        openSavedTabApps(tab) { _, _ in XCTFail("No fallback to the app") }
        XCTAssertTrue(notices.first?.body.hasPrefix("Can't find “report.txt”") == true)
        await settle()
        XCTAssertTrue(opened.isEmpty)
    }

    func testUndoOfAnUpdateKeepsTheOldDocument() async throws {
        let first = try file("first.txt")
        let second = try file("second.txt")
        let (tab, window) = makeTab("doc", windowId: 21, showing: first)
        pinDocumentFromSidebar(tab.name, updating: false)
        let pinned = await eventually { self.appearance("doc")?.document?.name == "first.txt" }
        XCTAssertTrue(pinned)
        axDocuments[window.windowId] = second.absoluteString
        pinDocumentFromSidebar(tab.name, updating: true)
        let updated = await eventually { self.appearance("doc")?.document?.name == "second.txt" }
        XCTAssertTrue(updated)

        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(appearance("doc")?.document?.name, "first.txt")
        refreshPinDocument(tab.name)

        XCTAssertEqual(appearance("doc")?.document?.name, "first.txt", "Its window shows second.txt; the pin stays first.txt")
        XCTAssertEqual(PinDocumentIdentity(fileURL: try XCTUnwrap(resolvePinDocument(try XCTUnwrap(appearance("doc")?.document)).url)),
            PinDocumentIdentity(fileURL: first))
    }

    func testARenamedFileGetsAFreshBookmarkAndNameWithoutAnyWindow() throws {
        let pinned = try file("report.txt")
        let (tab, _) = try emptyPinnedDocument("doc", file: pinned)
        let renamed = folder.appendingPathComponent("final.txt")
        try FileManager.default.moveItem(at: pinned, to: renamed)

        refreshPinDocument(tab.name)

        XCTAssertEqual(appearance("doc")?.document?.name, "final.txt")
        guard case .found(let url, let isStale) = resolvePinDocument(try XCTUnwrap(appearance("doc")?.document)) else {
            return XCTFail("Still the same file")
        }
        XCTAssertEqual(url.lastPathComponent, "final.txt")
        XCTAssertFalse(isStale)
    }

    // MARK: - Reopen

    func testClickingAPinnedDocumentOpensItsFileAndWaitsForThatFile() async throws {
        let pinned = try file("report.txt")
        let (tab, _) = try emptyPinnedDocument("doc", file: pinned)
        var asked: [NewWindowRequestTarget] = []

        openSavedTabApps(tab) { target, _ in asked.append(target) }

        let opening = await eventually { !self.opened.isEmpty }
        XCTAssertTrue(opening)
        XCTAssertEqual(asked, [], "The app alone is never asked for a window")
        XCTAssertEqual(opened.first?.file.lastPathComponent, "report.txt")
        XCTAssertEqual(opened.first?.app, URL(fileURLWithPath: "/Applications/Viewer.app"))
        let registry = NewWindowIntentRegistry.shared
        XCTAssertTrue(registry.hasDocumentIntent(bundleId: appId))
        XCTAssertNil(registry.claim(windowId: 51, pid: 18301, bundleId: appId, firstSeenUptime: registry.now(),
            document: try file("another.txt").absoluteString), "Another document of the app goes elsewhere")
        XCTAssertTrue(registry.claim(windowId: 52, pid: 18301, bundleId: appId, firstSeenUptime: registry.now(),
            document: pinned.absoluteString) === tab)
    }

    func testAPinnedDocumentWhoseFileIsGoneOpensNothing() async throws {
        let pinned = try file("report.txt")
        let (tab, _) = try emptyPinnedDocument("doc", file: pinned)
        try FileManager.default.removeItem(at: pinned)
        _ = try file("report.txt", "replaced by something else\n")
        var asked: [NewWindowRequestTarget] = []

        openSavedTabApps(tab) { target, _ in asked.append(target) }

        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.body.hasPrefix("Can't find “report.txt”") == true)
        XCTAssertEqual(asked, [], "No fallback to the app")
        await settle()
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(NewWindowIntentRegistry.shared.hasDocumentIntent(bundleId: appId))
    }

    func testADocumentAlreadyOpenElsewhereIsShownThereNotMoved() async throws {
        let pinned = try file("report.txt")
        let (pin, _) = try emptyPinnedDocument("doc", file: pinned)
        let (other, window) = makeTab("other", windowId: 61, showing: pinned)
        candidates = [window]

        openSavedTabApps(pin) { _, _ in XCTFail("The app isn't asked") }

        let told = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(told)
        XCTAssertTrue(notices.first?.body.contains("already open in") == true)
        let focused = await eventually { focus.windowOrNil === window }
        XCTAssertTrue(focused, "Focused where it is")
        XCTAssertTrue(window.nodeWorkspace === other, "It stays where it is")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(NewWindowIntentRegistry.shared.hasDocumentIntent(bundleId: appId))
    }

    func testAFailedOpenOrNoWindowSaysSoAndPlacesNothing() async throws {
        let pinned = try file("report.txt")
        let (tab, _) = try emptyPinnedDocument("doc", file: pinned)
        openFailure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "the app refused"])

        openSavedTabApps(tab) { _, _ in }

        let failed = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(failed)
        XCTAssertTrue(notices.first?.body.contains("couldn't open “report.txt”: the app refused") == true)
        XCTAssertFalse(NewWindowIntentRegistry.shared.hasDocumentIntent(bundleId: appId))

        // The app took it but no window showing that file came: it says so once the wait is over.
        openFailure = nil
        notices = []
        let registry = NewWindowIntentRegistry.shared
        var clock: TimeInterval = 5000
        registry.now = { clock }
        openSavedTabApps(tab) { _, _ in }
        let waiting = await eventually { registry.hasDocumentIntent(bundleId: self.appId) && self.opened.count == 2 }
        XCTAssertTrue(waiting)
        clock += 10 * newWindowIntentTimeout
        registry.expireOverdueIntents()
        let timedOut = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(timedOut)
        XCTAssertEqual(notices.first?.body, "Viewer didn't open “report.txt”.")
        XCTAssertTrue(tab.allLeafWindowsRecursive.isEmpty)
    }

    func testAnOrdinaryPinStillOpensItsApp() throws {
        var record = SavedWorkspaceRecord(workspaceName: "plain")
        record.launchApps = [SavedLaunchApp(bundleId: appId)]
        savedWorkspaceStore.insert(record)
        materializeSavedWorkspaceNames()
        let tab = try XCTUnwrap(Workspace.existing(byName: "plain"))
        try setWorkspaceSidebarTabFavorite(tab, true)
        var asked: [String] = []

        openSavedTabApps(tab) { target, _ in asked.append(target.bundleId) }

        XCTAssertEqual(asked, [appId])
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: - F4: the file is found again right before the app is asked

    private func reopenWhileItsSearchWaits(_ change: (URL) throws -> Void) async throws -> (pinned: URL, tab: Workspace) {
        let pinned = try file("report.txt")
        let (tab, _) = try emptyPinnedDocument("doc", file: pinned)
        let (_, window) = makeTab("other", windowId: 61, showing: nil)
        candidates = [window]
        axGate.close()
        openSavedTabApps(tab) { _, _ in XCTFail("No fallback to the app") }
        let searching = await eventually { self.axGate.waiting == 1 }
        XCTAssertTrue(searching)
        try change(pinned)
        axGate.open()
        await settle()
        return (pinned, tab)
    }

    func testAFileReplacedWhileTheSearchWaitsIsNotOpened() async throws {
        _ = try await reopenWhileItsSearchWaits { pinned in
            _ = try FileManager.default.replaceItemAt(pinned, withItemAt: try self.file("replacement.tmp", "replacement\n"))
        }
        XCTAssertTrue(opened.isEmpty, "Zero opens")
        XCTAssertTrue(notices.first?.body.hasPrefix("Can't find “report.txt”") == true)
        XCTAssertFalse(NewWindowIntentRegistry.shared.hasDocumentIntent(bundleId: appId))
    }

    func testAFileDeletedWhileTheSearchWaitsIsNotOpened() async throws {
        _ = try await reopenWhileItsSearchWaits { pinned in try FileManager.default.removeItem(at: pinned) }
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(notices.first?.body.hasPrefix("Can't find") == true)
    }

    func testAFileRenamedWhileTheSearchWaitsOpensWhereItIsNow() async throws {
        let renamed = folder.appendingPathComponent("renamed.txt")
        _ = try await reopenWhileItsSearchWaits { pinned in try FileManager.default.moveItem(at: pinned, to: renamed) }
        let opening = await eventually { !self.opened.isEmpty }
        XCTAssertTrue(opening)
        XCTAssertEqual(opened.map(\.file.lastPathComponent), ["renamed.txt"], "The fresh path, not the one found before the wait")
    }

    // MARK: - F3: a changed pin withdraws its request, waiting or claimed

    private func clickAndWaitForRequest(_ tab: Workspace) async {
        openSavedTabApps(tab) { _, _ in }
        let waiting = await eventually { NewWindowIntentRegistry.shared.hasDocumentIntent(bundleId: self.appId) && !self.opened.isEmpty }
        XCTAssertTrue(waiting)
    }

    func testForgetWhileItsDocumentOpensWithdrawsTheRequest() async throws {
        let pinned = try file("report.txt")
        let (tab, _) = try emptyPinnedDocument("doc", file: pinned)
        await clickAndWaitForRequest(tab)

        forgetPinDocumentFromSidebar(tab.name)
        let forgot = await eventually { self.appearance("doc")?.document == nil }
        XCTAssertTrue(forgot)

        let registry = NewWindowIntentRegistry.shared
        XCTAssertFalse(registry.hasDocumentIntent(bundleId: appId))
        XCTAssertNil(registry.claim(windowId: 71, pid: 18301, bundleId: appId, firstSeenUptime: registry.now(),
            document: pinned.absoluteString), "Its window goes the usual way")
        XCTAssertEqual(notices, [])
    }

    func testUndoWhileItsDocumentOpensWithdrawsTheRequest() async throws {
        let pinned = try file("report.txt")
        let (tab, _) = try emptyPinnedDocument("doc", file: pinned)
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin Document")
        await clickAndWaitForRequest(tab)

        try WorkspaceSidebarTabUndo.shared.undo()

        XCTAssertNil(appearance("doc")?.document)
        let registry = NewWindowIntentRegistry.shared
        XCTAssertFalse(registry.hasDocumentIntent(bundleId: appId), "Undone: withdrawn")
        XCTAssertNil(registry.claim(windowId: 72, pid: 18301, bundleId: appId, firstSeenUptime: registry.now(),
            document: pinned.absoluteString))
        XCTAssertEqual(notices, [])
    }

    func testRetargetingWhileItsDocumentOpensWithdrawsTheRequest() async throws {
        let pinned = try file("report.txt")
        let (tab, _) = try emptyPinnedDocument("doc", file: pinned)
        await clickAndWaitForRequest(tab)

        commit(tab, try document(try file("other.txt")), title: "Update Document")

        let registry = NewWindowIntentRegistry.shared
        XCTAssertFalse(registry.hasDocumentIntent(bundleId: appId), "The old file's request is withdrawn")
        XCTAssertNil(registry.claim(windowId: 72, pid: 18301, bundleId: appId, firstSeenUptime: registry.now(),
            document: pinned.absoluteString), "So the old file's window doesn't come into the retargeted pin")
    }

    func testAChangeAfterTheWindowWasClaimedLetsItGoTheUsualWay() async throws {
        let pinned = try file("report.txt")
        let (tab, _) = try emptyPinnedDocument("doc", file: pinned)
        await clickAndWaitForRequest(tab)
        let registry = NewWindowIntentRegistry.shared
        XCTAssertTrue(registry.claim(windowId: 73, pid: 18301, bundleId: appId, firstSeenUptime: registry.now(),
            document: pinned.absoluteString) === tab)
        // Bound to the pin by the claim, not placed yet.
        let window = TestWindow.new(id: 73, parent: tab.rootTilingContainer, app: app)

        try setWorkspaceSidebarTabFavorite(tab, false)

        let claim = try XCTUnwrap(registry.consumeClaim(windowId: 73))
        XCTAssertTrue(claim.isWithdrawn, "No placement, focus or report for an unpinned tab")
        placeWithdrawnNewWindow(window, claim: claim)
        XCTAssertFalse(window.nodeWorkspace === tab)
        XCTAssertEqual(notices, [])
    }

    func testAChangeWhileTheAppIsAskedWithdrawsTheRequest() async throws {
        let pinned = try file("report.txt")
        let (tab, _) = try emptyPinnedDocument("doc", file: pinned)
        openGate.close()
        openSavedTabApps(tab) { _, _ in }
        let asking = await eventually { self.openGate.waiting == 1 }
        XCTAssertTrue(asking)

        commit(tab, nil, title: "Forget Document")
        openGate.open()
        await settle()

        XCTAssertFalse(NewWindowIntentRegistry.shared.hasDocumentIntent(bundleId: appId))
        XCTAssertEqual(notices, [])
    }

    func testFocusingAnAlreadyOpenWindowIsCheckedAgainInItsOwnSession() async throws {
        let pinned = try file("report.txt")
        let (pin, _) = try emptyPinnedDocument("doc", file: pinned)
        let (_, window) = makeTab("other", windowId: 61, showing: pinned)
        candidates = [window]
        let work = Workspace.get(byName: "work")
        _ = TestWindow.new(id: 62, parent: work.rootTilingContainer, app: TestApp(pid: 77, bundleId: "com.example.editor"))
        XCTAssertTrue(work.focusWorkspace())
        focusGate.close()

        openSavedTabApps(pin) { _, _ in }
        let queued = await eventually { self.focusGate.waiting == 1 }
        XCTAssertTrue(queued)
        commit(pin, nil, title: "Forget Document")
        focusGate.open()
        await settle()

        XCTAssertFalse(focus.windowOrNil === window, "The pin changed before its turn: nothing is focused for it")
    }

    // MARK: - F6: revealing a document open on another display keeps the pointer

    /// Two synthetic displays: Left shows "work", focused; Right shows "other", whose one window shows
    /// `file`. The pinned document "doc" has no window. Sessions run, with the sidebar off so no panel
    /// is framed; `on-focused-monitor-changed` is recorded instead of run, and no pointer can move.
    private func documentOpenOnTheOtherDisplay(_ file: URL) throws -> (pin: Workspace, work: Workspace, other: Workspace,
                                                                       window: Window, monitors: [Monitor]) {
        config.workspaceSidebar.enabled = false
        let monitors: [Monitor] = ["Left", "Right"].enumerated().map { index, name in
            let rect = Rect(topLeftX: CGFloat(index) * 1920, topLeftY: 0, width: 1920, height: 1080)
            return WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: index + 1, name: name, rect: rect,
                visibleRect: rect, isMain: index == 0)
        }
        setMonitorsForTests(monitors)
        Workspace.reconcileWorkspaceState()
        let (pin, _) = try emptyPinnedDocument("doc", file: file)
        let work = Workspace.get(byName: "work")
        _ = TestWindow.new(id: 62, parent: work.rootTilingContainer, app: TestApp(pid: 77, bundleId: "com.example.editor"))
        let (other, window) = makeTab("other", windowId: 61, showing: file)
        XCTAssertTrue(monitors[0].setActiveWorkspace(work))
        XCTAssertTrue(monitors[1].setActiveWorkspace(other))
        XCTAssertTrue(work.focusWorkspace())
        checkOnFocusChangedCallbacks()
        candidates = [window]
        return (pin, work, other, window, monitors)
    }

    private func recordMonitorHooks() -> () -> [String] {
        let savedHooks = runFocusedMonitorChangedCommands
        let savedMove = postMoveMouseEvent
        var hooks: [String] = []
        runFocusedMonitorChangedCommands = { focus, keepsPointer in hooks.append("\(focus.workspace.name) keepsPointer=\(keepsPointer)") }
        postMoveMouseEvent = { _ in XCTFail("No real pointer move"); return false }
        addTeardownBlock { @MainActor in
            runFocusedMonitorChangedCommands = savedHooks
            postMoveMouseEvent = savedMove
            setMonitorsForTests(nil)
        }
        return { hooks }
    }

    func testRevealingADocumentOpenOnAnotherDisplayKeepsThePointerForThatChangeOnly() async throws {
        let hooks = recordMonitorHooks()
        let pinned = try file("report.txt")
        let (pin, work, other, window, monitors) = try documentOpenOnTheOtherDisplay(pinned)
        XCTAssertEqual(hooks(), [])

        openSavedTabApps(pin) { _, _ in XCTFail("The app isn't asked") }

        let focused = await eventually { focus.windowOrNil === window }
        XCTAssertTrue(focused, "Focused where it is, on Right")
        let hooked = await eventually { !hooks().isEmpty }
        XCTAssertTrue(hooked)
        XCTAssertEqual(hooks(), ["other keepsPointer=true"], "The reveal's own display change keeps the pointer")
        XCTAssertTrue(window.nodeWorkspace === other, "Same window, same tab")
        XCTAssertTrue(monitors[1].activeWorkspace === other, "Still on its own display")
        XCTAssertTrue(pin.allLeafWindowsRecursive.isEmpty, "Nothing moved into the pin")
        XCTAssertTrue(opened.isEmpty, "Nothing opened")
        XCTAssertTrue(notices.first?.body.contains("already open in") == true)

        // A later change of display, not the reveal's, is as always.
        XCTAssertTrue(work.focusWorkspace())
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(hooks(), ["other keepsPointer=true", "work keepsPointer=false"])
    }

    func testACancelledRevealOnAnotherDisplayFocusesNothingAndKeepsNothing() async throws {
        let hooks = recordMonitorHooks()
        let pinned = try file("report.txt")
        let (pin, _, other, window, _) = try documentOpenOnTheOtherDisplay(pinned)
        focusGate.close()

        openSavedTabApps(pin) { _, _ in XCTFail("The app isn't asked") }
        let queued = await eventually { self.focusGate.waiting == 1 }
        XCTAssertTrue(queued)
        commit(pin, nil, title: "Forget Document")
        focusGate.open()
        await settle()

        XCTAssertFalse(focus.windowOrNil === window, "Withdrawn: nothing is focused for it")
        XCTAssertEqual(hooks(), [], "No display change")
        // Nothing was kept for a later change either.
        XCTAssertTrue(other.focusWorkspace())
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(hooks(), ["other keepsPointer=false"])
    }

    // MARK: - Generic placement leaves pinned documents alone

    func testAWindowOfTheAppDoesntGoIntoAnEmptyPinnedDocument() throws {
        let (pin, _) = try emptyPinnedDocument("doc", file: try file("report.txt"))
        let work = Workspace.get(byName: "work")
        _ = TestWindow.new(id: 40, parent: work.rootTilingContainer, app: TestApp(pid: 77, bundleId: "com.example.editor"))
        XCTAssertTrue(work.focusWorkspace())
        let window = TestWindow.new(id: 71, parent: work.rootTilingContainer, app: app)

        XCTAssertFalse(moveNewWindowToEmptyPinIfNeeded(window, detectedIn: work, isNewRegularWindow: true))
        XCTAssertTrue(pin.allLeafWindowsRecursive.isEmpty)

        // The same pin, as an ordinary pin, is its app's home as before.
        commit(pin, nil, title: "Forget Document")
        XCTAssertTrue(moveNewWindowToEmptyPinIfNeeded(window, detectedIn: work, isNewRegularWindow: true))
        XCTAssertTrue(window.nodeWorkspace === pin)
    }

    func testSavedRoutingDoesntPutAnotherWindowIntoAPinnedDocument() async throws {
        let layout = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [
            savedSlot("viewer", bundleId: appId, title: "report.txt", windowId: 900, pid: 18299),
        ]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "doc", displayName: "Report", layout: layout))
        materializeSavedWorkspaceNames()
        let pin = try XCTUnwrap(Workspace.existing(byName: "doc"))
        commit(pin, try document(try file("report.txt")))
        savedWorkspaceRuntime.manualArmUntilByBundleId[appId] = savedWorkspaceRuntime.now.addingTimeInterval(60)
        let work = Workspace.get(byName: "work")
        let relaunched = TestApp(pid: 18302, bundleId: appId)
        let window = TestWindow.new(id: 72, parent: work.rootTilingContainer, app: relaunched)

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)
        XCTAssertFalse(routed, "Not by title, not as the app's only waiting place")
        XCTAssertTrue(window.nodeWorkspace === work)

        // Without its document, the same place takes the app's window as before.
        commit(pin, nil, title: "Forget Document")
        let routedOrdinary = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)
        XCTAssertTrue(routedOrdinary)
        XCTAssertTrue(window.nodeWorkspace === pin)
    }
}
