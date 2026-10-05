@testable import AppBundle
import AppKit
import Common
import XCTest

/// Tabs mode: a pin with no window is its app's home. A window of that app that would otherwise
/// get a new tab goes into the pin instead.
@MainActor
final class SavedWorkspaceEmptyPinTest: XCTestCase {
    private var defaultAppIsFrontmost: (@MainActor (Window) -> Bool)?

    private let telegram = "ru.keepcoder.Telegram"
    /// Running since long before WinMux started, so it's never armed.
    private lazy var telegramApp = TestApp(pid: 18293, bundleId: telegram, launchDate: savedTestNow.addingTimeInterval(-86400))
    private var running: [String: [SavedRunningApp]] {
        [telegram: [SavedRunningApp(pid: 18293, launchDate: savedTestNow.addingTimeInterval(-86400))]]
    }

    override func setUp() async throws {
        defaultAppIsFrontmost = newWindowAppIsFrontmost
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment(runningApps: running)
        workspaceSidebarOrganizationStore = .init()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        newWindowAppIsFrontmost = { _ in false }
    }

    override func tearDown() async throws {
        if let defaultAppIsFrontmost { newWindowAppIsFrontmost = defaultAppIsFrontmost }
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    /// A pin in All Projects whose saved place held Telegram's window 571.
    private func pinTelegram(_ name: String = "22") throws -> Workspace {
        let layout = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [
            savedSlot("telegram", bundleId: telegram, title: "Telegram", windowId: 571, pid: 18293),
        ]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: name, displayName: "Telegram", layout: layout))
        materializeSavedWorkspaceNames()
        let pin = try XCTUnwrap(Workspace.existing(byName: name))
        try setWorkspaceSidebarTabPinScope(pin, .allProjects, projectId: pin.projectId)
        return pin
    }

    /// The tab on screen, with a window of another app in it.
    private func workOnAnotherTab() -> Workspace {
        let work = Workspace.get(byName: "work")
        _ = TestWindow.new(id: 40, parent: work.rootTilingContainer, app: TestApp(pid: 77, bundleId: "com.example.editor"))
        XCTAssertTrue(work.focusWorkspace())
        return work
    }

    /// Checkpoints while Telegram keeps running with its window hidden, until the grace for a
    /// closed window has run out.
    private func captureUntilTheSlotIsDropped() {
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow, runningApps: running))
        let later = savedTestNow.addingTimeInterval(SavedWorkspaceTiming.closedWindowGrace + 1)
        savedWorkspaceRuntime.environment = .forTests(now: later, runningApps: running)
        captureSavedWorkspaces(facts: savedTestFacts(now: later, runningApps: running))
    }

    func testTheSameWindowShownAgainAfterItsSlotWasDroppedGoesBackToTheEmptyPin() async throws {
        let pin = try pinTelegram()
        let work = workOnAnotherTab()
        captureUntilTheSlotIsDropped()
        let record = try XCTUnwrap(savedWorkspaceStore.record(named: "22"))
        XCTAssertEqual(record.layout.allSlots.count, 0, "Its window was hidden for longer than the grace: the slot is dropped")
        XCTAssertEqual(record.launchApps?.map(\.bundleId), [telegram], "The pin still shows Telegram, dimmed")

        // Telegram shows the same window again (alt-t, or the Dock).
        let window = TestWindow.new(id: 571, parent: work.rootTilingContainer, app: telegramApp, title: "Telegram")
        let restored = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertFalse(restored)
        XCTAssertTrue(window.nodeWorkspace === pin, "It goes to the pin, not to a new tab")
        XCTAssertEqual(work.allLeafWindowsRecursive.map(\.windowId), [40])
        captureSavedWorkspaces(facts: savedTestFacts(now: savedWorkspaceRuntime.now, runningApps: running))
        let slots = try XCTUnwrap(savedWorkspaceStore.record(named: "22")).layout.allSlots
        XCTAssertEqual(slots.map(\.lastWindowId), [571])
        XCTAssertEqual(slots.map(\.lastPid), [18293])
    }
}
