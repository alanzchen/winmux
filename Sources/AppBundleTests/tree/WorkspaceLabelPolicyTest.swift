@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class WorkspaceLabelPolicyTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private func bindings(_ text: String) {
        let parsed = parseConfig("""
            config-version = 2
            [workspace-sidebar]
                enabled = true
                mode = 'tabs'
            [mode.main.binding]
            \(text)
            """)
        XCTAssertTrue(parsed.errors.isEmpty, "\(parsed.errors)")
        config.modes = parsed.config.modes
    }

    func testStockNumberBindingsStayInTheCurrentProjectAfterAnotherTabIsRenamed() async throws {
        bindings("""
            ctrl-2 = 'workspace 2'
            alt-shift-2 = 'move-node-to-workspace 2'
            """)
        let foreign = Workspace.get(byName: "2")
        _ = TestWindow.new(id: 2, parent: foreign.rootTilingContainer)
        try renameWorkspaceForSidebar(workspaceName: foreign.name, displayName: "Notes")
        let project = createWorkspaceProject().id
        let first = Workspace.get(byName: "3")
        first.assignProject(project)
        first.markAsAutomaticallyNamed()
        let window = TestWindow.new(id: 30, parent: first.rootTilingContainer)
        _ = TestWindow.new(id: 31, parent: first.rootTilingContainer)
        let second = Workspace.get(byName: "4")
        second.assignProject(project)
        second.markAsAutomaticallyNamed()
        let secondWindow = TestWindow.new(id: 40, parent: second.rootTilingContainer)
        _ = switchWorkspaceProject(project, on: mainMonitor)
        _ = window.focusWindow()
        Workspace.reconcileWorkspaceState()
        XCTAssertEqual(numberedWorkspaceNavigationTabs(current: first).map(\.name), ["3", "4"])
        let move = try await parseCommand("trigger-binding alt-shift-2 --mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(move.exitCode.rawValue, 0)
        XCTAssertTrue(window.nodeWorkspace === second)
        _ = secondWindow.focusWindow()
        let focus = try await parseCommand("trigger-binding ctrl-2 --mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(focus.exitCode.rawValue, 0)
        XCTAssertTrue(AppBundle.focus.workspace === second)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), project)
        XCTAssertEqual(foreign.projectId, workspaceProjectDefaultId)
    }

    func testConfiguredExactDisplayLabelBindingSelectsThatTabWithoutChangingNumbers() async throws {
        bindings("""
            ctrl-n = 'workspace Notes'
            alt-shift-n = 'move-node-to-workspace Notes'
            """)
        let first = Workspace.get(byName: "1")
        let window = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        _ = TestWindow.new(id: 11, parent: first.rootTilingContainer)
        let second = Workspace.get(byName: "4")
        _ = TestWindow.new(id: 4, parent: second.rootTilingContainer)
        let notes = Workspace.get(byName: "2")
        _ = TestWindow.new(id: 2, parent: notes.rootTilingContainer)
        try renameWorkspaceForSidebar(workspaceName: notes.name, displayName: "Notes")
        winMuxWorkspaceState.moveWorkspace(notes.id, after: second.id)
        _ = window.focusWindow()
        let labelled = try await parseCommand("trigger-binding ctrl-n --mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(labelled.exitCode.rawValue, 0)
        XCTAssertTrue(focus.workspace === notes)
        _ = window.focusWindow()
        let moved = try await parseCommand("trigger-binding alt-shift-n --mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(moved.exitCode.rawValue, 0)
        XCTAssertTrue(window.nodeWorkspace === notes)
        let numbered = try await parseCommand("workspace 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(numbered.exitCode.rawValue, 0)
        XCTAssertTrue(focus.workspace === second)
    }

    func testForeignAndArchivedLabelTargetsAreRejectedWithoutMutatingAnything() async throws {
        let project = createWorkspaceProject().id
        let source = Workspace.get(byName: "source")
        source.assignProject(project)
        let window = TestWindow.new(id: 1, parent: source.rootTilingContainer)
        let target = Workspace.get(byName: "chat")
        target.assignProject(workspaceProjectDefaultId)
        target.preferredMonitorPoint = mainMonitor.rect.topLeftCorner
        let originalPoint = target.preferredMonitorPoint
        config.workspaceSidebar.workspaceLabels["chat"] = "Discord"
        _ = window.focusWindow()
        for archived in [false, true] {
            if archived { target.lifecycle = .archived }
            let originalLifecycle = target.lifecycle
            XCTAssertNil(resolveConfiguredLabelWorkspaceTarget(named: "chat", from: source, monitor: mainMonitor))
            for command in ["workspace chat", "move-node-to-workspace chat"] {
                // Check command resolution before the command-sequence post-refresh legitimately
                // prunes archived workspaces. That cleanup is not a resolver side effect.
                let result = try await parseCommand(command).cmdOrDie.run(.defaultEnv, CmdIo(stdin: .emptyStdin))
                XCTAssertNotEqual(result.rawValue, 0)
                XCTAssertTrue(Workspace.existing(byName: "chat") === target)
                XCTAssertEqual(target.projectId, workspaceProjectDefaultId)
                XCTAssertEqual(target.lifecycle, originalLifecycle)
                XCTAssertEqual(target.preferredMonitorPoint, originalPoint)
                XCTAssertTrue(window.nodeWorkspace === source)
                XCTAssertTrue(focus.workspace === source)
            }
        }
        // Archive rejection also holds inside the current project.
        source.assignProject(workspaceProjectDefaultId)
        XCTAssertNil(resolveConfiguredLabelWorkspaceTarget(named: "chat", from: source, monitor: mainMonitor))
    }

    func testAbsentLiteralLabelTargetIsCreatedInTheCurrentProject() async throws {
        let project = createWorkspaceProject().id
        let source = Workspace.get(byName: "source")
        source.assignProject(project)
        let window = TestWindow.new(id: 1, parent: source.rootTilingContainer)
        config.workspaceSidebar.workspaceLabels["chat"] = "Discord"
        _ = window.focusWindow()
        let result = try await parseCommand("move-node-to-workspace chat").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode.rawValue, 0)
        let target = try XCTUnwrap(Workspace.existing(byName: "chat"))
        XCTAssertTrue(window.nodeWorkspace === target)
        XCTAssertEqual(target.projectId, project)
        XCTAssertFalse(target.isKeptWhenEmpty)
    }

    func testExplicitKeepSurvivesLastWindowCloseAndForgetReallyStopsKeeping() async throws {
        config.workspaceSidebar.saveNamedWorkspaces = true
        let first = Workspace.get(byName: "1")
        _ = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        _ = first.focusWorkspace()
        let tab = Workspace.get(byName: "2")
        let window = TestWindow.new(id: 2, parent: tab.rootTilingContainer)
        try renameWorkspaceForSidebar(workspaceName: tab.name, displayName: "Notes")
        XCTAssertFalse(tab.retainsTabAfterLastWindowCloses)
        let renamed = try XCTUnwrap(workspaceSidebarSavedState(for: tab, runningApps: [:]))
        XCTAssertFalse(renamed.keepWhenEmpty)
        try keepWorkspaceWhenEmptyForSidebar(workspaceName: tab.name)
        XCTAssertEqual(savedWorkspaceStore.record(named: tab.name)?.keepWhenEmpty, true)
        window.removeClosedWindowFromTree()
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(tab.isKeptWhenEmpty)
        XCTAssertTrue(workspaceTabIsShown(tab))
        XCTAssertTrue(Workspace.existing(byName: tab.name) === tab)
        await updateWorkspaceSidebarModel()
        let kept = try XCTUnwrap(TrayMenuModel.shared.workspaceSidebarWorkspaces.first { $0.name == tab.name })
        let menu = workspaceSidebarWorkspaceMenuSections(kept, context: workspaceSidebarWorkspaceMenuContext(workspaceName: tab.name))
        XCTAssertTrue(menu.remove.contains { $0.title == "Stop Keeping Empty Tab" })
        XCTAssertFalse(menu.keep.contains { $0.title == "Keep Tab When Empty" })
        try forgetSavedWorkspaceForSidebar(workspaceName: tab.name)
        XCTAssertFalse(tab.isSaved)
        XCTAssertFalse(tab.isKeptWhenEmpty)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[tab.name], "Notes", "Forget retains the name until ordinary pruning")
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: tab.name))
        XCTAssertNil(config.workspaceSidebar.workspaceLabels[tab.name])
    }
    func testKeepDoesNotMutateAnExistingReadOnlySavedIdentity() throws {
        let tab = Workspace.get(byName: "read-only")
        let record = SavedWorkspaceRecord(workspaceName: tab.name, displayName: "Notes")
        savedWorkspaceStore = SavedWorkspaceStore(file: .init(workspaces: [record]), url: nil, readOnlyReason: "newer")
        XCTAssertThrowsError(try keepWorkspaceWhenEmptyForSidebar(workspaceName: tab.name))
        XCTAssertEqual(savedWorkspaceStore.record(named: tab.name), record)
        XCTAssertFalse(tab.retainsTabAfterLastWindowCloses)
    }

    func testSidebarNumberBindingsAlsoStayPositionalAcrossProjects() async throws {
        config.workspaceSidebar.mode = .sidebar
        try await testStockNumberBindingsStayInTheCurrentProjectAfterAnotherTabIsRenamed()
    }

    func testExistingLiteralNameWinsOverAConfiguredDisplayLabelAlias() async throws {
        bindings("ctrl-n = 'workspace Notes'")
        let literal = Workspace.get(byName: "Notes")
        _ = TestWindow.new(id: 1, parent: literal.rootTilingContainer)
        let labelled = Workspace.get(byName: "2")
        let window = TestWindow.new(id: 2, parent: labelled.rootTilingContainer)
        try renameWorkspaceForSidebar(workspaceName: labelled.name, displayName: "Notes")
        _ = window.focusWindow()
        let result = try await parseCommand("workspace Notes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode.rawValue, 0)
        XCTAssertTrue(focus.workspace === literal)
        _ = window.focusWindow()
        let move = try await parseCommand("move-node-to-workspace Notes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(move.exitCode.rawValue, 0)
        XCTAssertTrue(window.nodeWorkspace === literal)
    }

    func testConfiguredLabelAliasesAreUniqueWithinTheCurrentProjectAndNeverCreateOnRejection() async throws {
        bindings("ctrl-n = 'workspace Notes'")
        let one = Workspace.get(byName: "1")
        let window = TestWindow.new(id: 1, parent: one.rootTilingContainer)
        let two = Workspace.get(byName: "2")
        _ = TestWindow.new(id: 2, parent: two.rootTilingContainer)
        let foreign = Workspace.get(byName: "foreign")
        foreign.assignProject(createWorkspaceProject().id)
        _ = TestWindow.new(id: 3, parent: foreign.rootTilingContainer)
        config.workspaceSidebar.workspaceLabels = [one.name: "Notes", two.name: "Notes", foreign.name: "Notes"]
        _ = window.focusWindow()
        for command in ["workspace Notes", "move-node-to-workspace Notes"] {
            let code = try await parseCommand(command).cmdOrDie.run(.defaultEnv, CmdIo(stdin: .emptyStdin))
            XCTAssertNotEqual(code.rawValue, 0)
            XCTAssertNil(Workspace.existing(byName: "Notes"))
            XCTAssertTrue(window.nodeWorkspace === one)
        }
        config.workspaceSidebar.workspaceLabels.removeValue(forKey: one.name)
        let local = try await parseCommand("workspace Notes").cmdOrDie.run(.defaultEnv, CmdIo(stdin: .emptyStdin))
        XCTAssertEqual(local.rawValue, 0)
        XCTAssertTrue(focus.workspace === two)
        two.lifecycle = .archived
        _ = window.focusWindow()
        let unavailable = try await parseCommand("move-node-to-workspace Notes").cmdOrDie.run(.defaultEnv, CmdIo(stdin: .emptyStdin))
        XCTAssertNotEqual(unavailable.rawValue, 0)
        XCTAssertNil(Workspace.existing(byName: "Notes"))
        XCTAssertTrue(window.nodeWorkspace === one)
        config.workspaceSidebar.workspaceLabels.removeValue(forKey: two.name)
        for command in ["workspace Notes", "move-node-to-workspace Notes"] {
            let foreignOnly = try await parseCommand(command).cmdOrDie.run(.defaultEnv, CmdIo(stdin: .emptyStdin))
            XCTAssertNotEqual(foreignOnly.rawValue, 0)
            XCTAssertNil(Workspace.existing(byName: "Notes"))
            XCTAssertTrue(window.nodeWorkspace === one)
        }
    }

    func testExplicitKeepSurvivesSavedStoreReload() throws {
        let tab = Workspace.get(byName: "kept")
        try keepWorkspaceWhenEmptyForSidebar(workspaceName: tab.name)
        let data = try encodeSavedWorkspacesFile(savedWorkspaceStore.file)
        let decoded = try JSONDecoder().decode(SavedWorkspacesFile.self, from: data)
        savedWorkspaceStore = SavedWorkspaceStore(file: decoded, url: nil)
        materializeSavedWorkspaceNames()
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(Workspace.existing(byName: tab.name) === tab)
        XCTAssertEqual(savedWorkspaceStore.record(named: tab.name)?.keepWhenEmpty, true)
        XCTAssertTrue(tab.retainsTabAfterLastWindowCloses)
        XCTAssertTrue(workspaceTabIsShown(tab))
    }

    func testSidebarSaveDoesNotTurnIntoExplicitKeepWhenSwitchingToTabs() async throws {
        config.workspaceSidebar.mode = .sidebar
        let tab = Workspace.get(byName: "saved")
        let window = TestWindow.new(id: 1, parent: tab.rootTilingContainer)
        XCTAssertTrue(window.focusWindow())
        let task = try XCTUnwrap(saveWorkspaceFromSidebar(tab.name))
        // The action keeps the meaning of the menu that was clicked, even if mode changes
        // while its session waits. A populated visible tab cannot prune before the action.
        config.workspaceSidebar.mode = .tabs
        await task.value
        XCTAssertTrue(tab.isSaved)
        XCTAssertNil(savedWorkspaceStore.record(named: tab.name)?.keepWhenEmpty)
        XCTAssertFalse(tab.isExplicitlyKeptTab)
        window.removeClosedWindowFromTree()
        XCTAssertFalse(workspaceTabIsShown(tab))
    }

    func testFailedKeepWriteRestoresSavedAndRuntimeIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("file-not-directory")
        try Data([0]).write(to: blocker)
        let tab = Workspace.get(byName: "failed-keep")
        tab.markAsTransientBlank()
        savedWorkspaceStore = SavedWorkspaceStore(url: blocker.appendingPathComponent("saved.json"))
        let before = savedWorkspaceStore.file
        let visibleBefore = savedWorkspaceRuntime.visibleOnHomeAtLastCheckpoint
        XCTAssertThrowsError(try keepWorkspaceWhenEmptyForSidebar(workspaceName: tab.name))
        XCTAssertEqual(savedWorkspaceStore.file, before)
        XCTAssertEqual(savedWorkspaceRuntime.visibleOnHomeAtLastCheckpoint, visibleBefore)
        XCTAssertEqual(tab.lifecycle, .transient)
        XCTAssertFalse(tab.isSaved)
        XCTAssertFalse(tab.isExplicitlyKeptTab)
    }

    func testOrphanCleanupVisitsEveryKeyAndPreservesLiveAndSavedLabels() {
        _ = Workspace.get(byName: "live")
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "saved"))
        config.workspaceSidebar.workspaceLabels = ["live": "Live", "saved": "Saved"]
        for index in 0 ..< 128 { config.workspaceSidebar.workspaceLabels["orphan-\(index)"] = "Old" }
        clearOrphanedWorkspaceSidebarLabels()
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels, ["live": "Live", "saved": "Saved"])
    }

}
