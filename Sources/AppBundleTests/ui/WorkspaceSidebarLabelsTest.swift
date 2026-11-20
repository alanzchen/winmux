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

    func testLabelledPersistentWorkspaceSurvivesEmptyReconcileAndStaysInSidebar() async throws {
        let text = """
            config-version = 2
            persistent-workspaces = ['1', '2', '3']

            [workspace-sidebar.workspace-labels]
                "1" = "id/w"
                "2" = "id/a"
                "3" = "id/c"
            """
        let file = try writeConfig(text)
        let before = try Data(contentsOf: file)

        let one = Workspace.get(byName: "1")
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = one.focusWorkspace()
        let reloaded = try await reload(file)
        XCTAssertTrue(reloaded.isOk)

        // Visit persistent labelled workspace "2" while empty, then leave it and reconcile.
        let two = Workspace.get(byName: "2")
        XCTAssertTrue(two.focusWorkspace())
        XCTAssertEqual(workspaceDisplayName("2"), "id/a")
        XCTAssertTrue(one.focusWorkspace())
        Workspace.reconcileWorkspaceState()

        XCTAssertTrue(Workspace.existing(byName: "2") === two)
        XCTAssertTrue(isUserFacingWorkspace(two))
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["2"], "id/a")
        XCTAssertEqual(workspaceDisplayName("2"), "id/a")
        let viewModels = await buildWorkspaceSidebarWorkspaceViewModels(
            currentFocus: focus,
            workspaceLabels: effectiveWorkspaceSidebarLabels(),
            availableMonitors: sortedMonitors,
        )
        XCTAssertEqual(viewModels.first(where: { $0.name == "2" })?.displayName, "id/a")
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testNonPersistentRuleCreatedWorkspaceWithLabelSurvivesLastWindowCloseUntilDeleted() async throws {
        let text = """
            config-version = 2

            [workspace-sidebar.workspace-labels]
                "1" = "id/w"
                "chat" = "id/c"

            [[on-window-detected]]
                if.app-name-regex-substring = 'discord'
                run = ['move-node-to-workspace chat']
            """
        let file = try writeConfig(text)
        let before = try Data(contentsOf: file)

        let one = Workspace.get(byName: "1")
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = one.focusWorkspace()
        let reloaded = try await reload(file)
        XCTAssertTrue(reloaded.isOk)

        let discordApp = TestApp(pid: 42, bundleId: "com.hnc.Discord", name: "Discord")
        let firstDiscord = TestWindow.new(id: 10, parent: one.rootTilingContainer, app: discordApp)
        try await tryOnWindowDetected(firstDiscord)
        Workspace.reconcileWorkspaceState()

        let chat = try XCTUnwrap(Workspace.existing(byName: "chat"))
        XCTAssertTrue(firstDiscord.nodeWorkspace === chat)
        XCTAssertEqual(workspaceDisplayName("chat"), "id/c")

        // Closing the last window leaves the labelled workspace empty, yet permanent.
        firstDiscord.unbindFromParent()
        Workspace.reconcileWorkspaceState()

        XCTAssertTrue(Workspace.existing(byName: "chat") === chat, "Labelled workspace must survive empty reconcile")
        XCTAssertTrue(isUserFacingWorkspace(chat))
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["chat"], "id/c")
        XCTAssertEqual(workspaceDisplayName("chat"), "id/c")
        let emptyViewModels = await buildWorkspaceSidebarWorkspaceViewModels(
            currentFocus: focus,
            workspaceLabels: effectiveWorkspaceSidebarLabels(),
            availableMonitors: sortedMonitors,
        )
        XCTAssertEqual(emptyViewModels.first(where: { $0.name == "chat" })?.displayName, "id/c")
        XCTAssertEqual(try Data(contentsOf: file), before, "Config file on disk must remain unchanged")

        // Re-opening Discord routes back into the surviving labelled workspace.
        let secondDiscord = TestWindow.new(id: 11, parent: one.rootTilingContainer, app: discordApp)
        try await tryOnWindowDetected(secondDiscord)
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(secondDiscord.nodeWorkspace === chat)
        XCTAssertEqual(workspaceDisplayName("chat"), "id/c")
        XCTAssertEqual(try Data(contentsOf: file), before)

        // Explicit deletion still removes the workspace and clears its label.
        try deleteWorkspaceForSidebar(workspaceName: "chat")
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: "chat"))
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["chat"])
    }

    func testUIRenamedTemporaryWorkspaceSurvivesLastWindowCloseKeepsAutoNumberAndPrunesAfterLabelReset() async throws {
        config.workspaceSidebar.saveNamedWorkspaces = false
        let one = Workspace.get(byName: "1")
        one.markAsAutomaticallyNamed()
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = one.focusWorkspace()
        Workspace.reconcileWorkspaceState()

        let temp = createBlankWorkspace(projectId: workspaceProjectDefaultId, monitor: mainMonitor)
        XCTAssertEqual(temp.name, "2")
        let window = TestWindow.new(id: 2, parent: temp.rootTilingContainer)
        Workspace.reconcileWorkspaceState()

        try renameWorkspaceForSidebar(workspaceName: temp.name, displayName: "Scratch")
        XCTAssertFalse(temp.isSaved)
        XCTAssertEqual(workspaceDisplayName("2"), "Scratch")

        // Closing the last window leaves the UI-renamed workspace alive in the sidebar, keeping number "2".
        window.unbindFromParent()
        Workspace.reconcileWorkspaceState()

        XCTAssertTrue(Workspace.existing(byName: "2") === temp)
        XCTAssertTrue(isUserFacingWorkspace(temp))
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["2"], "Scratch")
        XCTAssertEqual(workspaceDisplayName("2"), "Scratch")
        let viewModels = await buildWorkspaceSidebarWorkspaceViewModels(
            currentFocus: focus,
            workspaceLabels: effectiveWorkspaceSidebarLabels(),
            availableMonitors: sortedMonitors,
        )
        XCTAssertEqual(viewModels.first(where: { $0.name == "2" })?.displayName, "Scratch")

        // Creating a new automatic workspace must get a different number ("3") and never inherit "Scratch".
        let next = createBlankWorkspace(projectId: workspaceProjectDefaultId, monitor: mainMonitor)
        XCTAssertEqual(next.name, "3")
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["3"])
        XCTAssertNotEqual(workspaceDisplayName("3"), "Scratch")

        // An unlabelled empty workspace still prunes automatically.
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: "3"))
        XCTAssertTrue(Workspace.existing(byName: "2") === temp)

        // Resetting the label in the UI makes workspace "2" unlabelled again, so it prunes on reconcile.
        try resetWorkspaceSidebarName(workspaceName: "2")
        Workspace.reconcileWorkspaceState()

        XCTAssertNil(Workspace.existing(byName: "2"))
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["2"])
    }

    func testAutomaticTabCreationSkipsConfiguredLabelNamesAndCancellingDiscardsItWhileExplicitTargetsUseLabel() async throws {
        let text = """
            config-version = 2

            [workspace-sidebar]
            enabled = true
            mode = 'tabs'

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
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = one.focusWorkspace()
        let reloaded = try await reload(file)
        XCTAssertTrue(reloaded.isOk)
        Workspace.reconcileWorkspaceState()

        // Automatic tab creation must skip uncreated names that have a configured label ("2", "3").
        let newTab = newTabWorkspace(projectId: one.projectId, monitor: mainMonitor)
        XCTAssertEqual(newTab.workspace.name, "4")
        XCTAssertTrue(newTab.workspace.focusWorkspace())
        closeUnusedNewTab(newTab)
        Workspace.reconcileWorkspaceState()

        XCTAssertNil(Workspace.existing(byName: "4"))
        XCTAssertNil(Workspace.existing(byName: "2"))
        XCTAssertNil(Workspace.existing(byName: "3"))
        XCTAssertTrue(focus.workspace === one)

        // Cancelling a new placeholder tab inside a sidebar group also skips "2"/"3" and discards cleanly.
        let group = try workspaceSidebarOrganizationStore.create(projectId: one.projectId, workspaceNames: [])
        let groupTab = try XCTUnwrap(newTabInSidebarCollection(group.id, monitor: mainMonitor))
        XCTAssertEqual(groupTab.workspace.name, "4")
        XCTAssertTrue(groupTab.workspace.focusWorkspace())
        closeUnusedNewTab(groupTab)
        Workspace.reconcileWorkspaceState()

        XCTAssertNil(Workspace.existing(byName: "4"))
        XCTAssertNil(Workspace.existing(byName: "2"))
        XCTAssertNil(Workspace.existing(byName: "3"))
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels, ["1": "id/w", "2": "id/a", "3": "id/c"])
        XCTAssertEqual(try Data(contentsOf: file), before)

        // Explicitly focusing workspace "2" by command creates "2" with its configured label "id/a".
        let focusTwo = try await parseCommand("workspace 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(focusTwo.exitCode.rawValue, 0, "\(focusTwo.stderr)")
        XCTAssertEqual(focus.workspace.name, "2")
        XCTAssertEqual(workspaceDisplayName("2"), "id/a")

        // Explicitly moving a window to workspace "3" via on-window-detected creates "3" with label "id/c".
        let discordApp = TestApp(pid: 42, bundleId: "com.hnc.Discord", name: "Discord")
        let discordWindow = TestWindow.new(id: 30, parent: one.rootTilingContainer, app: discordApp)
        try await tryOnWindowDetected(discordWindow)
        Workspace.reconcileWorkspaceState()

        let three = try XCTUnwrap(Workspace.existing(byName: "3"))
        XCTAssertTrue(discordWindow.nodeWorkspace === three)
        XCTAssertEqual(workspaceDisplayName("3"), "id/c")
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testClosingEmptyLabelledUnsavedTabFromSidebarDeletesTabAndClearsLabel() async throws {
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        config.workspaceSidebar.saveNamedWorkspaces = false

        let one = Workspace.get(byName: "1")
        _ = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = one.focusWorkspace()

        let two = createBlankWorkspace(projectId: one.projectId, monitor: mainMonitor)
        let window = TestWindow.new(id: 2, parent: two.rootTilingContainer)
        try renameWorkspaceForSidebar(workspaceName: two.name, displayName: "Scratch")
        XCTAssertFalse(two.isSaved)
        XCTAssertTrue(two.hasConfiguredLabel)

        // Automatic pruning keeps the empty labelled tab.
        window.unbindFromParent()
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(Workspace.existing(byName: two.name) === two)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[two.name], "Scratch")

        // Automatic closeEmptyTab leaves a labelled tab intact.
        closeEmptyTab(two)
        XCTAssertTrue(Workspace.existing(byName: two.name) === two)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[two.name], "Scratch")

        // Clicking Close on the empty labelled unsaved tab in the sidebar deletes it and clears its label.
        try closeWorkspaceSidebarEmptyTab(two)
        Workspace.reconcileWorkspaceState()

        XCTAssertNil(Workspace.existing(byName: two.name))
        XCTAssertNil(config.workspaceSidebar.workspaceLabels[two.name])
    }

    func testWorkspaceAndMoveCommandsAgreeOnLabelledNumericWorkspaceEvenWhenAutoTabsOccupyPosition() async throws {
        let text = """
            config-version = 2

            [workspace-sidebar]
            enabled = true
            mode = 'tabs'

            [workspace-sidebar.workspace-labels]
                "1" = "id/w"
                "2" = "Notes"
                "3" = "Chat"
            """
        let file = try writeConfig(text)
        let before = try Data(contentsOf: file)

        let one = Workspace.get(byName: "1")
        let win1 = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        _ = win1.focusWindow()
        let reloaded = try await reload(file)
        XCTAssertTrue(reloaded.isOk)
        Workspace.reconcileWorkspaceState()

        // Create two automatic tabs while "2" and "3" are absent: they get auto-named "4" and "5"
        // and sit at display positions 2 and 3.
        let tab4 = newTabWorkspace(projectId: one.projectId, monitor: mainMonitor).workspace
        XCTAssertEqual(tab4.name, "4")
        let win4 = TestWindow.new(id: 4, parent: tab4.rootTilingContainer)
        XCTAssertTrue(tab4.focusWorkspace())
        let tab5 = newTabWorkspace(projectId: one.projectId, monitor: mainMonitor).workspace
        XCTAssertEqual(tab5.name, "5")
        _ = TestWindow.new(id: 5, parent: tab5.rootTilingContainer)
        XCTAssertTrue(win1.focusWindow())
        Workspace.reconcileWorkspaceState()

        XCTAssertNil(Workspace.existing(byName: "2"))
        XCTAssertNil(Workspace.existing(byName: "3"))
        XCTAssertEqual(numberedWorkspaceNavigationTabs(current: one).map(\.name), ["1", "4", "5"])

        // `workspace 2` must create and focus workspace "2" ("Notes"), never tab "4" (the 2nd tab).
        let focusTwo = try await parseCommand("workspace 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(focusTwo.exitCode.rawValue, 0, "\(focusTwo.stderr)")
        let two = try XCTUnwrap(Workspace.existing(byName: "2"))
        XCTAssertTrue(focus.workspace === two)
        XCTAssertEqual(workspaceDisplayName(two.name), "Notes")

        // `move-node-to-workspace 2` must target the same workspace "2" ("Notes"), never tab "4".
        XCTAssertTrue(win1.focusWindow())
        let moveToTwo = try await parseCommand("move-node-to-workspace 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(moveToTwo.exitCode.rawValue, 0, "\(moveToTwo.stderr)")
        XCTAssertTrue(win1.nodeWorkspace === two)
        XCTAssertEqual(workspaceDisplayName(two.name), "Notes")

        // Reverse order for "3" ("Chat"): `move-node-to-workspace 3` creates "3" (not 3rd tab "5"),
        // then `workspace 3` focuses that same workspace "3" even though it is not at position 3.
        XCTAssertTrue(win4.focusWindow())
        let moveToThree = try await parseCommand("move-node-to-workspace 3").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(moveToThree.exitCode.rawValue, 0, "\(moveToThree.stderr)")
        let three = try XCTUnwrap(Workspace.existing(byName: "3"))
        XCTAssertTrue(win4.nodeWorkspace === three)
        XCTAssertEqual(workspaceDisplayName(three.name), "Chat")

        XCTAssertTrue(tab5.focusWorkspace())
        let focusThree = try await parseCommand("workspace 3").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(focusThree.exitCode.rawValue, 0, "\(focusThree.stderr)")
        XCTAssertTrue(focus.workspace === three)
        XCTAssertEqual(workspaceDisplayName(three.name), "Chat")
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
}
