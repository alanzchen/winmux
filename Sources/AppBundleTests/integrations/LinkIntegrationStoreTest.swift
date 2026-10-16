@testable import AppBundle
import Foundation
import XCTest

/// The user's integrations: added off, turned on only for the scripts the user looked at, kept across
/// restarts, and never written over a file WinMux can't fully read. Imports read Hookmark's records and run
/// none. The records here are written for these tests.
@MainActor
final class LinkIntegrationStoreTest: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-integrations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private var fileURL: URL { directory.appendingPathComponent("link-integrations.json") }

    private func pasted(_ bundleId: String = "com.example.Notebook", getAddress: String = "return \"x-notebook://1\"") throws
        -> LinkIntegration {
        try makePastedLinkIntegration(bundleId: bundleId, appName: "Notebook", getAddress: getAddress, getName: nil,
            openItem: "open location \"$0\"", newItem: nil, scheme: "x-notebook")
    }

    func testAddedIntegrationsAreOffAndOnlyTheScriptsLookedAtAreTrusted() throws {
        let store = LinkIntegrationStore(url: fileURL)
        var added = try pasted()
        added.isEnabled = true
        added.trustedDigest = added.digest
        try store.add([added])
        let kept = try XCTUnwrap(store.integration(forBundleId: "com.example.Notebook"))
        XCTAssertFalse(kept.isEnabled, "Never on as added")
        XCTAssertFalse(kept.isActive)

        XCTAssertThrowsError(try store.setEnabled(id: kept.id, true, trustingDigest: "something else"))
        XCTAssertThrowsError(try store.setEnabled(id: kept.id, true), "Turning on needs the scripts looked at")
        try store.setEnabled(id: kept.id, true, trustingDigest: kept.digest)
        XCTAssertTrue(try XCTUnwrap(store.integration(id: kept.id)).isActive)

        var renamed = try XCTUnwrap(store.integration(id: kept.id))
        renamed.appName = "Notebook Pro"
        try store.update(renamed)
        let afterRename = try XCTUnwrap(store.integration(id: kept.id))
        XCTAssertFalse(afterRename.isActive, "$$ is the app name: a new name is new code")
        XCTAssertNotNil(afterRename.editedAt)

        try store.setEnabled(id: kept.id, true, trustingDigest: afterRename.digest)
        var newItemOnly = try XCTUnwrap(store.integration(id: kept.id))
        newItemOnly.newItem = "make new note"
        try store.update(newItemOnly)
        XCTAssertTrue(try XCTUnwrap(store.integration(id: kept.id)).isActive, "New Item never runs: still trusted")

        XCTAssertThrowsError(try store.add([try pasted()])) { error in
            XCTAssertEqual(error as? LinkIntegrationError, .duplicateApp("Notebook"))
        }
    }

    func testHookmarksOwnSchemesNeverGoToAnIntegrationEvenFromAHandEditedFile() {
        var hooked = LinkIntegration(bundleId: "com.example.Hooked", appName: "Hooked", getAddress: "return 1",
            openItem: "open location \"$0\"", scheme: "hook", source: .init(kind: .pasted))
        hooked.isEnabled = true
        hooked.trustedDigest = hooked.digest
        let store = LinkIntegrationStore(integrations: [hooked])
        XCTAssertEqual(store.opener(forScheme: "hook"), .none)
        XCTAssertEqual(store.opener(forScheme: "HOOKMARK"), .none)
    }

    func testAnUnsupportedIntegrationCantBeTurnedOn() throws {
        let store = LinkIntegrationStore()
        let hookmark = try pasted(getAddress: "tell application \"Hookmark\" to return address of current node")
        try store.add([hookmark])
        XCTAssertThrowsError(try store.setEnabled(id: hookmark.id, true, trustingDigest: hookmark.digest))
        XCTAssertFalse(try XCTUnwrap(store.integration(id: hookmark.id)).isEnabled)
    }

    func testIntegrationsAreKeptAcrossRestartsAndAFileThatCantBeReadIsLeftAlone() throws {
        let store = LinkIntegrationStore(url: fileURL)
        let added = try pasted()
        try store.add([added])
        try store.setEnabled(id: added.id, true, trustingDigest: added.digest)

        let reloaded = LinkIntegrationStore.load(url: fileURL, readOnly: false)
        XCTAssertNil(reloaded.readOnlyReason)
        XCTAssertEqual(reloaded.integrations, store.integrations)
        XCTAssertTrue(reloaded.integrations.first?.isActive == true)

        let readOnly = LinkIntegrationStore.load(url: fileURL, readOnly: true)
        XCTAssertNotNil(readOnly.readOnlyReason)
        XCTAssertThrowsError(try readOnly.remove(id: added.id))

        try Data("{ not json".utf8).write(to: fileURL)
        let damaged = LinkIntegrationStore.load(url: fileURL, readOnly: false)
        XCTAssertTrue(damaged.integrations.isEmpty)
        XCTAssertNotNil(damaged.readOnlyReason)
        XCTAssertThrowsError(try damaged.add([try pasted("com.example.Other")]))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "{ not json", "Nothing written over it")

        try Data(#"{"version":99,"integrations":[]}"#.utf8).write(to: fileURL)
        XCTAssertNotNil(LinkIntegrationStore.load(url: fileURL, readOnly: false).readOnlyReason, "A newer WinMux's file")

        let missing = LinkIntegrationStore.load(url: directory.appendingPathComponent("none.json"), readOnly: false)
        XCTAssertNil(missing.readOnlyReason)
        XCTAssertTrue(missing.integrations.isEmpty)
    }

    func testPastedIntegrationsAreCheckedBeforeTheyreKept() {
        func refusal(_ make: () throws -> LinkIntegration) -> String? {
            do { _ = try make(); return nil } catch { return error.localizedDescription }
        }
        XCTAssertNotNil(refusal { try makePastedLinkIntegration(bundleId: "not a bundle id", appName: "", getAddress: "return 1",
            getName: nil, openItem: nil, newItem: nil, scheme: nil) })
        XCTAssertNotNil(refusal { try makePastedLinkIntegration(bundleId: "com.example.A", appName: "", getAddress: "  \n",
            getName: nil, openItem: nil, newItem: nil, scheme: nil) })
        XCTAssertNotNil(refusal { try makePastedLinkIntegration(bundleId: "com.example.A", appName: "", getAddress: "return 1",
            getName: nil, openItem: nil, newItem: nil, scheme: "x-a://") })
        for hookmarks in ["hook", "Hookmark"] {
            XCTAssertNotNil(refusal { try makePastedLinkIntegration(bundleId: "com.example.A", appName: "", getAddress: "return 1",
                getName: nil, openItem: "open location \"$0\"", newItem: nil, scheme: hookmarks) }, "Hookmark's own links stay its own")
        }
        XCTAssertNotNil(refusal { try makePastedLinkIntegration(bundleId: "com.example.A", appName: "",
            getAddress: String(repeating: "x", count: linkIntegrationScriptLimit + 1), getName: nil, openItem: nil, newItem: nil,
            scheme: nil) })
        let made = try? makePastedLinkIntegration(bundleId: " com.example.A ", appName: "", getAddress: "return 1", getName: "",
            openItem: "", newItem: nil, scheme: "")
        XCTAssertEqual(made?.bundleId, "com.example.A")
        XCTAssertEqual(made?.appName, "com.example.A")
        XCTAssertNil(made?.getName)
        XCTAssertNil(made?.openItem)
        XCTAssertNil(made?.scheme)
        XCTAssertEqual(made?.source.kind, .pasted)
    }

    // MARK: - Importing

    private func plist(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    func testHookmarkRecordsAreImportedOffWithTheirProvenanceAndNoneRun() throws {
        let data = try plist(["scripts": [
            "com.example.Notebook": ["name": "Notebook", "url": "tell application \"Notebook\" to return URL of front note",
                                     "title": "tell application \"Notebook\" to return name of front note",
                                     "open": "tell application \"Notebook\" to open location \"$0\"", "scheme": "x-notebook",
                                     "new": "tell application \"Notebook\" to make new note named \"$title\"",
                                     "de": ["name": "Notizbuch"]],
            "com.example.Ledger": ["name": "Ledger", "url": "//JavaScript\nApplication('Ledger').selection()[0].url()",
                                   "scripting-method": "x-callback-url"],
            "com.csa.mymeta.default": ["name": "Default", "url": "return \"\""],
            "com.example.Existing": ["name": "Existing", "url": "return 1"],
            "not a bundle id": ["name": "Odd", "url": "return 1"],
            "com.example.NoAddress": ["name": "Nothing"],
            "com.example.BadScheme": ["name": "Bad", "url": "return 1", "scheme": "x bad://"],
            "com.example.HookScheme": ["name": "Hooked", "url": "return 1", "open": "open location \"$0\"", "scheme": "hook"],
            "com.example.NotARecord": "text",
        ]])
        let found = try importHookmarkIntegrations(data, fileName: "Customized.plist", existingBundleIds: ["com.example.Existing"])
        XCTAssertEqual(found.integrations.map(\.bundleId), ["com.example.Ledger", "com.example.Notebook"])
        XCTAssertEqual(Set(found.skipped.map(\.key)), ["com.csa.mymeta.default", "com.example.Existing", "not a bundle id",
                                                       "com.example.NoAddress", "com.example.BadScheme", "com.example.NotARecord",
                                                       "com.example.HookScheme"])
        let notebook = try XCTUnwrap(found.integrations.last)
        XCTAssertEqual(notebook.getName, "tell application \"Notebook\" to return name of front note")
        XCTAssertEqual(notebook.openItem, "tell application \"Notebook\" to open location \"$0\"")
        XCTAssertEqual(notebook.newItem, "tell application \"Notebook\" to make new note named \"$title\"")
        XCTAssertEqual(notebook.scheme, "x-notebook")
        XCTAssertFalse(notebook.isEnabled)
        XCTAssertEqual(notebook.source.kind, .imported)
        XCTAssertEqual(notebook.source.fileName, "Customized.plist")
        XCTAssertEqual(notebook.source.recordKey, "com.example.Notebook")
        XCTAssertEqual(notebook.source.fileDigest?.count, 64)
        XCTAssertEqual(notebook.analysis.verdict, .runsUnchanged)
        XCTAssertEqual(found.integrations.first?.analysis.verdict, .unsupported, "An x-callback-url record")
        XCTAssertTrue(linkIntegrationImportSummary(found).hasPrefix("2 records found: 1 runs unchanged, 1 unsupported; 7 left out."))

        let topLevel = try importHookmarkIntegrations(try plist(["com.example.Notebook": ["name": "Notebook", "url": "return 1"]]),
            fileName: "one.plist")
        XCTAssertEqual(topLevel.integrations.map(\.bundleId), ["com.example.Notebook"])
    }

    func testFilesThatArentHookmarkRecordsAreRefusedWhole() throws {
        XCTAssertThrowsError(try importHookmarkIntegrations(Data("plain text".utf8), fileName: "a.txt"))
        XCTAssertThrowsError(try importHookmarkIntegrations(try plist(["a", "b"]), fileName: "list.plist"))
        XCTAssertThrowsError(try importHookmarkIntegrations(try plist(["scripts": [String: Any]()]), fileName: "empty.plist"))
        XCTAssertThrowsError(try importHookmarkIntegrations(Data(count: linkIntegrationImportFileLimit + 1), fileName: "big.plist"))
        var many: [String: Any] = [:]
        for index in 0 ... linkIntegrationImportRecordLimit { many["com.example.App\(index)"] = ["url": "return 1"] }
        XCTAssertThrowsError(try importHookmarkIntegrations(try plist(["scripts": many]), fileName: "many.plist"))
    }
}
