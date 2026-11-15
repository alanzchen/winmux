@testable import AppBundle
import AppKit
import XCTest

/// A window set aside, brought back where a reopen asked: macOS's focus, read after the restore, decides its focus once
/// per refresh (Astra REVIEW-7, R7-2 and R7-3). A native panel that had focus is never overridden, and a restore under
/// way when it was placed only places it.
@MainActor
final class RestoreFocusDecisionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetFocusCacheForTests()
        resetFrozenRestoresForTests()
        NewWindowIntentRegistry.shared.resetForTests()
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = nil
        TestApp.shared.hasActiveTransientNativeFocus = false
    }

    override func tearDown() async throws {
        setBlockingRefreshOverridesForTests()
        resetFocusCacheForTests()
        resetFrozenRestoresForTests()
        NewWindowIntentRegistry.shared.resetForTests()
        TestApp.shared.focusedWindow = nil
        TestApp.shared.hasActiveTransientNativeFocus = false
        appForTests = nil
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private func setAsideAndAskToReopen(nativeAnchor: Bool) async throws -> (anchor: TestWindow, returning: TestWindow) {
        let target = focus.workspace
        let anchor = TestWindow.new(id: 100, parent: target.rootTilingContainer)
        let returning = TestWindow.new(id: 200, parent: Workspace.get(byName: "old").rootTilingContainer)
        _ = anchor.focusWindow()
        TestApp.shared.focusedWindow = nativeAnchor ? anchor : nil
        if nativeAnchor { updateFocusCache(anchor) }
        noteWindowPresentability([200: false])
        try await normalizeLayoutReason()
        XCTAssertTrue(returning.isSetAsideAsNotPresentable)
        let registry = NewWindowIntentRegistry.shared
        XCTAssertNotNil(registry.register(bundleId: try XCTUnwrap(returning.app.rawAppBundleId), pid: returning.app.pid,
            targetWorkspace: target, preexistingWindowIds: [], focusGeneration: focusChangeGeneration, reopens: true))
        registry.isRegistered = { $0 === anchor || $0 === returning }
        return (anchor, returning)
    }

    /// A native panel had focus when the refresh began and was gone after the restore: macOS's focus changed meanwhile,
    /// and the newer one stands.
    func testAReopenDoesntTakeFocusAPanelHeldWhenTheRefreshBegan() async throws {
        let (anchor, returning) = try await setAsideAndAskToReopen(nativeAnchor: false)
        TestApp.shared.hasActiveTransientNativeFocus = true
        setBlockingRefreshOverridesForTests(refresh: {
            noteWindowPresentability([200: true])
            TestApp.shared.hasActiveTransientNativeFocus = false
        })
        try await runHeavyCompleteRefreshSession(.globalObserverLeftMouseUp)
        XCTAssertTrue(returning.nodeWorkspace === anchor.nodeWorkspace, "Placed where asked")
        XCTAssertEqual(returning.nativeFocusCount, 0)
    }

    /// macOS's focus didn't change: the refresh focuses the reopened window, and the restore under way, ending, doesn't
    /// focus it again.
    func testARestoreUnderWayEndingDoesntFocusAReopenedWindowAgain() async throws {
        let (anchor, returning) = try await setAsideAndAskToReopen(nativeAnchor: true)
        beginFrozenRestore()
        setBlockingRefreshOverridesForTests(refresh: { noteWindowPresentability([200: true]) })
        try await runHeavyCompleteRefreshSession(.globalObserverLeftMouseUp)
        XCTAssertTrue(returning.nodeWorkspace === anchor.nodeWorkspace)
        XCTAssertEqual(returning.nativeFocusCount, 1, "The refresh decided")
        endFrozenRestore()
        XCTAssertEqual(returning.nativeFocusCount, 1)
        XCTAssertFalse(NewWindowIntentRegistry.shared.hasPendingIntents)
    }

    /// Brought back with no read of macOS's focus after it (a refresh cut short; here, outside one) while a restore was
    /// under way: that restore, ending, only places it.
    func testARestoreUnderWayEndingDoesntFocusAReopenNoRefreshDecided() async throws {
        let (anchor, returning) = try await setAsideAndAskToReopen(nativeAnchor: true)
        beginFrozenRestore()
        noteWindowPresentability([200: true])
        try await normalizeLayoutReason()
        XCTAssertTrue(returning.nodeWorkspace === anchor.nodeWorkspace)
        endFrozenRestore()
        XCTAssertEqual(returning.nativeFocusCount, 0)
        XCTAssertEqual(anchor.nativeFocusCount, 0)
    }
}
