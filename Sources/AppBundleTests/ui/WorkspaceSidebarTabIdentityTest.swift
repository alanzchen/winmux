import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarTabIdentityTest: XCTestCase {
    private var originalAppIsFrontmost: (@MainActor (AppBundle.Window) -> Bool)?

    override func setUp() async throws {
        originalAppIsFrontmost = newWindowAppIsFrontmost
        prepareTabs()
        newWindowAppIsFrontmost = { _ in true }
    }

    override func tearDown() async throws {
        if let originalAppIsFrontmost { newWindowAppIsFrontmost = originalAppIsFrontmost }
        WorkspaceSidebarTabUndo.shared.clear()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
        try await super.tearDown()
    }

    private func prepareTabs() {
        setUpWorkspacesForTests()
        setRunningTestApp()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        workspaceSidebarOrganizationStore = .init()
        config.workspaceSidebar = .init(enabled: true, mode: .tabs)
    }

    private func setRunningTestApp(at now: Date = savedTestNow) {
        setSavedWorkspaceTestEnvironment(now: now, runningApps: ["bobko.WinMux.test-app": [
            SavedRunningApp(pid: TestApp.shared.pid, launchDate: now.addingTimeInterval(-3600)),
        ]])
        savedWorkspaceRuntime.firstWindowSeenByPid[TestApp.shared.pid] = now.addingTimeInterval(-3600)
    }

    func testNewSameAppWindowInheritsGroupAndRemainsASeparateTab() async throws {
        let origin = focus.workspace
        let opener = TestWindow.new(id: 201, parent: origin.rootTilingContainer)
        XCTAssertTrue(opener.focusWindow())
        let group = try workspaceSidebarOrganizationStore.create(projectId: origin.projectId, workspaceNames: [origin.name])
        try workspaceSidebarOrganizationStore.edit(group.id) { $0.isCollapsed = true }
        let window = TestWindow.new(id: 202, parent: origin.rootTilingContainer)
        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
        let target = try XCTUnwrap(window.nodeWorkspace)
        XCTAssertFalse(target === origin)
        XCTAssertEqual(target.allLeafWindowsRecursive.map(\.windowId), [202])
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: target.name)?.id, group.id)
        XCTAssertTrue(focus.windowOrNil === window)
        XCTAssertTrue(try XCTUnwrap(workspaceSidebarOrganizationStore.collection(containing: target.name)).containsVisibleWorkspace())
        XCTAssertEqual(workspaceNavigationTabs(current: target).map(\.name), [origin.name, target.name])
    }

    func testBackgroundOtherAppStartupAndUnfocusedWindowsDoNotInheritGroup() async throws {
        for scenario in ["background", "other-app", "startup", "restoring", "inactive-origin", "sidebar-mode"] {
            prepareTabs()
            newWindowAppIsFrontmost = { _ in scenario != "background" }
            let origin = focus.workspace
            XCTAssertTrue(TestWindow.new(id: 201, parent: origin.rootTilingContainer).focusWindow())
            _ = try workspaceSidebarOrganizationStore.create(projectId: origin.projectId, workspaceNames: [origin.name])
            if scenario == "inactive-origin" {
                XCTAssertTrue(TestWindow.new(id: 203, parent: Workspace.get(byName: "elsewhere").rootTilingContainer).focusWindow())
            }
            if scenario == "restoring" { savedWorkspaceRuntime.runtimeReadyAt = savedWorkspaceRuntime.now }
            if scenario == "sidebar-mode" {
                config.workspaceSidebar.mode = .sidebar
                config.openNewWindowsInNewWorkspace = true
            }
            let app = scenario == "other-app" ? TestApp(pid: 99, bundleId: "test.other") : TestApp.shared
            let window = TestWindow.new(id: 202, parent: origin.rootTilingContainer, app: app)
            try await $_isStartup.withValue(scenario == "startup") {
                _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
            }
            let target = try XCTUnwrap(window.nodeWorkspace)
            XCTAssertFalse(target === origin, scenario)
            XCTAssertNil(workspaceSidebarOrganizationStore.collection(containing: target.name), scenario)
        }
    }

    func testNewWindowRuleOverridesGroupInheritance() async throws {
        let origin = focus.workspace
        XCTAssertTrue(TestWindow.new(id: 201, parent: origin.rootTilingContainer).focusWindow())
        _ = try workspaceSidebarOrganizationStore.create(projectId: origin.projectId, workspaceNames: [origin.name])
        let (parsed, errors) = parseConfig("""
        [[on-window-detected]]
        if.app-id = 'bobko.WinMux.test-app'
        run = ['move-node-to-workspace destination']
        """)
        XCTAssertEqual(errors.descriptions, [])
        config.onWindowDetected = parsed.onWindowDetected
        let window = TestWindow.new(id: 202, parent: origin.rootTilingContainer)
        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
        XCTAssertEqual(window.nodeWorkspace?.name, "destination")
        XCTAssertNil(workspaceSidebarOrganizationStore.collection(containing: "destination"))
    }

    func testInheritedGroupDoesNotKeepAnEmptyTabOrLeaveItsNameReserved() async throws {
        let (origin, window, target, group) = try await newGroupedWindow()
        XCTAssertTrue(target.isSaved) // Reserve the identity for restoration, not an empty tab.
        XCTAssertFalse(target.isKeptWhenEmpty)
        let record = try XCTUnwrap(savedWorkspaceStore.record(named: target.name))
        XCTAssertEqual(record.keepWhenEmpty, false)
        XCTAssertEqual(try JSONDecoder().decode(SavedWorkspaceRecord.self, from: JSONEncoder().encode(record)), record)
        var model = tab(target.name, ids: [window.windowId])
        model.savedState = workspaceSidebarSavedState(for: target, runningApps: [:])
        let titles = workspaceSidebarWorkspaceMenuEntries(model,
            context: .init(monitorCount: 1, currentDisplayName: nil, separatesIntoTabs: true)).map(\.title)
        XCTAssertTrue(titles.contains("Keep Tab When Empty"))
        XCTAssertFalse(titles.contains("Stop Keeping Empty Tab"))
        let sidebarTitles = workspaceSidebarWorkspaceMenuEntries(model,
            context: .init(monitorCount: 1, currentDisplayName: nil)).map(\.title)
        XCTAssertTrue(sidebarTitles.contains("Keep Workspace When Empty"))
        XCTAssertFalse(sidebarTitles.contains("Save Workspace"))
        window.closeAxWindow()
        XCTAssertTrue(workspaceTabAfterLastWindowClosed(target) === origin)
        XCTAssertTrue(origin.focusWorkspace())
        pruneEmptyWorkspaces()
        XCTAssertFalse(isUserFacingWorkspace(target), "The closed tab disappears while its short restore grace elapses")
        XCTAssertTrue(Workspace.existing(byName: target.name) === target)
        XCTAssertEqual(savedWorkspaceStore.record(named: target.name)?.keepWhenEmpty, false)
        let rows = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:], availableMonitors: monitors)
        XCTAssertFalse(rows.contains { $0.name == target.name })
        setRunningTestApp(at: savedTestNow.addingTimeInterval(SavedWorkspaceTiming.closedWindowGrace + 1))
        pruneEmptyWorkspaces()
        XCTAssertNil(Workspace.existing(byName: target.name))
        XCTAssertNil(savedWorkspaceStore.record(named: target.name))
        XCTAssertFalse(try XCTUnwrap(workspaceSidebarOrganizationStore.state.collections.first { $0.id == group.id })
            .workspaceNames.contains(target.name))
        materializeSavedWorkspaceNames()
        XCTAssertNil(Workspace.existing(byName: target.name))
    }

    func testExplicitSavingOrCustomizationKeepsAnInheritedTabWhenEmpty() async throws {
        for edit in ["save", "rename", "customize", "group"] {
            prepareTabs()
            let (origin, window, target, group) = try await newGroupedWindow()
            switch edit {
                case "save": try saveWorkspaceForSidebar(workspaceName: target.name, displayName: nil)
                case "rename": try renameWorkspaceForSidebar(workspaceName: target.name, displayName: "Review")
                case "customize": try saveWorkspaceSidebarIdentity(target)
                default: try assignWorkspaceToSidebarCollection(target, collectionId: group.id)
            }
            XCTAssertTrue(target.isKeptWhenEmpty, edit)
            window.closeAxWindow()
            XCTAssertNil(workspaceTabAfterLastWindowClosed(target), edit)
            XCTAssertTrue(origin.focusWorkspace())
            pruneEmptyWorkspaces()
            XCTAssertTrue(Workspace.existing(byName: target.name) === target, edit)
            XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: target.name)?.id, group.id, edit)
        }
    }

    func testInheritedIdentityWaitsForRestorationBeforePruning() async throws {
        let (origin, window, target, _) = try await newGroupedWindow()
        window.closeAxWindow()
        XCTAssertTrue(origin.focusWorkspace())
        let file = savedWorkspaceStore.file
        savedWorkspaceStore = .init(file: try JSONDecoder().decode(SavedWorkspacesFile.self,
            from: JSONEncoder().encode(file)), url: nil)
        savedWorkspaceRuntime.runtimeReadyAt = savedWorkspaceRuntime.now
        pruneEmptyWorkspaces()
        XCTAssertTrue(Workspace.existing(byName: target.name) === target)
        setRunningTestApp()
        savedWorkspaceRuntime.windowsAwaitingTitle[202] = .init(since: savedWorkspaceRuntime.now, pid: TestApp.shared.pid)
        pruneEmptyWorkspaces()
        XCTAssertTrue(Workspace.existing(byName: target.name) === target)
        savedWorkspaceRuntime.windowsAwaitingTitle = [:]
        pruneEmptyWorkspaces()
        setRunningTestApp(at: savedTestNow.addingTimeInterval(SavedWorkspaceTiming.closedWindowGrace + 1))
        pruneEmptyWorkspaces()
        XCTAssertNil(Workspace.existing(byName: target.name))
    }

    func testReadOnlyStoresSkipAutomaticGroupInheritance() async throws {
        for store in ["organization", "saved"] {
            prepareTabs()
            let origin = focus.workspace
            XCTAssertTrue(TestWindow.new(id: 201, parent: origin.rootTilingContainer).focusWindow())
            _ = try workspaceSidebarOrganizationStore.create(projectId: origin.projectId, workspaceNames: [origin.name])
            if store == "organization" {
                workspaceSidebarOrganizationStore = .init(state: workspaceSidebarOrganizationStore.state, readOnlyReason: "Read only")
            } else {
                savedWorkspaceStore = .init(url: nil, readOnlyReason: "Read only")
            }
            let window = TestWindow.new(id: 202, parent: origin.rootTilingContainer)
            _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
            let target = try XCTUnwrap(window.nodeWorkspace)
            XCTAssertFalse(target === origin, store)
            XCTAssertFalse(target.isSaved, store)
            XCTAssertNil(workspaceSidebarOrganizationStore.collection(containing: target.name), store)
        }
    }

    func testKeepingAnInheritedTabRequiresAWritableSavedIdentity() async throws {
        let (origin, window, target, group) = try await newGroupedWindow()
        let file = savedWorkspaceStore.file
        savedWorkspaceStore = .init(file: file, url: nil, readOnlyReason: "Saved by a newer version")
        XCTAssertThrowsError(try saveWorkspaceForSidebar(workspaceName: target.name, displayName: nil))
        XCTAssertThrowsError(try saveWorkspaceSidebarIdentity(target))
        XCTAssertEqual(savedWorkspaceStore.file, file)
        window.closeAxWindow()
        XCTAssertTrue(origin.focusWorkspace())
        pruneEmptyWorkspaces()
        XCTAssertEqual(savedWorkspaceStore.file, file)
        XCTAssertTrue(Workspace.existing(byName: target.name) === target)
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: target.name)?.id, group.id)
    }

    private func newGroupedWindow() async throws -> (Workspace, TestWindow, Workspace, WorkspaceTabCollection) {
        let origin = focus.workspace
        XCTAssertTrue(TestWindow.new(id: 201, parent: origin.rootTilingContainer).focusWindow())
        let group = try workspaceSidebarOrganizationStore.create(projectId: origin.projectId, workspaceNames: [origin.name])
        let window = TestWindow.new(id: 202, parent: origin.rootTilingContainer)
        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
        return (origin, window, try XCTUnwrap(window.nodeWorkspace), group)
    }

    func testReorderingAndDetachingDoNotKeepInheritedTabsWhenEmpty() async throws {
        for operation in ["reorder", "detach", "gap"] {
            prepareTabs()
            let (origin, window, inherited, group) = try await newGroupedWindow()
            if operation != "reorder" { _ = TestWindow.new(id: 203, parent: inherited.rootTilingContainer) }
            if operation == "detach" { try detachWorkspaceTabWindow(window) }
            else {
                applyTabGapDrop(sourceNode: window, sourceWindow: window, projectId: origin.projectId,
                    monitor: origin.workspaceMonitor,
                    gap: .init(workspaceName: origin.name, isAfter: false, collectionId: group.id))
            }
            let target = try XCTUnwrap(window.nodeWorkspace)
            XCTAssertEqual(target === inherited, operation == "reorder")
            XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: target.name)?.id, group.id)
            XCTAssertFalse(target.isKeptWhenEmpty, operation)
            XCTAssertEqual(savedWorkspaceStore.record(named: target.name)?.layout.allSlots.map(\.lastWindowId), [window.windowId])
            window.closeAxWindow()
            XCTAssertTrue(origin.focusWorkspace())
            pruneEmptyWorkspaces()
            setRunningTestApp(at: savedTestNow.addingTimeInterval(SavedWorkspaceTiming.closedWindowGrace + 1))
            pruneEmptyWorkspaces()
            XCTAssertNil(savedWorkspaceStore.record(named: target.name), operation)
        }
    }

    func testQuitAndLateRelaunchRestoreInheritedGroupWithoutAnEmptySidebarRow() async throws {
        let (origin, window, target, group) = try await newGroupedWindow()
        window.closeAxWindow()
        origin.allLeafWindowsRecursive.forEach { $0.closeAxWindow() }
        let otherApp = TestApp(pid: 90, bundleId: "other")
        let other = TestWindow.new(id: 290, parent: origin.rootTilingContainer, app: otherApp)
        XCTAssertTrue(other.focusWindow())
        let later = savedTestNow.addingTimeInterval(700)
        setSavedWorkspaceTestEnvironment(now: later, runningApps: ["other": [.init(pid: 90, launchDate: nil)]])
        pruneEmptyWorkspaces()
        XCTAssertTrue(Workspace.existing(byName: target.name) === target)
        XCTAssertFalse(isUserFacingWorkspace(target))
        let rows = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:], availableMonitors: monitors)
        XCTAssertFalse(rows.contains { $0.name == target.name })
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: target.name)?.id, group.id)
        let returningApp = TestApp(pid: 91, bundleId: "bobko.WinMux.test-app", launchDate: later)
        setSavedWorkspaceTestEnvironment(now: later, runningApps: [
            "other": [.init(pid: 90, launchDate: nil)], "bobko.WinMux.test-app": [.init(pid: 91, launchDate: later)],
        ])
        let returning = TestWindow.new(id: 291, parent: origin.rootTilingContainer, app: returningApp)
        _ = try await restoreOrDetectNewWindow(returning, isRegularWindow: true)
        XCTAssertTrue(returning.nodeWorkspace === target)
        XCTAssertFalse(target.isKeptWhenEmpty)
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: target.name)?.id, group.id)
    }

    func testHiddenAndMinimizedInheritedWindowsKeepTheirGroup() async throws {
        for state in ["hidden", "minimized"] {
            prepareTabs()
            let (origin, window, target, group) = try await newGroupedWindow()
            if state == "hidden" {
                window.bind(to: target.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
            } else {
                window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: target.name)
                window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
            }
            XCTAssertTrue(origin.focusWorkspace())
            pruneEmptyWorkspaces()
            XCTAssertTrue(Workspace.existing(byName: target.name) === target, state)
            XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: target.name)?.id, group.id, state)
        }
    }

    func testNewTabDoesNotReuseAnInheritedIdentityWaitingForRestoration() async throws {
        let (_, window, target, _) = try await newGroupedWindow()
        window.closeAxWindow()
        XCTAssertTrue(target.focusWorkspace())
        savedWorkspaceRuntime.runtimeReadyAt = savedWorkspaceRuntime.now
        let newTab = newTabWorkspace(projectId: target.projectId, monitor: target.workspaceMonitor)
        XCTAssertTrue(newTab.isNew)
        XCTAssertFalse(newTab.workspace === target)
        XCTAssertNil(workspaceSidebarOrganizationStore.collection(containing: newTab.workspace.name))
    }

    func testProjectFallbackSkipsHiddenAutomaticIdentitiesEvenWhenRemembered() async throws {
        let (origin, window, target, _) = try await newGroupedWindow()
        let project = createWorkspaceProject()
        XCTAssertTrue(moveWorkspaceToProject(workspaceName: target.name, projectId: project.id))
        for empty in projectWorkspaces(projectId: project.id) where empty !== target {
            removeWorkspaceFromRegistry(empty, reason: .deleted)
        }
        window.closeAxWindow()
        XCTAssertTrue(origin.focusWorkspace())
        setSavedWorkspaceTestEnvironment(runningApps: [:]) // The saved slot waits for the app's next launch.
        pruneEmptyWorkspaces()
        XCTAssertTrue(Workspace.existing(byName: target.name) === target)
        XCTAssertFalse(target.isOrdinaryEmptySlot)
        XCTAssertFalse(isUserFacingWorkspace(target))
        let monitor = origin.workspaceMonitor
        XCTAssertNil(preferredWorkspace(projectId: project.id, monitor: monitor))
        XCTAssertNil(availablePreferredWorkspace(projectId: project.id, monitor: monitor))
        XCTAssertFalse(workspaceNavigationTabs(current: target).contains(target))
        let viewport = MonitorViewportId(monitor)
        winMuxWorkspaceState.monitorViewportsById[viewport]?.lastActiveWorkspaceByProject[project.id] = target.id
        let selected = try XCTUnwrap(switchWorkspaceProject(project.id, on: monitor))
        XCTAssertFalse(selected === target)
        XCTAssertEqual(selected.projectId, project.id)
        XCTAssertFalse(selected.isSaved)
    }

    func testFailedGroupCleanupBacksOffWithoutReleasingTheIdentity() async throws {
        let (origin, window, target, group) = try await newGroupedWindow()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("blocked")
        try Data().write(to: parent) // A file cannot contain sidebar-organization.json.
        workspaceSidebarOrganizationStore = .init(state: workspaceSidebarOrganizationStore.state,
            url: parent.appendingPathComponent("sidebar-organization.json"))
        window.closeAxWindow()
        XCTAssertTrue(origin.focusWorkspace())
        pruneEmptyWorkspaces()
        let expired = savedTestNow.addingTimeInterval(SavedWorkspaceTiming.closedWindowGrace + 1)
        setRunningTestApp(at: expired)
        pruneEmptyWorkspaces()
        let retry = try XCTUnwrap(savedWorkspaceRuntime.organizationPruneRetryAfter[target.name])
        XCTAssertTrue(Workspace.existing(byName: target.name) === target)
        XCTAssertTrue(target.isSaved)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        pruneEmptyWorkspaces()
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: target.name)?.id, group.id,
            "Even after the path recovers, no write is retried before the deadline")
        setRunningTestApp(at: retry)
        pruneEmptyWorkspaces()
        XCTAssertNil(Workspace.existing(byName: target.name))
        XCTAssertNil(savedWorkspaceRuntime.organizationPruneRetryAfter[target.name])
    }

    func testSplitUndoRestoresAPrunedInheritedIdentityThroughTheSidebarSession() async throws {
        let wasEnabled = TrayMenuModel.shared.isEnabled
        let previousApp = appForTests
        TrayMenuModel.shared.isEnabled = true
        appForTests = TestApp.shared
        setScheduledRefreshOverrideForTests { _, _, _ in }
        defer {
            TrayMenuModel.shared.isEnabled = wasEnabled
            appForTests = previousApp
            setScheduledRefreshOverrideForTests(nil)
        }
        let (origin, window, target, group) = try await newGroupedWindow()
        window.nativeFocus()
        let split = try XCTUnwrap(runWorkspaceSidebarSession(undoTitle: "Split Tabs") {
            try splitWorkspaceSidebarTabWindow(window.windowId, fromWorkspace: target.id, withWorkspace: origin.id)
        })
        await split.value
        XCTAssertNil(Workspace.existing(byName: target.name))
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Split Tabs")
        try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {}
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Split Tabs")
        let undo = try XCTUnwrap(runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() })
        await undo.value
        XCTAssertTrue(window.nodeWorkspace === target)
        XCTAssertFalse(target.isKeptWhenEmpty)
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: target.name)?.id, group.id)
        XCTAssertEqual(savedWorkspaceStore.record(named: target.name)?.keepWhenEmpty, false)
    }

    func testSplitMenuUsesVisibleOrderAndKeepsRelatedActionsTogether() throws {
        let source = focus.workspace
        let first = TestWindow.new(id: 201, parent: source.rootTilingContainer)
        _ = TestWindow.new(id: 202, parent: source.rootTilingContainer)
        XCTAssertTrue(first.focusWindow())
        for (index, name) in ["ordinary", "pin", "last"].enumerated() {
            _ = TestWindow.new(id: UInt32(210 + index), parent: Workspace.get(byName: name).rootTilingContainer)
        }
        try workspaceSidebarOrganizationStore.update { $0.workspaces["pin"] = .init(isFavorite: true) }
        XCTAssertEqual(workspaceSidebarSplitDestinations(windowId: 202).map(\.name), ["pin", "ordinary", "last"])
        let oldSnapshot = TrayMenuModel.shared.workspaceSidebarWorkspaces
        defer { TrayMenuModel.shared.workspaceSidebarWorkspaces = oldSnapshot }
        TrayMenuModel.shared.workspaceSidebarWorkspaces = [tab("pin", ids: [211], label: "Inbox", emoji: "📮")]
        var sent: [WorkspaceSidebarAction] = []
        let menu = workspaceSidebarWorkspaceIdentityMenuModel(tab(source.name, ids: [201, 202]), windowId: 202,
            send: { sent.append($0) })
        let titles = menu.entries.map(\.title)
        XCTAssertFalse(titles.contains { $0.hasPrefix("Customize") })
        XCTAssertFalse(titles.contains("Rename Tab"))
        XCTAssertNotEqual(titles.first, "")
        XCTAssertNotEqual(titles.last, "")
        XCTAssertFalse(zip(titles, titles.dropFirst()).contains { $0.isEmpty && $1.isEmpty })
        let detach = try XCTUnwrap(titles.firstIndex(of: "Move Notes to New Tab"))
        XCTAssertEqual(titles[detach + 1], "Separate into Tabs")
        XCTAssertLessThan(detach, try XCTUnwrap(titles.firstIndex(of: "Keep Tab When Empty")))
        XCTAssertEqual(menu.entries.first { $0.title == "Split with" }?.children.first?.title, "📮 Inbox")
        try XCTUnwrap(menu.entries.first { $0.title == "Split with" }?.children.first?.perform)()
        XCTAssertEqual(sent, [.splitTabWindow(202, fromWorkspace: source.id, withWorkspace: Workspace.get(byName: "pin").id)])

        config.workspaceSidebar.mode = .sidebar
        let oldMenu = workspaceSidebarWorkspaceIdentityMenuModel(tab(source.name, ids: [201, 202]), send: { _ in })
        XCTAssertTrue(oldMenu.entries.contains { $0.title == "Customize Sidebar…" })
        XCTAssertFalse(oldMenu.entries.contains { $0.title == "Split with" })
    }

    func testMenuSplitMovesOnlyClickedMemberPreservesDestinationAndCanUndo() throws {
        let source = focus.workspace
        let first = TestWindow.new(id: 201, parent: source.rootTilingContainer)
        let second = TestWindow.new(id: 202, parent: source.rootTilingContainer)
        XCTAssertTrue(first.focusWindow())
        let destination = Workspace.get(byName: "destination")
        _ = TestWindow.new(id: 203, parent: destination.rootTilingContainer)
        let group = try workspaceSidebarOrganizationStore.create(projectId: destination.projectId, workspaceNames: [destination.name])
        let before = WorkspaceSidebarTabUndoSnapshot()
        try splitWorkspaceSidebarTabWindow(202, fromWorkspace: source.id, withWorkspace: destination.id)
        XCTAssertTrue(first.nodeWorkspace === source)
        XCTAssertTrue(second.nodeWorkspace === destination)
        XCTAssertEqual(destination.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [203, 202])
        XCTAssertEqual(destination.rootTilingContainer.orientation, .h)
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: destination.name)?.id, group.id)
        WorkspaceSidebarTabUndo.shared.record("Split Tabs", before: before)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(second.nodeWorkspace === source)
        XCTAssertTrue(focus.windowOrNil === first)
        XCTAssertEqual(destination.allLeafWindowsRecursive.map(\.windowId), [203])
    }

    func testSplitMenuRejectsFloatingMissingAndOtherDisplayDestinations() throws {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT")
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        Workspace.reconcileWorkspaceState()
        let source = left.activeWorkspace
        let first = TestWindow.new(id: 201, parent: source.rootTilingContainer)
        XCTAssertTrue(first.focusWindow())
        let destination = Workspace.get(byName: "destination")
        let target = TestWindow.new(id: 202, parent: destination.rootTilingContainer)
        destination.seedMonitorIfNeeded(left)
        XCTAssertTrue(canSplitWorkspaceSidebarTabWindow(first, with: destination))
        XCTAssertTrue(right.setActiveWorkspace(destination))
        XCTAssertFalse(canSplitWorkspaceSidebarTabWindow(first, with: destination))
        XCTAssertThrowsError(try splitWorkspaceSidebarTabWindow(201, fromWorkspace: source.id, withWorkspace: destination.id))
        XCTAssertTrue(first.nodeWorkspace === source)
        XCTAssertFalse(canSplitWorkspaceSidebarTabWindow(first, with: source))
        XCTAssertThrowsError(try splitWorkspaceSidebarTabWindow(201, fromWorkspace: source.id, withWorkspace: WorkspaceId("missing")))
        target.closeAxWindow()
        XCTAssertFalse(canSplitWorkspaceSidebarTabWindow(first, with: destination))
        first.bind(to: source, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        XCTAssertTrue(first.isFloating)
        XCTAssertTrue(workspaceSidebarSplitDestinations(windowId: 201).isEmpty)
    }

    func testSplitRejectsFullscreenAndAMemberThatMovedSinceOpeningTheMenu() throws {
        let source = focus.workspace
        let first = TestWindow.new(id: 201, parent: source.rootTilingContainer)
        let destination = Workspace.get(byName: "destination")
        let target = TestWindow.new(id: 202, parent: destination.rootTilingContainer)
        XCTAssertTrue(first.focusWindow())
        first.isFullscreen = true
        XCTAssertFalse(canSplitWorkspaceSidebarTabWindow(first, with: destination))
        XCTAssertThrowsError(try splitWorkspaceSidebarTabWindow(201, fromWorkspace: source.id, withWorkspace: destination.id))
        first.isFullscreen = false
        target.isFullscreen = true
        XCTAssertFalse(canSplitWorkspaceSidebarTabWindow(first, with: destination))
        target.isFullscreen = false
        XCTAssertTrue(canSplitWorkspaceSidebarTabWindow(first, with: destination))
        let later = Workspace.get(byName: "later")
        first.bind(to: later.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        XCTAssertThrowsError(try splitWorkspaceSidebarTabWindow(201, fromWorkspace: source.id, withWorkspace: destination.id))
        XCTAssertTrue(first.nodeWorkspace === later)
        XCTAssertEqual(destination.allLeafWindowsRecursive.map(\.windowId), [202])
    }

    func testCountOwnerMovesOutOfCollapsedGroupAndReturnsWhenExpanded() throws {
        let hidden = tab("grouped", ids: [201])
        let visible = tab("outside", ids: [202])
        var group = WorkspaceTabCollection(projectId: workspaceProjectDefaultId, name: "Website Eng", workspaceNames: [hidden.name])
        group.isCollapsed = true
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.targetMonitorScopeId = hidden.monitorScopeId
        snapshot.workspaces = [hidden, visible]
        let view = WorkspaceSidebarView(snapshot: snapshot)
        XCTAssertTrue(view.tabCollectionDisclosure(group).isCollapsed)
        XCTAssertEqual(workspaceSidebarBadgeOwners(snapshot.workspaces, collections: [group], collapsedCollectionIds: [group.id]),
            ["/Applications/Test.app": 202])
        snapshot.workspaces[0].isVisible = true
        XCTAssertFalse(WorkspaceSidebarView(snapshot: snapshot).tabCollectionDisclosure(group).isCollapsed)
        XCTAssertEqual(workspaceSidebarBadgeOwners(snapshot.workspaces), ["/Applications/Test.app": 201])
        XCTAssertFalse(view.tabCollectionDisclosure(group, isSearching: true).isCollapsed)
        snapshot.targetMonitorScopeId = "another-display"
        XCTAssertTrue(WorkspaceSidebarView(snapshot: snapshot).tabCollectionDisclosure(group).isCollapsed)
    }

    func testSplitMenuRejectsADestinationWhoseNameWasReused() throws {
        let source = focus.workspace
        let window = TestWindow.new(id: 201, parent: source.rootTilingContainer)
        XCTAssertTrue(window.focusWindow())
        let original = Workspace.get(byName: "destination")
        let oldWindow = TestWindow.new(id: 202, parent: original.rootTilingContainer)
        let targetId = original.id
        oldWindow.closeAxWindow()
        removeWorkspaceFromRegistry(original, reason: .pruned)
        let replacement = Workspace.get(byName: "destination")
        _ = TestWindow.new(id: 203, parent: replacement.rootTilingContainer)
        XCTAssertNotEqual(replacement.id, targetId)
        XCTAssertThrowsError(try splitWorkspaceSidebarTabWindow(201, fromWorkspace: source.id, withWorkspace: targetId))
        XCTAssertTrue(window.nodeWorkspace === source)
        XCTAssertEqual(replacement.allLeafWindowsRecursive.map(\.windowId), [203])
    }

    func testSplitLayoutUsesTheActualBadgeBudget() {
        XCTAssertFalse(workspaceSidebarSplitUsesIcons(width: 260, windowCount: 2))
        XCTAssertTrue(workspaceSidebarSplitUsesIcons(width: 260, windowCount: 2,
            badgeWidths: [workspaceSidebarBadgeWidth(label: "1234", showsDot: false), 6]))
        XCTAssertFalse(workspaceSidebarSplitUsesIcons(width: 340, windowCount: 2, badgeWidths: [32, 32]))
        XCTAssertTrue(workspaceSidebarSplitUsesIcons(width: 180, windowCount: 3))
    }

    func testNamedSplitShowsIdentityAndEachMemberRemainsClickable() throws {
        let workspace = tab("pair", ids: [201, 202], label: "Checkout bug", emoji: "🐛")
        XCTAssertEqual(WorkspaceSidebarSplitIdentity(workspace)?.name, "Checkout bug")
        XCTAssertEqual(WorkspaceSidebarSplitIdentity(workspace)?.emoji, "🐛")
        XCTAssertNil(WorkspaceSidebarSplitIdentity(tab("unnamed", ids: [201, 202])))
        for width: CGFloat in [180, 280] {
            var selected: [WorkspaceSidebarAction] = []
            let card = WorkspaceSidebarTabCardView(workspace: workspace, presentation: workspaceSidebarTabPresentation(workspace),
                isActive: false, isDropTarget: false, dragSourceWindowId: nil, selectedSearchTarget: nil,
                activation: .init(allowsActivation: true, isInUseOnOtherDisplay: false, requestOverride: {}),
                isShowingOverride: false, overrideMinHeight: 36, actions: .init(send: { selected.append($0) }),
                onBeginRename: {}, onCommitOverride: {}, onCancelOverride: {})
            try click(card, size: CGSize(width: width, height: 36), points: [
                CGPoint(x: width - 63, y: 18), CGPoint(x: width - 20, y: 18), CGPoint(x: 30, y: 18),
            ])
            XCTAssertEqual(selected, [.selectWindow(201), .selectWindow(202), .selectWorkspace("pair")])
        }
    }

    func testNamedPinnedPairKeepsBothTargetsInExpandedAndCompactViews() throws {
        let workspace = tab("pair", ids: [201, 202], label: "Checkout bug", emoji: "🐛")
        for compact in [false, true] {
            let width: CGFloat = compact ? 34 : 160
            let height: CGFloat = compact ? 34 : 54
            var selected: [UInt32?] = []
            let view = WorkspaceSidebarPinnedTab(workspace: workspace, badgeModel: .init(), compact: compact) { selected.append($0) }
            try click(view, size: CGSize(width: width, height: height), points: [
                CGPoint(x: width / 4, y: compact ? 17 : 37), CGPoint(x: width * 3 / 4, y: compact ? 17 : 37),
            ])
            XCTAssertEqual(selected, [201, 202])
        }
    }

    func testManyWindowNamedSplitFitsAndKeepsEveryMemberClickable() throws {
        let ids = Array(UInt32(201)...UInt32(208))
        let workspace = tab("many", ids: ids, label: "Review", emoji: "🔎")
        var selected: [WorkspaceSidebarAction] = []
        let card = WorkspaceSidebarTabCardView(workspace: workspace, presentation: workspaceSidebarTabPresentation(workspace),
            isActive: false, isDropTarget: false, dragSourceWindowId: nil, selectedSearchTarget: nil,
            activation: .init(allowsActivation: true, isInUseOnOtherDisplay: false, requestOverride: {}),
            isShowingOverride: false, overrideMinHeight: 36, actions: .init(send: { selected.append($0) }),
            onBeginRename: {}, onCommitOverride: {}, onCancelOverride: {})
        try click(card, size: CGSize(width: 180, height: 36), points: ids.indices.map {
            CGPoint(x: (CGFloat($0) + 0.5) * 180 / 8, y: 18)
        })
        XCTAssertEqual(selected, ids.map { .selectWindow($0) })
    }

    private func tab(_ name: String, ids: [UInt32], label: String = "", emoji: String? = nil) -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: name, projectId: workspaceProjectDefaultId, displayName: label.isEmpty ? name : label,
            sidebarLabel: label, isGeneratedName: false, monitorScopeId: "monitor:0,0", monitorName: "Main",
            isFocused: false, isVisible: false, items: ids.map {
                .init(kind: .window(.init(windowId: $0, workspaceName: name, appName: "Notes", appBundleId: nil,
                    appBundlePath: "/Applications/Test.app", title: "Notes \($0)", isFocused: false)))
            }, appearance: .init(emoji: emoji))
    }

    private func click(_ view: some View, size: CGSize, points: [CGPoint]) throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let native = NSWindow(contentRect: CGRect(origin: CGPoint(x: 300, y: 200), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.contentView = host
        native.orderFrontRegardless()
        defer { native.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        native.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(host.fittingSize.width, size.width, accuracy: 0.5)
        for point in points {
            let location = host.convert(CGPoint(x: point.x, y: host.isFlipped ? point.y : size.height - point.y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: native.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)), atStart: false)
            }
            let deadline = Date().addingTimeInterval(0.2)
            while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: deadline,
                inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }
    }
}
