@testable import AppBundle
import AppKit
import XCTest

final class NewFloatingWindowPresentationTest: XCTestCase {
    @MainActor
    func testCallbackFloatedWindowIsSelectedOnceEvenWhenNativeFocusAlreadyMatches() {
        let (existing, floating) = setUpScenario()
        let presentation = makePresentation(nativeFocused: existing)
        record(floating, in: presentation)
        record(floating, in: presentation)

        XCTAssertTrue(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(floating.windowId)) === floating)
        XCTAssertNil(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(floating.windowId)))
    }

    @MainActor
    func testSingleFloatBehindExistingNativeWindowIsSelected() {
        let (existing, floating) = setUpScenario()
        let presentation = makePresentation(nativeFocused: existing)
        record(floating, in: presentation)

        XCTAssertTrue(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(existing.windowId)) === floating)
    }

    @MainActor
    func testMultipleFloatsRequireNativeTarget() {
        let (existing, first) = setUpScenario()
        let second = TestWindow.new(id: 3, parent: focus.workspace)
        let ambiguous = makePresentation(nativeFocused: existing)
        record(first, in: ambiguous)
        record(second, in: ambiguous)
        XCTAssertNil(ambiguous.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(existing.windowId)))

        let resolved = makePresentation(nativeFocused: existing)
        record(second, in: resolved)
        record(first, in: resolved)
        XCTAssertTrue(resolved.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(second.windowId)) === second)
    }

    @MainActor
    func testNativeChoiceOfNewTiledWindowWinsOverSingleNewFloat() {
        let (_, floating) = setUpScenario()
        let tiled = TestWindow.new(id: 3, parent: focus.workspace.rootTilingContainer)
        let presentation = makePresentation(nativeFocused: tiled)
        record(floating, in: presentation)
        record(tiled, in: presentation)

        XCTAssertNil(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(tiled.windowId)))
        XCTAssertTrue(presentation.suppressFocusSync)
    }

    @MainActor
    func testStartupRestoresAndBackgroundDetectionsDoNotPresent() {
        let (existing, floating) = setUpScenario()
        let startup = NewFloatingWindowPresentation(isStartup: true, frontmostAppPid: 0)
        startup.recordNativeFocusBeforeLayout(existing)
        record(floating, in: startup)
        XCTAssertNil(startup.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(floating.windowId)))

        let restored = makePresentation(nativeFocused: existing)
        restored.recordDetection(floating, wasRestored: true, focusGenerationBeforeCallbacks: focusChangeGeneration)
        XCTAssertNil(restored.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(floating.windowId)))

        let background = NewFloatingWindowPresentation(isStartup: false, frontmostAppPid: 99)
        background.recordNativeFocusBeforeLayout(existing)
        record(floating, in: background)
        XCTAssertNil(background.consumeCandidate(frontmostAppPid: 99, nativeObservation: .window(floating.windowId)))
    }

    @MainActor
    func testRoutingAndNativeStateAreRecheckedAfterLayout() {
        let (existing, floating) = setUpScenario()
        let hidden = makePresentation(nativeFocused: existing)
        record(floating, in: hidden)
        _ = floating.bindAsFloatingWindow(to: Workspace.get(byName: "hidden"))
        XCTAssertNil(hidden.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(existing.windowId)))

        _ = floating.bindAsFloatingWindow(to: focus.workspace)
        let minimized = makePresentation(nativeFocused: existing)
        record(floating, in: minimized)
        floating.recordObservedNativeState(fullscreen: false, minimized: true, token: floating.nativeStateObservationToken())
        XCTAssertNil(minimized.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(existing.windowId)))

        floating.recordObservedNativeState(fullscreen: false, minimized: false, token: floating.nativeStateObservationToken())
        let tiled = makePresentation(nativeFocused: existing)
        record(floating, in: tiled)
        floating.bind(to: focus.workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertNil(tiled.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(existing.windowId)))
    }

    @MainActor
    func testExplicitCallbackOrLaterFocusChangesWin() {
        let (existing, floating) = setUpScenario()
        let other = TestWindow.new(id: 3, parent: focus.workspace.rootTilingContainer)
        let callback = makePresentation(nativeFocused: existing)
        let generationBeforeCallback = focusChangeGeneration
        _ = other.focusWindow()
        callback.recordDetection(floating, wasRestored: false, focusGenerationBeforeCallbacks: generationBeforeCallback)
        callback.recordNativeFocusBeforeLayout(existing)
        XCTAssertNil(callback.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(floating.windowId)))

        _ = existing.focusWindow()
        let later = makePresentation(nativeFocused: existing)
        record(floating, in: later)
        _ = other.focusWindow()
        _ = existing.focusWindow()
        XCTAssertNil(later.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(floating.windowId)))
    }

    @MainActor
    func testNewNativeFocusAppSwitchAndTransientDoNotGetOverridden() {
        let (existing, floating) = setUpScenario()
        let other = TestWindow.new(id: 3, parent: focus.workspace.rootTilingContainer)
        for observation in [NativeFocusedWindowObservation.window(other.windowId), .transient, .unavailable] {
            let presentation = makePresentation(nativeFocused: existing)
            record(floating, in: presentation)
            XCTAssertNil(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: observation))
            XCTAssertTrue(presentation.suppressFocusSync)
        }
        let switched = makePresentation(nativeFocused: existing)
        record(floating, in: switched)
        XCTAssertNil(switched.consumeCandidate(frontmostAppPid: 99, nativeObservation: .window(floating.windowId)))
        XCTAssertTrue(switched.suppressFocusSync)
    }

    @MainActor
    func testExplicitSelectionOfAlreadyFocusedWindowWins() {
        let (existing, floating) = setUpScenario()
        let callback = makePresentation(nativeFocused: existing)
        let generationBeforeCallback = focusChangeGeneration
        XCTAssertTrue(existing.focusWindow())
        callback.recordDetection(floating, wasRestored: false, focusGenerationBeforeCallbacks: generationBeforeCallback)
        callback.recordNativeFocusBeforeLayout(existing)
        XCTAssertNil(callback.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(existing.windowId)))

        let later = makePresentation(nativeFocused: existing)
        record(floating, in: later)
        XCTAssertTrue(existing.focusWindow())
        XCTAssertNil(later.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(existing.windowId)))
    }

    @MainActor
    func testClosedCandidateAndCancelledSessionCannotPresent() async {
        let (existing, floating) = setUpScenario()
        let closed = makePresentation(nativeFocused: existing)
        record(floating, in: closed)
        floating.unbindFromParent()
        XCTAssertNil(closed.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(existing.windowId)))

        _ = floating.bindAsFloatingWindow(to: focus.workspace)
        let cancelled = makePresentation(nativeFocused: existing)
        record(floating, in: cancelled)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return cancelled.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(floating.windowId)) == nil
        }
        let didSkip = await task.value
        XCTAssertTrue(didSkip)
    }

    func testForceRaiseBypassesActivationOnlyShortcut() {
        XCTAssertTrue(shouldUseActivationOnlyForNativeFocus(targetWindowId: 1, lastNativeFocusedWindowId: 1, logicalWindowsCount: 2))
        XCTAssertFalse(shouldUseActivationOnlyForNativeFocus(targetWindowId: 1, lastNativeFocusedWindowId: 1, logicalWindowsCount: 2, forceRaise: true))
        XCTAssertFalse(shouldUseActivationOnlyForNativeFocus(targetWindowId: 1, lastNativeFocusedWindowId: nil, logicalWindowsCount: 1, forceRaise: true))
    }

    func testQueuedRaiseDoesNotOverrideLaterNativeFocusOrTransient() {
        XCTAssertTrue(shouldPerformNewFloatingWindowPresentation(targetWindowId: 2, expectedNativeWindowId: 1, currentNativeObservation: .window(1), isAppActive: true))
        XCTAssertTrue(shouldPerformNewFloatingWindowPresentation(targetWindowId: 2, expectedNativeWindowId: 1, currentNativeObservation: .window(2), isAppActive: true))
        for observation in [NativeFocusedWindowObservation.window(3), .transient, .unavailable] {
            XCTAssertFalse(shouldPerformNewFloatingWindowPresentation(targetWindowId: 2, expectedNativeWindowId: 1, currentNativeObservation: observation, isAppActive: true))
        }
        XCTAssertFalse(shouldPerformNewFloatingWindowPresentation(targetWindowId: 2, expectedNativeWindowId: 1, currentNativeObservation: .window(1), isAppActive: false))
        XCTAssertFalse(shouldPerformNewFloatingWindowPresentation(targetWindowId: 2, expectedNativeWindowId: nil, currentNativeObservation: .window(1), isAppActive: true))
    }

    @MainActor
    func testRejectedNativeRequestDoesNotLeaveLogicalFocusToReassertAfterSheetDismissal() async throws {
        let (existing, floating) = setUpScenario()
        TrayMenuModel.shared.isEnabled = true
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = existing
        updateFocusCache(existing)
        let presentation = makePresentation(nativeFocused: existing)
        record(floating, in: presentation)
        XCTAssertTrue(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(existing.windowId)) === floating)
        XCTAssertTrue(focus.windowOrNil === existing, "Selecting a presentation candidate must not commit logical focus")
        XCTAssertFalse(presentation.finishPresentation(floating, wasAccepted: false, focusGenerationBeforeRequest: focusChangeGeneration, frontmostAppPid: 0))
        XCTAssertTrue(presentation.suppressFocusSync)

        TestApp.shared.focusedWindow = nil
        TestApp.shared.hasActiveTransientNativeFocus = true
        try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String))
        try await runLightSession(.ax(kAXFocusedWindowChangedNotification as String), .forceRun, shouldSchedulePostRefresh: false) {}
        XCTAssertTrue(focus.windowOrNil === existing)
        XCTAssertNil(TestApp.shared.focusedWindow)
        TestApp.shared.hasActiveTransientNativeFocus = false
        TestApp.shared.focusedWindow = existing
        try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String))
        XCTAssertTrue(focus.windowOrNil === existing)
        XCTAssertTrue(TestApp.shared.focusedWindow === existing)
    }

    @MainActor
    func testNativeAcceptanceCommitsOnlyWithoutAnInterveningFocusChoice() {
        let (existing, floating) = setUpScenario()
        let accepted = makePresentation(nativeFocused: existing)
        let generation = focusChangeGeneration
        XCTAssertTrue(accepted.finishPresentation(floating, wasAccepted: true, focusGenerationBeforeRequest: generation, frontmostAppPid: 0))
        XCTAssertTrue(focus.windowOrNil === floating)

        _ = existing.focusWindow()
        let superseded = makePresentation(nativeFocused: existing)
        let beforeRequest = focusChangeGeneration
        XCTAssertTrue(existing.focusWindow())
        XCTAssertFalse(superseded.finishPresentation(floating, wasAccepted: true, focusGenerationBeforeRequest: beforeRequest, frontmostAppPid: 0))
        XCTAssertTrue(focus.windowOrNil === existing)
    }

    @MainActor
    func testInitialNativeDetectionCallbackChoiceWinsInFullAndLightSessions() async throws {
        for isLight in [false, true] {
            let (existing, floating) = setUpScenario()
            TrayMenuModel.shared.isEnabled = true
            TestApp.shared.focusedWindow = floating
            updateFocusCache(existing)
            appForTests = InitialDetectionCallbackApp {
                let beforeCallbacks = focusChangeGeneration
                _ = existing.focusWindow()
                newFloatingWindowPresentation?.recordDetection(floating, wasRestored: false, focusGenerationBeforeCallbacks: beforeCallbacks)
                return floating
            }
            if isLight {
                try await runLightSession(.ax(kAXFocusedWindowChangedNotification as String), .forceRun, shouldSchedulePostRefresh: false) {}
            } else {
                try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String))
            }
            XCTAssertTrue(focus.windowOrNil === existing)
            XCTAssertTrue(TestApp.shared.focusedWindow === existing, "The callback's native focus choice must be applied")
        }
    }

    @MainActor
    private func setUpScenario() -> (TestWindow, TestWindow) {
        setUpWorkspacesForTests()
        let workspace = focus.workspace
        let existing = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        _ = existing.focusWindow()
        let floating = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        // Model the final result of an on-window-detected layout rule.
        _ = floating.bindAsFloatingWindow(to: workspace)
        return (existing, floating)
    }

    @MainActor
    private func makePresentation(nativeFocused: Window) -> NewFloatingWindowPresentation {
        let presentation = NewFloatingWindowPresentation(isStartup: false, frontmostAppPid: 0)
        presentation.recordNativeFocusBeforeLayout(nativeFocused)
        return presentation
    }

    @MainActor
    private func record(_ window: Window, in presentation: NewFloatingWindowPresentation) {
        presentation.recordDetection(window, wasRestored: false, focusGenerationBeforeCallbacks: focusChangeGeneration)
    }
}

private final class InitialDetectionCallbackApp: AbstractApp {
    let pid: Int32 = 987654
    let rawAppBundleId: String? = "dev.winmux.initial-detection-test"
    let name: String? = "Initial detection test"
    let execPath: String? = nil
    let bundlePath: String? = nil
    private let callback: @MainActor () -> Window?

    init(_ callback: @escaping @MainActor () -> Window?) { self.callback = callback }

    @MainActor
    func getFocusedWindow() async throws -> Window? { callback() }
}
