import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class SavedWorkspaceLoanOwnershipTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private func installLoan(withBorrower: Bool) {
        var loan = SavedWindowSlot(id: "loan", bundleId: "com.test.editor", appName: "Editor", title: "Document",
            lastWindowId: 8801, lastPid: 880)
        loan.membership = .lentFromPin
        _ = Workspace.get(byName: "pin")
        savedWorkspaceStore.insert(.init(workspaceName: "pin", layout: .init(root: savedRoot(.tiles, .h, [.slot(loan)]))))
        if withBorrower {
            _ = Workspace.get(byName: "borrower")
            let resident = SavedWindowSlot(id: "resident", bundleId: loan.bundleId, appName: "Editor", title: "Document",
                lastWindowId: 8801, lastPid: 880)
            savedWorkspaceStore.insert(.init(workspaceName: "borrower", layout: .init(root: savedRoot(.tiles, .h, [.slot(resident)]))))
        }
        savedWorkspaceRuntime.environment.runningApps = { [:] }
    }

    func testStartupDoesNotLaunchAnAppForARetentionOnlyLoan() async {
        installLoan(withBorrower: false)
        var launched: [String] = []
        savedWorkspaceRuntime.environment.openApplication = { bundle, _ in launched.append(bundle); return true }
        XCTAssertTrue(missingSavedWorkspaceApps(workspaceNames: nil).isEmpty)
        XCTAssertEqual(missingSavedWorkspaceApps(workspaceNames: ["pin"]).map(\.bundleId), ["com.test.editor"])
        let result = await openMissingSavedWorkspaceApps(workspaceNames: nil)
        XCTAssertTrue(result.opened.isEmpty)
        XCTAssertTrue(launched.isEmpty)
    }

    func testStartupUsesBorrowersClaimAndExplicitPinReopenOwnsBeforeLaunch() async throws {
        for explicit in [false, true] {
            setUpWorkspacesForTests()
            setSavedWorkspaceTestEnvironment()
            config.workspaceSidebar.mode = .tabs
            installLoan(withBorrower: true)
            var routedTo: String?
            savedWorkspaceRuntime.environment.openApplication = { bundle, _ in
                XCTAssertEqual(savedWorkspaceRuntime.preferredRestoreWorkspace(bundleId: bundle), explicit ? "pin" : nil)
                let app = TestApp(pid: 881, bundleId: bundle, name: "Editor", launchDate: savedTestNow)
                let window = TestWindow.new(id: 8811, parent: focus.workspace.rootTilingContainer, app: app, title: "Document")
                do {
                    let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)
                    XCTAssertTrue(routed)
                    routedTo = window.nodeWorkspace?.name
                    return true
                } catch {
                    XCTFail("Routing failed: \(error)")
                    return false
                }
            }
            let result = await openMissingSavedWorkspaceApps(workspaceNames: explicit ? ["pin"] : nil)
            XCTAssertEqual(result.opened, ["Editor"])
            XCTAssertEqual(routedTo, explicit ? "pin" : "borrower")
        }
    }

    func testLegacyLayoutMigratesToAnOwnershipAwareEncodingBoundary() throws {
        let legacy = Data(#"{"version":1,"workspaces":[{"id":"p","workspaceName":"pin","layout":{"root":{"children":[{"kind":"slot","slot":{"id":"loan","bundleId":"com.test.editor","title":"Document","membership":"lentFromPin"}}]}}},{"id":"b","workspaceName":"borrower","layout":{"root":{"children":[{"kind":"slot","slot":{"id":"resident","bundleId":"com.test.editor","title":"Document"}}]}}}]}"#.utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("saved-workspaces.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try legacy.write(to: url)
        let store = SavedWorkspaceStore.load(from: url).store
        XCTAssertFalse(store.isReadOnly)
        XCTAssertEqual(store.file.version, 2)
        XCTAssertEqual(store.records[0].layout.allSlots[0].membership, .lentFromPin)
        let encoded = try encodeSavedWorkspacesFile(store.file)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let records = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
        for record in records {
            XCTAssertNil(record["layout"], "A v1 router must not decode v2 ownership as resident claims")
            XCTAssertNotNil(record["content"])
        }
        XCTAssertEqual(try JSONDecoder().decode(SavedWorkspacesFile.self, from: encoded), store.file)
        // Optional diagnostic output is consumed by the actual base decoder/router verification.
        if let output = ProcessInfo.processInfo.environment["WINMUX_REVIEW_EXPORTED_CONTENT"] {
            try encoded.write(to: URL(fileURLWithPath: output))
        }
    }
}
