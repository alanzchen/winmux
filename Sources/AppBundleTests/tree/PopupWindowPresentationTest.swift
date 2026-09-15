@testable import AppBundle
import Common
import XCTest

@MainActor
final class PopupWindowPresentationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testNewPopupPromotedToIndependentWindowPresentsAfterFloatingCallback() async throws {
        let existing = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = existing.focusWindow()
        let promoted = TestWindow.new(id: 2, parent: macosPopupWindowsContainer)
        var origin = PopupWindowPresentationState(firstSeenDuringStartup: false, firstSeenInActiveApp: true, wasInitiallyPopup: true)
        let presentation = NewFloatingWindowPresentation(isStartup: false, frontmostAppPid: 0)
        presentation.recordNativeFocusBeforeLayout(existing)
        config.onWindowDetected = [WindowDetectedCallback(rawRun: [
            LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.floating])),
        ])]

        // Positive AX reclassification binds the formerly incomplete window before
        // its callback runs. This is the same handoff used by validateStillPopups.
        promoted.bind(to: focus.workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        try await $newFloatingWindowPresentation.withValue(presentation) {
            try await runCallbacksAfterPopupPromotion(promoted, mayPresent: origin.consume())
        }

        XCTAssertTrue(promoted.isFloating)
        XCTAssertTrue(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(existing.windowId)) === promoted)
        XCTAssertFalse(origin.consume(), "A later reclassification must not present an existing window again")
    }

    func testStartupRestoredBackgroundAndPreviouslyManagedWindowsNeverPresentOnPromotion() async throws {
        for (startup, restored, initiallyActive, initiallyPopup) in [(true, false, true, true), (false, true, true, true), (false, false, false, true), (false, false, true, false)] {
            setUpWorkspacesForTests()
            let existing = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
            _ = existing.focusWindow()
            let promoted = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
            var origin = PopupWindowPresentationState(firstSeenDuringStartup: startup, firstSeenInActiveApp: initiallyActive, wasInitiallyPopup: initiallyPopup)
            origin.wasRestored = restored
            let presentation = NewFloatingWindowPresentation(isStartup: false, frontmostAppPid: 0)
            presentation.recordNativeFocusBeforeLayout(existing)
            config.onWindowDetected = [WindowDetectedCallback(rawRun: [
                LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.floating])),
            ])]

            try await $newFloatingWindowPresentation.withValue(presentation) {
                try await runCallbacksAfterPopupPromotion(promoted, mayPresent: origin.consume())
            }

            XCTAssertTrue(promoted.isFloating, "Existing callback behavior is preserved")
            XCTAssertNil(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(existing.windowId)))
            XCTAssertTrue(focus.windowOrNil === existing)
        }
    }

    func testPromotedWindowRunsCompleteCallbackChainBeforePresentationDecision() async throws {
        let existing = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        _ = existing.focusWindow()
        let promoted = TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        var origin = PopupWindowPresentationState(firstSeenDuringStartup: false, firstSeenInActiveApp: true, wasInitiallyPopup: true)
        let presentation = NewFloatingWindowPresentation(isStartup: false, frontmostAppPid: 0)
        presentation.recordNativeFocusBeforeLayout(existing)
        config.onWindowDetected = [
            WindowDetectedCallback(checkFurtherCallbacks: true, rawRun: [
                LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.floating])),
            ]),
            WindowDetectedCallback(rawRun: [
                MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "hidden")),
            ]),
        ]

        try await $newFloatingWindowPresentation.withValue(presentation) {
            try await runCallbacksAfterPopupPromotion(promoted, mayPresent: origin.consume())
        }

        XCTAssertEqual(promoted.nodeWorkspace?.name, "hidden")
        XCTAssertTrue(promoted.isFloating)
        XCTAssertNil(presentation.consumeCandidate(frontmostAppPid: 0, nativeObservation: .window(existing.windowId)))
        XCTAssertTrue(focus.windowOrNil === existing)
    }
}
