@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class ActivatedFloatingWindowPresentationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testReusedFloatingWindowIsRaisedOnceWhenAppActivates() {
        let window = makeFocusedFloatingWindow()
        let presentation = makeActivation(window)

        XCTAssertTrue(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(window.windowId)) === window)
        XCTAssertNil(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(window.windowId)))
    }

    func testOrdinaryRefreshAndStartupDoNotRaiseReusedWindows() {
        let window = makeFocusedFloatingWindow()
        for presentation in [
            NewFloatingWindowPresentation(isStartup: false, frontmostAppPid: 0),
            NewFloatingWindowPresentation(isStartup: true, frontmostAppPid: 0, activatedAppPid: 0),
        ] {
            presentation.recordNativeFocusBeforeLayout(window)
            XCTAssertNil(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(window.windowId)))
        }
    }

    func testRestorationDuringActivationDoesNotBecomeReusedWindowPresentation() {
        let window = makeFocusedFloatingWindow()
        for detectedBeforeNativeFocus in [false, true] {
            let presentation = NewFloatingWindowPresentation(isStartup: false, frontmostAppPid: 0, activatedAppPid: 0)
            if !detectedBeforeNativeFocus { presentation.recordNativeFocusBeforeLayout(window) }
            presentation.recordDetection(window, wasRestored: true, focusGenerationBeforeCallbacks: focusChangeGeneration)
            if detectedBeforeNativeFocus { presentation.recordNativeFocusBeforeLayout(window) }
            XCTAssertNil(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(window.windowId)))
        }
    }

    func testStaleActivationAndLaterAppSwitchDoNotRaise() {
        let window = makeFocusedFloatingWindow()
        let stale = NewFloatingWindowPresentation(isStartup: false, frontmostAppPid: 0, activatedAppPid: 99)
        stale.recordNativeFocusBeforeLayout(window)
        XCTAssertNil(stale.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(window.windowId)))

        let switched = makeActivation(window)
        XCTAssertNil(switched.consumeCandidate(frontmostAppPid: 99, nativeObservation: .window(window.windowId)))
        XCTAssertTrue(switched.suppressFocusSync)
    }

    func testTransientOrNewerNativeWindowCancelsActivationRaise() {
        let window = makeFocusedFloatingWindow()
        let other = TestWindow.new(id: 2, parent: focus.workspace)
        for observation in [NativeFocusedWindowObservation.transient, .unavailable, .window(other.windowId)] {
            let presentation = makeActivation(window)
            XCTAssertNil(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: observation))
            XCTAssertTrue(presentation.suppressFocusSync)
        }
    }

    func testNewFloatingWindowStillTakesPriorityOverReusedActivatedWindow() {
        let reused = makeFocusedFloatingWindow()
        let newWindow = TestWindow.new(id: 2, parent: focus.workspace)
        let presentation = makeActivation(reused)
        presentation.recordDetection(newWindow, wasRestored: false, focusGenerationBeforeCallbacks: focusChangeGeneration)

        XCTAssertTrue(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(reused.windowId)) === newWindow)
    }

    func testCallbackFocusChoiceAndProjectFocusHoldWin() {
        let window = makeFocusedFloatingWindow()
        let other = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        let callback = makeActivation(window)
        let generation = focusChangeGeneration
        _ = other.focusWindow()
        callback.recordDetection(window, wasRestored: false, focusGenerationBeforeCallbacks: generation)
        callback.recordNativeFocusBeforeLayout(window)
        XCTAssertNil(callback.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(window.windowId)))

        // A project hold keeps logical focus elsewhere even while macOS reports the old
        // project's window. Activation cannot undo that deliberate logical focus choice.
        let held = makeActivation(window)
        XCTAssertNil(held.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(window.windowId)))
    }

    func testLayoutRoutingMinimizationAndFullscreenAreRechecked() {
        let window = makeFocusedFloatingWindow()
        let workspace = focus.workspace
        let routed = makeActivation(window)
        _ = window.bindAsFloatingWindow(to: Workspace.get(byName: "hidden"))
        XCTAssertNil(routed.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(window.windowId)))

        _ = window.bindAsFloatingWindow(to: workspace)
        _ = window.focusWindow()
        for fullscreen in [false, true] {
            let presentation = makeActivation(window)
            window.recordObservedNativeState(fullscreen: fullscreen, minimized: !fullscreen, token: window.nativeStateObservationToken())
            XCTAssertNil(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(window.windowId)))
        }
    }

    func testTiledAndAttachedPopupWindowsAreNotActivationCandidates() {
        let window = makeFocusedFloatingWindow()
        for parent in [focus.workspace.rootTilingContainer as NonLeafTreeNodeObject, macosPopupWindowsContainer] {
            window.bind(to: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            let presentation = makeActivation(window)
            XCTAssertNil(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(window.windowId)))
        }
    }

    func testLaterExplicitFocusChoiceCancelsRaiseEvenWhenIDsMatch() {
        let window = makeFocusedFloatingWindow()
        let presentation = makeActivation(window)
        _ = window.focusWindow()
        XCTAssertNil(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(window.windowId)))
    }

    func testCoalescedWindowRefreshRetainsLatestActivationIdentity() async throws {
        var events: [RefreshSessionEvent] = []
        var activationPids: [Int32?] = []
        await withCheckedContinuation { started in
            setScheduledRefreshOverrideForTests { event, _, activatedAppPid in
                events.append(event)
                activationPids.append(activatedAppPid)
                if events.count == 1 {
                    scheduleRefreshSession(.globalObserver(NSWorkspace.didActivateApplicationNotification.rawValue), activatedAppPid: 7)
                    scheduleRefreshSession(.ax(kAXWindowCreatedNotification as String))
                    scheduleRefreshSession(.globalObserver(NSWorkspace.didActivateApplicationNotification.rawValue), activatedAppPid: 9)
                    scheduleRefreshSession(.ax(kAXWindowCreatedNotification as String))
                    started.resume()
                }
            }
            scheduleRefreshSession(.ax(kAXWindowCreatedNotification as String))
        }
        try await waitForScheduledRefreshForTests()
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.last?.requiresWindowRefreshBarrier == true)
        XCTAssertEqual(activationPids, [nil, 9])
        setScheduledRefreshOverrideForTests(nil)
    }

    func testCommandCancelsPendingActivationWithoutDiscardingRefresh() async throws {
        TrayMenuModel.shared.isEnabled = true
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = makeFocusedFloatingWindow()
        var activationPids: [Int32?] = []
        var paused: CheckedContinuation<Void, Never>?
        await withCheckedContinuation { started in
            setScheduledRefreshOverrideForTests { _, _, activatedAppPid in
                activationPids.append(activatedAppPid)
                if activationPids.count == 1 {
                    scheduleRefreshSession(.globalObserver(NSWorkspace.didActivateApplicationNotification.rawValue), activatedAppPid: 7)
                    await withCheckedContinuation {
                        paused = $0
                        started.resume()
                    }
                }
            }
            scheduleRefreshSession(.ax(kAXWindowCreatedNotification as String))
        }
        try await runLightSession(.hotkeyBinding, .forceRun) {}
        paused?.resume()
        try await waitForScheduledRefreshForTests()
        XCTAssertGreaterThanOrEqual(activationPids.count, 2)
        XCTAssertTrue(activationPids.allSatisfy { $0 == nil })
        setScheduledRefreshOverrideForTests(nil)
    }

    private func makeFocusedFloatingWindow() -> TestWindow {
        let window = TestWindow.new(id: 1, parent: focus.workspace)
        _ = window.focusWindow()
        return window
    }

    private func makeActivation(_ window: Window) -> NewFloatingWindowPresentation {
        let presentation = NewFloatingWindowPresentation(isStartup: false, frontmostAppPid: 0, activatedAppPid: 0)
        presentation.recordNativeFocusBeforeLayout(window)
        return presentation
    }
}
