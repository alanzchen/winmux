@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class SavedWorkspaceDisplayAffinityTest: XCTestCase {
    private let laptop = SavedWorkspaceTestMonitor(id: 1, name: "Built-in Display", x: 0, isMain: true, uuid: "LAPTOP", isBuiltin: true)
    private let dell = SavedWorkspaceTestMonitor(id: 2, name: "DELL U2723QE", x: 1920, width: 2560, height: 1440, uuid: "DELL")

    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
    }

    /// A saved workspace with a window, visible on `monitor`.
    private func savedWorkspace(_ name: String, on monitor: Monitor, windowId: UInt32) throws -> Workspace {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: windowId, parent: workspace.rootTilingContainer)
        XCTAssertTrue(monitor.setActiveWorkspace(workspace))
        try ensureSavedWorkspaceRecord(workspace)
        return workspace
    }

    func testReconnectAtNewPositionRestoresSavedWorkspaceByIdentity() throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        let code = try savedWorkspace("code", on: dell, windowId: 1)
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.display?.uuid, "DELL")

        setMonitorsForTests([laptop])
        Workspace.reconcileWorkspaceState()
        XCTAssertFalse(code.isVisible)
        XCTAssertNotNil(Workspace.existing(byName: "code"))
        checkWorkspaceHierarchyInvariants(requireActiveMonitorViewports: true)

        let dellOnTheLeft = dell.moved(toX: -2560)
        setMonitorsForTests([laptop, dellOnTheLeft])
        Workspace.reconcileWorkspaceState()

        XCTAssertTrue(dellOnTheLeft.activeWorkspace === code)
        XCTAssertFalse(laptop.activeWorkspace === code)
    }

    func testDisconnectHidesWithoutChangingAffinity() throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        let code = try savedWorkspace("code", on: dell, windowId: 1)

        setMonitorsForTests([laptop])
        Workspace.reconcileWorkspaceState()
        captureSavedWorkspaces(facts: savedTestFacts())

        XCTAssertFalse(code.isVisible)
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.display?.uuid, "DELL")
        XCTAssertNil(savedHomeMonitor(of: code))
    }

    func testDisplaysTradingPlacesKeepTheirWorkspaces() throws {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT")
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        Workspace.reconcileWorkspaceState()
        let onLeft = Workspace.get(byName: "a")
        let onRight = Workspace.get(byName: "b")
        TestWindow.new(id: 1, parent: onLeft.rootTilingContainer)
        TestWindow.new(id: 2, parent: onRight.rootTilingContainer)
        XCTAssertTrue(left.setActiveWorkspace(onLeft))
        XCTAssertTrue(right.setActiveWorkspace(onRight))
        Workspace.reconcileWorkspaceState()

        // Same two points, but the displays swapped (for example after a main-display change).
        setMonitorsForTests([right.moved(toX: 0, isMain: true), left.moved(toX: 1920, isMain: false)])
        Workspace.reconcileWorkspaceState()

        XCTAssertTrue(right.moved(toX: 0).activeWorkspace === onRight)
        XCTAssertTrue(left.moved(toX: 1920).activeWorkspace === onLeft)
    }

    func testKeylessMonitorsKeepPositionBasedBehavior() {
        let main = SavedWorkspaceTestMonitor(id: 1, name: "Main", x: 0, isMain: true, uuid: nil)
        let secondary = SavedWorkspaceTestMonitor(id: 2, name: "Secondary", x: 1920, uuid: nil)
        setMonitorsForTests([main, secondary])
        Workspace.reconcileWorkspaceState()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertTrue(secondary.setActiveWorkspace(workspace))

        setMonitorsForTests([main, secondary.moved(toX: 1900)])
        Workspace.reconcileWorkspaceState()

        XCTAssertTrue(secondary.moved(toX: 1900).activeWorkspace === workspace)
    }

    func testDuplicateUuidResolvesByNearestLastPoint() {
        let first = SavedWorkspaceTestMonitor(id: 2, name: "Twin", x: 1920, uuid: "TWIN")
        let second = SavedWorkspaceTestMonitor(id: 3, name: "Twin", x: 3840, uuid: "TWIN")
        let affinity = SavedDisplayAffinity(uuid: "TWIN", vendor: nil, model: nil, serial: nil, isBuiltin: false, name: "Twin", lastTopLeft: CGPoint(x: 3800, y: 0))

        let resolved = resolveSavedDisplay(affinity, in: [laptop, first, second])

        XCTAssertEqual(resolved?.rect.topLeftCorner, second.rect.topLeftCorner)
    }

    func testBuiltinAffinityResolvesWithoutUuid() {
        let affinity = SavedDisplayAffinity(uuid: "GONE", vendor: nil, model: nil, serial: nil, isBuiltin: true, name: "Built-in", lastTopLeft: .zero)

        XCTAssertEqual(resolveSavedDisplay(affinity, in: [dell, laptop])?.name, laptop.name)
        XCTAssertNil(resolveSavedDisplay(SavedDisplayAffinity(uuid: "GONE", vendor: nil, model: nil, serial: nil, isBuiltin: false, name: "", lastTopLeft: .zero), in: [dell, laptop]))
    }

    func testStartupShowsMostRecentlyVisibleSavedWorkspacePerDisplay() throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        _ = try savedWorkspace("older", on: dell, windowId: 1)
        let newer = try savedWorkspace("newer", on: dell, windowId: 2)
        let mail = try savedWorkspace("mail", on: laptop, windowId: 3)
        XCTAssertGreaterThan(
            try XCTUnwrap(savedWorkspaceStore.record(named: "newer")?.lastVisibleSequence),
            try XCTUnwrap(savedWorkspaceStore.record(named: "older")?.lastVisibleSequence),
        )

        // A fresh launch starts without display state.
        winMuxWorkspaceState.monitorViewportsById = [:]
        Workspace.reconcileWorkspaceState()

        XCTAssertTrue(dell.activeWorkspace === newer)
        XCTAssertTrue(laptop.activeWorkspace === mail)
    }

    func testHiddenSavedWorkspaceOpensOnItsHomeDisplayWhenFocused() throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        let code = try savedWorkspace("code", on: dell, windowId: 1)
        let other = Workspace.get(byName: "other")
        TestWindow.new(id: 2, parent: other.rootTilingContainer)
        XCTAssertTrue(dell.setActiveWorkspace(other))
        XCTAssertTrue(laptop.activeWorkspace.focusWorkspace())

        XCTAssertTrue(code.focusWorkspace())

        XCTAssertTrue(dell.activeWorkspace === code)
    }

    func testAutomaticSelectionSkipsSavedWorkspaceHomedElsewhere() throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        let code = try savedWorkspace("code", on: dell, windowId: 1)
        XCTAssertTrue(dell.setActiveWorkspace(Workspace.get(byName: "other")))

        XCTAssertFalse(workspaceIsAvailableForMonitor(code, monitor: laptop))
        XCTAssertTrue(workspaceIsAvailableForMonitor(code, monitor: dell))
    }

    func testFallbackNeverReusesAnEmptySavedWorkspace() throws {
        let empty = Workspace.get(byName: "empty")
        try ensureSavedWorkspaceRecord(empty)
        savedWorkspaceStore.update(named: "empty") { $0.display = nil }

        let fallback = getOrCreateFallbackWorkspace(projectId: workspaceProjectDefaultId, monitor: mainMonitor, excluding: nil)

        XCTAssertFalse(fallback === empty)
    }

    func testExplicitMoveRehomesSoftWorkspaceButNotPinnedOne() throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        let soft = try savedWorkspace("soft", on: dell, windowId: 1)

        XCTAssertTrue(overrideWorkspaceOnMonitorBySwappingActiveViewports(soft, targetMonitor: laptop))
        XCTAssertEqual(savedWorkspaceStore.record(named: "soft")?.display?.uuid, "LAPTOP")

        let pinned = try savedWorkspace("pinned", on: dell, windowId: 2)
        XCTAssertTrue(try setSavedWorkspacePinned(pinned, true))
        XCTAssertFalse(overrideWorkspaceOnMonitorBySwappingActiveViewports(pinned, targetMonitor: laptop))
        XCTAssertTrue(dell.activeWorkspace === pinned)
        XCTAssertEqual(savedWorkspaceStore.record(named: "pinned")?.display?.uuid, "DELL")
    }

    func testMoveWhileHomeIsDisconnectedIsTemporary() throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        let code = try savedWorkspace("code", on: dell, windowId: 1)
        setMonitorsForTests([laptop])
        Workspace.reconcileWorkspaceState()

        noteSavedWorkspacePlacedByUser(code, on: laptop)

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.display?.uuid, "DELL")
    }

    func testPinnedReturnsOnReconnectEvenIfVisibleElsewhereAndSourceGetsFallback() throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        let pinned = try savedWorkspace("pinned", on: dell, windowId: 1)
        XCTAssertTrue(try setSavedWorkspacePinned(pinned, true))
        setMonitorsForTests([laptop])
        Workspace.reconcileWorkspaceState()
        // With its display gone the pin can't hold, so it can be shown on the laptop.
        XCTAssertTrue(laptop.setActiveWorkspace(pinned))

        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()

        XCTAssertTrue(dell.activeWorkspace === pinned)
        XCTAssertFalse(laptop.activeWorkspace === pinned)
        checkWorkspaceHierarchyInvariants(requireActiveMonitorViewports: true)
    }

    func testSoftWorkspaceVisibleElsewhereStaysOnReconnect() throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        let soft = try savedWorkspace("soft", on: dell, windowId: 1)
        setMonitorsForTests([laptop])
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(laptop.setActiveWorkspace(soft))

        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()

        XCTAssertTrue(laptop.activeWorkspace === soft)
    }

    func testPinnedRefusesSummonAndMoveToAnotherDisplay() async throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        let pinned = try savedWorkspace("pinned", on: dell, windowId: 1)
        XCTAssertTrue(try setSavedWorkspacePinned(pinned, true))
        XCTAssertTrue(dell.setActiveWorkspace(Workspace.get(byName: "other")))
        XCTAssertTrue(laptop.activeWorkspace.focusWorkspace())

        let args = SummonWorkspaceCmdArgs(rawArgs: []).copy(\.target, .initialized(.parse("pinned").getOrDie()))
        let result = try await SummonWorkspaceCommand(args: args).run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode, 1)
        XCTAssertFalse(laptop.activeWorkspace === pinned)
        XCTAssertTrue(savedPinBlocks(pinned, on: laptop))
        XCTAssertFalse(savedPinBlocks(pinned, on: dell))
    }

    func testSidebarClickOnPinnedWorkspaceOpensItOnItsDisplay() throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        let pinned = try savedWorkspace("pinned", on: dell, windowId: 1)
        XCTAssertTrue(try setSavedWorkspacePinned(pinned, true))
        XCTAssertTrue(dell.setActiveWorkspace(Workspace.get(byName: "other")))

        XCTAssertTrue(focusWorkspaceFromSidebar(pinned, targetMonitorScopeId: workspaceSidebarMonitorScopeId(for: laptop)))

        XCTAssertTrue(dell.activeWorkspace === pinned)
    }

    func testUnpinKeepsSoftHome() throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        let pinned = try savedWorkspace("pinned", on: dell, windowId: 1)
        XCTAssertTrue(try setSavedWorkspacePinned(pinned, true))

        XCTAssertTrue(try setSavedWorkspacePinned(pinned, false))

        XCTAssertEqual(savedWorkspaceStore.record(named: "pinned")?.isPinnedToDisplay, false)
        XCTAssertEqual(savedWorkspaceStore.record(named: "pinned")?.display?.uuid, "DELL")
        XCTAssertFalse(try setSavedWorkspacePinned(pinned, false))
    }

    func testConfigForceAssignmentOverridesSavedHome() throws {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
        let code = try savedWorkspace("code", on: dell, windowId: 1)
        XCTAssertTrue(try setSavedWorkspacePinned(code, true))
        XCTAssertTrue(dell.setActiveWorkspace(Workspace.get(byName: "other")))
        config.workspaceToMonitorForceAssignment["code"] = [.main]

        XCTAssertTrue(savedHomeAllows(code, on: laptop))
        XCTAssertFalse(savedPinBlocks(code, on: laptop))
        XCTAssertTrue(code.workspaceMonitor.rect.topLeftCorner == laptop.rect.topLeftCorner)
    }

    func testFakeMonitorWithoutIdentityNeverBecomesHome() throws {
        let fake = SavedWorkspaceTestMonitor(id: 1, name: "Test Monitor", x: 0, isMain: true, uuid: nil)
        setMonitorsForTests([fake])
        Workspace.reconcileWorkspaceState()
        let code = try savedWorkspace("code", on: fake, windowId: 1)

        captureSavedWorkspaces(facts: savedTestFacts())

        XCTAssertNil(savedWorkspaceStore.record(named: "code")?.display)
        XCTAssertThrowsError(try setSavedWorkspacePinned(code, true))
    }
}
