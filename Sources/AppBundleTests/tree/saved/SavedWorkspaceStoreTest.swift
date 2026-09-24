@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class SavedWorkspaceStoreTest: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "WinMuxSavedWorkspaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileUrl: URL { directory.appending(path: "saved-workspaces.json") }

    private func sampleRecord(_ name: String = "3") -> SavedWorkspaceRecord {
        SavedWorkspaceRecord(
            id: "saved-\(name)",
            workspaceName: name,
            displayName: "Code",
            projectId: WorkspaceProjectId("project-a"),
            namingStyle: .automatic,
            display: SavedDisplayAffinity(uuid: "UUID-A", vendor: 1, model: 2, serial: 3, isBuiltin: false, name: "DELL", lastTopLeft: CGPoint(x: 1920, y: 0)),
            isPinnedToDisplay: true,
            lastVisibleSequence: 7,
            layout: SavedWorkspaceLayout(
                root: savedRoot(.tiles, .h, [
                    savedSlot("a", title: "main.swift — App", windowId: 11, pid: 101, weight: 2, isMostRecent: true),
                    savedContainer(.tabGroup, .v, weight: 1.5, [savedSlot("b", bundleId: "com.test.term"), savedSlot("c", bundleId: "com.test.browser")]),
                ]),
                floating: [SavedWindowSlot(id: "f", bundleId: "com.test.chat", title: "Chat")],
            ),
        )
    }

    func testRoundTripPreservesNestedTreeSlotsAffinityPinAndSequence() throws {
        let store = SavedWorkspaceStore(url: fileUrl, fileWasAbsentAtLoad: true)
        XCTAssertTrue(store.insert(sampleRecord()))
        store.flushNow()

        let (loaded, notice) = SavedWorkspaceStore.load(from: fileUrl)

        XCTAssertNil(notice)
        XCTAssertFalse(loaded.isReadOnly)
        XCTAssertFalse(loaded.fileWasAbsentAtLoad)
        XCTAssertEqual(loaded.records, [sampleRecord()])
        XCTAssertTrue(loaded.hasSlots(bundleId: "com.test.term"))
        XCTAssertTrue(loaded.hasSlots(bundleId: "com.test.chat"))
        XCTAssertFalse(loaded.hasSlots(bundleId: "com.test.other"))
        XCTAssertEqual(savedShape(try XCTUnwrap(loaded.record(named: "3")).layout.root), "h[a t[b c]]")
    }

    func testMissingOptionalKeysDecodeWithDefaults() throws {
        let json = """
            {"workspaces": [{"id": "saved-x", "workspaceName": "x",
              "layout": {"root": {"children": [{"kind": "slot", "slot": {"id": "s", "bundleId": "com.test.app"}}]}}}]}
            """
        try json.write(to: fileUrl, atomically: true, encoding: .utf8)

        let (loaded, notice) = SavedWorkspaceStore.load(from: fileUrl)

        XCTAssertNil(notice)
        let record = try XCTUnwrap(loaded.record(named: "x"))
        XCTAssertEqual(record.projectId, workspaceProjectDefaultId)
        XCTAssertEqual(record.namingStyle, .explicit)
        XCTAssertNil(record.display)
        XCTAssertFalse(record.isPinnedToDisplay)
        XCTAssertEqual(record.layout.root.layout, .tiles)
        XCTAssertEqual(record.layout.root.allSlots.first?.weight, 1)
        XCTAssertEqual(loaded.file.version, savedWorkspacesFileVersion)
    }

    func testNewerVersionLoadsReadOnlyAndNeverOverwritesFile() throws {
        let json = #"{"version": 99, "workspaces": [{"id": "saved-x", "workspaceName": "x", "futureField": 1}]}"#
        try json.write(to: fileUrl, atomically: true, encoding: .utf8)

        let (loaded, notice) = SavedWorkspaceStore.load(from: fileUrl)
        loaded.update(named: "x") { $0.displayName = "Changed" }
        loaded.flushNow()

        XCTAssertNotNil(notice)
        XCTAssertTrue(loaded.isReadOnly)
        XCTAssertEqual(loaded.records.map(\.workspaceName), ["x"])
        XCTAssertEqual(try String(contentsOf: fileUrl, encoding: .utf8), json)
        XCTAssertThrowsError(try ensureSavedWorkspaceRecordIn(loaded))
    }

    private func ensureSavedWorkspaceRecordIn(_ store: SavedWorkspaceStore) throws {
        savedWorkspaceStore = store
        try ensureSavedWorkspaceRecord(Workspace.get(byName: "y"))
    }

    func testCorruptFileMovedAsideStoreStartsEmpty() throws {
        try "{not json".write(to: fileUrl, atomically: true, encoding: .utf8)

        let (loaded, notice) = SavedWorkspaceStore.load(from: fileUrl)

        XCTAssertNotNil(notice)
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertFalse(loaded.isReadOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileUrl.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("saved-workspaces.corrupt-") }.count, 1)
    }

    func testCorruptFileIsRestoredFromThePreviousCopy() throws {
        let store = SavedWorkspaceStore(url: fileUrl, fileWasAbsentAtLoad: true)
        store.insert(sampleRecord("1"))
        store.flushNow()
        let (next, _) = SavedWorkspaceStore.load(from: fileUrl)
        next.insert(sampleRecord("2"))
        next.flushNow()
        try "{broken".write(to: fileUrl, atomically: true, encoding: .utf8)

        let (loaded, notice) = SavedWorkspaceStore.load(from: fileUrl)

        XCTAssertTrue(notice?.contains("previous copy") == true, notice ?? "")
        XCTAssertEqual(loaded.records.map(\.workspaceName), ["1"])
        XCTAssertFalse(loaded.adoptsLabels)
        XCTAssertFalse(loaded.isReadOnly)
    }

    func testFirstWriteOfSessionKeepsPreviousGeneration() throws {
        let first = SavedWorkspaceStore(url: fileUrl, fileWasAbsentAtLoad: true)
        first.insert(sampleRecord("1"))
        first.flushNow()

        let (second, _) = SavedWorkspaceStore.load(from: fileUrl)
        second.insert(sampleRecord("2"))
        second.flushNow()
        second.insert(sampleRecord("3"))
        second.flushNow()

        let backup = directory.appending(path: "saved-workspaces.previous.json")
        let (previous, _) = SavedWorkspaceStore.load(from: backup)
        XCTAssertEqual(previous.records.map(\.workspaceName), ["1"])
        XCTAssertEqual(SavedWorkspaceStore.load(from: fileUrl).store.records.map(\.workspaceName), ["1", "2", "3"])
    }

    func testDuplicateWorkspaceNamesKeepFirst() throws {
        let json = #"{"workspaces": [{"id": "a", "workspaceName": "x", "displayName": "First"}, {"id": "b", "workspaceName": "x", "displayName": "Second"}]}"#
        try json.write(to: fileUrl, atomically: true, encoding: .utf8)

        let (loaded, _) = SavedWorkspaceStore.load(from: fileUrl)

        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertEqual(loaded.record(named: "x")?.displayName, "First")
    }

    func testUnchangedContentIsNotRewritten() throws {
        let store = SavedWorkspaceStore(url: fileUrl, fileWasAbsentAtLoad: true)
        store.insert(sampleRecord())
        store.flushNow()
        let before = try FileManager.default.attributesOfItem(atPath: fileUrl.path)[.modificationDate] as? Date
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: fileUrl.path)

        let (loaded, _) = SavedWorkspaceStore.load(from: fileUrl)
        loaded.update(named: "3") { $0.displayName = "Code" }
        loaded.flushNow()

        XCTAssertNotNil(before)
        let after = try FileManager.default.attributesOfItem(atPath: fileUrl.path)[.modificationDate] as? Date
        XCTAssertEqual(after, Date(timeIntervalSince1970: 0))
    }

    func testReorderFollowsGivenNamesAndKeepsUnknownOrder() {
        let store = SavedWorkspaceStore(url: nil)
        for name in ["a", "b", "c", "d"] { store.insert(SavedWorkspaceRecord(workspaceName: name)) }

        store.reorder(workspaceNamesInOrder: ["c", "a"])

        XCTAssertEqual(store.records.map(\.workspaceName), ["c", "a", "b", "d"])
        XCTAssertEqual(store.record(named: "b")?.workspaceName, "b")
    }
}
