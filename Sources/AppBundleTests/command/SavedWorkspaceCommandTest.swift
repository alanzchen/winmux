@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class SavedWorkspaceCommandTest: XCTestCase {
    private let laptop = SavedWorkspaceTestMonitor(id: 1, name: "Built-in Display", x: 0, isMain: true, uuid: "LAPTOP", isBuiltin: true)
    private let dell = SavedWorkspaceTestMonitor(id: 2, name: "DELL U2723QE", x: 1920, uuid: "DELL")

    override func setUp() async throws {
        setUpWorkspacesForTests()
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
    }

    func testParsesSavedWorkspaceSurface() {
        XCTAssertNotNil(parseCommand("save-workspace").cmdOrNil)
        XCTAssertNotNil(parseCommand("save-workspace --workspace 3 --name 'Code Review' --pin-to-display --fail-if-noop --json").cmdOrNil)
        XCTAssertNotNil(parseCommand("save-workspace --unpin-display").cmdOrNil)
        XCTAssertNotNil(parseCommand("forget-workspace --workspace code --fail-if-noop --json").cmdOrNil)
        XCTAssertEqual(
            parseCommand("save-workspace --pin-to-display --unpin-display").errorOrNil,
            "ERROR: Conflicting options: --pin-to-display, --unpin-display",
        )
        XCTAssertNotNil(parseCommand("save-workspace extra").errorOrNil)
        XCTAssertNotNil(parseCommand("forget-workspace --name x").errorOrNil)
        XCTAssertTrue(SaveWorkspaceCmdArgs.info.allowInConfig)
        XCTAssertFalse(ForgetWorkspaceCmdArgs.info.allowInConfig)
    }

    func testSaveFocusedWorkspaceWithName() async throws {
        let workspace = focus.workspace

        let result = try await run("save-workspace --name ' Code ' --json")

        let json = try jsonObject(result)
        XCTAssertTrue(workspace.isSaved)
        XCTAssertEqual(workspaceDisplayName(workspace.name), "Code")
        XCTAssertEqual(json["workspace"] as? String, workspace.name)
        XCTAssertEqual(json["display-name"] as? String, "Code")
        XCTAssertEqual(json["saved"] as? Bool, true)
        XCTAssertEqual(json["pinned"] as? Bool, false)
        XCTAssertEqual(json["changed"] as? Bool, true)
        XCTAssertEqual(json["display"] as? String, laptop.name)
        XCTAssertEqual(json["saved-id"] as? String, savedWorkspaceStore.record(named: workspace.name)?.id)
    }

    func testSaveTargetsWorkspaceFlagAndReportsNoop() async throws {
        let target = Workspace.get(byName: "3")
        TestWindow.new(id: 1, parent: target.rootTilingContainer)

        let first = try await run("save-workspace --workspace 3")
        XCTAssertEqual(first.exitCode, 0)
        XCTAssertTrue(target.isSaved)

        let noop = try await run("save-workspace --workspace 3")
        XCTAssertEqual(noop.exitCode, 0)
        XCTAssertEqual(noop.stderr, ["Workspace '3' is already saved. Tip: use --fail-if-noop to exit with non-zero code"])

        let failing = try await run("save-workspace --workspace 3 --fail-if-noop")
        XCTAssertEqual(failing.exitCode, 1)
        XCTAssertEqual(failing.stderr, ["Workspace '3' is already saved"])
    }

    func testSaveRejectsInvalidNameBeforeSaving() async throws {
        let result = try await run("save-workspace --name '   '")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(focus.workspace.isSaved)
    }

    func testPinAndUnpinToCurrentDisplay() async throws {
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertTrue(dell.setActiveWorkspace(workspace))

        let pinned = try await run("save-workspace --workspace code --pin-to-display --json")
        XCTAssertEqual(try jsonObject(pinned)["pinned"] as? Bool, true)
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.display?.uuid, "DELL")
        XCTAssertTrue(savedPinBlocks(workspace, on: laptop))

        let again = try await run("save-workspace --workspace code --pin-to-display --fail-if-noop")
        XCTAssertEqual(again.exitCode, 1)
        XCTAssertEqual(again.stderr, ["Workspace 'code' is already saved and kept on display '\(dell.name)'"])

        let unpinned = try await run("save-workspace --workspace code --unpin-display")
        XCTAssertEqual(unpinned.exitCode, 0)
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.isPinnedToDisplay, false)
        XCTAssertFalse(savedPinBlocks(workspace, on: laptop))
    }

    func testPinRefusedWhenConfigAssignsMonitor() async throws {
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        config.workspaceToMonitorForceAssignment["code"] = [.main]

        let result = try await run("save-workspace --workspace code --pin-to-display")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(workspace.isSaved)
    }

    func testPinRefusedOnDisplayWithoutIdentity() async throws {
        let fake = SavedWorkspaceTestMonitor(id: 1, name: "Test Monitor", x: 0, isMain: true, uuid: nil)
        setMonitorsForTests([fake])
        Workspace.reconcileWorkspaceState()

        let result = try await run("save-workspace --pin-to-display")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(focus.workspace.isSaved)
    }

    func testForgetStopsSavingAndReportsNoop() async throws {
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try ensureSavedWorkspaceRecord(workspace)

        let forgotten = try await run("forget-workspace --workspace code --json")
        let json = try jsonObject(forgotten)
        XCTAssertEqual(json["saved"] as? Bool, false)
        XCTAssertEqual(json["changed"] as? Bool, true)
        XCTAssertNil(json["saved-id"])
        XCTAssertFalse(workspace.isSaved)
        XCTAssertNotNil(Workspace.existing(byName: "code"))

        let noop = try await run("forget-workspace --workspace code --fail-if-noop")
        XCTAssertEqual(noop.exitCode, 1)
        XCTAssertEqual(noop.stderr, ["Workspace 'code' is not saved"])
    }

    func testRenamingASavedWorkspaceIsAChange() async throws {
        TestWindow.new(id: 1, parent: Workspace.get(byName: "code").rootTilingContainer)
        _ = try await run("save-workspace --workspace code --name Code")

        let renamed = try await run("save-workspace --workspace code --name Review --fail-if-noop --json")

        XCTAssertEqual(try jsonObject(renamed)["changed"] as? Bool, true)
        XCTAssertEqual(workspaceDisplayName("code"), "Review")
    }

    func testNamingASavedWorkspaceItsDefaultNameClearsTheName() async throws {
        TestWindow.new(id: 1, parent: Workspace.get(byName: "code").rootTilingContainer)
        _ = try await run("save-workspace --workspace code --name Code")

        let reset = try await run("save-workspace --workspace code --name code --json")

        XCTAssertEqual(try jsonObject(reset)["changed"] as? Bool, true)
        XCTAssertNil(savedWorkspaceStore.record(named: "code")?.displayName)
        XCTAssertNil(config.workspaceSidebar.workspaceLabels["code"])
        XCTAssertTrue(Workspace.get(byName: "code").isSaved)
    }

    func testUnpinningAnUnpinnedWorkspaceIsANoop() async throws {
        TestWindow.new(id: 1, parent: Workspace.get(byName: "code").rootTilingContainer)
        _ = try await run("save-workspace --workspace code")

        let noop = try await run("save-workspace --workspace code --unpin-display --fail-if-noop")
        let json = try await run("save-workspace --workspace code --json")

        XCTAssertEqual(noop.exitCode, 1)
        XCTAssertEqual(noop.stderr, ["Workspace 'code' is already saved and not kept on a display"])
        XCTAssertEqual(json.exitCode, 0)
        XCTAssertEqual(json.stderr, ["Workspace 'code' is already saved. Tip: use --fail-if-noop to exit with non-zero code"])
        XCTAssertEqual(try jsonObject(json)["changed"] as? Bool, false)
    }

    func testPinChangesAreRefusedWithAReadOnlyStore() async throws {
        TestWindow.new(id: 1, parent: Workspace.get(byName: "code").rootTilingContainer)
        _ = try await run("save-workspace --workspace code")
        let record = try XCTUnwrap(savedWorkspaceStore.record(named: "code"))
        savedWorkspaceStore = SavedWorkspaceStore(file: SavedWorkspacesFile(workspaces: [record]), url: nil, readOnlyReason: "newer")

        let result = try await run("save-workspace --workspace code --pin-to-display")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.isPinnedToDisplay, false)
    }

    func testReadOnlyStoreReportsError() async throws {
        savedWorkspaceStore = SavedWorkspaceStore(url: nil, readOnlyReason: "written by a newer WinMux")

        let result = try await run("save-workspace")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stderr, ["Saved workspaces are read-only: written by a newer WinMux"])
    }

    func testWorkspaceFormatVariablesShowDisplayNameAndSavedState() async throws {
        let saved = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: saved.rootTilingContainer)
        try saveWorkspaceForSidebar(workspaceName: "code", displayName: "Code")
        let plain = Workspace.get(byName: "plain")
        TestWindow.new(id: 2, parent: plain.rootTilingContainer)

        let result = try await run("list-workspaces --all --format '%{workspace}|%{workspace-display-name}|%{workspace-is-saved}'")

        XCTAssertTrue(result.stdout.contains("code|Code|true"), "\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("plain|plain|false"), "\(result.stdout)")
    }

    private func run(_ command: String) async throws -> CmdResult {
        try await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }

    private func jsonObject(_ result: CmdResult) throws -> [String: Any] {
        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)")
        let data = try XCTUnwrap(result.stdout.singleOrNil()?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
