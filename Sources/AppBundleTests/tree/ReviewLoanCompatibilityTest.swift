@testable import AppBundle
import AppKit
import Common
import XCTest

/// Same source runs on the new branch and its actual 03b634fa decoder/router.
@MainActor
final class ReviewLoanCompatibilityTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private func fixture() throws -> Data {
        let loan = SavedWindowSlot(id: "loan-slot", bundleId: "com.review.editor", title: "Document",
            lastWindowId: 8801, lastPid: 880)
        let owner = SavedWindowSlot(id: "owner-slot", bundleId: "com.review.editor", title: "Document",
            lastWindowId: 8801, lastPid: 880)
        let file = SavedWorkspacesFile(workspaces: [
            .init(workspaceName: "review-pin", layout: .init(root: savedRoot(.tiles, .h, [.slot(loan)]))),
            .init(workspaceName: "review-borrower", layout: .init(root: savedRoot(.tiles, .h, [.slot(owner)]))),
        ])
        func mark(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if object["id"] as? String == "loan-slot" { object["membership"] = "lentFromPin" }
                return object.mapValues(mark)
            }
            if let array = value as? [Any] { return array.map(mark) }
            return value
        }
        let marked = mark(try JSONSerialization.jsonObject(with: encodeSavedWorkspacesFile(file)))
        return try JSONSerialization.data(withJSONObject: marked, options: [.sortedKeys, .prettyPrinted])
    }

    private func loaded(_ data: Data) throws -> SavedWorkspaceStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("saved-workspaces.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return SavedWorkspaceStore.load(from: url).store
    }

    func testVersionOneLoanMarkerSurvivesTheActualDecoderAndEncoder() throws {
        let store = try loaded(fixture())
        XCTAssertFalse(store.isReadOnly, "Version 1 is accepted for normal use by both builds")
        let encoded = try encodeSavedWorkspacesFile(store.file)
        if let output = ProcessInfo.processInfo.environment["WINMUX_REVIEW_REENCODED_OUTPUT"] {
            try encoded.write(to: URL(fileURLWithPath: output))
        }
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("lentFromPin"),
            "A downgrade rewrite must not erase restoration ownership")
    }

    func testVersionOneRetainedLoanCannotStealBorrowersRestoredWindow() async throws {
        savedWorkspaceStore = try loaded(fixture())
        materializeSavedWorkspaceNames()
        let borrower = try XCTUnwrap(Workspace.existing(byName: "review-borrower"))
        let app = TestApp(pid: 881, bundleId: "com.review.editor", name: "Editor",
            launchDate: savedTestNow.addingTimeInterval(-5))
        let window = TestWindow.new(id: 8811, parent: focus.workspace.rootTilingContainer, app: app, title: "Document")
        XCTAssertFalse(waitingSavedSlots(bundleId: "com.review.editor", routingWindow: window).contains { $0.workspaceName == "review-pin" },
            "A retained loan is a resource, not a competing restore claim")
        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true, wasAdmitted: true)
        XCTAssertTrue(routed)
        XCTAssertTrue(window.nodeWorkspace === borrower,
            "A file written by C must restore Document into review-borrower even after downgrade")
    }
}
