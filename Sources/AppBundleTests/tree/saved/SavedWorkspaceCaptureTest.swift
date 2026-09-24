@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class SavedWorkspaceCaptureTest: XCTestCase {
    private let editor = "com.test.editor"
    private let terminal = "com.test.terminal"

    override func setUp() async throws { setUpWorkspacesForTests() }

    private func running(_ apps: [(String, Int32)]) -> [String: [SavedRunningApp]] {
        Dictionary(grouping: apps.map { ($0.0, SavedRunningApp(pid: $0.1, launchDate: savedTestNow.addingTimeInterval(-3600))) }, by: \.0)
            .mapValues { $0.map(\.1) }
    }

    func testCaptureRecordsTreeTabGroupWeightsTitlesAndMru() throws {
        let editorApp = TestApp(pid: 1001, bundleId: editor, name: "Editor", bundlePath: "/Applications/Editor.app")
        let workspace = Workspace.get(byName: "code")
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root, adaptiveWeight: 2, app: editorApp, title: "main.swift — App")
        let tabs = TilingContainer(parent: root, adaptiveWeight: 1, .v, .tabGroup, index: INDEX_BIND_LAST)
        let second = TestWindow.new(id: 2, parent: tabs, app: editorApp)
        TestWindow.new(id: 3, parent: tabs, app: editorApp)
        second.markAsMostRecentChild()
        try ensureSavedWorkspaceRecord(workspace)

        captureSavedWorkspaces(facts: savedTestFacts(titles: [2: "notes.md — App"]))

        let layout = try XCTUnwrap(savedWorkspaceStore.record(named: "code")).layout
        XCTAssertEqual(layout.root.allSlots.map(\.lastWindowId), [1, 2, 3])
        XCTAssertEqual(layout.root.children.map(\.weight), [2, 1])
        guard case .container(let savedTabs) = layout.root.children[1] else { return XCTFail() }
        XCTAssertEqual(savedTabs.layout, .tabGroup)
        XCTAssertEqual(savedTabs.children.map(\.isMostRecentInParent), [true, false])
        XCTAssertEqual(layout.root.allSlots.map(\.title), [nil, "notes.md — App", nil])
        XCTAssertEqual(layout.root.allSlots.first?.bundlePath, "/Applications/Editor.app")
        XCTAssertEqual(layout.root.allSlots.first?.lastPid, 1001)
    }

    func testCheckpointFetchesTitlesOfSavedWindows() async throws {
        setSavedWorkspaceTestEnvironment()
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app, title: "main.swift — App")
        TestWindow.new(id: 2, parent: workspace, app: app)
        try ensureSavedWorkspaceRecord(workspace)

        await runSavedWorkspaceCheckpoint()

        let layout = try XCTUnwrap(savedWorkspaceStore.record(named: "code")).layout
        XCTAssertEqual(layout.root.allSlots.map(\.title), ["main.swift — App"])
        XCTAssertEqual(layout.floating.map(\.title), ["TestWindow(2)"])
    }

    func testCheckpointSkippedWhileSuspendedOrFrozenForShutdown() async throws {
        setSavedWorkspaceTestEnvironment(runningApps: [editor: [SavedRunningApp(pid: 1001, launchDate: nil)]])
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        let before = try XCTUnwrap(savedWorkspaceStore.record(named: "code"))
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)

        savedWorkspaceRuntime.suspensions = [.screenLocked]
        await runSavedWorkspaceCheckpoint()
        XCTAssertEqual(savedWorkspaceStore.record(named: "code"), before)

        savedWorkspaceRuntime.suspensions = []
        savedWorkspaceRuntime.frozenForShutdownUntil = savedTestNow.addingTimeInterval(60)
        await runSavedWorkspaceCheckpoint()
        XCTAssertEqual(savedWorkspaceStore.record(named: "code"), before)

        savedWorkspaceRuntime.frozenForShutdownUntil = nil
        await runSavedWorkspaceCheckpoint()
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 2)
    }

    func testSlotIdsAreStableAcrossCaptures() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        let before = try XCTUnwrap(savedWorkspaceStore.record(named: "code")).layout.root.allSlots.map(\.id)

        captureSavedWorkspaces(facts: savedTestFacts(running: running([(editor, 1001)])))

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.map(\.id), before)
    }

    func testQuitAppSlotKeepsItsPosition() throws {
        let editorApp = TestApp(pid: 1001, bundleId: editor)
        let terminalApp = TestApp(pid: 1002, bundleId: terminal)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: editorApp)
        let terminalWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: terminalApp)
        TestWindow.new(id: 3, parent: workspace.rootTilingContainer, app: editorApp)
        try ensureSavedWorkspaceRecord(workspace)

        terminalWindow.unbindFromParent()
        captureSavedWorkspaces(facts: savedTestFacts(running: running([(editor, 1001)])))
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(3600), running: running([(editor, 1001)])))

        let slots = try XCTUnwrap(savedWorkspaceStore.record(named: "code")).layout.root.allSlots
        XCTAssertEqual(slots.map(\.bundleId), [editor, terminal, editor])
    }

    func testRelaunchedAppDropsSlotsOfWindowsItDidntBringBack() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        second.unbindFromParent()
        // The editor restarted as pid 2002 long enough ago that it isn't bringing window 2 back.
        let relaunched = [editor: [SavedRunningApp(pid: 2002, launchDate: savedTestNow.addingTimeInterval(-600))]]

        // Until the new instance shows a window, it may still restore this one.
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(3600), runningApps: relaunched, registeredWindowPids: [1001]))
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 2)

        captureSavedWorkspaces(facts: savedTestFacts(runningApps: relaunched, registeredWindowPids: [1001, 2002]))
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 2)
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(16), runningApps: relaunched, registeredWindowPids: [1001, 2002]))

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.map(\.lastWindowId), [1])
    }

    func testRelaunchThatRestoresNothingGetsTheLongerGrace() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        first.unbindFromParent()
        second.unbindFromParent()
        let relaunched = [editor: [SavedRunningApp(pid: 2002, launchDate: savedTestNow.addingTimeInterval(-600))]]

        captureSavedWorkspaces(facts: savedTestFacts(runningApps: relaunched, registeredWindowPids: [2002]))
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(30), runningApps: relaunched, registeredWindowPids: [2002]))
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 2)

        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(61), runningApps: relaunched, registeredWindowPids: [2002]))
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 0)
    }

    func testRelaunchedAppThatShowedAndClosedAWindowStillExpiresOldPlaces() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        second.unbindFromParent()
        let relaunched = [editor: [SavedRunningApp(pid: 2002, launchDate: savedTestNow.addingTimeInterval(-600))]]
        // The new instance showed a window long ago and has none now.
        savedWorkspaceRuntime.firstWindowSeenByPid[2002] = savedTestNow.addingTimeInterval(-600)

        captureSavedWorkspaces(facts: savedTestFacts(runningApps: relaunched, registeredWindowPids: [1001]))
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(16), runningApps: relaunched, registeredWindowPids: [1001]))

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.map(\.lastWindowId), [1])
    }

    func testWindowWaitingForItsTitleIsNotSavedWhereItLandedMeanwhile() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app, title: "")
        savedWorkspaceRuntime.windowsAwaitingTitle[2] = SavedTitleWait(since: savedTestNow, pid: 1001)

        captureSavedWorkspaces(facts: savedTestFacts(runningApps: running([(editor, 1001)])))

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.map(\.lastWindowId), [1])
    }

    func testRelaunchedAppThatJustShowedItsFirstWindowIsStillArmed() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        second.unbindFromParent()
        // Launched long ago (or with no launch date), but its first window appeared just now.
        let relaunched = [editor: [SavedRunningApp(pid: 2002, launchDate: nil)]]
        savedWorkspaceRuntime.firstWindowSeenByPid[2002] = savedTestNow

        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(30), runningApps: relaunched, registeredWindowPids: [1001, 2002]))

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 2)
        XCTAssertTrue(savedWorkspaceRuntime.vanishedSlots.isEmpty)
    }

    func testClosedWindowOfRunningAppDroppedOnlyAfterGrace() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        let closed = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        let apps = running([(editor, 1001)])

        closed.unbindFromParent()
        captureSavedWorkspaces(facts: savedTestFacts(running: apps))
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 2)
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(10), running: apps))
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 2)

        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(16), running: apps))

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.map(\.lastWindowId), [1])
        XCTAssertTrue(savedWorkspaceRuntime.vanishedSlots.isEmpty)
    }

    func testMassVanishUsesExtendedGrace() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        let apps = running([(editor, 1001)])

        first.unbindFromParent()
        second.unbindFromParent()
        captureSavedWorkspaces(facts: savedTestFacts(running: apps))
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(30), running: apps))
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 2)

        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(61), running: apps))
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 0)
    }

    func testStaleVanishedSlotsOfRemovedRecordsArePruned() throws {
        savedWorkspaceRuntime.vanishedSlots["slot-gone"] = SavedVanishedSlot(since: savedTestNow, grace: 15)
        _ = try makeSavedTestWorkspace("code")

        captureSavedWorkspaces(facts: savedTestFacts())

        XCTAssertTrue(savedWorkspaceRuntime.vanishedSlots.isEmpty)
    }

    func testGraceIsChosenWhenTheWindowVanishes() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        let apps = running([(editor, 1001)])
        first.unbindFromParent()
        second.unbindFromParent()
        captureSavedWorkspaces(facts: savedTestFacts(running: apps))

        // A new window arrives; the workspace is no longer empty, but the vanished windows keep
        // the longer grace they got when everything disappeared.
        TestWindow.new(id: 3, parent: workspace.rootTilingContainer, app: app)
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(30), running: apps))

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 3)
    }

    func testWindowBeingRoutedIsNeitherAdoptedNorMissing() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        savedWorkspaceRuntime.routingInFlightWindowIds = [2]

        captureSavedWorkspaces(facts: savedTestFacts(running: running([(editor, 1001)])))

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.map(\.lastWindowId), [1])
    }

    func testMinimizedWindowWithoutAttributionKeepsItsSlot() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        let minimized = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        let other = Workspace.get(byName: "other")
        let moved = TestWindow.new(id: 3, parent: workspace.rootTilingContainer, app: app)
        captureSavedWorkspaces(facts: savedTestFacts(running: running([(editor, 1001)])))

        minimized.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: nil)
        minimized.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        moved.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: other.name)
        moved.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(3600), running: running([(editor, 1001)])))

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.map(\.lastWindowId), [1, 2])
    }

    func testWindowStillClassifiedAsPopupKeepsItsSlot() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        let window = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)

        window.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(3600), running: running([(editor, 1001)])))

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.map(\.lastWindowId), [1, 2])
    }

    func testHiddenWorkspaceKeepsItsTwinDisplayTieBreak() throws {
        let laptop = SavedWorkspaceTestMonitor(id: 1, name: "Built-in", x: 0, isMain: true, uuid: "LAPTOP", isBuiltin: true)
        let first = SavedWorkspaceTestMonitor(id: 2, name: "Twin", x: 1920, uuid: "TWIN")
        let second = SavedWorkspaceTestMonitor(id: 3, name: "Twin", x: 3840, uuid: "TWIN")
        setMonitorsForTests([laptop, first, second])
        Workspace.reconcileWorkspaceState()
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertTrue(second.setActiveWorkspace(workspace))
        try ensureSavedWorkspaceRecord(workspace)

        setMonitorsForTests([laptop, first])
        Workspace.reconcileWorkspaceState()
        captureSavedWorkspaces(facts: savedTestFacts())
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.display?.lastTopLeft, CGPoint(x: 3840, y: 0))

        setMonitorsForTests([laptop, first, second])
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(second.activeWorkspace === workspace)
    }

    func testWindowMovedToAnotherWorkspaceDropsSlotImmediately() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        let moved = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        let other = try makeSavedTestWorkspace("other")

        moved.bind(to: other.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        captureSavedWorkspaces(facts: savedTestFacts(running: running([(editor, 1001)])))

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.map(\.lastWindowId), [1])
        XCTAssertEqual(savedWorkspaceStore.record(named: "other")?.layout.root.allSlots.map(\.lastWindowId), [2])
    }

    func testSlotsKeptDuringStartupRestoreWindowAndForArmedApps() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        let closed = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)
        closed.unbindFromParent()

        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(100), running: running([(editor, 1001)]), startupRestoreActive: true))
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 2)

        let justLaunched = [editor: [SavedRunningApp(pid: 1001, launchDate: savedTestNow.addingTimeInterval(170))]]
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(200), running: justLaunched))
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.count, 2)
    }

    func testFloatingWindowIsSavedAsFloating() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        TestWindow.new(id: 2, parent: workspace, app: app)

        try ensureSavedWorkspaceRecord(workspace)

        let layout = try XCTUnwrap(savedWorkspaceStore.record(named: "code")).layout
        XCTAssertEqual(layout.root.allSlots.map(\.lastWindowId), [1])
        XCTAssertEqual(layout.floating.map(\.lastWindowId), [2])
    }

    func testMinimizedWindowKeepsSlot() throws {
        let app = TestApp(pid: 1001, bundleId: editor)
        let workspace = Workspace.get(byName: "code")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer, app: app)
        let minimized = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, app: app)
        try ensureSavedWorkspaceRecord(workspace)

        minimized.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: "code")
        minimized.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(3600), running: running([(editor, 1001)])))

        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.layout.root.allSlots.map(\.lastWindowId), [1, 2])
    }

    func testVisibilityOnHomeBumpsSequenceOnlyWhenItBecomesVisible() throws {
        let main = SavedWorkspaceTestMonitor(id: 1, name: "Main", x: 0, isMain: true, uuid: "MAIN")
        setMonitorsForTests([main])
        let first = Workspace.get(byName: "a")
        let second = Workspace.get(byName: "b")
        XCTAssertTrue(main.setActiveWorkspace(first))
        try ensureSavedWorkspaceRecord(first)
        try ensureSavedWorkspaceRecord(second)
        XCTAssertNotNil(savedWorkspaceStore.record(named: "b")?.display)
        let firstSequence = try XCTUnwrap(savedWorkspaceStore.record(named: "a")?.lastVisibleSequence)

        captureSavedWorkspaces(facts: savedTestFacts())
        XCTAssertEqual(savedWorkspaceStore.record(named: "a")?.lastVisibleSequence, firstSequence)

        XCTAssertTrue(main.setActiveWorkspace(second))
        captureSavedWorkspaces(facts: savedTestFacts())

        let secondSequence = try XCTUnwrap(savedWorkspaceStore.record(named: "b")?.lastVisibleSequence)
        XCTAssertGreaterThan(secondSequence, firstSequence)
    }
}

@MainActor
private func savedTestFacts(now: Date = savedTestNow, running: [String: [SavedRunningApp]], startupRestoreActive: Bool = false) -> SavedWorkspaceCaptureFacts {
    savedTestFacts(now: now, runningApps: running, startupRestoreActive: startupRestoreActive)
}
