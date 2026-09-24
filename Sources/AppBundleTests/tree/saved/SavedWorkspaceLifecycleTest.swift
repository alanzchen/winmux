@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class SavedWorkspaceLifecycleTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testRenameSavesWhenOptionOn() throws {
        config.workspaceSidebar.saveNamedWorkspaces = true
        let workspace = Workspace.get(byName: "1")
        workspace.markAsAutomaticallyNamed()
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        try renameWorkspaceForSidebar(workspaceName: "1", displayName: "  Code ")

        XCTAssertTrue(workspace.isSaved)
        XCTAssertEqual(savedWorkspaceStore.record(named: "1")?.displayName, "Code")
        XCTAssertEqual(savedWorkspaceStore.record(named: "1")?.namingStyle, .automatic)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["1"], "Code")
        XCTAssertEqual(savedWorkspaceStore.record(named: "1")?.layout.root.allSlots.map(\.lastWindowId), [1])
    }

    func testRenameDoesNotSaveWhenOptionOff() throws {
        Workspace.get(byName: "1").markAsAutomaticallyNamed()

        try renameWorkspaceForSidebar(workspaceName: "1", displayName: "Code")

        XCTAssertFalse(Workspace.get(byName: "1").isSaved)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["1"], "Code")
    }

    func testExplicitSaveWorksWithOptionOff() throws {
        let workspace = Workspace.get(byName: "1")
        workspace.markAsAutomaticallyNamed()

        try saveWorkspaceForSidebar(workspaceName: "1", displayName: "Notes")

        XCTAssertTrue(workspace.isSaved)
        XCTAssertEqual(workspaceDisplayName("1"), "Notes")
    }

    func testRenameToDefaultKeepsSavedWithAutomaticName() throws {
        config.workspaceSidebar.saveNamedWorkspaces = true
        let workspace = Workspace.get(byName: "1")
        workspace.markAsAutomaticallyNamed()
        XCTAssertTrue(mainMonitor.setActiveWorkspace(workspace))
        try renameWorkspaceForSidebar(workspaceName: "1", displayName: "Code")

        try renameWorkspaceForSidebar(workspaceName: "1", displayName: workspaceDefaultDisplayName("1"))

        XCTAssertTrue(workspace.isSaved)
        XCTAssertNil(savedWorkspaceStore.record(named: "1")?.displayName)
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["1"])
    }

    func testSavedEmptyWorkspaceSurvivesPruneKeepsLabelAndIsUserFacing() throws {
        config.workspaceSidebar.saveNamedWorkspaces = true
        let saved = Workspace.get(byName: "2")
        saved.markAsTransientBlank()
        try renameWorkspaceForSidebar(workspaceName: "2", displayName: "Later")
        XCTAssertFalse(saved.isVisible)

        Workspace.reconcileWorkspaceState()

        XCTAssertTrue(Workspace.existing(byName: "2") === saved)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["2"], "Later")
        XCTAssertTrue(isUserFacingWorkspace(saved))
        XCTAssertFalse(saved.isOrdinaryEmptySlot)
    }

    func testOrphanLabelClearingSkipsSavedNames() {
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "7", displayName: "Seven"))
        config.workspaceSidebar.workspaceLabels["7"] = "Seven"
        config.workspaceSidebar.workspaceLabels["8"] = "Eight"

        clearOrphanedWorkspaceSidebarLabels()

        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["7"], "Seven")
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["8"])
    }

    func testReconcileRecreatesMissingSavedWorkspace() {
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "code", namingStyle: .explicit))

        Workspace.reconcileWorkspaceState()

        XCTAssertNotNil(Workspace.existing(byName: "code"))
        XCTAssertEqual(Workspace.existing(byName: "code")?.lifecycle, .durable)
    }

    func testForgetKeepsWindowsAndNameThenEmptyIsPrunedAndLabelCleared() throws {
        config.workspaceSidebar.saveNamedWorkspaces = true
        let workspace = Workspace.get(byName: "2")
        workspace.markAsAutomaticallyNamed()
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try renameWorkspaceForSidebar(workspaceName: "2", displayName: "Code")

        XCTAssertTrue(try forgetSavedWorkspace(workspace))

        XCTAssertFalse(workspace.isSaved)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels["2"], "Code")
        Workspace.reconcileWorkspaceState()
        XCTAssertNotNil(Workspace.existing(byName: "2"))

        window.unbindFromParent()
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: "2"))
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["2"])
    }

    func testDeleteWorkspaceForgetsRecordAndClearsLabel() throws {
        config.workspaceSidebar.saveNamedWorkspaces = true
        let workspace = Workspace.get(byName: "2")
        workspace.markAsAutomaticallyNamed()
        try renameWorkspaceForSidebar(workspaceName: "2", displayName: "Code")

        try deleteWorkspaceForSidebar(workspaceName: "2")
        Workspace.reconcileWorkspaceState()

        XCTAssertNil(savedWorkspaceStore.record(named: "2"))
        XCTAssertNil(Workspace.existing(byName: "2"))
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["2"])
    }

    func testDeleteProjectForgetsItsSavedWorkspaces() throws {
        let project = createWorkspaceProject()
        let workspace = Workspace.get(byName: "5")
        workspace.assignProject(project.id)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try ensureSavedWorkspaceRecord(workspace)

        try deleteWorkspaceProject(project.id)
        Workspace.reconcileWorkspaceState()

        XCTAssertNil(savedWorkspaceStore.record(named: "5"))
        XCTAssertNil(Workspace.existing(byName: "5"))
    }

    func testMaterializeReservesNamesBeforeAutomaticGeneration() {
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "1", namingStyle: .automatic))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "3", namingStyle: .automatic))
        materializeSavedWorkspaceNames()

        let first = createBlankWorkspace(projectId: workspaceProjectDefaultId, monitor: mainMonitor)
        let second = createBlankWorkspace(projectId: workspaceProjectDefaultId, monitor: mainMonitor)

        XCTAssertEqual([first.name, second.name], ["2", "4"])
        XCTAssertTrue(Workspace.existing(byName: "3")?.usesAutomaticDisplayName == true)
    }

    func testNextAutomaticNameSkipsUnmaterializedSavedName() {
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "1"))

        XCTAssertEqual(nextAutomaticWorkspaceName(), "2")
    }

    func testProjectAssignmentRestoresProjectAndOrderWithoutTransientBlanks() {
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "6", projectId: "project-a"))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "5", projectId: "project-a"))
        materializeSavedWorkspaceNames()
        XCTAssertEqual(Workspace.existing(byName: "6")?.projectId, workspaceProjectDefaultId)
        config.workspaceSidebar.projectLabels["project-a"] = "Alpha"
        savedWorkspaceRuntime.projectAssignmentPending = true
        savedWorkspaceRuntime.configLoadState = .userConfig

        materializePersistedWorkspaceProjects()

        XCTAssertEqual(Workspace.existing(byName: "6")?.projectId, "project-a")
        XCTAssertEqual(projectWorkspaces(projectId: "project-a").map(\.name), ["6", "5"])
        XCTAssertFalse(savedWorkspaceRuntime.projectAssignmentPending)
    }

    func testMissingProjectMovesRecordToDefaultOnlyAfterUserConfigLoad() {
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "5", projectId: "gone"))
        materializeSavedWorkspaceNames()
        savedWorkspaceRuntime.projectAssignmentPending = true
        savedWorkspaceRuntime.configLoadState = .userConfig

        materializePersistedWorkspaceProjects()

        XCTAssertEqual(Workspace.existing(byName: "5")?.projectId, workspaceProjectDefaultId)
        XCTAssertEqual(savedWorkspaceStore.record(named: "5")?.projectId, workspaceProjectDefaultId)
    }

    func testDefaultConfigFallbackLeavesRecordProjectUntouchedAndReassignsAfterFix() throws {
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "5", projectId: "project-a"))
        materializeSavedWorkspaceNames()
        savedWorkspaceRuntime.projectAssignmentPending = true
        noteSavedWorkspaceConfigLoaded(isDefaultFallback: true)

        materializePersistedWorkspaceProjects()
        captureSavedWorkspaces(facts: savedTestFacts())

        let workspace = try XCTUnwrap(Workspace.existing(byName: "5"))
        XCTAssertEqual(workspace.projectId, workspaceProjectDefaultId)
        XCTAssertEqual(savedWorkspaceStore.record(named: "5")?.projectId, "project-a")
        XCTAssertTrue(savedWorkspaceRuntime.projectAssignmentPending)

        config.workspaceSidebar.projectLabels["project-a"] = "Alpha"
        noteSavedWorkspaceConfigLoaded(isDefaultFallback: false)
        materializePersistedWorkspaceProjects()

        XCTAssertEqual(workspace.projectId, "project-a")
        XCTAssertFalse(savedWorkspaceRuntime.projectAssignmentPending)
    }

    func testDisplayNameFallsBackToRecordAndCheckpointNeverClearsIt() throws {
        let workspace = try makeSavedTestWorkspace("x", displayName: "Code")
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["x"])

        captureSavedWorkspaces(facts: savedTestFacts())

        XCTAssertEqual(workspaceDisplayName(workspace.name), "Code")
        XCTAssertEqual(effectiveWorkspaceSidebarLabels()["x"], "Code")
        XCTAssertEqual(savedWorkspaceStore.record(named: "x")?.displayName, "Code")

        config.workspaceSidebar.workspaceLabels["x"] = "Renamed in TOML"
        captureSavedWorkspaces(facts: savedTestFacts())
        XCTAssertEqual(savedWorkspaceStore.record(named: "x")?.displayName, "Renamed in TOML")
    }

    func testSmartLayoutSkippedWhenFocusedWorkspaceIsSaved() throws {
        XCTAssertTrue(shouldApplySmartLayoutAtStartup(didLoadPersistedFrozenWorld: false))
        try ensureSavedWorkspaceRecord(focus.workspace)

        XCTAssertFalse(shouldApplySmartLayoutAtStartup(didLoadPersistedFrozenWorld: false))
        XCTAssertFalse(shouldApplySmartLayoutAtStartup(didLoadPersistedFrozenWorld: true))
    }

    func testFirstCheckpointAdoptsLabeledWorkspacesOnlyWhenFileWasAbsent() {
        config.workspaceSidebar.saveNamedWorkspaces = true
        savedWorkspaceStore = SavedWorkspaceStore(url: nil, fileWasAbsentAtLoad: true)
        let withWindows = Workspace.get(byName: "1")
        TestWindow.new(id: 1, parent: withWindows.rootTilingContainer)
        let empty = Workspace.get(byName: "2")
        XCTAssertTrue(mainMonitor.setActiveWorkspace(empty))
        config.workspaceSidebar.workspaceLabels["1"] = "Code"
        config.workspaceSidebar.workspaceLabels["2"] = "Stale"

        adoptLabeledWorkspacesIfNeeded()

        XCTAssertTrue(withWindows.isSaved)
        XCTAssertFalse(empty.isSaved)
        XCTAssertEqual(savedWorkspaceStore.record(named: "1")?.displayName, "Code")

        savedWorkspaceStore = SavedWorkspaceStore(url: nil, fileWasAbsentAtLoad: false)
        savedWorkspaceRuntime.didRunLabelAdoption = false
        adoptLabeledWorkspacesIfNeeded()
        XCTAssertTrue(savedWorkspaceStore.isEmpty)
    }

    func testReadOnlyStoreRefusesToSave() {
        savedWorkspaceStore = SavedWorkspaceStore(url: nil, readOnlyReason: "newer")
        config.workspaceSidebar.saveNamedWorkspaces = true
        Workspace.get(byName: "1").markAsAutomaticallyNamed()

        XCTAssertThrowsError(try renameWorkspaceForSidebar(workspaceName: "1", displayName: "Code"))
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["1"])
    }
}
