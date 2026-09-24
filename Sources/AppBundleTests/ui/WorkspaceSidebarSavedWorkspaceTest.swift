@testable import AppBundle
import AppKit
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarSavedWorkspaceTest: XCTestCase {
    private let laptop = SavedWorkspaceTestMonitor(id: 1, name: "Built-in Display", x: 0, isMain: true, uuid: "LAPTOP", isBuiltin: true)
    private let dell = SavedWorkspaceTestMonitor(id: 2, name: "DELL U2723QE", x: 1920, width: 2560, height: 1440, uuid: "DELL")
    private let testAppBundleId = "bobko.WinMux.test-app"

    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment(runningApps: [testAppBundleId: [SavedRunningApp(pid: 0, launchDate: nil)]])
    }

    override func tearDown() async throws { setMonitorsForTests(nil) }

    // MARK: - View model

    /// A workspace with a window, visible on `monitor`.
    @discardableResult
    private func workspace(_ name: String, on monitor: Monitor, windowId: UInt32, saved: Bool = true) throws -> Workspace {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: windowId, parent: workspace.rootTilingContainer)
        XCTAssertTrue(monitor.setActiveWorkspace(workspace))
        if saved { try ensureSavedWorkspaceRecord(workspace) }
        return workspace
    }

    private func sidebarWorkspace(_ name: String) async throws -> WorkspaceSidebarWorkspaceViewModel {
        let workspaces = await buildWorkspaceSidebarWorkspaceViewModels(
            currentFocus: focus,
            workspaceLabels: [:],
            availableMonitors: sortedMonitors,
        )
        return try XCTUnwrap(workspaces.first { $0.name == name })
    }

    private func twoMonitors() {
        setMonitorsForTests([laptop, dell])
        Workspace.reconcileWorkspaceState()
    }

    func testOnlySavedWorkspacesCarrySavedState() async throws {
        twoMonitors()
        try workspace("plain", on: laptop, windowId: 1, saved: false)
        try workspace("code", on: dell, windowId: 2)

        let plain = try await sidebarWorkspace("plain")
        let code = try await sidebarWorkspace("code")

        XCTAssertNil(plain.savedState)
        XCTAssertEqual(code.savedState, WorkspaceSidebarSavedState(
            isPinnedToDisplay: false,
            homeDisplayName: "DELL U2723QE",
            isHomeConnected: true,
            isForceAssignedByConfig: false,
            missingAppNames: [],
        ))
    }

    func testPinnedWorkspaceKeepsItsHomeWhileDisconnected() async throws {
        twoMonitors()
        let code = try workspace("code", on: dell, windowId: 1)
        XCTAssertTrue(try setSavedWorkspacePinned(code, true))

        var saved = try await sidebarWorkspace("code").savedState
        XCTAssertEqual(saved?.isPinnedToDisplay, true)
        XCTAssertEqual(saved?.homeDisplayName, "DELL U2723QE")
        XCTAssertEqual(saved?.isHomeConnected, true)

        setMonitorsForTests([laptop])
        Workspace.reconcileWorkspaceState()
        saved = try await sidebarWorkspace("code").savedState
        XCTAssertEqual(saved?.isPinnedToDisplay, true)
        XCTAssertEqual(saved?.homeDisplayName, "DELL U2723QE")
        XCTAssertEqual(saved?.isHomeConnected, false)
    }

    func testForceAssignmentIsReportedOnlyWhileItResolves() async throws {
        twoMonitors()
        try workspace("code", on: laptop, windowId: 1)

        config.workspaceToMonitorForceAssignment["code"] = [.sequenceNumber(5)]
        let unresolved = try await sidebarWorkspace("code")
        XCTAssertEqual(unresolved.savedState?.isForceAssignedByConfig, false)

        config.workspaceToMonitorForceAssignment["code"] = [.main]
        let resolved = try await sidebarWorkspace("code")
        XCTAssertEqual(resolved.savedState?.isForceAssignedByConfig, true)
    }

    func testMissingAppsAreNamedInSavedOrder() async throws {
        twoMonitors()
        try workspace("code", on: dell, windowId: 1)
        let slots: [SavedWindowSlot] = [
            .init(id: "editor", bundleId: "com.test.editor", appName: "Editor"),
            .init(id: "running", bundleId: "com.test.running", appName: "Running"),
            .init(id: "chat", bundleId: "com.test.chat", bundlePath: "/Applications/Chat.app"),
            .init(id: "editor-2", bundleId: "com.test.editor", appName: "Editor"),
            .init(id: "anonymous", bundleId: "com.test.anonymous"),
        ]
        savedWorkspaceStore.update(named: "code") { record in
            record.layout = SavedWorkspaceLayout(root: SavedLayoutContainer(children: slots.map { .slot($0) }))
        }
        setSavedWorkspaceTestEnvironment(runningApps: [
            testAppBundleId: [SavedRunningApp(pid: 0, launchDate: nil)],
            "com.test.running": [SavedRunningApp(pid: 50, launchDate: nil)],
        ])

        let code = try await sidebarWorkspace("code")

        XCTAssertEqual(code.savedState?.missingAppNames, ["Editor", "Chat", "com.test.anonymous"])
    }

    func testSavedStateSurvivesOptimisticFocusAndSearchFilter() {
        let savedState = WorkspaceSidebarSavedState(
            isPinnedToDisplay: true,
            homeDisplayName: "DELL U2723QE",
            isHomeConnected: false,
            isForceAssignedByConfig: false,
            missingAppNames: ["Editor"],
        )
        let focused = model("focused", isFocused: true)
        let code = model("code", savedState: savedState, windowTitle: "Release notes")

        let marked = workspaceSidebarWorkspacesMarkingFocused("code", in: [focused, code])
        XCTAssertEqual(marked?.map(\.isFocused), [false, true])
        XCTAssertEqual(marked?.last?.savedState, savedState)

        let filtered = workspaceSidebarFilteredWorkspacesByProject(
            [workspaceProjectDefaultId: [focused, code]],
            projects: [],
            query: "release",
        )[workspaceProjectDefaultId] ?? []
        XCTAssertEqual(filtered.map(\.name), ["code"])
        XCTAssertEqual(filtered.first?.items.map(\.id), ["window:2"], "Matching rows rebuild the workspace")
        XCTAssertEqual(filtered.first?.savedState, savedState)
    }

    // MARK: - Menu

    private func model(
        _ name: String,
        savedState: WorkspaceSidebarSavedState? = nil,
        isFocused: Bool = false,
        windowTitle: String = "Notes",
    ) -> WorkspaceSidebarWorkspaceViewModel {
        let window = WorkspaceSidebarWindowViewModel(windowId: isFocused ? 1 : 2, workspaceName: name,
            appName: "Notes", appBundleId: nil, appBundlePath: nil, title: windowTitle, isFocused: false)
        return WorkspaceSidebarWorkspaceViewModel(name: name, projectId: workspaceProjectDefaultId,
            displayName: name.capitalized, sidebarLabel: name, isGeneratedName: false,
            monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: isFocused, isVisible: isFocused,
            items: [.init(kind: .window(window))], savedState: savedState)
    }

    private func saved(
        pinned: Bool = false,
        home: String? = "DELL U2723QE",
        connected: Bool = true,
        forceAssigned: Bool = false,
        missing: [String] = [],
    ) -> WorkspaceSidebarSavedState {
        WorkspaceSidebarSavedState(isPinnedToDisplay: pinned, homeDisplayName: home, isHomeConnected: connected,
            isForceAssignedByConfig: forceAssigned, missingAppNames: missing)
    }

    private func entries(
        _ savedState: WorkspaceSidebarSavedState?,
        monitorCount: Int = 2,
        currentDisplay: String? = "DELL U2723QE",
        forceAssigned: Bool = false,
        currentDisplayHasIdentity: Bool = true,
        canOpenApps: Bool = true,
    ) -> [WorkspaceSidebarWorkspaceMenuEntry] {
        workspaceSidebarWorkspaceMenuEntries(model("code", savedState: savedState), context: .init(
            monitorCount: monitorCount,
            currentDisplayName: currentDisplay,
            isForceAssignedByConfig: forceAssigned,
            currentDisplayHasIdentity: currentDisplayHasIdentity,
            canOpenApps: canOpenApps,
        ))
    }

    private func entry(_ title: String, in entries: [WorkspaceSidebarWorkspaceMenuEntry]) throws -> WorkspaceSidebarWorkspaceMenuEntry {
        try XCTUnwrap(entries.first { $0.title == title }, "No \(title) in \(entries.map(\.title))")
    }

    func testUnsavedMenuOffersSaveAndKeepOnCurrentDisplay() throws {
        let menu = entries(nil)

        XCTAssertEqual(menu.map(\.title), [
            "Customize Dock & Sidebar…",
            "",
            "Rename Workspace",
            "Save Workspace",
            "Keep on “DELL U2723QE”",
            "",
            "Delete Workspace",
        ])
        XCTAssertEqual(menu.map(\.command), [
            .customizeDock,
            nil,
            .rename,
            .send(.saveWorkspace("code")),
            .send(.setSavedWorkspacePinned("code", true)),
            nil,
            .send(.deleteWorkspace("code")),
        ])
        let keepOn = try entry("Keep on “DELL U2723QE”", in: menu)
        XCTAssertFalse(keepOn.checked)
        XCTAssertTrue(keepOn.enabled)
        XCTAssertTrue(try entry("Delete Workspace", in: menu).isDestructive)
        XCTAssertEqual(menu.filter(\.isDestructive).map(\.title), ["Delete Workspace"])
    }

    func testSavedMenuOffersMissingAppsAndForget() throws {
        let menu = entries(saved(missing: ["Editor", "Chat"]))

        XCTAssertEqual(menu.map(\.title), [
            "Customize Dock & Sidebar…",
            "",
            "Rename Workspace",
            "Keep on “DELL U2723QE”",
            "Open Missing Apps (2)",
            "",
            "Forget Saved Workspace",
            "Delete Workspace",
        ])
        XCTAssertEqual(try entry("Open Missing Apps (2)", in: menu).command, .send(.openSavedWorkspaceApps("code")))
        XCTAssertEqual(try entry("Forget Saved Workspace", in: menu).command, .send(.forgetSavedWorkspace("code")))
        XCTAssertFalse(entries(saved()).contains { $0.title.hasPrefix("Open Missing Apps") }, "Nothing missing, nothing to open")
    }

    func testReadOnlyHidesOpenMissingAppsButTooltipStillNamesThem() {
        let state = saved(missing: ["Editor"])

        XCTAssertFalse(entries(state, canOpenApps: false).contains { $0.title.hasPrefix("Open Missing Apps") })
        XCTAssertTrue(workspaceSidebarSavedWorkspaceDescription(state).contains("Missing: Editor"))
    }

    func testSingleMonitorHidesKeepOnUnlessPinned() throws {
        let single = entries(saved(), monitorCount: 1, currentDisplay: "Built-in Display")
        XCTAssertFalse(single.contains { $0.title.hasPrefix("Keep on") })
        XCTAssertFalse(entries(nil, monitorCount: 1).contains { $0.title.hasPrefix("Keep on") })

        let pinned = entries(saved(pinned: true), monitorCount: 1, currentDisplay: "DELL U2723QE")
        let keepOn = try entry("Keep on “DELL U2723QE”", in: pinned)
        XCTAssertTrue(keepOn.checked)
        XCTAssertTrue(keepOn.enabled)
        XCTAssertEqual(keepOn.command, .send(.setSavedWorkspacePinned("code", false)))
    }

    func testPinnedMenuNamesDisconnectedHomeRatherThanCurrentDisplay() throws {
        let menu = entries(saved(pinned: true, connected: false), monitorCount: 1, currentDisplay: "Built-in Display")

        let keepOn = try entry("Keep on “DELL U2723QE” (Disconnected)", in: menu)
        XCTAssertTrue(keepOn.checked)
        XCTAssertEqual(keepOn.command, .send(.setSavedWorkspacePinned("code", false)))
        XCTAssertFalse(menu.contains { $0.title.contains("Built-in Display") })
    }

    func testUnpinnedMenuNamesTheCurrentDisplayNotTheSoftHome() throws {
        let menu = entries(saved(home: "DELL U2723QE", connected: false), currentDisplay: "Built-in Display")

        let keepOn = try entry("Keep on “Built-in Display”", in: menu)
        XCTAssertFalse(keepOn.checked)
        XCTAssertEqual(keepOn.command, .send(.setSavedWorkspacePinned("code", true)))
    }

    func testForceAssignedPinnedWorkspaceCanStillBeUnpinned() throws {
        let menu = entries(saved(pinned: true, forceAssigned: true), currentDisplay: "Built-in Display")

        let keepOn = try entry("Keep on “DELL U2723QE” (Overridden by Config)", in: menu)
        XCTAssertTrue(keepOn.enabled)
        XCTAssertTrue(keepOn.checked)
        XCTAssertEqual(keepOn.command, .send(.setSavedWorkspacePinned("code", false)))
    }

    func testUnrecognizedDisplayCantBePinnedTo() throws {
        let keepOn = try entry("Keep on “Projector” (Display Not Recognized)",
            in: entries(saved(), currentDisplay: "Projector", currentDisplayHasIdentity: false))

        XCTAssertFalse(keepOn.enabled)
        XCTAssertNil(keepOn.command)
        let pinned = try entry("Keep on “DELL U2723QE”",
            in: entries(saved(pinned: true), currentDisplay: "Projector", currentDisplayHasIdentity: false))
        XCTAssertEqual(pinned.command, .send(.setSavedWorkspacePinned("code", false)), "Unpinning always works")
    }

    func testConfigForceAssignmentDisablesKeepOn() throws {
        for menu in [
            entries(saved(forceAssigned: true), currentDisplay: "Built-in Display"),
            entries(nil, currentDisplay: "Built-in Display", forceAssigned: true),
        ] {
            let keepOn = try entry("Keep on “Built-in Display” (Set in Config)", in: menu)
            XCTAssertFalse(keepOn.enabled)
            XCTAssertTrue(keepOn.checked, "The config already keeps it there")
            XCTAssertNil(keepOn.command)
        }
    }

    func testLiveContextReadsMonitorsAndForceAssignment() throws {
        twoMonitors()
        try workspace("code", on: dell, windowId: 1, saved: false)

        XCTAssertEqual(workspaceSidebarWorkspaceMenuContext(workspaceName: "code"), .init(
            monitorCount: 2,
            currentDisplayName: "DELL U2723QE",
            isForceAssignedByConfig: false,
        ))
        config.workspaceToMonitorForceAssignment["code"] = [.main]
        XCTAssertTrue(workspaceSidebarWorkspaceMenuContext(workspaceName: "code").isForceAssignedByConfig)
        XCTAssertNil(workspaceSidebarWorkspaceMenuContext(workspaceName: "missing").currentDisplayName)
        XCTAssertNil(Workspace.existing(byName: "missing"), "Building a menu must not create a workspace")
    }

    func testMenuEntriesPerformTheirCommands() throws {
        var sent: [WorkspaceSidebarAction] = []
        var renames = 0
        let menu = workspaceSidebarWorkspaceMenu(model("code", savedState: saved(missing: ["Editor"])),
            rename: { renames += 1 }, send: { sent.append($0) })

        for title in ["Rename Workspace", "Open Missing Apps (1)", "Forget Saved Workspace", "Delete Workspace"] {
            try XCTUnwrap(menu.first { $0.title == title }?.perform, title)()
        }

        XCTAssertEqual(renames, 1)
        XCTAssertEqual(sent, [.openSavedWorkspaceApps("code"), .forgetSavedWorkspace("code"), .deleteWorkspace("code")])
        XCTAssertTrue(try XCTUnwrap(menu.first { $0.title == "Delete Workspace" }).isDestructive)
    }

    func testNativeDockWorkspaceMenuMatchesSharedEntries() throws {
        twoMonitors()
        try workspace("code", on: dell, windowId: 1)
        var sent: [WorkspaceSidebarAction] = []
        var workspace = sidebarAppIconsTestWorkspace()
        workspace = WorkspaceSidebarWorkspaceViewModel(name: "code", projectId: workspace.projectId,
            displayName: "Code", sidebarLabel: "Code", isGeneratedName: false, monitorScopeId: workspace.monitorScopeId,
            monitorName: "DELL U2723QE", isFocused: true, isVisible: true, items: workspace.items,
            apps: sidebarAppIconsTestApps(count: 1), savedState: saved(pinned: true, missing: ["Editor"]))
        let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 240, height: 800))
        view.configure(nativeDockFixture(workspace, actions: WorkspaceSidebarActions(send: { sent.append($0) })))
        view.layoutSubtreeIfNeeded()
        defer { view.detach() }

        let tile = try XCTUnwrap(view.buttonFrame(workspaceName: "code", appId: nil))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(CGPoint(x: tile.midX, y: tile.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(view.menu(for: event))
        let expected = workspaceSidebarWorkspaceMenuEntries(workspace, context: workspaceSidebarWorkspaceMenuContext(workspaceName: "code"))

        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "" : $0.title }, expected.map(\.title))
        XCTAssertEqual(menu.items.map(\.isSeparatorItem), expected.map(\.isSeparator))
        let items = menu.items.filter { !$0.isSeparatorItem }
        let entries = expected.filter { !$0.isSeparator }
        XCTAssertEqual(items.map(\.isEnabled), entries.map(\.enabled))
        XCTAssertEqual(items.map { $0.state == .on }, entries.map(\.checked))
        XCTAssertEqual(menu.items.first { $0.title.hasPrefix("Keep on") }?.title, "Keep on “DELL U2723QE”")
        XCTAssertEqual(menu.items.first { $0.title.hasPrefix("Keep on") }?.state, .on)

        let forget = try XCTUnwrap(menu.items.firstIndex { $0.title == "Forget Saved Workspace" })
        menu.performActionForItem(at: forget)
        let keepOn = try XCTUnwrap(menu.items.firstIndex { $0.title.hasPrefix("Keep on") })
        menu.performActionForItem(at: keepOn)
        XCTAssertEqual(sent, [.forgetSavedWorkspace("code"), .setSavedWorkspacePinned("code", false)])
    }

    private func nativeDockFixture(_ workspace: WorkspaceSidebarWorkspaceViewModel, actions: WorkspaceSidebarActions) -> WorkspaceSidebarNativeDock {
        var config = WorkspaceSidebarConfiguration.empty
        config.showAppIcons = true
        config.dockPosition = .left
        let compactLength = workspaceSidebarDockContentHeight(appCounts: [workspace.apps.count], configuration: config,
            showsCreateWorkspace: false, showsMonitorSelector: false, projectCount: 1)
        return WorkspaceSidebarNativeDock(configuration: config, visibleWidth: config.compactRailWidth,
            compactLength: compactLength, leadingLength: 0, trailingLength: 38,
            leading: AnyView(EmptyView()), trailing: AnyView(EmptyView()),
            workspaces: [.init(workspace: workspace, isActive: true, isEnabled: true, opacity: 1,
                select: {}, selectApp: { _ in }, rename: {})],
            projectId: workspaceProjectDefaultId, monitorScopeId: workspaceSidebarDefaultScopeId,
            showsCreate: false, reduceTransparency: false, blockers: [],
            motion: WorkspaceSidebarDockMotionController(), hitRegions: WorkspaceSidebarDockHitRegions(), actions: actions)
    }

    // MARK: - Indicator and tooltip

    func testTooltipDescribesHomeAndMissingApps() {
        XCTAssertEqual(workspaceSidebarWorkspaceTooltip(model("code")), "Code")
        XCTAssertEqual(workspaceSidebarWorkspaceTooltip(model("code", savedState: saved())),
            "Code\nSaved workspace · Returns to “DELL U2723QE”")
        XCTAssertEqual(workspaceSidebarWorkspaceTooltip(model("code", savedState: saved(pinned: true, missing: ["Xcode", "Slack"]))),
            "Code\nSaved workspace · Kept on “DELL U2723QE” · Missing: Xcode, Slack")
        XCTAssertEqual(workspaceSidebarSavedWorkspaceDescription(saved(home: nil)), "Saved workspace")
        XCTAssertEqual(workspaceSidebarSavedWorkspaceDescription(saved(forceAssigned: true)), "Saved workspace",
            "The config, not the saved home, decides where it goes")
    }

    // MARK: - Actions

    func testSaveAndForgetFromSidebar() async throws {
        let code = try workspace("code", on: mainMonitor, windowId: 1, saved: false)

        await saveWorkspaceFromSidebar("code")?.value
        XCTAssertTrue(code.isSaved)
        XCTAssertNil(savedWorkspaceStore.record(named: "code")?.displayName, "Saving from the menu keeps the automatic name")

        await forgetSavedWorkspaceFromSidebar("code")?.value
        XCTAssertFalse(code.isSaved)
        XCTAssertNotNil(Workspace.existing(byName: "code"), "Forgetting keeps the workspace and its windows")
    }

    func testAdapterRoutesSavedWorkspaceActions() async throws {
        let code = try workspace("code", on: mainMonitor, windowId: 1, saved: false)

        handleWorkspaceSidebarAction(.saveWorkspace("code"))
        try await waitUntil { code.isSaved }
        handleWorkspaceSidebarAction(.forgetSavedWorkspace("code"))
        try await waitUntil { !code.isSaved }
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testKeepOnFromSidebarSavesAndPinsToTheCurrentDisplay() async throws {
        twoMonitors()
        let code = try workspace("code", on: dell, windowId: 1, saved: false)

        await setSavedWorkspacePinnedFromSidebar("code", pinned: true)?.value
        XCTAssertTrue(code.isSaved)
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.isPinnedToDisplay, true)
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.display?.uuid, "DELL")

        await setSavedWorkspacePinnedFromSidebar("code", pinned: false)?.value
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.isPinnedToDisplay, false)
        XCTAssertEqual(savedWorkspaceStore.record(named: "code")?.display?.uuid, "DELL", "Unpinning keeps the soft home")
        XCTAssertTrue(code.isSaved)
    }

    func testOpenMissingAppsFromSidebarOpensOnlyThatWorkspacesApps() async throws {
        twoMonitors()
        try workspace("code", on: dell, windowId: 1)
        try workspace("notes", on: laptop, windowId: 2)
        savedWorkspaceStore.update(named: "code") { record in
            record.layout = SavedWorkspaceLayout(root: SavedLayoutContainer(children: [
                .slot(.init(id: "editor", bundleId: "com.test.editor", appName: "Editor", bundlePath: "/Applications/Editor.app")),
            ]))
        }
        savedWorkspaceStore.update(named: "notes") { record in
            record.layout = SavedWorkspaceLayout(root: SavedLayoutContainer(children: [
                .slot(.init(id: "notes", bundleId: "com.test.notes", appName: "Notes")),
            ]))
        }
        var opened: [String] = []
        var environment = SavedWorkspaceEnvironment.forTests(now: savedTestNow)
        environment.openApplication = { bundleId, _ in
            opened.append(bundleId)
            return true
        }
        savedWorkspaceRuntime.environment = environment

        let result = await openSavedWorkspaceAppsFromSidebar("code")?.value

        XCTAssertEqual(result?.opened.count, 1)
        XCTAssertEqual(opened, ["com.test.editor"])
        XCTAssertNotNil(savedWorkspaceRuntime.manualArmUntilByBundleId["com.test.editor"], "Its windows may return to their slots")
        XCTAssertNil(savedWorkspaceRuntime.manualArmUntilByBundleId["com.test.notes"])
    }

    func testOpenMissingAppsReportsAppsThatCouldntOpen() async throws {
        let workspace = try makeSavedTestWorkspace("gone")
        savedWorkspaceStore.update(named: workspace.name) { record in
            record.layout = SavedWorkspaceLayout(root: SavedLayoutContainer(children: [
                .slot(.init(id: "old", bundleId: "com.test.uninstalled", appName: "Old App")),
            ]))
        }
        var environment = SavedWorkspaceEnvironment.forTests(now: savedTestNow)
        environment.openApplication = { _, _ in false }
        savedWorkspaceRuntime.environment = environment
        MessageModel.shared.message = nil
        defer { MessageModel.shared.message = nil }

        let result = await openSavedWorkspaceAppsFromSidebar("gone")?.value

        XCTAssertEqual(result?.failed, ["Old App"])
        XCTAssertEqual(MessageModel.shared.message?.body, "Couldn't open Old App.")
    }
}
