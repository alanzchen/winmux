import AppKit
@testable import AppBundle
import Common
import XCTest

@MainActor
final class WorkspaceSidebarFullscreenTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    override func tearDown() async throws {
        WorkspaceSidebarPanel.shared.resetHiddenSidebarState()
        for panel in WorkspaceSidebarPanel.visiblePanels { panel.resetHiddenSidebarState() }
        nativeFullscreenChromeSuppression = NativeFullscreenChromeSuppression()
        setMonitorsForTests(nil)
        config = defaultConfig
    }

    func testFullscreenOnAnotherDisplayStaysHiddenAcrossFocusAndTransientChanges() async {
        let secondary = monitor(x: -1920, y: -300, index: 2)
        setMonitorsForTests([mainMonitor, secondary])
        let fullscreen = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        fullscreen.nativeIsMacosFullscreen = true
        let ordinary = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        let frames: [UInt32: CGRect] = [1: CGRect(x: -1920, y: -300, width: 1920, height: 1080)]
        for nativeFocused in [fullscreen, ordinary, nil] {
            await updateNativeFullscreenChromeSuppression(nativeFocused: nativeFocused, readOnScreenFrames: { frames })
            XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: secondary))
            XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
        }
    }

    func testInactiveFullscreenSpaceDoesNotHideDesktopAndExitRestoresChrome() async {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.nativeIsMacosFullscreen = true
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenFrames: { [1: frame] })
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
        await updateNativeFullscreenChromeSuppression(nativeFocused: nil, readOnScreenFrames: { [:] })
        XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenFrames: { [1: frame] })
        window.nativeIsMacosFullscreen = false
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenFrames: {
            XCTFail("Ordinary windows should not need a WindowServer snapshot")
            return [1: frame]
        })
        XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testOrdinaryMaximizedAndWinMuxFullscreenWindowsStayVisibleWithoutPolling() async {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer,
            rect: mainMonitor.rect)
        window.isFullscreen = true
        window.recordObservedNativeState(fullscreen: false, minimized: false, token: window.nativeStateObservationToken())
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenFrames: {
            XCTFail("No native fullscreen windows: do not query WindowServer")
            return nil
        })
        XCTAssertEqual(window.nativeStateFetchCount, 0)
        XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testFailedSnapshotPreservesSuppressionUntilSuccessfulSnapshot() async {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.nativeIsMacosFullscreen = true
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenFrames: {
            [1: CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        })
        await updateNativeFullscreenChromeSuppression(nativeFocused: nil, readOnScreenFrames: { nil })
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
        await updateNativeFullscreenChromeSuppression(nativeFocused: nil, readOnScreenFrames: { [:] })
        XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testCommandObservesCurrentSuppressionBeforeItsBody() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer, rect: mainMonitor.rect)
        window.nativeFocus()
        nativeFullscreenChromeSuppression.windowFrames = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {
            XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor),
                "Commands must sample fullscreen state before deciding whether to open search")
        }
    }

    func testCancelledObservationDoesNotOverwriteSuppression() async {
        nativeFullscreenChromeSuppression.windowFrames = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await updateNativeFullscreenChromeSuppression(nativeFocused: nil)
        }
        await task.value
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testFullscreenOnlyReadsAreCachedAndInvalidatedWithoutInventingMinimizedState() async {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        for _ in 0..<3 {
            await updateNativeFullscreenChromeSuppression(nativeFocused: window)
        }
        XCTAssertEqual(window.nativeStateFetchCount, 1)
        XCTAssertEqual(window.lastKnownNativeFullscreen, false)
        XCTAssertNil(window.lastKnownNativeMinimized)
        window.nativeIsMacosFullscreen = true
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenFrames: {
            [1: CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        })
        XCTAssertEqual(window.nativeStateFetchCount, 2)
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testInvalidatedObservationKeepsChromeHiddenUntilNextRefresh() async {
        let window = InvalidatingFullscreenWindow(id: 1, TestApp.shared, lastFloatingSize: nil,
            parent: focus.workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        nativeFullscreenChromeSuppression.windowFrames = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenFrames: {
            XCTFail("A torn AX sample must not overwrite the last visibility decision")
            return [:]
        })
        XCTAssertNil(window.lastKnownNativeFullscreen)
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testCommandFallsBackAfterDisplayDisconnectWithoutReopeningHiddenPanel() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let previousEnabled = TrayMenuModel.shared.isEnabled
        TrayMenuModel.shared.isEnabled = true
        defer { TrayMenuModel.shared.isEnabled = previousEnabled }
        config.workspaceSidebar.enabled = true
        let oldScope = workspaceSidebarMonitorScopeId(for: mainMonitor)
        WorkspaceSidebarPanel.refreshAll()
        let oldPanel = try XCTUnwrap(WorkspaceSidebarPanel.panel(for: oldScope))
        let replacement = monitor(x: 1920, y: 0, index: 1)
        setMonitorsForTests([replacement])
        WorkspaceSidebarPanel.refreshAll()
        oldPanel.refresh()
        XCTAssertFalse(oldPanel.isVisible)
        XCTAssertNil(oldPanel.currentSidebarPanelLayout())
        let nextPanel = try XCTUnwrap(workspaceSidebarPanelForCommand(focusedScopeId: oldScope))
        XCTAssertEqual(nextPanel.monitorScopeId, workspaceSidebarMonitorScopeId(for: replacement))
        nativeFullscreenChromeSuppression.windowFrames = [CGRect(x: 1920, y: 0, width: 1920, height: 1080)]
        nextPanel.refresh()
        XCTAssertNil(workspaceSidebarPanelForCommand(focusedScopeId: oldScope))
        XCTAssertNil(nextPanel.currentSidebarPanelLayout())
    }

    func testHidingPanelPreservesDropPreviewOnAnotherDisplay() {
        TrayMenuModel.shared.workspaceSidebarDropPreview = WorkspaceSidebarDropPreviewViewModel(
            sourceWindowId: 1, label: "App", appName: "App", targetWorkspaceName: "2",
            targetsNewWorkspace: false, targetMonitorScopeId: "monitor:1920.0,0.0", isTabGroup: false, windowCount: 1)
        defer { TrayMenuModel.shared.workspaceSidebarDropPreview = nil }
        WorkspaceSidebarPanel.shared.resetHiddenSidebarState()
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.sourceWindowId, 1)
    }

    func testBothModesHideCancelEditingAndRestoreConfiguredWidth() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let panel = WorkspaceSidebarPanel.shared
        let previousEnabled = TrayMenuModel.shared.isEnabled
        TrayMenuModel.shared.isEnabled = true
        defer { TrayMenuModel.shared.isEnabled = previousEnabled }
        config.workspaceSidebar.enabled = true
        XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenAuxiliary))

        for dock in [false, true] {
            for (autoHide, pinned) in [(false, false), (true, false), (false, true), (true, true)] {
                config.workspaceSidebar.showAppIcons = dock
                config.workspaceSidebar.autoHide = autoHide
                config.workspaceSidebar.alwaysExpanded = pinned
                panel.resetHiddenSidebarState()
                panel.viewModel.isWorkspaceSidebarExpanded = pinned
                panel.refresh(on: mainMonitor)
                XCTAssertTrue(panel.isVisible)
                let expectedWidth = panel.viewModel.workspaceSidebarVisibleWidth
                var cancellations = 0
                // Seed an input session without activating the app or installing a global tap.
                panel.inlineTextEditingActive = true
                panel.inlineTextEditingCancel = { cancellations += 1 }
                WorkspaceSidebarPanel.inputSession.acquire(panel)
                panel.commandExpansionLocksCollapse = true
                panel.bufferedCommandSidebarSearchKeys = [.text("x")]
                panel.pendingExpand = DispatchWorkItem { XCTFail("Hidden panel expanded") }
                nativeFullscreenChromeSuppression.windowFrames = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
                panel.refresh(on: mainMonitor)
                XCTAssertFalse(panel.isVisible)
                XCTAssertTrue(panel.ignoresMouseEvents)
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 0)
                XCTAssertEqual(cancellations, 1)
                XCTAssertNil(WorkspaceSidebarPanel.inputSession.owner)
                XCTAssertNil(panel.pendingExpand)
                XCTAssertFalse(panel.commandExpansionLocksCollapse)
                XCTAssertTrue(panel.bufferedCommandSidebarSearchKeys.isEmpty)
                panel.expandSidebar(to: 240, reason: .hover)
                panel.beginInlineTextEditing()
                panel.prepareForInlineTextEditing()
                XCTAssertFalse(panel.isVisible)
                XCTAssertFalse(panel.inlineTextEditingActive)
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 0)

                nativeFullscreenChromeSuppression = NativeFullscreenChromeSuppression()
                panel.refresh(on: mainMonitor)
                XCTAssertTrue(panel.isVisible)
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, expectedWidth)
                XCTAssertFalse(panel.inlineTextEditingActive)
            }
        }
    }

    private func monitor(x: CGFloat, y: CGFloat, index: Int) -> TestMonitor {
        let rect = Rect(topLeftX: x, topLeftY: y, width: 1920, height: 1080)
        return TestMonitor(monitorAppKitNsScreenScreensId: index, name: "Display \(index)",
            rect: rect, visibleRect: rect, isMain: false)
    }
}

private final class InvalidatingFullscreenWindow: Window {
    @MainActor override var isMacosFullscreen: Bool {
        get async throws {
            invalidateLastKnownNativeState()
            return false
        }
    }
}
