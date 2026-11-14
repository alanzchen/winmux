@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class AstraFrameFitDelta2Test: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setMonitorsForTests([FitTestMonitor()])
        startFrameFitTestClock()
    }

    override func tearDown() async throws {
        stopFrameFitTestClock()
        setMonitorsForTests(nil)
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private func layout(_ workspace: Workspace, passes: Int = 1) async throws {
        for _ in 0 ..< passes {
            advanceFrameFitTestClock(by: 0.1)
            try await $refreshSessionEvent.withValue(.ax(kAXResizedNotification as String)) {
                try await layoutWorkspaces()
            }
        }
    }

    private func exerciseReturnFromMinimize(parkFirst: Bool) async throws {
        let workspace = Workspace.get(byName: "delta-rearm")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480))
        app.answers = false
        let window = FrameFitTestWindow(id: 711, parent: workspace.rootTilingContainer, native: app)
        try await layout(workspace, passes: 6)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(app.sizeWrites, 3, "The failing app has exhausted acquisition")
        XCTAssertNotEqual(app.frame.size, cell.size)

        if parkFirst {
            try await parkHiddenWindow(window, in: .bottomRightCorner, reasserting: false)
            XCTAssertTrue(window.isHiddenInCorner)
            XCTAssertEqual(app.sizeWrites, 3, "Move-only parking must preserve the bound")
        }
        // The same tree transition as normalization on kAXWindowMiniaturized.
        window.rememberMacOsLayoutOrigin(detachFromWorkspace: true)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        app.answers = true
        // The production restore path, with the remembered tiling parent kind.
        try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: .tilingContainer,
            prevWorkspaceName: nil, workspace: workspace)
        try await layout(workspace, passes: 6)
        XCTAssertFalse(window.isHiddenInCorner)
        XCTAssertEqual(window.lastAppliedLayoutPhysicalRect, cell, "Same display, epoch and cell")
        XCTAssertEqual(app.sizeWrites, 4, "Leaving tiling must rearm even after a move-only park")
        XCTAssertEqual(app.frame, cell, "The now-responsive app must take the cell after restoration")
    }

    func testParkThenMinimizeAndRestoreRearmsExhaustedFit() async throws {
        try await exerciseReturnFromMinimize(parkFirst: true)
    }

    func testMinimizeAndRestoreWithoutParkRearmsExhaustedFit() async throws {
        try await exerciseReturnFromMinimize(parkFirst: false)
    }

    func testParkAndUnparkWithoutLeavingTilingKeepsExhaustedBudget() async throws {
        let workspace = Workspace.get(byName: "delta-park-only")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480))
        app.answers = false
        let window = FrameFitTestWindow(id: 712, parent: workspace.rootTilingContainer, native: app)
        try await layout(workspace, passes: 6)
        XCTAssertEqual(app.sizeWrites, 3)
        try await parkHiddenWindow(window, in: .bottomRightCorner, reasserting: false)
        app.answers = true
        try await layout(workspace, passes: 6)
        XCTAssertEqual(app.sizeWrites, 3, "Parking itself must not refill acquisition")
    }
}
