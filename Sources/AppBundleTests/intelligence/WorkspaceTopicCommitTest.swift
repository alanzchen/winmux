@testable import AppBundle
import Common
import XCTest

/// Applying suggestions: one write, one Undo, nothing but organization changed; the whole batch
/// refused when anything about a member changed; failures that leave nothing behind.
@MainActor
final class WorkspaceTopicCommitTest: XCTestCase {
    private var provider: FakeWorkspaceTopicProvider!
    private var coordinator: WorkspaceTopicCoordinator!
    private var directory: URL!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        TopicTestApps.reset()
        provider = FakeWorkspaceTopicProvider(script: ["ECON 4310": ["ECON 4310"], "tiling-app": ["tiling-app"]])
        coordinator = WorkspaceTopicTestEnvironment.setUp(provider: provider)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("topic-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        workspaceTopicBeforeOrganizationWriteForTests = nil
        setServerReadOnlyForTests(false)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
        WorkspaceTopicTestEnvironment.tearDown()
        resetSavedWorkspacesForTests()
        TopicTestApps.reset()
        try await super.tearDown()
    }

    private var tabs: [String: Workspace] = [:]

    private func makeTabs() {
        let titles: [(String, TestApp, String)] = [
            ("deck", TopicTestApps.keynote, "ECON 4310 week 3"),
            ("grades", TopicTestApps.numbers, "ECON 4310 grades"),
            ("code", TopicTestApps.xcode, "Config.swift — tiling-app"),
            ("shell", TopicTestApps.terminal, "tiling-app — build"),
        ]
        for (index, (name, app, title)) in titles.enumerated() {
            let workspace = Workspace.get(byName: name)
            TestWindow.new(id: UInt32(300 + index), parent: workspace.rootTilingContainer, app: app, title: title)
            tabs[name] = workspace
        }
        // A split: two windows in one tab, kept whole.
        TestWindow.new(id: 310, parent: tabs["code"]!.rootTilingContainer, app: TopicTestApps.terminal, title: "tiling-app — test")
    }

    private func ready() async throws {
        await updateWorkspaceSidebarModel()
        coordinator.suggest(WorkspaceTopicTestEnvironment.scope(), snapshot: WorkspaceTopicTestEnvironment.snapshot)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(coordinator.groups.count, 2)
    }

    private func applyNow() async -> WorkspaceTopicCoordinator.Phase {
        await coordinator.apply()?.value
        return coordinator.phase
    }

    /// Stand-ins for "no layout, display or focus work": the trees' own objects and frames.
    private func layoutFingerprint() -> [String] {
        Workspace.all.map { workspace in
            "\(workspace.name):\(ObjectIdentifier(workspace.rootTilingContainer).hashValue):\(workspace.rootTilingContainer.layoutDescription)"
        } + [String(describing: focus.windowOrNil?.windowId), focus.workspace.name,
             winMuxWorkspaceState.monitorViewportsById.map { "\($0.key):\(String(describing: $0.value.activeWorkspaceId))" }.sorted().joined()]
    }

    private func frameWrites() -> Int {
        Workspace.all.flatMap(\.allLeafWindowsRecursive).compactMap { $0 as? TestWindow }.reduce(0) { $0 + $1.setAxFrameCount }
    }

    private func nativeFocusCalls() -> Int {
        Workspace.all.flatMap(\.allLeafWindowsRecursive).compactMap { $0 as? TestWindow }.reduce(0) { $0 + $1.nativeFocusCount }
    }

    func testApplyMakesEveryGroupInOneEditWithOneUndoAndNothingElse() async throws {
        makeTabs()
        try workspaceSidebarOrganizationStore.update { $0.workspaces["other-pin", default: .init()].setFavorite(true) }
        try await ready()
        let layout = layoutFingerprint()
        let writes = frameWrites()
        let focusCalls = nativeFocusCalls()
        let econ = try XCTUnwrap(coordinator.groups.firstIndex { $0.name == "ECON 4310" })
        coordinator.groups[econ].name = "  Econ\u{0} class "
        XCTAssertNil(coordinator.groups[econ].problem)
        let phase = await applyNow()
        XCTAssertEqual(phase, .idle, "Applied and closed")
        let collections = workspaceSidebarOrganizationStore.state.collections
        XCTAssertEqual(Set(collections.map(\.name)), ["Econ class", "tiling-app"])
        XCTAssertEqual(Set(collections.flatMap(\.workspaceNames)), ["deck", "grades", "code", "shell"])
        XCTAssertTrue(collections.allSatisfy { $0.projectId == focus.workspace.projectId })
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces["other-pin"]?.isFavorite, true, "Pins untouched")
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Group by Topic")
        XCTAssertEqual(layoutFingerprint(), layout, "No tree, display or focus change")
        XCTAssertEqual(frameWrites(), writes)
        XCTAssertEqual(nativeFocusCalls(), focusCalls, "No native focus request")
        for name in ["deck", "grades", "code", "shell"] {
            XCTAssertNotNil(savedWorkspaceStore.record(named: name), "Each member keeps its name across a relaunch")
        }
        XCTAssertEqual(tabs["code"]!.allLeafWindowsRecursive.map(\.windowId), [302, 310], "The split stays whole")

        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [])
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces["other-pin"]?.isFavorite, true)
        for name in ["deck", "grades", "code", "shell"] { XCTAssertNil(savedWorkspaceStore.record(named: name)) }
        XCTAssertEqual(layoutFingerprint(), layout, "Undo rebuilds nothing and moves no focus")
        XCTAssertEqual(frameWrites(), writes)
        XCTAssertEqual(nativeFocusCalls(), focusCalls)
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    func testNavigationAfterApplySurvivesUndo() async throws {
        makeTabs()
        try await ready()
        _ = await applyNow()
        XCTAssertTrue(tabs["shell"]!.focusWorkspace())
        let focused = focus.workspace
        let viewports = winMuxWorkspaceState.monitorViewportsById.mapValues(\.activeWorkspaceId)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(focus.workspace === focused, "The tab chosen after Apply stays chosen")
        XCTAssertEqual(winMuxWorkspaceState.monitorViewportsById.mapValues(\.activeWorkspaceId), viewports)
    }

    func testPreviewAndCancelSaveNothing() async throws {
        let url = directory.appendingPathComponent("organization.json")
        workspaceSidebarOrganizationStore = WorkspaceSidebarOrganizationStore(url: url)
        makeTabs()
        try await ready()
        coordinator.groups[0].name = "Edited"
        coordinator.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [])
        XCTAssertTrue(savedWorkspaceStore.records.isEmpty)
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    // MARK: Stale members reject the whole batch

    private func assertRejected(_ change: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async throws {
        makeTabs()
        try await ready()
        try await change()
        let collections = workspaceSidebarOrganizationStore.state.collections
        let phase = await applyNow()
        guard case .notApplied(let message) = phase else { return XCTFail("\(phase)", file: file, line: line) }
        XCTAssertEqual(message, workspaceTopicOutOfDateMessage, file: file, line: line)
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, collections, "Nothing applied, not even the fresh group",
            file: file, line: line)
        XCTAssertTrue(savedWorkspaceStore.records.isEmpty, file: file, line: line)
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title, file: file, line: line)
    }

    func testARecycledNameIsntTheSameTab() async throws {
        try await assertRejected {
            let old = tabs["deck"]!
            for window in old.allLeafWindowsRecursive { window.unbindFromParent() }
            _ = winMuxWorkspaceState.removeWorkspace(old)
            let reborn = Workspace.get(byName: "deck")
            TestWindow.new(id: 320, parent: reborn.rootTilingContainer, app: TopicTestApps.keynote, title: "ECON 4310 week 3")
        }
    }

    func testATabMovedToAnotherProjectIsRejected() async throws {
        try await assertRejected {
            winMuxWorkspaceState.projectsById["elsewhere"] = WorkspaceProject(id: "elsewhere", name: "Elsewhere", order: 9)
            tabs["grades"]!.assignProject("elsewhere")
        }
    }

    func testATabPinnedOrGroupedMeanwhileIsRejected() async throws {
        try await assertRejected {
            try workspaceSidebarOrganizationStore.update { $0.workspaces["code", default: .init()].setFavorite(true) }
        }
        setUpWorkspacesForTests()
        _ = WorkspaceTopicTestEnvironment.setUp(provider: provider)
        try await assertRejected {
            _ = try workspaceSidebarOrganizationStore.create(projectId: focus.workspace.projectId, workspaceNames: ["shell"])
        }
    }

    func testAWindowAddedOrRetitledMeanwhileIsRejected() async throws {
        try await assertRejected {
            TestWindow.new(id: 330, parent: tabs["deck"]!.rootTilingContainer, app: TopicTestApps.mail, title: "Re: dinner")
        }
        setUpWorkspacesForTests()
        _ = WorkspaceTopicTestEnvironment.setUp(provider: provider)
        try await assertRejected {
            (tabs["grades"]!.allLeafWindowsRecursive.first as? TestWindow)?.customTitle = "Payroll"
            resetCachedWindowTitles()
            await updateWorkspaceSidebarModel()
            // The preview would close on that update; Apply from it must still refuse.
            XCTAssertTrue(self.coordinator.isActive)
        }
    }

    func testATabRelabeledMeanwhileIsRejected() async throws {
        try await assertRejected {
            config.workspaceSidebar.workspaceLabels["deck"] = "Payroll"
            await updateWorkspaceSidebarModel()
        }
    }

    func testAMemberNoLongerInTheSidebarsListIsRejected() async throws {
        makeTabs()
        await updateWorkspaceSidebarModel()
        let display = workspaceSidebarMonitorScopeId(for: mainMonitor)
        TrayMenuModel.shared.workspaceSidebarSelectedMonitorScopeId = display
        coordinator.suggest(WorkspaceTopicTestEnvironment.scope(), snapshot: WorkspaceTopicTestEnvironment.snapshot)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.groups.count, 2)
        // "grades" is now listed on another display; the panel itself still shows the same list.
        TrayMenuModel.shared.workspaceSidebarWorkspaces = TrayMenuModel.shared.workspaceSidebarWorkspaces.map {
            $0.name == "grades" ? moved($0, to: "monitor:5000,0") : $0
        }
        guard let request = coordinator.request else { return XCTFail() }
        let plan = coordinator.groups.map { WorkspaceTopicCommitGroup(name: $0.name, members: $0.includedMembers) }
        XCTAssertEqual(commitWorkspaceTopicGroups(plan, request: request, isCurrent: true), .notApplied(workspaceTopicOutOfDateMessage))
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [])
        TrayMenuModel.shared.workspaceSidebarSelectedMonitorScopeId = workspaceSidebarDefaultScopeId
    }

    /// A member moved to another display while the sidebar still shows the older list.
    func testAMemberMovedLiveBeforeTheSidebarCatchesUpIsRejected() async throws {
        let main = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Main", rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true)
        let side = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Side", rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        setMonitorsForTests([main, side])
        defer { setMonitorsForTests(nil) }
        makeTabs()
        for workspace in tabs.values { workspace.preferredMonitorPoint = main.rect.topLeftCorner }
        await updateWorkspaceSidebarModel()
        let display = workspaceSidebarMonitorScopeId(for: main)
        TrayMenuModel.shared.workspaceSidebarSelectedMonitorScopeId = display
        coordinator.suggest(WorkspaceTopicTestEnvironment.scope(), snapshot: WorkspaceTopicTestEnvironment.snapshot)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.groups.count, 2)
        guard let request = coordinator.request else { return XCTFail() }
        let plan = coordinator.groups.map { WorkspaceTopicCommitGroup(name: $0.name, members: $0.includedMembers) }
        tabs["grades"]!.preferredMonitorPoint = side.rect.topLeftCorner
        XCTAssertEqual(workspaceSidebarMonitorScopeId(for: tabs["grades"]!.workspaceMonitor), workspaceSidebarMonitorScopeId(for: side))
        XCTAssertEqual(commitWorkspaceTopicGroups(plan, request: request, isCurrent: true), .notApplied(workspaceTopicOutOfDateMessage),
            "Not republished yet, but it isn't on this display any more")
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [])
        TrayMenuModel.shared.workspaceSidebarSelectedMonitorScopeId = workspaceSidebarDefaultScopeId
    }

    /// A split member with no title of its own, minimized after the preview: the text sent is the
    /// same, but the tab can no longer be read whole.
    func testAMemberThatCantBeReadWholeAnyMoreIsRejected() async throws {
        for republish in [false, true] {
            setUpWorkspacesForTests()
            TopicTestApps.reset()
            coordinator = WorkspaceTopicTestEnvironment.setUp(provider: provider)
            makeTabs()
            let blank = TestWindow.new(id: 340, parent: tabs["grades"]!.rootTilingContainer, app: TopicTestApps.mail, title: "")
            try await ready()
            guard let request = coordinator.request else { return XCTFail() }
            let plan = coordinator.groups.map { WorkspaceTopicCommitGroup(name: $0.name, members: $0.includedMembers) }
            blank.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            blank.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: "grades")
            if republish { await updateWorkspaceSidebarModel() }
            XCTAssertEqual(commitWorkspaceTopicGroups(plan, request: request, isCurrent: true), .notApplied(workspaceTopicOutOfDateMessage),
                republish ? "Republished: the tab is incomplete now" : "Before the sidebar shows it: live state says so")
            XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [])
        }
    }

    private func moved(_ tab: WorkspaceSidebarWorkspaceViewModel, to scope: String) -> WorkspaceSidebarWorkspaceViewModel {
        WorkspaceSidebarWorkspaceViewModel(name: tab.name, projectId: tab.projectId, displayName: tab.displayName,
            sidebarLabel: tab.sidebarLabel, isGeneratedName: tab.isGeneratedName, monitorScopeId: scope, monitorName: tab.monitorName,
            isFocused: tab.isFocused, isVisible: tab.isVisible, items: tab.items, apps: tab.apps, savedState: tab.savedState,
            appearance: tab.appearance)
    }

    func testChangedPrivacySettingsRejectTheBatch() async throws {
        makeTabs()
        try await ready()
        guard let request = coordinator.request else { return XCTFail() }
        let plan = coordinator.groups.map { WorkspaceTopicCommitGroup(name: $0.name, members: $0.includedMembers) }
        config.workspaceSidebar.intelligence.excludedApps = ["com.apple.Terminal"]
        XCTAssertEqual(commitWorkspaceTopicGroups(plan, request: request, isCurrent: true), .notApplied(workspaceTopicOutOfDateMessage))
        config.workspaceSidebar.intelligence.excludedApps = []
        XCTAssertEqual(commitWorkspaceTopicGroups(plan, request: request, isCurrent: false), .notApplied(workspaceTopicOutOfDateMessage),
            "A newer suggestion replaced it")
        let duplicate = [plan[0], WorkspaceTopicCommitGroup(name: "Again", members: plan[0].members)]
        XCTAssertEqual(commitWorkspaceTopicGroups(duplicate, request: request, isCurrent: true), .notApplied(workspaceTopicOutOfDateMessage),
            "A tab in two groups")
        XCTAssertEqual(commitWorkspaceTopicGroups([WorkspaceTopicCommitGroup(name: "One", members: [plan[0].members[0]])],
            request: request, isCurrent: true), .notApplied(workspaceTopicOutOfDateMessage), "A group of one")
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [])
    }

    func testUndoIsRecordedAtTheCommitItself() async throws {
        makeTabs()
        try await ready()
        guard let request = coordinator.request else { return XCTFail() }
        let plan = coordinator.groups.map { WorkspaceTopicCommitGroup(name: $0.name, members: $0.includedMembers) }
        XCTAssertEqual(commitWorkspaceTopicGroups(plan, request: request, isCurrent: true), .applied(groups: 2))
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Group by Topic", "Before any refresh could run")
    }

    // MARK: Read-only

    func testReadOnlyNeverWrites() async throws {
        makeTabs()
        try await ready()
        let reasons: [(String, () -> Void, () -> Void)] = [
            ("server", { setServerReadOnlyForTests(true) }, { setServerReadOnlyForTests(false) }),
            ("organization", { workspaceSidebarOrganizationStore = WorkspaceSidebarOrganizationStore(readOnlyReason: "organization") },
             { workspaceSidebarOrganizationStore = .init() }),
            ("saved", { savedWorkspaceStore = SavedWorkspaceStore(url: nil, readOnlyReason: "saved") }, { resetSavedWorkspacesForTests() }),
        ]
        for (label, set, unset) in reasons {
            set()
            XCTAssertNotNil(workspaceTopicReadOnlyReason(), label)
            let phase = await applyNow()
            guard case .notApplied = phase else { XCTFail("\(label): \(phase)"); unset(); continue }
            XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [], label)
            XCTAssertNil(WorkspaceSidebarTabUndo.shared.title, label)
            unset()
            try await ready()
        }
    }

    // MARK: Faults

    /// A path no store can write: its parent is a file.
    private func unwritable(_ name: String) throws -> URL {
        let blocker = directory.appendingPathComponent("blocker-\(name)")
        try Data("x".utf8).write(to: blocker)
        return blocker.appendingPathComponent("\(name).json")
    }

    func testAFailedIdentityWriteAppliesNothing() async throws {
        makeTabs()
        try await ready()
        savedWorkspaceStore = SavedWorkspaceStore(url: try unwritable("saved"))
        let lifecycles = tabs.mapValues(\.lifecycle)
        let phase = await applyNow()
        guard case .notApplied(let message) = phase else { return XCTFail("\(phase)") }
        XCTAssertTrue(message.hasPrefix("Couldn't apply the groups"))
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [], "No group was written")
        XCTAssertTrue(savedWorkspaceStore.records.isEmpty, "Identities rolled back in memory")
        XCTAssertEqual(tabs.mapValues(\.lifecycle), lifecycles)
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title, "No success, no Undo")
    }

    func testAFailedOrganizationWriteRemovesTheIdentitiesItJustSaved() async throws {
        makeTabs()
        try await ready()
        let savedURL = directory.appendingPathComponent("saved-workspaces.json")
        savedWorkspaceStore = SavedWorkspaceStore(url: savedURL)
        workspaceSidebarOrganizationStore = WorkspaceSidebarOrganizationStore(url: try unwritable("organization"))
        var identitiesOnDiskBeforeOrganization: Int?
        workspaceTopicBeforeOrganizationWriteForTests = {
            identitiesOnDiskBeforeOrganization = (try? self.decodeSavedFile(savedURL))?.workspaces.count
        }
        let phase = await applyNow()
        guard case .notApplied(let message) = phase else { return XCTFail("\(phase)") }
        XCTAssertFalse(message.contains("stay saved"), message)
        XCTAssertEqual(identitiesOnDiskBeforeOrganization, 4, "Identities were written first")
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [])
        XCTAssertTrue(savedWorkspaceStore.records.isEmpty)
        XCTAssertEqual(try decodeSavedFile(savedURL).workspaces.count, 0, "And removed from disk again")
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    func testAFailedCleanupIsReported() async throws {
        makeTabs()
        try await ready()
        let savedDirectory = directory.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: savedDirectory, withIntermediateDirectories: true)
        let savedURL = savedDirectory.appendingPathComponent("saved-workspaces.json")
        savedWorkspaceStore = SavedWorkspaceStore(url: savedURL)
        workspaceSidebarOrganizationStore = WorkspaceSidebarOrganizationStore(url: try unwritable("organization"))
        workspaceTopicBeforeOrganizationWriteForTests = {
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: savedDirectory.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: savedDirectory.path) }
        let phase = await applyNow()
        guard case .notApplied(let message) = phase else { return XCTFail("\(phase)") }
        XCTAssertTrue(message.contains("they stay saved"), message)
        XCTAssertTrue(savedWorkspaceStore.records.isEmpty, "Memory is rolled back; the disk keeps a reserved name until the next write")
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [])
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    func testUndoThatCantWriteTheOrganizationKeepsItsHistory() async throws {
        makeTabs()
        try await ready()
        _ = await applyNow()
        let applied = workspaceSidebarOrganizationStore.state
        workspaceSidebarOrganizationStore = WorkspaceSidebarOrganizationStore(state: applied, url: try unwritable("organization"))
        XCTAssertThrowsError(try WorkspaceSidebarTabUndo.shared.undo())
        XCTAssertEqual(workspaceSidebarOrganizationStore.state, applied, "Nothing changed")
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Group by Topic", "Still there to try again")
        for name in ["deck", "grades", "code", "shell"] { XCTAssertNotNil(savedWorkspaceStore.record(named: name)) }
    }

    func testUndoThatCantWriteIdentitiesRemovesTheGroupsAndSaysSo() async throws {
        makeTabs()
        try await ready()
        _ = await applyNow()
        savedWorkspaceStore = SavedWorkspaceStore(file: savedWorkspaceStore.file, url: try unwritable("saved"))
        XCTAssertThrowsError(try WorkspaceSidebarTabUndo.shared.undo()) { error in
            XCTAssertTrue(error.localizedDescription.contains("The groups were removed"), error.localizedDescription)
        }
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [])
        for name in ["deck", "grades", "code", "shell"] {
            XCTAssertNotNil(savedWorkspaceStore.record(named: name), "Kept in memory as on disk")
        }
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    func testUndoKeepsIdentitiesALaterEditAlsoUses() async throws {
        makeTabs()
        try await ready()
        _ = await applyNow()
        // Pinning a member afterwards is a later edit: it replaces this Undo, so nothing of the
        // apply's identities is removed behind its back.
        await handleWorkspaceSidebarOrganizationAction(.setWorkspaceFavorite("deck", true))?.value
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin Tab")
        XCTAssertNotNil(savedWorkspaceStore.record(named: "deck"))
    }

    private func decodeSavedFile(_ url: URL) throws -> SavedWorkspacesFile {
        try JSONDecoder().decode(SavedWorkspacesFile.self, from: Data(contentsOf: url))
    }
}
