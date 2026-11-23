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
        config.workspaceSidebar.enabled = true
        workspaceSidebarOrganizationStore = .init()
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
        workspaceSidebarOrganizationStore = .init()
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

    func testConfiguredLabelsSurviveStartupUntilRestoredIdentitiesAreKnown() async throws {
        let file = try writeConfig("""
            config-version = 2
            [workspace-sidebar.workspace-labels]
                "1" = "Main"
                "2" = "Restored"
                "3" = "Orphan"
            """)
        let before = try Data(contentsOf: file)
        let one = Workspace.get(byName: "1")
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = one.focusWorkspace()
        isDeferringOrphanedWorkspaceLabelCleanup = true
        defer { isDeferringOrphanedWorkspaceLabelCleanup = false }
        let result = try await reload(file)
        XCTAssertTrue(result.isOk)
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: "2"))
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["2"], "Restored")
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["3"], "Orphan")
        let restored = Workspace.get(byName: "2")
        _ = TestWindow.new(id: 2, parent: restored.rootTilingContainer)
        isDeferringOrphanedWorkspaceLabelCleanup = false
        Workspace.reconcileWorkspaceState()
        XCTAssertEqual(workspaceDisplayName("2"), "Restored")
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["3"])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testRuleCreatesLabelledWorkspaceDuringStartupWithoutKeepingItEmpty() async throws {
        let file = try writeConfig("""
            config-version = 2
            [workspace-sidebar.workspace-labels]
                "1" = "Main"
                "chat" = "Discord"
                "orphan" = "Unused"
            [[on-window-detected]]
                if.app-name-regex-substring = 'discord'
                run = ['move-node-to-workspace chat']
            """)
        let one = Workspace.get(byName: "1")
        let window = TestWindow.new(id: 1, parent: one.rootTilingContainer,
            app: TestApp(pid: 42, bundleId: "com.hnc.Discord", name: "Discord"))
        _ = window.focusWindow()
        isDeferringOrphanedWorkspaceLabelCleanup = true
        defer { isDeferringOrphanedWorkspaceLabelCleanup = false }
        let result = try await reload(file)
        XCTAssertTrue(result.isOk)
        XCTAssertNil(Workspace.existing(byName: "chat"))
        try await tryOnWindowDetected(window)
        isDeferringOrphanedWorkspaceLabelCleanup = false
        Workspace.reconcileWorkspaceState()
        let chat = try XCTUnwrap(Workspace.existing(byName: "chat"))
        XCTAssertTrue(window.nodeWorkspace === chat)
        XCTAssertEqual(workspaceDisplayName("chat"), "Discord")
        XCTAssertFalse(chat.isKeptWhenEmpty)
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["orphan"])
    }

    func testExplicitRenameAndResetPreserveOtherSavedLabels() async throws {
        let file = try writeConfig("""
            config-version = 2
            [workspace-sidebar.workspace-labels]
                "1" = "Main"
                "2" = "Saved Two"
                "3" = "Saved Three"
            """)
        let one = Workspace.get(byName: "1")
        one.markAsAutomaticallyNamed()
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = one.focusWorkspace()
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "2"))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "3"))
        let result = try await reload(file)
        XCTAssertTrue(result.isOk)
        try renameWorkspaceForSidebar(workspaceName: "1", displayName: "Work")
        try persistWorkspaceSidebarLabel(workspaceName: "1", label: "Work", targetUrl: file, userInitiated: true)
        let afterRename = parseConfig(try String(contentsOf: file, encoding: .utf8)).config.workspaceSidebar.workspaceLabels
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels, ["1": "Work", "2": "Saved Two", "3": "Saved Three"])
        XCTAssertEqual(afterRename, config.workspaceSidebar.workspaceLabels)
        try resetWorkspaceSidebarName(workspaceName: "1")
        try persistWorkspaceSidebarLabel(workspaceName: "1", label: nil, targetUrl: file, userInitiated: true)
        let afterReset = parseConfig(try String(contentsOf: file, encoding: .utf8)).config.workspaceSidebar.workspaceLabels
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels, ["2": "Saved Two", "3": "Saved Three"])
        XCTAssertEqual(afterReset, config.workspaceSidebar.workspaceLabels)
    }

    func testDeletingExistingWorkspaceClearsOnlyItsLiveOrSavedLabel() throws {
        let one = Workspace.get(byName: "1")
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        let two = Workspace.get(byName: "2")
        _ = TestWindow.new(id: 2, parent: two.rootTilingContainer)
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "3"))
        config.workspaceSidebar.workspaceLabels = ["1": "Main", "2": "Delete", "3": "Saved"]
        try deleteWorkspaceForSidebar(workspaceName: "2")
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["2"])
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["1"], "Main")
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["3"], "Saved")
    }

    func testLabelledPersistentWorkspaceSurvivesBecauseOfItsExplicitConfiguration() async throws {
        let file = try writeConfig("""
            config-version = 2
            persistent-workspaces = ['2']
            [workspace-sidebar]
                enabled = true
                mode = 'tabs'
            [workspace-sidebar.workspace-labels]
                "2" = "Kept by config"
            """)
        let one = Workspace.get(byName: "1")
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        let two = Workspace.get(byName: "2")
        _ = one.focusWorkspace()
        let result = try await reload(file)
        XCTAssertTrue(result.isOk)
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(Workspace.existing(byName: "2") === two)
        XCTAssertTrue(two.isKeptWhenEmpty)
        XCTAssertFalse(workspaceTabIsShown(two), "Config persistence reserves an identity, not a listed empty tab")
        XCTAssertEqual(workspaceDisplayName("2"), "Kept by config")
        try resetWorkspaceSidebarName(workspaceName: "2")
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(Workspace.existing(byName: "2") === two, "The explicit config, not its label, keeps it")
    }

    func testNonPersistentRuleCreatedLabelledWorkspaceClosesAndCanBeRecreated() async throws {
        let file = try writeConfig("""
            config-version = 2
            [workspace-sidebar.workspace-labels]
                "chat" = "Discord"
            [[on-window-detected]]
                if.app-name-regex-substring = 'discord'
                run = ['move-node-to-workspace chat']
            """)
        let one = Workspace.get(byName: "1")
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = one.focusWorkspace()
        isDeferringOrphanedWorkspaceLabelCleanup = true
        defer { isDeferringOrphanedWorkspaceLabelCleanup = false }
        let result = try await reload(file)
        XCTAssertTrue(result.isOk)
        let app = TestApp(pid: 42, bundleId: "com.hnc.Discord", name: "Discord")
        let first = TestWindow.new(id: 10, parent: one.rootTilingContainer, app: app)
        try await tryOnWindowDetected(first)
        isDeferringOrphanedWorkspaceLabelCleanup = false
        let chat = try XCTUnwrap(Workspace.existing(byName: "chat"))
        XCTAssertTrue(first.nodeWorkspace === chat)
        XCTAssertEqual(workspaceDisplayName("chat"), "Discord")
        first.removeClosedWindowFromTree()
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: "chat"))
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["chat"])
        let second = TestWindow.new(id: 11, parent: one.rootTilingContainer, app: app)
        try await tryOnWindowDetected(second)
        let recreated = try XCTUnwrap(Workspace.existing(byName: "chat"))
        XCTAssertFalse(recreated === chat)
        XCTAssertTrue(second.nodeWorkspace === recreated)
        XCTAssertEqual(workspaceDisplayName("chat"), "chat")
        try deleteWorkspaceForSidebar(workspaceName: "chat")
        XCTAssertNil(Workspace.existing(byName: "chat"))
    }

    func testUIRenamedUnsavedTabClosesReleasesItsNumberAndDoesNotLeakItsLabel() throws {
        config.workspaceSidebar.mode = .tabs
        config.workspaceSidebar.saveNamedWorkspaces = false
        let one = Workspace.get(byName: "1")
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = one.focusWorkspace()
        Workspace.reconcileWorkspaceState()
        let tab = createBlankWorkspace(projectId: one.projectId, monitor: mainMonitor)
        XCTAssertEqual(tab.name, "2")
        let window = TestWindow.new(id: 2, parent: tab.rootTilingContainer)
        try renameWorkspaceForSidebar(workspaceName: tab.name, displayName: "Scratch")
        XCTAssertFalse(tab.isSaved)
        XCTAssertFalse(tab.isKeptWhenEmpty)
        window.removeClosedWindowFromTree()
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: "2"))
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["2"])
        let next = createBlankWorkspace(projectId: one.projectId, monitor: mainMonitor)
        XCTAssertEqual(next.name, "2")
        XCTAssertNotEqual(workspaceDisplayName(next.name), "Scratch")
        try renameWorkspaceForSidebar(workspaceName: next.name, displayName: "Temporary")
        try resetWorkspaceSidebarName(workspaceName: next.name)
        XCTAssertNil(config.workspaceSidebar.workspaceLabels[next.name])
    }

    func testAutomaticNamesReservePendingLabelsButOrphansAndCancelledTabsReleaseThem() throws {
        config.workspaceSidebar.mode = .tabs
        let one = Workspace.get(byName: "1")
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = one.focusWorkspace()
        config.workspaceSidebar.workspaceLabels = ["2": "Pending", "3": "Pending too"]
        XCTAssertEqual(nextAutomaticWorkspaceName(), "4")
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["2"])
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["3"])
        let next = newTabWorkspace(projectId: one.projectId, monitor: mainMonitor)
        XCTAssertEqual(next.workspace.name, "2")
        XCTAssertTrue(next.workspace.focusWorkspace())
        closeUnusedNewTab(next)
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: "2"))
        XCTAssertTrue(focus.workspace === one)
        let group = try workspaceSidebarOrganizationStore.create(projectId: one.projectId, workspaceNames: [])
        let grouped = try XCTUnwrap(newTabInSidebarCollection(group.id, monitor: mainMonitor))
        XCTAssertEqual(grouped.workspace.name, "2")
        XCTAssertTrue(grouped.workspace.focusWorkspace())
        closeUnusedNewTab(grouped)
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: "2"))
        XCTAssertTrue(focus.workspace === one)
    }

    func testClosingEmptyLabelledTabDeletesItsIdentityWithoutImplyingRetention() throws {
        config.workspaceSidebar.mode = .tabs
        let one = Workspace.get(byName: "1")
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = one.focusWorkspace()
        let two = createBlankWorkspace(projectId: one.projectId, monitor: mainMonitor)
        try renameWorkspaceForSidebar(workspaceName: two.name, displayName: "Scratch")
        XCTAssertFalse(two.isSaved)
        XCTAssertFalse(two.isKeptWhenEmpty)
        try closeWorkspaceSidebarEmptyTab(two)
        XCTAssertNil(Workspace.existing(byName: two.name))
        XCTAssertNil(config.workspaceSidebar.workspaceLabels[two.name])
        let kept = createBlankWorkspace(projectId: one.projectId, monitor: mainMonitor)
        try renameWorkspaceForSidebar(workspaceName: kept.name, displayName: "Kept")
        try keepWorkspaceWhenEmptyForSidebar(workspaceName: kept.name)
        XCTAssertTrue(workspaceTabIsShown(kept))
        try closeWorkspaceSidebarEmptyTab(kept)
        XCTAssertNil(Workspace.existing(byName: kept.name))
        XCTAssertFalse(kept.isSaved)
        XCTAssertNil(config.workspaceSidebar.workspaceLabels[kept.name])
        let project = createWorkspaceProject().id
        let sole = try XCTUnwrap(Workspace.all.first { $0.projectId == project })
        try renameWorkspaceForSidebar(workspaceName: sole.name, displayName: "Sole named tab")
        try closeWorkspaceSidebarEmptyTab(sole)
        XCTAssertNil(Workspace.existing(byName: sole.name))
        XCTAssertNil(config.workspaceSidebar.workspaceLabels[sole.name])
        XCTAssertTrue(Workspace.all.contains { $0.projectId == project && !$0.isArchived })
    }

    func testWorkspaceAndMoveCommandsUsePositionsDespiteLabelledNumericNames() async throws {
        config.workspaceSidebar.mode = .tabs
        let one = Workspace.get(byName: "1")
        let win1 = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = TestWindow.new(id: 11, parent: one.rootTilingContainer)
        let four = Workspace.get(byName: "4")
        let win4 = TestWindow.new(id: 4, parent: four.rootTilingContainer)
        _ = TestWindow.new(id: 44, parent: four.rootTilingContainer)
        let five = Workspace.get(byName: "5")
        _ = TestWindow.new(id: 5, parent: five.rootTilingContainer)
        let two = Workspace.get(byName: "2")
        _ = TestWindow.new(id: 2, parent: two.rootTilingContainer)
        try renameWorkspaceForSidebar(workspaceName: "2", displayName: "Notes")
        winMuxWorkspaceState.moveWorkspace(two.id, after: five.id)
        _ = win1.focusWindow()
        Workspace.reconcileWorkspaceState()
        XCTAssertEqual(numberedWorkspaceNavigationTabs(current: one).map(\.name), ["1", "4", "5", "2"])
        let focusTwo = try await parseCommand("workspace 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(focusTwo.exitCode.rawValue, 0)
        XCTAssertTrue(focus.workspace === four)
        _ = win1.focusWindow()
        let moveTwo = try await parseCommand("move-node-to-workspace 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(moveTwo.exitCode.rawValue, 0)
        XCTAssertTrue(win1.nodeWorkspace === four)
        _ = win4.focusWindow()
        let moveThree = try await parseCommand("move-node-to-workspace 3").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(moveThree.exitCode.rawValue, 0)
        XCTAssertTrue(win4.nodeWorkspace === five)
        let focusThree = try await parseCommand("workspace 3").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(focusThree.exitCode.rawValue, 0)
        XCTAssertTrue(focus.workspace === five)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["2"], "Notes")
    }
}
