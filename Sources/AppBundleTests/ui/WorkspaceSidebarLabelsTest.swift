@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class WorkspaceSidebarLabelsTest: XCTestCase {
    private var directory: URL!
    private var previousConfig: Config!
    private var previousConfigUrl: URL!
    private var savedActiveMode: String?

    override func setUp() async throws {
        setUpWorkspacesForTests()
        previousConfig = config
        previousConfigUrl = configUrl
        savedActiveMode = activeMode
        activeMode = nil
        directory = FileManager.default.temporaryDirectory.appending(path: "workspace-sidebar-labels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        resetHotKeys()
        activeMode = savedActiveMode
        config = previousConfig
        configUrl = previousConfigUrl
        resetConfigErrorStateForTests()
        TrayMenuModel.shared.lastReloadConfigContainedWarnings = false
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeConfig(_ text: String) throws -> URL {
        let url = directory.appending(path: "winmux.toml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func reload(_ url: URL) async throws -> ReloadConfigResult {
        try await reloadConfig(args: ReloadConfigCmdArgs(rawArgs: []).copy(\.noGui, true), forceConfigUrl: url)
    }

    func testConfiguredLabelsForUncreatedWorkspacesSurviveStartupReconcileAndApplyWhenCreated() async throws {
        let text = """
            config-version = 2
            persistent-workspaces = ['1', '2', '3']

            [workspace-sidebar.workspace-labels]
                "1" = "id/w"
                "2" = "id/a"
                "3" = "id/c"

            [[on-window-detected]]
                if.app-name-regex-substring = 'discord'
                run = ['move-node-to-workspace 3']
            """
        let file = try writeConfig(text)
        let before = try Data(contentsOf: file)

        let one = Workspace.get(byName: "1")
        _ = one.focusWorkspace()
        let reloaded = try await reload(file)
        XCTAssertTrue(reloaded.isOk, "\(reloaded.stdout)\n\(reloaded.stderr)")
        XCTAssertFalse(configWriteBackSuspended)

        Workspace.reconcileWorkspaceState()
        Workspace.reconcileWorkspaceState()

        XCTAssertNil(Workspace.existing(byName: "2"))
        XCTAssertNil(Workspace.existing(byName: "3"))
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels, ["1": "id/w", "2": "id/a", "3": "id/c"])
        XCTAssertEqual(try Data(contentsOf: file), before, "Config file must not be rewritten to prune uncreated workspace labels")

        // When workspaces appear later, their configured labels apply immediately.
        let two = Workspace.get(byName: "2")
        let three = Workspace.get(byName: "3")
        _ = TestWindow.new(id: 201, parent: two.rootTilingContainer)
        _ = TestWindow.new(id: 301, parent: three.rootTilingContainer)
        Workspace.reconcileWorkspaceState()

        XCTAssertEqual(workspaceDisplayName("1"), "id/w")
        XCTAssertEqual(workspaceDisplayName("2"), "id/a")
        XCTAssertEqual(workspaceDisplayName("3"), "id/c")

        let viewModels = await buildWorkspaceSidebarWorkspaceViewModels(
            currentFocus: focus,
            workspaceLabels: effectiveWorkspaceSidebarLabels(),
            availableMonitors: sortedMonitors,
        )
        let labelsByName = Dictionary(uniqueKeysWithValues: viewModels.map { ($0.name, $0.displayName) })
        XCTAssertEqual(labelsByName["1"], "id/w")
        XCTAssertEqual(labelsByName["2"], "id/a")
        XCTAssertEqual(labelsByName["3"], "id/c")
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testUncreatedWorkspaceLabelsSurviveWithoutPersistentWorkspacesAndApplyOnMove() async throws {
        let text = """
            config-version = 2

            [workspace-sidebar.workspace-labels]
                "1" = "Main"
                "chat" = "Discord"

            [[on-window-detected]]
                if.app-name-regex-substring = 'discord'
                run = ['move-node-to-workspace chat']
            """
        let file = try writeConfig(text)
        let before = try Data(contentsOf: file)

        let one = Workspace.get(byName: "1")
        let window = TestWindow.new(id: 1, parent: one.rootTilingContainer, app: TestApp(pid: 42, bundleId: "com.hnc.Discord", name: "Discord"))
        _ = window.focusWindow()

        let reloaded = try await reload(file)
        XCTAssertTrue(reloaded.isOk)

        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: "chat"))
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["chat"], "Discord")
        XCTAssertEqual(try Data(contentsOf: file), before)

        try await tryOnWindowDetected(window)
        Workspace.reconcileWorkspaceState()

        let chat = try XCTUnwrap(Workspace.existing(byName: "chat"))
        XCTAssertTrue(window.nodeWorkspace === chat)
        XCTAssertEqual(workspaceDisplayName(chat.name), "Discord")
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["chat"], "Discord")
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testExplicitRenameAndResetStillPersistWhilePreservingUncreatedLabels() async throws {
        let text = """
            config-version = 2

            [workspace-sidebar.workspace-labels]
                "1" = "id/w"
                "2" = "id/a"
                "3" = "id/c"
            """
        let file = try writeConfig(text)
        let one = Workspace.get(byName: "1")
        one.markAsAutomaticallyNamed()
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = one.focusWorkspace()

        let reloaded = try await reload(file)
        XCTAssertTrue(reloaded.isOk)
        Workspace.reconcileWorkspaceState()

        try renameWorkspaceForSidebar(workspaceName: "1", displayName: "Work")
        try persistWorkspaceSidebarLabel(workspaceName: "1", label: "Work", targetUrl: file, userInitiated: true)
        let afterRename = parseConfig(try String(contentsOf: file, encoding: .utf8)).config.workspaceSidebar.workspaceLabels
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels, ["1": "Work", "2": "id/a", "3": "id/c"])
        XCTAssertEqual(afterRename, ["1": "Work", "2": "id/a", "3": "id/c"])

        try resetWorkspaceSidebarName(workspaceName: "1")
        try persistWorkspaceSidebarLabel(workspaceName: "1", label: nil, targetUrl: file, userInitiated: true)
        let afterReset = parseConfig(try String(contentsOf: file, encoding: .utf8)).config.workspaceSidebar.workspaceLabels
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels, ["2": "id/a", "3": "id/c"])
        XCTAssertEqual(afterReset, ["2": "id/a", "3": "id/c"])
    }

    func testDeletingExistingWorkspaceClearsItsLabelWithoutAffectingUncreatedLabels() throws {
        let one = Workspace.get(byName: "1")
        one.markAsAutomaticallyNamed()
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        let two = Workspace.get(byName: "2")
        two.markAsAutomaticallyNamed()
        _ = TestWindow.new(id: 2, parent: two.rootTilingContainer)
        config.workspaceSidebar.workspaceLabels = ["1": "id/w", "2": "id/a", "3": "id/c"]

        try deleteWorkspaceForSidebar(workspaceName: "2")
        Workspace.reconcileWorkspaceState()

        XCTAssertNil(config.workspaceSidebar.workspaceLabels["2"])
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["1"], "id/w")
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["3"], "id/c")
    }
}
