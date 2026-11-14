@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class CarbonDelta3ReviewTest: XCTestCase {
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

    private func layout(event: RefreshSessionEvent, passes: Int = 1) async throws {
        for _ in 0 ..< passes {
            advanceFrameFitTestClock(by: 0.1)
            try await $refreshSessionEvent.withValue(event) {
                try await layoutWorkspaces()
            }
        }
    }

    /// BLOCK-D3-1a (fullscreen enter/exit): entering macOS native fullscreen without a prior park
    /// rearms `frameFitArming` and clears `frameFitLaidOut = false`, but leaves `lastAppliedLayoutPhysicalRect`
    /// equal to `cell`. Exiting native fullscreen via CLI/hotkey (`.socketServer` / `.hotkeyBinding`, where
    /// `canReuseLastAppliedWindowFrames == true`) hits `canReuseLastAppliedWindowFrame` == true, skips
    /// `setAxLayoutFrame` completely, never spends the rearmed budget, and leaves `frameFitLaidOut == false`
    /// while the window is tiled on screen.
    func testMacosNativeFullscreenEnterAndExitInCommandSessionAppliesRearmedLayoutFrame() async throws {
        let workspace = Workspace.get(byName: "delta3-native-fs")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480))
        app.answers = false
        let window = FrameFitTestWindow(id: 801, parent: workspace.rootTilingContainer, native: app)
        try await layout(event: .ax(kAXResizedNotification as String), passes: 6)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(app.sizeWrites, 3)

        // Enter macOS native fullscreen (same tree transition as MacosNativeFullscreenCommand / normalizeLayoutReason).
        window.rememberMacOsLayoutOrigin()
        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let armingAfterEnter = window.frameFitArming
        XCTAssertEqual(armingAfterEnter, 1)

        // App becomes responsive; user exits native fullscreen via CLI/hotkey command session.
        app.answers = true
        try await exitMacOsNativeUnconventionalState(
            window: window,
            prevParentKind: .tilingContainer,
            prevWorkspaceName: workspace.name,
            workspace: workspace
        )
        let commandEvent = RefreshSessionEvent.socketServer(MacosNativeFullscreenCmdArgs(rawArgs: [].slice))
        XCTAssertTrue(commandEvent.canReuseLastAppliedWindowFrames)
        try await layout(event: commandEvent, passes: 6)

        XCTAssertEqual(app.sizeWrites, 4, "Exiting native fullscreen in a command session must deliver the rearmed layout write")
        XCTAssertEqual(app.frame, cell, "Window must take its tiling cell after exiting macOS native fullscreen")

        // Because the window was laid out in tiling again, leaving tiling a second time must rearm again.
        window.bindAsFloatingWindow(to: workspace)
        XCTAssertEqual(window.frameFitArming, armingAfterEnter + 1, "frameFitLaidOut must be true once tiled layout runs")
    }

    /// BLOCK-D3-1b (responsive native fullscreen enter/exit): even when the app always answers AX writes,
    /// macOS native fullscreen changes the native frame while `lastAppliedLayoutPhysicalRect` stays at the old
    /// tiling cell; exiting via `MacosNativeFullscreenCommand` skips `setAxLayoutFrame` and leaves the window
    /// at its post-fullscreen frame instead of restoring `cell`.
    func testResponsiveWindowExitingMacosNativeFullscreenInCommandSessionRestoresTilingCell() async throws {
        let workspace = Workspace.get(byName: "delta3-native-fs-responsive")
        XCTAssertTrue(workspace.focusWorkspace())
        let preFullscreenRect = Rect(topLeftX: 120, topLeftY: 120, width: 800, height: 600)
        let app = SimulatedAppWindow(preFullscreenRect)
        let window = FrameFitTestWindow(id: 802, parent: workspace.rootTilingContainer, native: app)
        try await layout(event: .ax(kAXResizedNotification as String), passes: 3)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(app.frame, cell)

        window.rememberMacOsLayoutOrigin()
        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        // Simulate macOS native fullscreen and subsequent native exit restoring the window's user frame.
        app.frame = preFullscreenRect

        try await exitMacOsNativeUnconventionalState(
            window: window,
            prevParentKind: .tilingContainer,
            prevWorkspaceName: workspace.name,
            workspace: workspace
        )
        try await layout(event: .socketServer(MacosNativeFullscreenCmdArgs(rawArgs: [].slice)), passes: 3)

        XCTAssertEqual(app.frame, cell, "Command-driven native fullscreen exit must re-apply the tiling cell")
    }

    /// BLOCK-D3-1c (workspace switch while minimized + frame-reusing restore / sidebar recall):
    /// minimizing from a visible workspace without a prior park leaves `lastAppliedLayoutPhysicalRect == cell`,
    /// switching workspaces while minimized never clears it (minimized windows live outside workspace leaves),
    /// and restoring during a `.menuBarButton` / `.hotkeyBinding` / `.onFocusChanged` session skips `setAxLayoutFrame`.
    func testMinimizeThenWorkspaceSwitchWhileMinimizedAndFrameReusingRestoreAppliesRearmedFit() async throws {
        let wsA = Workspace.get(byName: "delta3-min-a")
        let wsB = Workspace.get(byName: "delta3-min-b")
        XCTAssertTrue(wsA.focusWorkspace())

        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480))
        app.answers = false
        let window = FrameFitTestWindow(id: 803, parent: wsA.rootTilingContainer, native: app)
        try await layout(event: .ax(kAXResizedNotification as String), passes: 6)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(app.sizeWrites, 3)

        // Minimize directly from the visible workspace (no park first).
        window.rememberMacOsLayoutOrigin(detachFromWorkspace: true)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertEqual(window.frameFitArming, 1)

        // Switch workspaces A -> B -> A while minimized.
        XCTAssertTrue(wsB.focusWorkspace())
        try await layout(event: .hotkeyBinding, passes: 2)
        XCTAssertTrue(wsA.focusWorkspace())
        try await layout(event: .hotkeyBinding, passes: 2)
        XCTAssertEqual(window.frameFitArming, 1, "Workspace switches while minimized must not bump arming")
        XCTAssertEqual(app.sizeWrites, 3)

        // Restore in a sidebar / hotkey / focus session (`canReuseLastAppliedWindowFrames == true`,
        // matching `runWorkspaceSidebarSession` -> `.menuBarButton` in `recallMinimizedWorkspaceSidebarPinWindow`).
        app.answers = true
        try await exitMacOsNativeUnconventionalState(
            window: window,
            prevParentKind: .tilingContainer,
            prevWorkspaceName: nil,
            workspace: wsA
        )
        XCTAssertTrue(RefreshSessionEvent.menuBarButton.canReuseLastAppliedWindowFrames)
        try await layout(event: .menuBarButton, passes: 6)

        XCTAssertEqual(app.sizeWrites, 4, "Restoring from minimize in a sidebar/hotkey session must deliver the rearmed write")
        XCTAssertEqual(app.frame, cell)
    }

    /// BLOCK-D3-1d (learned fit rearm under frame-reusing return, committee item 9):
    /// an aspect-constrained window that learned its size, minimized without parking, dropped its constraint,
    /// and returned in a `.hotkeyBinding` / `.menuBarButton` session must re-probe `cell` instead of reusing
    /// the pre-minimize `lastAppliedLayoutPhysicalRect`.
    func testLearnedFitRearmedByLeavingTilingAppliesNewSizeOnFrameReusingReturn() async throws {
        let workspace = Workspace.get(byName: "delta3-learned-return")
        XCTAssertTrue(workspace.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 600, height: 600), aspect: 1.0)
        let window = FrameFitTestWindow(id: 804, parent: workspace.rootTilingContainer, native: app)
        try await layout(event: .ax(kAXResizedNotification as String), passes: 6)
        let cell = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(app.sizeWrites, 2, "Aspect-constrained window learns its size in 2 writes")
        XCTAssertNotEqual(app.frame.size, cell.size)

        window.rememberMacOsLayoutOrigin(detachFromWorkspace: true)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        app.aspect = nil

        try await exitMacOsNativeUnconventionalState(
            window: window,
            prevParentKind: .tilingContainer,
            prevWorkspaceName: nil,
            workspace: workspace
        )
        try await layout(event: .hotkeyBinding, passes: 6)

        XCTAssertEqual(app.frame, cell, "Rearmed learned fit must take the cell when constraint is gone")
    }

    /// Positive check 1: repeated minimize/restore and float/tile cycles each cost at most one bounded arming
    /// (<= 3 acquisition writes per unresponsive cycle), and chained non-tiling rebinds never advance arming.
    func testRepeatedMinimizeRestoreAndFloatTogglesStayStrictlyBoundedPerCycle() async throws {
        let wsA = Workspace.get(byName: "delta3-bound-a")
        let wsB = Workspace.get(byName: "delta3-bound-b")
        XCTAssertTrue(wsA.focusWorkspace())
        let app = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480))
        app.answers = false
        let window = FrameFitTestWindow(id: 805, parent: wsA.rootTilingContainer, native: app)

        try await layout(event: .ax(kAXResizedNotification as String), passes: 6)
        XCTAssertEqual(app.sizeWrites, 3)
        XCTAssertEqual(window.frameFitArming, 0)

        for cycle in 1 ... 3 {
            window.rememberMacOsLayoutOrigin(detachFromWorkspace: true)
            window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            let expectedArming = UInt64(cycle)
            XCTAssertEqual(window.frameFitArming, expectedArming)

            // Chained non-tiling rebinds while out of tiling must not advance arming again.
            window.bindAsFloatingWindow(to: wsB)
            window.bind(to: wsB.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            window.bind(to: wsB.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            XCTAssertEqual(window.frameFitArming, expectedArming, "Non-tiling rebinds must not re-trigger leaving tiling")

            window.layoutReason = .standard
            window.bind(to: wsA.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            try await layout(event: .ax(kAXResizedNotification as String), passes: 8)
            XCTAssertEqual(app.sizeWrites, 3 * (cycle + 1), "Each user cycle spends at most 3 acquisition writes")
        }
    }

    /// Positive check 2: WinMux `isFullscreen` enter/exit clears `lastAppliedLayoutPhysicalRect` on fullscreen
    /// entry, lays out both fullscreen and split cells under `.socketServer`, and keeps covered siblings'
    /// exhausted budgets intact without rearming.
    func testWinMuxFullscreenEnterAndExitLaysOutBothCellsAndPreservesCoveredSiblingBudget() async throws {
        let workspace = Workspace.get(byName: "delta3-winmux-fs")
        XCTAssertTrue(workspace.focusWorkspace())
        let app1 = SimulatedAppWindow(Rect(topLeftX: 100, topLeftY: 100, width: 500, height: 400))
        let app2 = SimulatedAppWindow(Rect(topLeftX: 700, topLeftY: 100, width: 500, height: 400))
        app2.answers = false
        let w1 = FrameFitTestWindow(id: 806, parent: workspace.rootTilingContainer, native: app1)
        let w2 = FrameFitTestWindow(id: 807, parent: workspace.rootTilingContainer, native: app2)

        try await layout(event: .ax(kAXResizedNotification as String), passes: 6)
        let splitCell1 = try XCTUnwrap(w1.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(app1.frame, splitCell1)
        XCTAssertEqual(app2.sizeWrites, 3)

        w1.isFullscreen = true
        w1.markAsMostRecentChild()
        let cmdEvent = RefreshSessionEvent.socketServer(MacosNativeFullscreenCmdArgs(rawArgs: [].slice))
        try await layout(event: cmdEvent, passes: 4)
        XCTAssertEqual(app1.frame, workspace.workspaceMonitor.visibleRectPaddedByOuterGaps)
        XCTAssertTrue(w2.isHiddenInCorner)
        XCTAssertEqual(w2.frameFitArming, 0)
        XCTAssertEqual(app2.sizeWrites, 3)

        app2.answers = true
        w1.isFullscreen = false
        try await layout(event: cmdEvent, passes: 6)
        XCTAssertEqual(app1.frame, splitCell1)
        XCTAssertFalse(w2.isHiddenInCorner)
        XCTAssertEqual(w2.frameFitArming, 0, "Covered sibling parked during WinMux fullscreen never left tiling")
        XCTAssertEqual(app2.sizeWrites, 3, "Unparking covered sibling must preserve its exhausted budget")
    }

    /// Positive check 3: closing a window drops its pending follow-up, and reopening a new window instance
    /// with the same `windowId` starts cleanly at `frameFitArming == 0` with a fresh budget.
    func testCloseDropsPendingFollowUpAndReopenWithRecycledWindowIdStartsFresh() async throws {
        let workspace = Workspace.get(byName: "delta3-close-reopen")
        XCTAssertTrue(workspace.focusWorkspace())
        let closedApp = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480))
        closedApp.answers = false
        let closedWindow = FrameFitTestWindow(id: 808, parent: workspace.rootTilingContainer, native: closedApp)

        try await layout(event: .ax(kAXResizedNotification as String), passes: 1)
        XCTAssertEqual(closedApp.sizeWrites, 1, "First attempt spent; 60 ms follow-up is now pending")

        closedWindow.removeClosedWindowFromTree()
        advanceFrameFitTestClock(by: 0.2)
        XCTAssertEqual(closedApp.sizeWrites, 1, "Closing the window must cancel its pending follow-up")

        let reopenedApp = SimulatedAppWindow(Rect(topLeftX: 200, topLeftY: 200, width: 640, height: 480))
        let reopenedWindow = FrameFitTestWindow(id: 808, parent: workspace.rootTilingContainer, native: reopenedApp)
        XCTAssertEqual(reopenedWindow.frameFitArming, 0)
        try await layout(event: .ax(kAXResizedNotification as String), passes: 3)
        let cell = try XCTUnwrap(reopenedWindow.lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(reopenedApp.frame, cell)
    }
}
