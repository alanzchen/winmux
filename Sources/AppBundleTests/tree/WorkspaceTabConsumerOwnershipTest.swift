import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceTabConsumerOwnershipTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        AuxiliaryWindowRegistry.shared.removeAll()
    }

    override func tearDown() async throws {
        AuxiliaryWindowRegistry.shared.removeAll()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    func testVisibilityChecksDoNotCreateRootsAndKeepOffscreenOwnership() {
        let tab = Workspace.get(byName: "presence")
        tab.rootTilingContainer.unbindFromParent()
        XCTAssertFalse(workspaceHasSidebarVisibleWindows(tab))
        XCTAssertFalse(workspaceHasLifecycleWindows(tab))
        XCTAssertFalse(tab.children.contains { $0 is TilingContainer }, "A bind-path predicate must not create a root")
        let window = TestWindow.new(id: 8901, parent: tab)
        XCTAssertTrue(workspaceHasSidebarVisibleWindows(tab))
        XCTAssertTrue(workspaceHasLifecycleWindows(tab))
        window.layoutReason = .macos(prevParentKind: .workspace, prevWorkspaceName: tab.name)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertFalse(workspaceHasSidebarVisibleWindows(tab))
        XCTAssertTrue(workspaceHasLifecycleWindows(tab))
        window.bind(to: macosNotPresentableWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertFalse(workspaceHasLifecycleWindows(tab))
        XCTAssertEqual(WorkspaceTabSnapshot(tab).member(window.windowId)?.state, .notPresentable)
    }

    func testCloseConfirmationKeepsTheCapturedAuxiliaryRole() throws {
        let tab = Workspace.get(byName: "mail")
        let app = TestApp(pid: 891, bundleId: "com.apple.mail", name: "Mail")
        let opener = TestWindow.new(id: 8911, parent: tab.rootTilingContainer, app: app)
        let compose = TestWindow.new(id: 8912, parent: tab, app: app)
        AuxiliaryWindowRegistry.shared.record(compose.windowId, pid: app.pid, role: .mailCompose, parentWindowId: opener.windowId)
        let plan = WorkspaceTabClosePlan([tab])
        let before = try XCTUnwrap(plan.confirmation(multipleWindowsMessage: "Close windows?"))
        XCTAssertTrue(before.informative.contains("Mail compose"))
        AuxiliaryWindowRegistry.shared.detach(compose)
        XCTAssertEqual(plan.windowCount, 2)
        XCTAssertEqual(plan.confirmation(multipleWindowsMessage: "Close windows?")?.informative, before.informative)
        XCTAssertFalse(try XCTUnwrap(WorkspaceTabClosePlan([tab]).confirmation(multipleWindowsMessage: "Close windows?"))
            .informative.contains("Mail compose"))
    }

    func testAgentWindowDescriptionUsesCapturedPlacement() async throws {
        let tab = Workspace.get(byName: "captured")
        let window = TestWindow.new(id: 8921, parent: tab.rootTilingContainer)
        let member = try XCTUnwrap(WorkspaceTabSnapshot(tab).member(window.windowId))
        let original = try await AgentWindowInfo(member)
        window.bind(to: tab, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let captured = try await AgentWindowInfo(member)
        let current = try await AgentWindowInfo(try XCTUnwrap(WorkspaceTabSnapshot(tab).member(window.windowId)))
        XCTAssertEqual(captured.layout, original.layout)
        XCTAssertNotEqual(captured.layout, "floating")
        XCTAssertEqual(current.layout, "floating")
    }

    func testAgentInventoryIncludesOrphanMinimizedWindowExactlyOnce() async throws {
        let previousName = "deleted-borrower"
        XCTAssertNil(Workspace.existing(byName: previousName))
        let window = TestWindow.new(id: 8931, parent: macosMinimizedWindowsContainer)
        window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: previousName)
        let snapshot = try await AgentSnapshot.query()
        let matches = snapshot.inventory.windows.filter { $0.windowId == window.windowId }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.workspace, previousName)
        XCTAssertEqual(matches.first?.layout, "macos_native_minimized")
        XCTAssertFalse(snapshot.reasoning.panes.contains { $0.windowId == window.windowId })
    }
}
