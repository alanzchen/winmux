@testable import AppBundle
import AppKit
import Common
import XCTest

/// Pin Document: a pin that keeps the file its one window showed, opens that very file again, and
/// takes only a window proven to show it. Files are real temporary files; windows and the app's
/// answers are stand-ins.
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

    private var saved: (ax: @MainActor (Window) async -> String?, candidates: @MainActor (String) -> [Window],
                        appURL: @MainActor (String) -> URL?, open: @MainActor (URL, URL) async throws -> Int32,
                        notice: @MainActor (WinMuxToastNotice) -> Void)?

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
        pinDocumentProofs = [:]
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-pin-document-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saved = (pinDocumentAXDocument, pinDocumentCandidateWindows, pinDocumentAppURL, openPinDocumentFile, showWorkspaceSidebarNotice)
        pinDocumentAXDocument = { [unowned self] window in
            axReads.append(window.windowId)
            return axDocuments[window.windowId]
        }
        pinDocumentCandidateWindows = { [unowned self] bundleId in candidates.filter { $0.app.rawAppBundleId == bundleId } }
        pinDocumentAppURL = { _ in URL(fileURLWithPath: "/Applications/Viewer.app") }
        openPinDocumentFile = { [unowned self] file, app in
            opened.append((file, app))
            if let openFailure { throw openFailure }
            return 18301
        }
        showWorkspaceSidebarNotice = { [unowned self] notice in notices.append(notice) }
    }

    override func tearDown() async throws {
        if let saved {
            pinDocumentAXDocument = saved.ax
            pinDocumentCandidateWindows = saved.candidates
            pinDocumentAppURL = saved.appURL
            openPinDocumentFile = saved.open
            showWorkspaceSidebarNotice = saved.notice
        }
        pinDocumentProofs = [:]
        NewWindowIntentRegistry.shared.resetForTests()
        workspaceSidebarOrganizationStore = .init()
        try? FileManager.default.removeItem(at: folder)
        config = defaultConfig
        try await super.tearDown()
    }

    // MARK: - Helpers

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

    /// A pinned document with no window: its saved place held the viewer's window, now closed.
    private func emptyPinnedDocument(_ name: String, file: URL) throws -> (Workspace, WorkspaceSidebarPinDocument) {
        var record = SavedWorkspaceRecord(workspaceName: name)
        record.launchApps = [SavedLaunchApp(bundleId: appId)]
        savedWorkspaceStore.insert(record)
        materializeSavedWorkspaceNames()
        let tab = try XCTUnwrap(Workspace.existing(byName: name))
        let document = try XCTUnwrap(makeWorkspaceSidebarPinDocument(file, bundleId: appId))
        try setWorkspaceSidebarPinDocument(tab, document)
        return (tab, document)
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
        let document = try XCTUnwrap(makeWorkspaceSidebarPinDocument(pinned, bundleId: appId))
        let identity = try XCTUnwrap(PinDocumentIdentity(fileURL: pinned))

        try FileManager.default.removeItem(at: pinned)
        _ = try file("report.txt", "an unrelated file with the same name\n")

        XCTAssertNotEqual(PinDocumentIdentity(fileURL: pinned), identity, "Same path, same name: still another file")
        XCTAssertNil(resolvePinDocument(document), "The bookmark doesn't stand for whatever is at its path now")
    }

    func testARenamedOrMovedFileIsStillThePinnedFile() throws {
        let pinned = try file("report.txt")
        let identity = try XCTUnwrap(PinDocumentIdentity(fileURL: pinned))
        let document = try XCTUnwrap(makeWorkspaceSidebarPinDocument(pinned, bundleId: appId))
        let sub = folder.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let moved = sub.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: pinned, to: moved)

        let resolved = try XCTUnwrap(resolvePinDocument(document))
        XCTAssertEqual(PinDocumentIdentity(fileURL: resolved.url), identity)
        XCTAssertEqual(resolved.url.lastPathComponent, "renamed.txt")
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

    func testAFailedWriteLeavesTheTabAsItWas() throws {
        let pinned = try file("report.txt")
        let (tab, _) = makeTab("doc", windowId: 21, showing: pinned)
        workspaceSidebarOrganizationStore = .init(readOnlyReason: "read-only for the test")
        let document = try XCTUnwrap(makeWorkspaceSidebarPinDocument(pinned, bundleId: appId))

        XCTAssertThrowsError(try setWorkspaceSidebarPinDocument(tab, document))
        XCTAssertNil(appearance("doc"))
    }

    func testUpdateKeepsTheOldDocumentWhenTheWindowShowsNoFile() async throws {
        let pinned = try file("report.txt")
        let (tab, window) = makeTab("doc", windowId: 21, showing: pinned)
        let document = try XCTUnwrap(makeWorkspaceSidebarPinDocument(pinned, bundleId: appId))
        try setWorkspaceSidebarPinDocument(tab, document)
        axDocuments[window.windowId] = nil

        pinDocumentFromSidebar(tab.name, updating: true)

        let refused = await eventually { !self.notices.isEmpty }
        XCTAssertTrue(refused)
        XCTAssertEqual(appearance("doc")?.document, document)
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
        unpinned.document = try XCTUnwrap(makeWorkspaceSidebarPinDocument(first, bundleId: appId))
        unpinned.setFavorite(false)
        XCTAssertNil(unpinned.document)
    }

    func testFilesWithoutDocumentsStillLoadAndDocumentsRoundTrip() throws {
        let old = #"{"version":1,"collections":[],"workspaces":{"a":{"isFavorite":true}}}"#
        let loaded = try JSONDecoder().decode(WorkspaceSidebarOrganization.self, from: Data(old.utf8))
        XCTAssertNil(loaded.workspaces["a"]?.document)

        var state = WorkspaceSidebarOrganization()
        state.workspaces["a", default: .init()].setFavorite(true)
        state.workspaces["a"]?.document = try XCTUnwrap(makeWorkspaceSidebarPinDocument(try file("report.txt"), bundleId: appId))
        let decoded = try JSONDecoder().decode(WorkspaceSidebarOrganization.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
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
        try? await Task.sleep(nanoseconds: 100_000_000)
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
        let waiting = await eventually { registry.hasDocumentIntent(bundleId: appId) && self.opened.count == 2 }
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
        try setWorkspaceSidebarPinDocument(pin, nil)
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
        try setWorkspaceSidebarPinDocument(pin, try XCTUnwrap(makeWorkspaceSidebarPinDocument(try file("report.txt"), bundleId: appId)))
        savedWorkspaceRuntime.manualArmUntilByBundleId[appId] = savedWorkspaceRuntime.now.addingTimeInterval(60)
        let work = Workspace.get(byName: "work")
        let relaunched = TestApp(pid: 18302, bundleId: appId)
        let window = TestWindow.new(id: 72, parent: work.rootTilingContainer, app: relaunched)

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)
        XCTAssertFalse(routed, "Not by title, not as the app's only waiting place")
        XCTAssertTrue(window.nodeWorkspace === work)

        // Without its document, the same place takes the app's window as before.
        try setWorkspaceSidebarPinDocument(pin, nil)
        let routedOrdinary = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)
        XCTAssertTrue(routedOrdinary)
        XCTAssertTrue(window.nodeWorkspace === pin)
    }

    // MARK: - Keeping the bookmark current

    func testASaveSeenByThePinsOwnWindowKeepsItsDocument() async throws {
        let pinned = try file("report.txt")
        let (tab, window) = makeTab("doc", windowId: 21, showing: pinned)
        let document = try XCTUnwrap(makeWorkspaceSidebarPinDocument(pinned, bundleId: appId))
        try setWorkspaceSidebarPinDocument(tab, document)
        notePinDocumentProof(tab.name, window: window, path: pinned.path)
        // A safe save: the edited copy replaces the file at its path.
        let edited = try file("edited.tmp", "edited and saved\n")
        _ = try FileManager.default.replaceItemAt(pinned, withItemAt: edited)
        XCTAssertNil(resolvePinDocument(document), "The bookmark alone no longer finds it")

        await refreshPinDocument(tab.name)

        let refreshed = try XCTUnwrap(appearance("doc")?.document)
        XCTAssertNotEqual(refreshed, document)
        let resolved = try XCTUnwrap(resolvePinDocument(refreshed))
        XCTAssertEqual(PinDocumentIdentity(fileURL: resolved.url), PinDocumentIdentity(fileURL: pinned))
    }

    func testAWindowShowingAnotherFileOrNeverSeenWithTheDocumentChangesNothing() async throws {
        let pinned = try file("report.txt")
        let other = try file("other.txt")
        let (tab, window) = makeTab("doc", windowId: 21, showing: other)
        let document = try XCTUnwrap(makeWorkspaceSidebarPinDocument(pinned, bundleId: appId))
        try setWorkspaceSidebarPinDocument(tab, document)
        notePinDocumentProof(tab.name, window: window, path: pinned.path)

        await refreshPinDocument(tab.name)
        XCTAssertEqual(appearance("doc")?.document, document, "Another file in its window never retargets the pin")

        // Replaced at its path, with no proof that this window showed it: refused, not guessed.
        pinDocumentProofs = [:]
        axDocuments[window.windowId] = pinned.absoluteString
        _ = try FileManager.default.replaceItemAt(pinned, withItemAt: try file("replacement.tmp", "replacement\n"))
        await refreshPinDocument(tab.name)
        XCTAssertEqual(appearance("doc")?.document, document)
    }

    func testARenamedFileSeenInItsWindowGetsAFreshBookmarkAndName() async throws {
        let pinned = try file("report.txt")
        let (tab, window) = makeTab("doc", windowId: 21, showing: pinned)
        let document = try XCTUnwrap(makeWorkspaceSidebarPinDocument(pinned, bundleId: appId))
        try setWorkspaceSidebarPinDocument(tab, document)
        let renamed = folder.appendingPathComponent("final.txt")
        try FileManager.default.moveItem(at: pinned, to: renamed)
        axDocuments[window.windowId] = renamed.absoluteString

        await refreshPinDocument(tab.name)

        XCTAssertEqual(appearance("doc")?.document?.name, "final.txt")
        XCTAssertEqual(pinDocumentProofs[tab.name]?.path, renamed.standardizedFileURL.path)
    }
}
