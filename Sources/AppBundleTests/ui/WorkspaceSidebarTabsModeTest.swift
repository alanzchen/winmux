import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarTabsModeTest: XCTestCase {
    override func tearDown() {
        config = defaultConfig
        super.tearDown()
    }

    func testTabsModeParsesAndKeepsSidebarGeometry() {
        let (parsed, errors) = parseConfig("""
            [workspace-sidebar]
            mode = 'tabs'
            """)
        XCTAssertEqual(errors.descriptions, [])
        XCTAssertEqual(parsed.workspaceSidebar.mode, .tabs)
        XCTAssertTrue(parsed.workspaceSidebar.usesTabsList)
        XCTAssertFalse(parsed.workspaceSidebar.showAppIcons, "Tabs mode is not Dock mode")
        XCTAssertEqual(parsed.workspaceSidebar.effectiveCollapsedWidth, CGFloat(parsed.workspaceSidebar.collapsedWidth),
            "Tabs mode keeps the Sidebar rail")
        XCTAssertFalse(parsed.workspaceSidebar.floatsExpandedDockView)

        let (_, invalid) = parseConfig("""
            [workspace-sidebar]
            mode = 'list'
            """)
        XCTAssertEqual(invalid.descriptions, ["workspace-sidebar.mode: Possible values: sidebar, dock, tabs"])
    }

    func testSnapshotCarriesTabsModeAndSettingsOffersIt() {
        config.workspaceSidebar.mode = .tabs
        XCTAssertTrue(workspaceSidebarConfiguration().usesTabsList)
        XCTAssertFalse(workspaceSidebarConfiguration().showAppIcons)
        config.workspaceSidebar.mode = .sidebar
        XCTAssertFalse(workspaceSidebarConfiguration().usesTabsList)

        guard case .choice(let options) = SettingsCatalog.field("workspace-sidebar.mode").control else {
            return XCTFail("Mode is a choice")
        }
        XCTAssertEqual(options.map(\.value), ["dock", "sidebar", "tabs"])
    }

    func testCollapsedFolderStillShowsTheFocusedWindowAndSearchShowsEverything() {
        let workspace = tabsWorkspace("1", windows: [
            window(1, "Planning", focused: false),
            window(2, "WinMux — GitHub", focused: true),
        ], group: group(representative: 3, windows: [window(3, "Paper", focused: false), window(4, "Notes", focused: false)]))

        XCTAssertEqual(workspaceSidebarTabRows(for: workspace, isCollapsed: false, isSearching: false).map(\.id),
            ["window:1", "window:2", "group:3", "window:3", "window:4"])
        XCTAssertEqual(workspaceSidebarTabRows(for: workspace, isCollapsed: true, isSearching: false).map(\.id),
            ["window:2"], "The window in use stays visible in a collapsed folder")
        XCTAssertEqual(workspaceSidebarTabRows(for: workspace, isCollapsed: true, isSearching: true).count, 5,
            "A search reveals matches without changing the folder's saved state")
        XCTAssertEqual(workspaceSidebarTabWindowCount(workspace), 4)
    }

    func testFocusedWindowInsideACollapsedStackStaysVisible() {
        let workspace = tabsWorkspace("1", windows: [], group: group(representative: 3,
            windows: [window(3, "Paper", focused: false), window(4, "Notes", focused: true)]))
        let rows = workspaceSidebarTabRows(for: workspace, isCollapsed: true, isSearching: false)
        XCTAssertEqual(rows, [.window(window(4, "Notes", focused: true), isGroupChild: false)])
    }

    func testSearchFindsEveryStackWindowAndKeyboardOrderMatchesTheRows() throws {
        // Tab 5 is a split whose second window, 7, has no tab of its own.
        let stack = WorkspaceSidebarTabGroupViewModel(representativeWindowId: 5, workspaceName: "1", title: "Research",
            windowCount: 3, isFocused: false,
            tabs: [window(5, "Dia browser review", focused: false), window(6, "Arc spaces", focused: false)],
            allWindows: [window(5, "Dia browser review", focused: false), window(6, "Arc spaces", focused: false),
                         window(7, "Volcanic islands", focused: false, app: "Preview", bundleId: "com.apple.Preview")])
        let workspace = tabsWorkspace("1", displayName: "Planning", windows: [window(1, "Inbox", focused: false)], group: stack)
        let byProject = [workspaceProjectDefaultId: [workspace]]
        let projects = [WorkspaceSidebarProjectViewModel(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil)]

        let nested = try XCTUnwrap(workspaceSidebarFilteredWorkspacesByProject(byProject, projects: projects,
            query: "volcanic")[workspaceProjectDefaultId]?.first)
        XCTAssertEqual(workspaceSidebarTabRows(for: nested, isCollapsed: false, isSearching: true).map(\.id),
            ["group:5", "window:7"], "A window inside a split is found by its own title")

        let byWorkspaceName = try XCTUnwrap(workspaceSidebarFilteredWorkspacesByProject(byProject, projects: projects,
            query: "planning")[workspaceProjectDefaultId]?.first)
        let rows = workspaceSidebarTabRows(for: byWorkspaceName, isCollapsed: false, isSearching: true)
        XCTAssertEqual(rows.map(\.id), ["window:1", "group:5", "window:5", "window:6", "window:7"],
            "A workspace match keeps every window of its stacks")
        let renderedWindows: [WorkspaceSidebarSearchSelection] = rows.compactMap {
            if case .window(let window, _) = $0 { return .window(window.windowId) }
            return nil
        }
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [byWorkspaceName]), renderedWindows,
            "Arrow keys walk the same windows, in the same order, as the list shows")
    }

    func testActivationFollowsTheSidebarRules() {
        var sent: [WorkspaceSidebarAction] = []
        var overrides = 0
        func activation(allows: Bool, inUse: Bool) -> WorkspaceSidebarTabActivation {
            WorkspaceSidebarTabActivation(allowsActivation: allows, isInUseOnOtherDisplay: inUse,
                requestOverride: { overrides += 1 })
        }
        activation(allows: true, inUse: false).select(.selectWindow(1)) { sent.append($0) }
        XCTAssertEqual(sent, [.selectWindow(1)])
        activation(allows: false, inUse: false).select(.selectWindow(2)) { sent.append($0) }
        XCTAssertEqual(sent, [.selectWindow(1)], "A browsed or pinned folder isn't activated from its rows")
        activation(allows: true, inUse: true).select(.selectWorkspace("3")) { sent.append($0) }
        XCTAssertEqual(sent, [.selectWindow(1), .expandForWorkspaceOverride],
            "A workspace shown on another display asks first, with the panel fully open to read the prompt")
        XCTAssertEqual(overrides, 1)

        var dismissed = 0
        WorkspaceSidebarTabActivation(allowsActivation: true, isInUseOnOtherDisplay: false, requestOverride: {},
            dismissOverride: { dismissed += 1 }).select(.selectWindow(4)) { sent.append($0) }
        XCTAssertEqual(dismissed, 1, "Switching elsewhere dismisses a prompt left on another folder")

        beginWorkspaceSidebarItemDrag()
        defer { endWorkspaceSidebarItemDrag() }
        let before = sent
        activation(allows: true, inUse: false).select(.selectWindow(5)) { sent.append($0) }
        XCTAssertEqual(sent, before, "Releasing a drag never activates the row under the pointer")
    }

    func testTabsModeWinsOverLegacyShowAppIconsInEitherOrder() {
        for toml in ["mode = 'tabs'\nshow-app-icons = false", "show-app-icons = true\nmode = 'tabs'"] {
            let (parsed, errors) = parseConfig("[workspace-sidebar]\n\(toml)")
            XCTAssertEqual(errors.descriptions, [])
            XCTAssertEqual(parsed.workspaceSidebar.mode, .tabs, toml)
            XCTAssertTrue(parsed.workspaceSidebar.usesTabsList, toml)
            XCTAssertFalse(parsed.workspaceSidebar.showAppIcons, toml)
        }
    }

    func testStackTitleSearchShowsItsWindowsInTabsModeOnly() throws {
        let tabs = [window(5, "Paper", focused: false), window(6, "Notes", focused: false)]
        func workspace(allWindows: [WorkspaceSidebarWindowViewModel]) -> WorkspaceSidebarWorkspaceViewModel {
            // The stack's title matches nothing in its windows' own fields.
            let stack = WorkspaceSidebarTabGroupViewModel(representativeWindowId: 5, workspaceName: "1", title: "Thesis stack",
                windowCount: 2, isFocused: false, tabs: tabs, allWindows: allWindows)
            return tabsWorkspace("1", displayName: "Planning", windows: [], group: stack)
        }
        let projects = [WorkspaceSidebarProjectViewModel(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil)]
        func filtered(_ workspace: WorkspaceSidebarWorkspaceViewModel) throws -> WorkspaceSidebarWorkspaceViewModel {
            try XCTUnwrap(workspaceSidebarFilteredWorkspacesByProject([workspaceProjectDefaultId: [workspace]],
                projects: projects, query: "thesis")[workspaceProjectDefaultId]?.first)
        }
        let tabsResult = try filtered(workspace(allWindows: tabs))
        XCTAssertEqual(workspaceSidebarTabRows(for: tabsResult, isCollapsed: false, isSearching: true).map(\.id),
            ["group:5", "window:5", "window:6"])
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [tabsResult]), [.window(5), .window(6)])

        guard case .tabGroup(let sidebarGroup) = try filtered(workspace(allWindows: [])).items.first?.kind else {
            return XCTFail("The stack still matches")
        }
        XCTAssertEqual(sidebarGroup.searchVisibleTabs, [], "Sidebar mode keeps showing the stack's header alone")
    }

    func testCountsDuringSearchMatchWhatIsShown() {
        let stack = WorkspaceSidebarTabGroupViewModel(representativeWindowId: 5, workspaceName: "1", title: "Research",
            windowCount: 6, isFocused: false, tabs: [window(5, "A", focused: false)],
            searchVisibleTabs: [window(5, "A", focused: false)], allWindows: [window(5, "A", focused: false)])
        let workspace = tabsWorkspace("1", windows: [window(1, "B", focused: false)], group: stack)
        XCTAssertEqual(workspaceSidebarTabWindowCount(workspace, isSearching: true), 2)
        XCTAssertEqual(workspaceSidebarTabWindowCount(workspace, isSearching: false), 7)
    }

    func testSearchSelectionStaysInViewAndOtherwiseTheFocusedWindowDoes() {
        let folders = [
            tabsWorkspace("1", windows: [window(1, "A", focused: false)]),
            tabsWorkspace("2", windows: [window(2, "B", focused: true)],
                group: group(representative: 7, windows: [window(7, "C", focused: false), window(8, "D", focused: false)])),
        ]
        XCTAssertEqual(workspaceSidebarTabScrollTarget(folders: folders, searchSelection: .window(8)),
            WorkspaceSidebarTabScrollTarget(folderId: workspaceSidebarTabFolderRowId("2"), rowId: "window:8"),
            "Enter activates the selected result, so its folder and row must come into view")
        XCTAssertEqual(workspaceSidebarTabScrollTarget(folders: folders, searchSelection: .workspace("1")),
            WorkspaceSidebarTabScrollTarget(folderId: workspaceSidebarTabFolderRowId("1"), rowId: nil))
        XCTAssertEqual(workspaceSidebarTabScrollTarget(folders: folders, searchSelection: nil),
            WorkspaceSidebarTabScrollTarget(folderId: workspaceSidebarTabFolderRowId("2"), rowId: "window:2"))
        XCTAssertNil(workspaceSidebarTabScrollTarget(folders: [folders[0]], searchSelection: nil))
        XCTAssertEqual(workspaceSidebarTabScrollTarget(folders: folders, searchSelection: .window(999)),
            WorkspaceSidebarTabScrollTarget(folderId: workspaceSidebarTabFolderRowId("2"), rowId: "window:2"),
            "A result on another project's page leaves this page on its own window")
    }

    func testCollapsedFoldersForgetDeletedWorkspacesAndFocusedRowsAreFound() {
        XCTAssertEqual(workspaceSidebarPrunedCollapsedFolders(["1", "gone"], workspaceNames: ["1", "2"]), ["1"])
        let workspace = tabsWorkspace("1", windows: [window(1, "A", focused: false)],
            group: group(representative: 3, windows: [window(3, "B", focused: false), window(4, "C", focused: true)]))
        XCTAssertEqual(workspaceSidebarFocusedTabRowId(in: workspace), "window:4")
        XCTAssertNil(workspaceSidebarFocusedTabRowId(in: tabsWorkspace("2", windows: [window(9, "D", focused: false)])))
    }

    func testOnlyExpandedTabsModeSwapsTheWorkspacePage() {
        var layout = tabsSnapshot().configuration
        XCTAssertTrue(workspaceSidebarUsesTabsPage(layout: layout, expansionProgress: 1))
        XCTAssertTrue(workspaceSidebarUsesTabsPage(layout: layout, expansionProgress: workspaceSidebarRowsRevealProgress))
        XCTAssertFalse(workspaceSidebarUsesTabsPage(layout: layout, expansionProgress: workspaceSidebarRowsRevealProgress - 0.01),
            "The collapsed rail keeps the workspace rail")
        layout.usesTabsList = false
        XCTAssertFalse(workspaceSidebarUsesTabsPage(layout: layout, expansionProgress: 1), "Sidebar and Dock keep their sections")
    }

    func testAFolderWithHundredsOfWindowsLaysOutQuickly() throws {
        var fixture = tabsSnapshot()
        let windows = (1...300).map { index in
            window(UInt32(1000 + index), "Window \(index)", focused: index == 150)
        }
        fixture.workspaces = [tabsWorkspace("1", displayName: "Big", windows: windows, isVisible: true)]
        let view = WorkspaceSidebarView(snapshot: fixture, reduceMotionOverride: true, reduceTransparencyOverride: true)
        let started = Date()
        let host = NSHostingView(rootView: view.sidebarContent(expansionProgress: 1, layout: fixture.configuration)
            .coordinateSpace(name: "workspaceSidebarContent")
            .frame(width: 280, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 620)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "Laying out 300 tabs stays interactive")
        XCTAssertEqual(workspaceSidebarTabRows(for: fixture.workspaces[0], isCollapsed: false, isSearching: false).count, 300)
    }

    func testStacksListEveryWindowIncludingSplitsInsideATab() async {
        setUpWorkspacesForTests()
        config.workspaceSidebar.mode = .tabs
        let workspace = Workspace.get(byName: "tabs-mode")
        let stack = TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        stack.layout = .tabGroup
        _ = TestWindow.new(id: 11, parent: stack)
        let split = TilingContainer.newHTiles(parent: stack, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        _ = TestWindow.new(id: 12, parent: split)
        _ = TestWindow.new(id: 13, parent: split)

        let viewModel = await makeWorkspaceSidebarTabGroupViewModel(for: stack, workspaceName: workspace.name,
            currentFocus: focus)
        XCTAssertEqual(viewModel?.tabs.count, 2, "Tab-strip semantics keep one entry per tab")
        XCTAssertEqual(viewModel?.allWindows.map(\.windowId), [11, 12, 13], "Tabs mode lists every window")

        config.workspaceSidebar.mode = .sidebar
        let sidebarModel = await makeWorkspaceSidebarTabGroupViewModel(for: stack, workspaceName: workspace.name,
            currentFocus: focus)
        XCTAssertEqual(sidebarModel?.allWindows, [], "Other modes don't pay for the full list")
    }

    func testExpandedTabsListRendersFoldersAsDropTargets() throws {
        let fixture = tabsSnapshot()
        let view = WorkspaceSidebarView(snapshot: fixture, reduceMotionOverride: true, reduceTransparencyOverride: true)
        let probe = TabsDropTargetProbe()
        let content = view.sidebarContent(expansionProgress: 1, layout: fixture.configuration)
            .coordinateSpace(name: "workspaceSidebarContent")
            .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { probe.targets = $0 }
            .frame(width: 280, height: 620)
            .background(Color(red: 0.12, green: 0.13, blue: 0.16))
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 620)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()

        let kinds = probe.targets.map(\.kind)
        for workspace in fixture.workspaces {
            XCTAssertTrue(kinds.contains(.workspace(workspace.name)), "Folder \(workspace.name) accepts dropped tabs")
        }
        XCTAssertTrue(kinds.contains { kind in
            if case .newWorkspace(let projectId, _) = kind { return projectId == workspaceProjectDefaultId }
            return false
        }, "Dropping below the folders makes a new workspace")
        let first = try XCTUnwrap(probe.targets.first { $0.kind == .workspace("1") })
        let second = try XCTUnwrap(probe.targets.first { $0.kind == .workspace("2") })
        XCTAssertLessThan(first.frame.maxY, second.frame.minY)
        XCTAssertGreaterThanOrEqual(first.frame.height,
            workspaceSidebarTabFolderHeaderHeight + 3 * workspaceSidebarTabRowHeight, "Every window has a row")
        // A drop lands where the pointer is: inside folder 2's card, or on the New Workspace row.
        let surface = host.bounds
        XCTAssertEqual(workspaceSidebarLocalDropTarget(at: CGPoint(x: second.frame.midX, y: second.frame.maxY - 2),
            targets: probe.targets, surface: surface)?.kind, .workspace("2"), "All of a folder takes the drop itself")
        XCTAssertEqual(workspaceSidebarLocalDropTarget(at: CGPoint(x: second.frame.midX, y: second.frame.maxY + 1),
            targets: probe.targets, surface: surface)?.kind,
            .tabGap(projectId: workspaceProjectDefaultId, monitorScopeId: "monitor:0,0",
                gap: WorkspaceSidebarTabGap(workspaceName: "2", isAfter: true)),
            "Just below it is the gap after it")
        let newWorkspace = try XCTUnwrap(probe.targets.first { kind in
            if case .newWorkspace = kind.kind { return true }
            return false
        })
        XCTAssertEqual(workspaceSidebarLocalDropTarget(at: CGPoint(x: newWorkspace.frame.midX, y: newWorkspace.frame.midY),
            targets: probe.targets, surface: surface)?.kind, newWorkspace.kind)

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = projectRoot.appendingPathComponent(".build/sidebar-tabs-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("tabs-mode.png"))
    }

    // MARK: - Fixtures

    private func window(_ id: UInt32, _ title: String, focused: Bool, app: String = "Safari",
                        bundleId: String? = "com.apple.Safari") -> WorkspaceSidebarWindowViewModel {
        WorkspaceSidebarWindowViewModel(windowId: id, workspaceName: "1", appName: app, appBundleId: bundleId,
            appBundlePath: nil, title: title, isFocused: focused)
    }

    private func group(representative: UInt32, windows: [WorkspaceSidebarWindowViewModel]) -> WorkspaceSidebarTabGroupViewModel {
        WorkspaceSidebarTabGroupViewModel(representativeWindowId: representative, workspaceName: "1",
            title: windows.first?.title ?? "", windowCount: windows.count, isFocused: windows.contains(where: \.isFocused),
            tabs: Array(windows.prefix(1)), allWindows: windows)
    }

    private func tabsWorkspace(_ name: String, displayName: String? = nil, windows: [WorkspaceSidebarWindowViewModel],
                               group: WorkspaceSidebarTabGroupViewModel? = nil, isVisible: Bool = false) -> WorkspaceSidebarWorkspaceViewModel {
        var items = windows.map { WorkspaceSidebarItemViewModel(kind: .window($0)) }
        if let group { items.append(.init(kind: .tabGroup(group))) }
        return WorkspaceSidebarWorkspaceViewModel(name: name, projectId: workspaceProjectDefaultId,
            displayName: displayName ?? "Workspace \(name)", sidebarLabel: "", isGeneratedName: false,
            monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: isVisible, isVisible: isVisible, items: items)
    }

    private func tabsSnapshot() -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 44, expandedWidth: 280,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false,
            chromeStyle: .solid, solidChromeColor: .midnight, solidChromeCustomColor: "#191B20",
            showAppIcons: false, usesTabsList: true, alwaysExpanded: true)
        snapshot.visibleWidth = 280
        snapshot.targetMonitorScopeId = "monitor:0,0"
        snapshot.projects = [
            .init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: "#7BA3C9", emoji: "🔬"),
            .init(id: "itss", displayName: "ITSS", colorHex: "#7DBF8E", emoji: "🛰️"),
        ]
        snapshot.workspaces = [
            tabsWorkspace("1", displayName: "Planning", windows: [
                window(1, "WinMux — GitHub", focused: true),
                window(2, "zsh — winmux", focused: false, app: "Terminal", bundleId: "com.apple.Terminal"),
                window(3, "Sidebar ideas", focused: false, app: "Notes", bundleId: "com.apple.Notes"),
            ], isVisible: true),
            tabsWorkspace("2", displayName: "Reading", windows: [
                window(4, "A very long window title that should truncate neatly", focused: false,
                    app: "Preview", bundleId: "com.apple.Preview"),
            ], group: group(representative: 5, windows: [
                window(5, "Dia browser review", focused: false),
                window(6, "Arc spaces", focused: false),
            ])),
            tabsWorkspace("3", displayName: "Scratch", windows: []),
        ]
        return snapshot
    }
}

@MainActor
private final class TabsDropTargetProbe {
    var targets: [WorkspaceSidebarDropTargetFrame] = []
}
