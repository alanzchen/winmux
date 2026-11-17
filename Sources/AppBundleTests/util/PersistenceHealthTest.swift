@testable import AppBundle
import Common
import Foundation
import XCTest

/// Carbon L3-W5 / Astra C1: a state file WinMux couldn't write was dropped with `try?`, so a full disk or a lost
/// folder silently kept the UI ahead of what would come back after a restart. A failed write leaves the state
/// unsaved, is tried again on a bounded schedule, and keeps one menu item, with the details, until a write
/// succeeds; at quit it's logged.
@MainActor
final class PersistenceHealthTest: XCTestCase {
    private var folder: URL!
    /// A file where the state's folder should be: creating the folder fails, as on a lost or read-only volume.
    private var blocker: URL!
    private var retries: [(delay: Duration, run: @MainActor () -> Void)] = []
    private var savedStore: SavedWorkspaceStore!
    private var savedAuxURL: (@MainActor () -> URL?)?
    private var savedWorldURL: (() throws -> URL)?

    override func setUp() async throws {
        setUpWorkspacesForTests()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        blocker = folder.appendingPathComponent("state")
        try Data("not a folder".utf8).write(to: blocker)
        retries = []
        PersistenceHealth.shared.startRetry = { [unowned self] delay, run in
            retries.append((delay, run))
            return Task {}
        }
        savedStore = savedWorkspaceStore
        savedAuxURL = auxiliaryWindowLinksURL
        savedWorldURL = persistedFrozenWorldFileUrl
    }

    override func tearDown() async throws {
        savedWorkspaceStore = savedStore
        if let savedAuxURL { auxiliaryWindowLinksURL = savedAuxURL }
        if let savedWorldURL { persistedFrozenWorldFileUrl = savedWorldURL }
        AuxiliaryWindowRegistry.shared.removeAll()
        PersistenceHealth.shared.resetForTests()
        try? FileManager.default.removeItem(at: folder)
    }

    private var stateURL: URL { blocker.appendingPathComponent("saved-workspaces.json") }

    private func unblock() throws {
        try FileManager.default.removeItem(at: blocker)
    }

    private func storeWithAnUnsavedRecord() -> SavedWorkspaceStore {
        let store = SavedWorkspaceStore(url: stateURL, fileWasAbsentAtLoad: true)
        store.insert(SavedWorkspaceRecord(workspaceName: "tab-notes", displayName: "Notes"))
        return store
    }

    func testAFailedWriteKeepsTheStateUnsavedShowsTheMenuItemAndARetrySavesIt() throws {
        let store = storeWithAnUnsavedRecord()
        store.flushNow()

        let failure = try XCTUnwrap(PersistenceHealth.shared.failures[.savedWorkspaces])
        XCTAssertEqual(failure.attempts, 1)
        let details = try XCTUnwrap(TrayMenuModel.shared.persistenceFailureDetails, "A menu item until a write succeeds")
        XCTAssertEqual(details.description, persistenceFailedMenuTitle)
        XCTAssertTrue(details.body.contains("saved-workspaces.json"), details.body)
        XCTAssertEqual(retries.map(\.delay), [PersistenceHealth.retryDelays[0]])

        try unblock()
        retries.removeFirst().run()
        XCTAssertNil(PersistenceHealth.shared.failures[.savedWorkspaces])
        XCTAssertNil(TrayMenuModel.shared.persistenceFailureDetails)
        let written = try JSONDecoder().decode(SavedWorkspacesFile.self, from: Data(contentsOf: stateURL))
        XCTAssertEqual(written.workspaces.map(\.workspaceName), ["tab-notes"], "The record the failed write held back")
    }

    func testRetriesAreBoundedAndTheNextChangeStillSaves() throws {
        let store = storeWithAnUnsavedRecord()
        store.flushNow()
        var delays: [Duration] = []
        while let retry = retries.first {
            retries.removeFirst()
            delays.append(retry.delay)
            retry.run()
        }
        XCTAssertEqual(delays, PersistenceHealth.retryDelays)
        XCTAssertEqual(PersistenceHealth.shared.failures[.savedWorkspaces]?.attempts, PersistenceHealth.retryDelays.count + 1)
        XCTAssertNotNil(TrayMenuModel.shared.persistenceFailureDetails, "Still shown once the retries are spent")

        try unblock()
        store.insert(SavedWorkspaceRecord(workspaceName: "tab-mail", displayName: "Mail"))
        store.flushNow()
        XCTAssertNil(TrayMenuModel.shared.persistenceFailureDetails)
        let written = try JSONDecoder().decode(SavedWorkspacesFile.self, from: Data(contentsOf: stateURL))
        XCTAssertEqual(written.workspaces.map(\.workspaceName), ["tab-notes", "tab-mail"])
    }

    func testAnEditThatMustKnowSeesTheFailureAndItIsReportedToo() {
        let store = storeWithAnUnsavedRecord()
        XCTAssertThrowsError(try store.flushNowReportingFailure())
        XCTAssertNotNil(PersistenceHealth.shared.failures[.savedWorkspaces])
    }

    func testAFailedFlushAtQuitIsRecordedNotDropped() {
        savedWorkspaceStore = storeWithAnUnsavedRecord()
        persistedFrozenWorldFileUrl = { [blocker] in blocker!.appendingPathComponent("window-state.json") }
        _ = TestWindow.new(id: 70, parent: Workspace.get(byName: "kept").rootTilingContainer)
        prepareManagedWindowsForTermination(runtimeReady: true, restoreWindows: {})
        XCTAssertNotNil(PersistenceHealth.shared.failures[.savedWorkspaces])
        XCTAssertNotNil(PersistenceHealth.shared.failures[.restartWindowState])
        XCTAssertEqual(retries.count, 1, "Only the saved workspaces, which still hold changes, are tried again")
    }

    func testAuxiliaryLinksThatCantBeWrittenAreReportedAndRetried() throws {
        auxiliaryWindowLinksURL = { [blocker] in blocker!.appendingPathComponent("auxiliary-window-links.json") }
        let app = TestApp(pid: 71, bundleId: "com.example.messenger")
        let parent = TestWindow.new(id: 72, parent: Workspace.get(byName: "chat").rootTilingContainer, app: app)
        _ = TestWindow.new(id: 73, parent: Workspace.get(byName: "chat").rootTilingContainer, app: app)
        AuxiliaryWindowRegistry.shared.restore(73, pid: app.pid, role: .dialog, parentWindowId: parent.windowId)
        persistAuxiliaryWindowLinks()
        XCTAssertNotNil(PersistenceHealth.shared.failures[.auxiliaryWindowLinks])
        XCTAssertEqual(retries.count, 1)

        try unblock()
        retries.removeFirst().run()
        XCTAssertNil(PersistenceHealth.shared.failures[.auxiliaryWindowLinks])
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocker.appendingPathComponent("auxiliary-window-links.json").path))
    }

    func testEachFileIsClearedByItsOwnSuccessfulWrite() {
        let error = CocoaError(.fileWriteOutOfSpace)
        PersistenceHealth.shared.recordFailure(.savedWorkspaces, error, .notSaved)
        PersistenceHealth.shared.recordFailure(.auxiliaryWindowLinks, error, .notSaved)
        PersistenceHealth.shared.recordSuccess(.auxiliaryWindowLinks)
        XCTAssertNotNil(TrayMenuModel.shared.persistenceFailureDetails, "saved-workspaces.json is still unsaved")
        XCTAssertFalse(TrayMenuModel.shared.persistenceFailureDetails?.body.contains("auxiliary") ?? true)
        PersistenceHealth.shared.recordSuccess(.savedWorkspaces)
        XCTAssertNil(TrayMenuModel.shared.persistenceFailureDetails)
    }

    // MARK: Review nits (Astra AS-5-N1/N2, Carbon ASD-N2/N3)

    /// The details say what happens next, file by file, and promise no retry that won't run.
    func testTheDetailsSayWhatHappensNextForEachFile() throws {
        let store = storeWithAnUnsavedRecord()
        store.flushNow()
        var body = try XCTUnwrap(TrayMenuModel.shared.persistenceFailureDetails?.body)
        XCTAssertTrue(body.contains("saved-workspaces.json:") && body.contains("Trying again at"), body)
        XCTAssertTrue(TrayMenuModel.shared.canRetryPersistenceNow)

        while let retry = retries.first {
            retries.removeFirst()
            retry.run()
        }
        body = try XCTUnwrap(TrayMenuModel.shared.persistenceFailureDetails?.body)
        XCTAssertFalse(body.contains("Trying again at"), "No retry is scheduled any more: \(body)")
        XCTAssertTrue(body.contains("Will try again on its next change, or with \(persistenceRetryNowMenuTitle)."), body)
        XCTAssertTrue(body.contains("lost if WinMux quits"), body)

        PersistenceHealth.shared.recordFailure(.restartWindowState, CocoaError(.fileWriteOutOfSpace), .notSaved)
        PersistenceHealth.shared.recordFailure(.sidebarOrganization, CocoaError(.fileWriteNoPermission), .changeNotMade)
        body = try XCTUnwrap(TrayMenuModel.shared.persistenceFailureDetails?.body)
        XCTAssertTrue(body.contains("Not saved this session."), body)
        XCTAssertTrue(body.contains("The change wasn't made. Its next change tries again."), body)
    }

    func testTrySavingNowWritesWhatsUnsavedRightAway() throws {
        let store = storeWithAnUnsavedRecord()
        store.flushNow()
        try unblock()
        PersistenceHealth.shared.retryNow()
        XCTAssertNil(PersistenceHealth.shared.failures[.savedWorkspaces])
        XCTAssertFalse(TrayMenuModel.shared.canRetryPersistenceNow)
        XCTAssertNil(TrayMenuModel.shared.persistenceFailureDetails)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testOnlyFilesWithUnsavedChangesCanBeTriedAgain() {
        PersistenceHealth.shared.recordFailure(.sidebarOrganization, CocoaError(.fileWriteNoPermission), .changeNotMade)
        PersistenceHealth.shared.recordFailure(.savedWorkspaces, CocoaError(.fileWriteNoPermission), .notSaved)
        XCTAssertFalse(TrayMenuModel.shared.canRetryPersistenceNow)
        XCTAssertTrue(retries.isEmpty)
    }

    /// A refused sidebar-organization write is reported, for every caller, and the change isn't published.
    func testARefusedSidebarOrganizationWriteIsReportedAndTheChangeIsNotMade() throws {
        let store = WorkspaceSidebarOrganizationStore(url: blocker.appendingPathComponent("sidebar-organization.json"))
        XCTAssertThrowsError(try store.update { $0.workspaces["pin"] = WorkspaceSidebarItemAppearance(isFavorite: true) })
        XCTAssertNil(store.state.workspaces["pin"])
        let failure = try XCTUnwrap(PersistenceHealth.shared.failures[.sidebarOrganization])
        guard case .changeNotMade = failure.recovery else { return XCTFail("\(failure.recovery)") }
        XCTAssertTrue(retries.isEmpty, "A refused change isn't made again behind the user's back")

        try unblock()
        try store.update { $0.workspaces["pin"] = WorkspaceSidebarItemAppearance(isFavorite: true) }
        XCTAssertNil(PersistenceHealth.shared.failures[.sidebarOrganization])
    }

    func testAReadOnlySessionLeavesTheRestartSnapshotAlone() {
        setServerReadOnlyForTests(true)
        defer { setServerReadOnlyForTests(false) }
        let url = folder.appendingPathComponent("window-state.json")
        persistedFrozenWorldFileUrl = { url }
        _ = TestWindow.new(id: 74, parent: Workspace.get(byName: "kept").rootTilingContainer)
        persistFrozenWorldForRestartIfPossible()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(PersistenceHealth.shared.failures[.restartWindowState])
    }
}
