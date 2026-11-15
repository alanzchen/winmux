@testable import AppBundle
import Common
import Darwin
import Foundation
import XCTest

/// Carbon's S1 review reproducer for S1-C1, copied byte-identical: a summon or move-workspace-to-monitor that
/// workspace-to-monitor-force-assignment rejects must leave the source monitor as it was.
@MainActor
final class S1ForceAssignmentRejectionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
    }

    override func tearDown() async throws {
        setMonitorsForTests(nil)
    }

    func testRejectedSummonOfVisibleForceAssignedWorkspaceMustNotEvictItFromSourceMonitor() async throws {
        let main = TestMonitor(
            monitorAppKitNsScreenScreensId: 1,
            name: "Main",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            isMain: true,
        )
        let secondary = TestMonitor(
            monitorAppKitNsScreenScreensId: 2,
            name: "Secondary",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            isMain: false,
        )
        setMonitorsForTests([main, secondary])
        config.workspaceToMonitorForceAssignment["2"] = [.secondary]

        let ws1 = Workspace.get(byName: "1")
        let ws2 = Workspace.get(byName: "2")
        let w1 = TestWindow.new(id: 1, parent: ws1.rootTilingContainer)
        _ = TestWindow.new(id: 2, parent: ws2.rootTilingContainer)

        XCTAssertTrue(main.setActiveWorkspace(ws1))
        XCTAssertTrue(secondary.setActiveWorkspace(ws2))
        XCTAssertTrue(w1.focusWindow())
        XCTAssertEqual(secondary.activeWorkspace, ws2)
        XCTAssertTrue(ws2.isVisible)

        let result = try await parseCommand("summon-workspace 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.stderr.joined(separator: "\n").contains("workspace-to-monitor-force-assignment doesn't allow it"),
            "Unexpected stderr: \(result.stderr)",
        )

        // Failed summon must NOT evict ws2 from Secondary or spawn an extra blank workspace on Secondary.
        XCTAssertEqual(secondary.activeWorkspace, ws2, "Rejected summon-workspace evicted ws2 from Secondary")
        XCTAssertTrue(ws2.isVisible, "ws2 is no longer visible on any monitor after rejected summon-workspace")
    }

    func testRejectedMoveWorkspaceToMonitorLeavesBothDisplaysAndWorkspacesUntouched() async throws {
        let main = TestMonitor(
            monitorAppKitNsScreenScreensId: 1,
            name: "Main",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            isMain: true,
        )
        let secondary = TestMonitor(
            monitorAppKitNsScreenScreensId: 2,
            name: "Secondary",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            isMain: false,
        )
        setMonitorsForTests([main, secondary])
        config.workspaceToMonitorForceAssignment["2"] = [.secondary]

        let ws1 = Workspace.get(byName: "1")
        let ws2 = Workspace.get(byName: "2")
        _ = TestWindow.new(id: 1, parent: ws1.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws2.rootTilingContainer)
        XCTAssertTrue(main.setActiveWorkspace(ws1))
        XCTAssertTrue(secondary.setActiveWorkspace(ws2))
        XCTAssertTrue(w2.focusWindow())
        let workspacesBefore = Workspace.all.map(\.name)

        let result = try await parseCommand("move-workspace-to-monitor --workspace 2 left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.joined(separator: "\n").contains("workspace-to-monitor-force-assignment doesn't allow it"),
                      "Unexpected stderr: \(result.stderr)")
        XCTAssertEqual(secondary.activeWorkspace, ws2)
        XCTAssertEqual(main.activeWorkspace, ws1)
        // Nor may it add a workspace (the empty setup workspace may be pruned by the refresh).
        XCTAssertTrue(Set(Workspace.all.map(\.name)).isSubset(of: Set(workspacesBefore)), "A rejected move created a workspace: \(Workspace.all.map(\.name))")
    }
}
