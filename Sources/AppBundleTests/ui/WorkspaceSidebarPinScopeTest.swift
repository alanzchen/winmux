import AppKit
@testable import AppBundle
import Common
import XCTest

/// Tabs mode: a pin is its project's, as every pin was before, or in All Projects. The scope is saved
/// with the pin, leaves older files and builds alone, and moving a pin between the two keeps its tab,
/// windows and display, with one Undo.
@MainActor
final class WorkspaceSidebarPinScopeTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        WorkspaceSidebarTabUndo.shared.clear()
        setMonitorsForTests(nil)
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private var nextWindowId: UInt32 = 1

    private func tab(_ name: String, in projectId: WorkspaceProjectId, app: TestApp = TestApp.shared) -> Workspace {
        let tab = Workspace.get(byName: name)
        _ = TestWindow.new(id: nextWindowId, parent: tab.rootTilingContainer, app: app)
        nextWindowId += 1
        tab.assignProject(projectId)
        return tab
    }

    /// Projects A and B; A's `g` pinned in All Projects and `p` pinned in A, B's `q` pinned in B.
    /// B's `b1` is on screen.
    private func pins() throws -> (a: WorkspaceProjectId, b: WorkspaceProjectId, g: Workspace, p: Workspace, q: Workspace, b1: Workspace) {
        let a = createWorkspaceProject().id
        let b = createWorkspaceProject().id
        let g = tab("g", in: a), p = tab("p", in: a), q = tab("q", in: b), b1 = tab("b1", in: b)
        XCTAssertTrue(p.focusWorkspace())
        try setWorkspaceSidebarTabsFavorite([p, q], true)
        try setWorkspaceSidebarTabPinScope(g, .allProjects, projectId: a)
        XCTAssertTrue(b1.focusWorkspace())
        Workspace.reconcileWorkspaceState()
        return (a, b, g, p, q, b1)
    }

    private func appearance(_ name: String) -> WorkspaceSidebarItemAppearance? {
        workspaceSidebarOrganizationStore.state.workspaces[name]
    }

    private func scope(_ monitor: Monitor) -> String { workspaceSidebarMonitorScopeId(for: monitor) }

    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pin-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("sidebar-organization.json")
    }

    // MARK: The model

    func testAPinIsItsProjectsUntilItsPinnedInAllProjects() {
        var appearance = WorkspaceSidebarItemAppearance()
        appearance.setFavorite(true)
        XCTAssertNil(appearance.pinScope, "Pin Tab pins in the project, as before")
        XCTAssertFalse(appearance.isPinnedInAllProjects)
        appearance.pinOrder = 3
        appearance.setPinScope(.allProjects)
        XCTAssertTrue(appearance.isPinnedInAllProjects)
        XCTAssertNil(appearance.pinOrder, "It goes after the pins arranged there")
        appearance.pinOrder = 1
        appearance.setFavorite(true)
        XCTAssertEqual(appearance.pinOrder, 1, "Pinning a pin changes nothing")
        XCTAssertTrue(appearance.isPinnedInAllProjects)
        appearance.setFavorite(false)
        XCTAssertNil(appearance.pinScope, "Unpinning forgets the scope, as it forgets the place")
        XCTAssertNil(appearance.pinOrder)
        var unpinned = WorkspaceSidebarItemAppearance()
        unpinned.pinScope = .allProjects
        XCTAssertFalse(unpinned.isPinnedInAllProjects, "A scope means nothing without a pin")
        unpinned.setPinScope(nil)
        XCTAssertTrue(unpinned.isFavorite)
        XCTAssertNil(unpinned.pinScope)
    }

    // MARK: Files and builds

    func testFilesFromBeforeLoadAsProjectPinsWithoutBeingRewritten() throws {
        let url = try temporaryURL()
        let old = #"{"collections":[],"version":1,"workspaces":{"a":{"isFavorite":true,"pinOrder":0},"b":{"isFavorite":true}}}"#
        try Data(old.utf8).write(to: url)
        let store = WorkspaceSidebarOrganizationStore.load(url: url)
        XCTAssertNil(store.readOnlyReason)
        XCTAssertEqual(store.state.workspaces["a"]?.pinScope, nil)
        XCTAssertEqual(store.state.workspaces["a"]?.isPinnedInAllProjects, false)
        XCTAssertEqual(store.state.workspaces["b"]?.isFavorite, true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), old, "Loading writes nothing")
    }

    func testOnlyPinsInAllProjectsAddTheKeyAndTheScopeSurvivesARelaunch() throws {
        let url = try temporaryURL()
        let store = WorkspaceSidebarOrganizationStore.load(url: url)
        try store.update { $0.workspaces["a"] = .init(isFavorite: true, pinOrder: 0) }
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("pinScope"), "A file without them is as before")
        try store.update { $0.workspaces["b", default: .init()].setPinScope(.allProjects) }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(#""pinScope" : "allProjects""#), text)
        XCTAssertTrue(text.contains(#""version" : 1"#), "The version stays 1")
        let reloaded = WorkspaceSidebarOrganizationStore.load(url: url)
        XCTAssertNil(reloaded.readOnlyReason)
        XCTAssertEqual(reloaded.state, store.state)
        XCTAssertEqual(reloaded.state.workspaces["b"]?.isPinnedInAllProjects, true)
    }

    /// The appearance as builds before pins in All Projects decode and encode it.
    private struct OlderAppearance: Codable, Equatable {
        var colorHex: String? = nil
        var emoji: String? = nil
        var isFavorite = false
        var pinOrder: Int? = nil
    }

    private struct OlderOrganization: Codable {
        var version = 1
        var collections: [WorkspaceTabCollection] = []
        var workspaces: [String: OlderAppearance] = [:]
    }

    func testAnOlderBuildShowsAPinInAllProjectsAsItsHomesPinAndItsNextWriteDropsTheScope() throws {
        var state = WorkspaceSidebarOrganization()
        state.workspaces["g"] = .init(colorHex: "#FF0000", isFavorite: true, pinOrder: 0, pinScope: .allProjects)
        let newer = try JSONEncoder.winMuxDefault.encode(state)
        let older = try JSONDecoder().decode(OlderOrganization.self, from: newer)
        XCTAssertEqual(older.workspaces["g"], OlderAppearance(colorHex: "#FF0000", isFavorite: true, pinOrder: 0),
            "It reads the file, and shows the pin in its own project")
        let rewritten = try JSONEncoder.winMuxDefault.encode(older)
        XCTAssertFalse(String(decoding: rewritten, as: UTF8.self).contains("pinScope"))
        let back = try JSONDecoder().decode(WorkspaceSidebarOrganization.self, from: rewritten)
        XCTAssertEqual(back.workspaces["g"]?.isFavorite, true, "Back in this build it's still pinned, with its color")
        XCTAssertEqual(back.workspaces["g"]?.colorHex, "#FF0000")
        XCTAssertEqual(back.workspaces["g"]?.isPinnedInAllProjects, false, "in its project, where the older build kept it")
    }

    // MARK: Lists and order

    func testListsShowPinsInAllProjectsWithTheProjectTheyShowFirst() async throws {
        let (a, b, g, p, q, _) = try pins()
        await updateWorkspaceSidebarModel()
        let workspaces = TrayMenuModel.shared.workspaceSidebarWorkspaces
        let scopeId = scope(mainMonitor)
        func listed(_ projectId: WorkspaceProjectId, context: WorkspaceProjectId?) -> [String] {
            workspaceSidebarTabsListedWorkspacesByProject(workspaces, selectedScopeId: scopeId, focusedMonitorScopeId: scopeId,
                collections: [], sharesPinnedTabs: false, contextProjectId: context)[projectId]?.map(\.name) ?? []
        }
        XCTAssertEqual(listed(b, context: b).prefix(2), [g.name, q.name], "In B: the pin in All Projects, then B's pin")
        XCTAssertFalse(listed(a, context: b).contains(g.name), "and it isn't also listed under its home")
        XCTAssertEqual(listed(a, context: a).prefix(2), [g.name, p.name])
        XCTAssertEqual(listed(a, context: nil).filter { [g.name, p.name].contains($0) }.count, 2,
            "Without a project to show, every tab is listed with its own")
        XCTAssertEqual(workspaceSidebarTabsPinnedWorkspaces(workspaces, projectId: b, selectedScopeId: scopeId,
            focusedMonitorScopeId: scopeId, collections: [], sharesPinnedTabs: false, contextProjectId: b).map(\.name), [g.name, q.name])

        // Search lists it once, with the project it's shown in.
        let byProject = workspaceSidebarTabsListedWorkspacesByProject(workspaces, selectedScopeId: scopeId,
            focusedMonitorScopeId: scopeId, collections: [], sharesPinnedTabs: false, contextProjectId: b)
        XCTAssertEqual(byProject.values.flatMap { $0 }.filter { $0.name == g.name }.count, 1)
    }

    func testSharingDecidesWhichDisplaysListAPinAndScopeWhichProjects() async throws {
        let monitors = ["Left", "Right"].enumerated().map { index, name in
            let rect = Rect(topLeftX: CGFloat(index) * 1920, topLeftY: 0, width: 1920, height: 1080)
            return WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: index + 1, name: name, rect: rect,
                visibleRect: rect, isMain: index == 0)
        }
        setMonitorsForTests(monitors)
        let (_, b, g, _, q, _) = try pins()
        let c = createWorkspaceProject().id
        let c1 = tab("c1", in: c)
        c1.preferredMonitorPoint = monitors[1].rect.topLeftCorner
        XCTAssertTrue(monitors[1].setActiveWorkspace(c1))
        await updateWorkspaceSidebarModel()
        func pinsListed(on monitor: Monitor, sharing: Bool) -> [String] {
            var snapshot = WorkspaceSidebarSnapshot.empty
            snapshot.workspaces = TrayMenuModel.shared.workspaceSidebarWorkspaces
            snapshot.selectedMonitorScopeId = scope(monitor)
            snapshot.targetMonitorScopeId = scope(monitor)
            snapshot.focusedMonitorScopeId = TrayMenuModel.shared.workspaceSidebarFocusedMonitorScopeId
            snapshot.activeProjectId = activeWorkspaceProjectId(for: monitor)
            snapshot.configuration.usesTabsList = true
            snapshot.configuration.sharesPinnedTabs = sharing
            return snapshot.tabsPinnedWorkspaces(for: snapshot.activeProjectId).map(\.name)
        }
        XCTAssertEqual(activeWorkspaceProjectId(for: monitors[0]), b)
        XCTAssertEqual(activeWorkspaceProjectId(for: monitors[1]), c)
        XCTAssertEqual(pinsListed(on: monitors[0], sharing: false), [g.name, q.name], "Its own display lists it")
        XCTAssertEqual(pinsListed(on: monitors[1], sharing: false), [], "Without sharing, another display doesn't")
        XCTAssertEqual(pinsListed(on: monitors[0], sharing: true), [g.name, q.name])
        XCTAssertEqual(pinsListed(on: monitors[1], sharing: true), [g.name], "Shared, every display lists it, in its own project")
    }

    func testEachKindOfPinIsArrangedAmongItsOwn() throws {
        let (a, _, g, p, _, _) = try pins()
        let g2 = tab("g2", in: a)
        try setWorkspaceSidebarTabPinScope(g2, .allProjects, projectId: a)
        XCTAssertEqual(workspacePinnedTabs(in: a).map(\.name), [p.name], "A's own pins")
        XCTAssertEqual(workspacePinnedTabsInAllProjects().map(\.name), [g.name, g2.name])
        let beforeG = WorkspaceSidebarTabGap(workspaceName: g.name, isAfter: false)
        XCTAssertNil(workspacePinnedTabOrder(moving: p, beside: beforeG), "Beside a pin of the other kind it goes nowhere")
        XCTAssertEqual(workspacePinnedTabOrder(moving: g2, beside: beforeG), [g2.name, g.name])
        XCTAssertEqual(workspacePinnedTabOrder(moving: p, beside: beforeG, inAllProjects: true), [p.name, g.name, g2.name])
        try pinWorkspaceSidebarTab(g2, beside: beforeG)
        XCTAssertEqual(workspacePinnedTabsInAllProjects().map(\.name), [g2.name, g.name])
        XCTAssertEqual(workspacePinnedTabs(in: a).map(\.name), [p.name], "Arranging one kind leaves the other")
        XCTAssertTrue(workspaceIsPinnedInAllProjects(g2))
    }

    // MARK: Moving a pin between them

    func testPinningInAllProjectsKeepsTheTabAndItsHomeWithOneUndo() async throws {
        let (a, _, _, p, _, _) = try pins()
        let windows = p.allLeafWindowsRecursive.map(ObjectIdentifier.init)
        await handleWorkspaceSidebarOrganizationAction(.setWorkspacePinScope(p.name, .allProjects, projectId: a),
            targetMonitorScopeId: scope(mainMonitor))?.value
        XCTAssertTrue(Workspace.existing(byName: p.name) === p)
        XCTAssertTrue(workspaceIsPinnedInAllProjects(p))
        XCTAssertEqual(p.projectId, a, "Its home doesn't change")
        XCTAssertEqual(p.allLeafWindowsRecursive.map(ObjectIdentifier.init), windows)
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin to All Projects")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(appearance(p.name)?.isFavorite, true)
        XCTAssertFalse(workspaceIsPinnedInAllProjects(p), "Back among A's pins")
    }

    func testPinningAnOrdinaryTabInAllProjectsSavesItAndLeavesItsGroup() throws {
        let (a, _, _, _, _, _) = try pins()
        let t = tab("t", in: a)
        let group = try workspaceSidebarOrganizationStore.create(projectId: a, workspaceNames: [t.name])
        XCTAssertNil(savedWorkspaceStore.record(named: t.name))
        try setWorkspaceSidebarTabPinScope(t, .allProjects, projectId: a)
        XCTAssertTrue(workspaceIsPinnedInAllProjects(t))
        XCTAssertNotNil(savedWorkspaceStore.record(named: t.name), "Pinning saves the tab")
        XCTAssertFalse(workspaceSidebarOrganizationStore.state.collections.first { $0.id == group.id }!.workspaceNames.contains(t.name))
    }

    func testPinningAPinInAllProjectsBackInTheProjectShownMovesItThereWithOneUndo() async throws {
        let (a, b, g, _, q, b1) = try pins()
        XCTAssertTrue(g.focusWorkspace())
        let windows = g.allLeafWindowsRecursive.map(ObjectIdentifier.init)
        await handleWorkspaceSidebarOrganizationAction(.setWorkspacePinScope(g.name, nil, projectId: b),
            targetMonitorScopeId: scope(mainMonitor))?.value
        XCTAssertTrue(Workspace.existing(byName: g.name) === g)
        XCTAssertEqual(appearance(g.name)?.isFavorite, true, "Still pinned: moving between them isn't unpinning")
        XCTAssertFalse(workspaceIsPinnedInAllProjects(g))
        XCTAssertEqual(g.projectId, b, "It comes to the project the sidebar shows")
        XCTAssertEqual(savedWorkspaceStore.record(named: g.name)?.projectId, b, "and its saved record says so now")
        XCTAssertEqual(workspacePinnedTabs(in: b).map(\.name), [q.name, g.name])
        XCTAssertEqual(g.allLeafWindowsRecursive.map(ObjectIdentifier.init), windows)
        XCTAssertTrue(mainMonitor.activeWorkspace === g)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), b)
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin to This Project")

        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(workspaceIsPinnedInAllProjects(g))
        XCTAssertEqual(g.projectId, a, "Undo takes it home")
        XCTAssertEqual(savedWorkspaceStore.record(named: g.name)?.projectId, a)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), b)
        XCTAssertTrue(b1.projectId == b)
    }

    func testTheUndoOutlastsTheNextCapture() async throws {
        let (a, b, g, _, _, _) = try pins()
        XCTAssertTrue(g.focusWorkspace())
        captureSavedWorkspaces(facts: savedTestFacts())
        await handleWorkspaceSidebarOrganizationAction(.setWorkspacePinScope(g.name, nil, projectId: b),
            targetMonitorScopeId: scope(mainMonitor))?.value
        XCTAssertNotNil(WorkspaceSidebarTabUndo.shared.title)
        // The checkpoint that would have copied the new project into the record a moment later.
        captureSavedWorkspaces(facts: savedTestFacts())
        WorkspaceSidebarTabUndo.shared.invalidateIfChanged()
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin to This Project")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(g.projectId, a)
        XCTAssertTrue(workspaceIsPinnedInAllProjects(g))
    }

    func testPinningItBackInItsHomeChangesOnlyItsScope() throws {
        let (a, _, g, p, _, _) = try pins()
        let order = winMuxWorkspaceState.projectsById[a]!.workspaceOrder
        try setWorkspaceSidebarTabPinScope(g, nil, projectId: a, beside: .init(workspaceName: p.name, isAfter: false))
        XCTAssertEqual(g.projectId, a)
        XCTAssertEqual(workspacePinnedTabs(in: a).map(\.name), [g.name, p.name], "At the place it was dropped")
        XCTAssertEqual(winMuxWorkspaceState.projectsById[a]!.workspaceOrder, order)
    }

    func testAMoveThatCantBeSavedOrFinishedChangesNothing() throws {
        let (_, b, g, _, _, _) = try pins()
        let state = workspaceSidebarOrganizationStore.state
        workspaceSidebarOrganizationStore = .init(state: state, readOnlyReason: "Read only")
        XCTAssertThrowsError(try setWorkspaceSidebarTabPinScope(g, nil, projectId: b))
        XCTAssertNotEqual(g.projectId, b)
        workspaceSidebarOrganizationStore = .init(state: state)
        // A project that's gone can't take it: the pin stays where it was, in All Projects.
        try setWorkspaceSidebarTabPinScope(g, nil, projectId: "missing-project")
        XCTAssertTrue(workspaceIsPinnedInAllProjects(g))
        XCTAssertEqual(workspaceSidebarOrganizationStore.state, state)
    }

    func testUnpinningAPinInAllProjectsLeavesATabOfTheProjectShown() async throws {
        let (a, b, g, p, _, _) = try pins()
        XCTAssertTrue(g.focusWorkspace())
        await handleWorkspaceSidebarOrganizationAction(.setWorkspaceFavorite(g.name, false),
            targetMonitorScopeId: scope(mainMonitor))?.value
        XCTAssertEqual(appearance(g.name)?.isFavorite, false)
        XCTAssertEqual(g.projectId, b, "It stays where it's listed and on screen")
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), b)
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Unpin Tab")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(workspaceIsPinnedInAllProjects(g))
        XCTAssertEqual(g.projectId, a)

        await handleWorkspaceSidebarOrganizationAction(.setWorkspaceFavorite(p.name, false),
            targetMonitorScopeId: scope(mainMonitor))?.value
        XCTAssertEqual(p.projectId, a, "A project pin unpinned stays in its project, as before")
    }

    // MARK: The menu

    private func menuTitles(_ name: String) -> [String] {
        menu(name)?.entries.map(\.title) ?? []
    }

    private final class SentActions { var actions: [WorkspaceSidebarAction] = [] }

    private func menu(_ name: String, sent: SentActions? = nil) -> WorkspaceSidebarIdentityMenuModel? {
        workspaceSidebarIdentityMenuModel(.tab(name, windowId: nil), targetMonitorScopeId: scope(mainMonitor),
            sendAction: { action, _ in sent?.actions.append(action) })
    }

    func testTheMenuMovesAPinBetweenAllProjectsAndTheProjectShown() async throws {
        let (a, b, g, p, _, b1) = try pins()
        config.workspaceSidebar.projectLabels[b.rawValue] = "Bee"
        await updateWorkspaceSidebarModel()
        XCTAssertEqual(Array(menuTitles(b1.name).prefix(3)), ["Pin Tab", "Pin to All Projects", "Add to Group"],
            "Pin Tab still pins in the project")
        XCTAssertEqual(Array(menuTitles(p.name).prefix(2)), ["Unpin Tab", "Pin to All Projects"])
        let titles = menuTitles(g.name)
        XCTAssertEqual(Array(titles.prefix(2)), ["Unpin Tab", "Pin to “Bee” Only"], "Back to the project this sidebar shows")
        XCTAssertFalse(titles.contains("Add to Group"))
        XCTAssertFalse(titles.contains("Move to Project"))

        let sent = SentActions()
        menu(g.name, sent: sent)?.entries.first { $0.title == "Pin to “Bee” Only" }?.perform?()
        menu(p.name, sent: sent)?.entries.first { $0.title == "Pin to All Projects" }?.perform?()
        XCTAssertEqual(sent.actions, [.setWorkspacePinScope(g.name, nil, projectId: b), .setWorkspacePinScope(p.name, .allProjects, projectId: b)])
        XCTAssertEqual(workspaceSidebarOrganizationUndoTitle(.setWorkspacePinScope(g.name, nil, projectId: b)), "Pin to This Project")
        XCTAssertEqual(workspaceSidebarOrganizationUndoTitle(.setWorkspacePinScope(p.name, .allProjects, projectId: a)),
            "Pin to All Projects")
    }

    // MARK: Regressions

    func testPinsOfTheSameAppStayTheirOwnTabs() async throws {
        let (a, b, _, _, _, _) = try pins()
        let app = TestApp(pid: 4242, bundleId: "com.test.notes")
        let first = tab("notes-1", in: a, app: app), second = tab("notes-2", in: a, app: app)
        try setWorkspaceSidebarTabsFavorite([first, second], true)
        try setWorkspaceSidebarTabPinScope(first, .allProjects, projectId: a)
        XCTAssertEqual(first.allLeafWindowsRecursive.count, 1)
        XCTAssertEqual(second.allLeafWindowsRecursive.count, 1)
        XCTAssertTrue(workspaceIsPinnedInAllProjects(first))
        XCTAssertFalse(workspaceIsPinnedInAllProjects(second))
        XCTAssertTrue(first.focusWorkspace())
        XCTAssertTrue(second.focusWorkspace())
        XCTAssertTrue(first.focusWorkspace())
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), a)
        XCTAssertTrue(switchWorkspaceProject(b, on: mainMonitor) === first, "On screen, it stays through a switch")
        XCTAssertTrue(first.focusWorkspace())
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), b)
        XCTAssertTrue(second.focusWorkspace())
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), a, "The project pin of the same app is still A's own")
        XCTAssertEqual(first.allLeafWindowsRecursive.count + second.allLeafWindowsRecursive.count, 2, "Neither took the other's window")
    }

    func testAWindowOfAnEmptyPinInAllProjectsStillReopensIntoIt() async throws {
        let (a, b, _, _, _, b1) = try pins()
        let editor = "com.test.editor"
        let layout = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [
            savedSlot("editor", bundleId: editor, title: "main.swift", windowId: 11, pid: 900),
        ]))
        savedWorkspaceStore.insert(SavedWorkspaceRecord(workspaceName: "code", projectId: a, layout: layout))
        materializeSavedWorkspaceNames()
        let code = try XCTUnwrap(Workspace.existing(byName: "code"))
        XCTAssertEqual(code.projectId, a)
        try setWorkspaceSidebarTabPinScope(code, .allProjects, projectId: a)
        XCTAssertTrue(b1.focusWorkspace())
        let app = TestApp(pid: 900, bundleId: editor, launchDate: savedTestNow.addingTimeInterval(-86400))
        let window = TestWindow.new(id: 11, parent: focus.workspace.rootTilingContainer, app: app)

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)

        XCTAssertTrue(routed)
        XCTAssertTrue(window.nodeWorkspace === code, "It goes back into the pin, whatever project is shown")
        XCTAssertEqual(code.projectId, a)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), b)
    }
}
