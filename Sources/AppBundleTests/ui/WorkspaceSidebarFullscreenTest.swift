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
        let frames = [UInt32(1): OnScreenWindow(frame: CGRect(x: -1920, y: -300, width: 1920, height: 1080))]
        for nativeFocused in [fullscreen, ordinary, nil] {
            await updateNativeFullscreenChromeSuppression(nativeFocused: nativeFocused, readOnScreenWindows: { frames })
            XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: secondary))
            XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
        }
    }

    func testInactiveFullscreenSpaceDoesNotHideDesktopAndExitRestoresChrome() async {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.nativeIsMacosFullscreen = true
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenWindows: { [1: OnScreenWindow(frame: frame)] })
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
        await updateNativeFullscreenChromeSuppression(nativeFocused: nil, readOnScreenWindows: { [:] })
        XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenWindows: { [1: OnScreenWindow(frame: frame)] })
        window.nativeIsMacosFullscreen = false
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenWindows: {
            XCTFail("Ordinary windows should not need a WindowServer snapshot")
            return [1: OnScreenWindow(frame: frame)]
        })
        XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testOrdinaryMaximizedAndWinMuxFullscreenWindowsStayVisibleWithoutPolling() async {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer,
            rect: mainMonitor.rect)
        window.isFullscreen = true
        window.recordObservedNativeState(fullscreen: false, minimized: false, token: window.nativeStateObservationToken())
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenWindows: {
            XCTFail("No native fullscreen windows: do not query WindowServer")
            return nil
        })
        XCTAssertEqual(window.nativeStateFetchCount, 0)
        XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testFailedSnapshotPreservesSuppressionUntilSuccessfulSnapshot() async {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.nativeIsMacosFullscreen = true
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenWindows: {
            [1: OnScreenWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        })
        await updateNativeFullscreenChromeSuppression(nativeFocused: nil, readOnScreenWindows: { nil })
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
        await updateNativeFullscreenChromeSuppression(nativeFocused: nil, readOnScreenWindows: { [:] })
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
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenWindows: {
            [1: OnScreenWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        })
        XCTAssertEqual(window.nativeStateFetchCount, 2)
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testInvalidatedObservationKeepsChromeHiddenUntilNextRefresh() async {
        let window = InvalidatingFullscreenWindow(id: 1, TestApp.shared, lastFloatingSize: nil,
            parent: focus.workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        nativeFullscreenChromeSuppression.windowFrames = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        await updateNativeFullscreenChromeSuppression(nativeFocused: window, readOnScreenWindows: {
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

    func testBothModesHideCancelEditingAndRestoreConfiguredWidth() async throws {
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
                XCTAssertTrue(panel.ignoresMouseEvents)
                XCTAssertEqual(cancellations, 1)
                XCTAssertNil(WorkspaceSidebarPanel.inputSession.owner)
                XCTAssertNil(panel.pendingExpand)
                XCTAssertFalse(panel.commandExpansionLocksCollapse)
                XCTAssertTrue(panel.bufferedCommandSidebarSearchKeys.isEmpty)
                if panel.slideTransition.isAnimating {
                    XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, expectedWidth,
                        "Retain the outgoing layout until the slide finishes")
                    try await Task.sleep(for: .milliseconds(260))
                }
                XCTAssertFalse(panel.isVisible)
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 0)
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

    // PowerPoint's slide show is a buttonless AXUnknown popup with AXFullScreen = false, sized to the
    // whole display (github.com/nikitabobko/AeroSpace/issues/697). Presenter view adds a second one.
    func testDisplaySizedPresentationPopupsHideChromeOnTheirDisplaysAcrossFocusChanges() async {
        let secondary = monitor(x: 1920, y: 0, index: 2)
        setMonitorsForTests([mainMonitor, secondary])
        let slideShow = popup(id: 1, rect: secondary.rect)
        let editor = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        var onScreen = [UInt32(1): OnScreenWindow(frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))]
        for nativeFocused in [slideShow, editor, nil] {
            await updateNativeFullscreenChromeSuppression(nativeFocused: nativeFocused, readOnScreenWindows: { onScreen })
            XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: secondary))
            XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
        }
        XCTAssertEqual(slideShow.lastKnownNativeFullscreen, false, "The slide show never reports AX fullscreen")

        let presenterView = popup(id: 3, rect: mainMonitor.rect)
        onScreen[3] = OnScreenWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        await updateNativeFullscreenChromeSuppression(nativeFocused: presenterView, readOnScreenWindows: { onScreen })
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: secondary))
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor))

        // Ending the show destroys both windows; restoring chrome needs no WindowServer query.
        slideShow.unbindFromParent()
        presenterView.unbindFromParent()
        await updateNativeFullscreenChromeSuppression(nativeFocused: editor, readOnScreenWindows: {
            XCTFail("No display-sized popups remain: do not query WindowServer")
            return nil
        })
        XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: secondary))
        XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testOrdinaryPopupsNeverQueryWindowServer() async {
        let tooltip = popup(id: 1, rect: Rect(topLeftX: 100, topLeftY: 100, width: 240, height: 40))
        popup(id: 2, rect: Rect(topLeftX: 0, topLeftY: 25, width: 1920, height: 1055))
        popup(id: 3, rect: nil)
        await updateNativeFullscreenChromeSuppression(nativeFocused: tooltip, readOnScreenWindows: {
            XCTFail("Popups smaller than a display must not trigger a WindowServer query")
            return nil
        })
        XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testDisplaySizedPopupsOnlyHideChromeWhenVisibleBeneathIt() async {
        popup(id: 1, rect: mainMonitor.rect)
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let stayOnTopLevel = workspaceSidebarPanelLevel(stayOnTop: true).rawValue
        let floatingLevel = workspaceSidebarPanelLevel(stayOnTop: false).rawValue
        let cases: [(Bool, [UInt32: OnScreenWindow], Bool, String)] = [
            (true, [1: OnScreenWindow(frame: frame, layer: -2_147_483_623)], false, "Desktop-level wallpaper"),
            (true, [1: OnScreenWindow(frame: frame, layer: stayOnTopLevel + 1)], false, "Above the chrome, e.g. screenshot selection"),
            (true, [:], false, "Another Space or a hidden app"),
            (true, [1: OnScreenWindow(frame: frame.insetBy(dx: 200, dy: 200))], false, "The window shrank after the AX sample"),
            (true, [1: OnScreenWindow(frame: frame, layer: stayOnTopLevel)], true, "The stay-on-top sidebar can be ordered above it"),
            (true, [1: OnScreenWindow(frame: frame)], true, "Normal-level presentation"),
            (false, [1: OnScreenWindow(frame: frame, layer: floatingLevel + 1)], false, "Already above the floating sidebar"),
            (false, [1: OnScreenWindow(frame: frame, layer: floatingLevel)], true, "The floating sidebar can be ordered above it"),
        ]
        for (stayOnTop, onScreen, expected, reason) in cases {
            config.workspaceSidebar.stayOnTop = stayOnTop
            await updateNativeFullscreenChromeSuppression(nativeFocused: nil, readOnScreenWindows: { onScreen })
            XCTAssertEqual(shouldSuppressChromeForFullscreenContent(on: mainMonitor), expected, reason)
        }
    }

    func testResizedPopupIsResampledBeforeItCanHideChrome() async {
        let slideShow = popup(id: 1, rect: Rect(topLeftX: 200, topLeftY: 200, width: 800, height: 600))
        let editor = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        await updateNativeFullscreenChromeSuppression(nativeFocused: slideShow, readOnScreenWindows: {
            XCTFail("A window-sized popup must not trigger a WindowServer query")
            return nil
        })
        XCTAssertEqual(slideShow.axRectFetchCount, 0, "Registration already recorded the frame")
        // A slide show can open at its editor size and then grow; the resized event drops the cache.
        slideShow.nativeRect = mainMonitor.rect
        // Same app, but the editor holds focus: this double's getAxRect writes authoritatively,
        // which a focused window's torn-sample guard would reject. Production reads do not.
        await updateNativeFullscreenChromeSuppression(nativeFocused: editor, readOnScreenWindows: {
            [1: OnScreenWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        })
        XCTAssertEqual(slideShow.axRectFetchCount, 1)
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testUnknownPresentationFrameKeepsTheLastDecisionWithoutAskingBackgroundApps() async {
        let slideShow = popup(id: 1, rect: mainMonitor.rect)
        let editor = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        let browser = Window(id: 3, OtherTestApp.shared, lastFloatingSize: nil,
            parent: focus.workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let onScreen = [UInt32(1): OnScreenWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        await updateNativeFullscreenChromeSuppression(nativeFocused: slideShow, readOnScreenWindows: { onScreen })
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
        // After a move, a busy presenting app times out AX, or the presenter switched apps.
        slideShow.nativeRect = nil
        for (nativeFocused, expectedReads) in [(editor as Window?, 1), (browser, 1), (nil, 1), (editor, 2)] {
            await updateNativeFullscreenChromeSuppression(nativeFocused: nativeFocused, readOnScreenWindows: { onScreen })
            XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor), "Must not reveal chrome over the slides")
            XCTAssertEqual(slideShow.axRectFetchCount, expectedReads, "Only the focused app is asked, on every session")
        }

        await updateNativeFullscreenChromeSuppression(nativeFocused: browser, readOnScreenWindows: { [:] })
        XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor), "WindowServer still decides")
        await updateNativeFullscreenChromeSuppression(nativeFocused: editor, readOnScreenWindows: {
            XCTFail("An unknown frame that is not presenting must not query WindowServer")
            return nil
        })
        XCTAssertFalse(shouldSuppressChromeForFullscreenContent(on: mainMonitor))

        slideShow.nativeRect = mainMonitor.rect
        await updateNativeFullscreenChromeSuppression(nativeFocused: editor, readOnScreenWindows: { onScreen })
        XCTAssertTrue(shouldSuppressChromeForFullscreenContent(on: mainMonitor))
    }

    func testOnlyRegularAppsCanPresent() {
        XCTAssertTrue(isPresentationApp(activationPolicy: .regular))
        XCTAssertFalse(isPresentationApp(activationPolicy: .accessory), "Menu bar utility overlays")
        XCTAssertFalse(isPresentationApp(activationPolicy: .prohibited))
        XCTAssertTrue(isPresentationApp(activationPolicy: nil), "Test doubles have no activation policy")
    }

    @discardableResult
    private func popup(id: UInt32, rect: Rect?) -> TestWindow {
        TestWindow.new(id: id, parent: macosPopupWindowsContainer, rect: rect)
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

private final class OtherTestApp: AbstractApp {
    let pid: Int32 = 1
    let rawAppBundleId: String? = "bobko.WinMux.other-test-app"
    let name: String? = "Other test app"
    let execPath: String? = nil
    let bundlePath: String? = nil
    @MainActor static let shared = OtherTestApp()

    @MainActor func getFocusedWindow() async throws -> Window? { nil }
}
