import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarTabLayoutTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        clearWorkspaceSidebarDropPreview()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
        try await super.tearDown()
    }

    /// Where a row's icon starts, from the list's edge.
    private func iconX(_ indent: WorkspaceSidebarTabIndent) -> CGFloat { indent.inset + indent.leadingPadding }

    func testEveryLevelSharesOneIconColumnAndGroupsStepOneColumnIn() {
        let top = WorkspaceSidebarTabIndent()
        XCTAssertEqual(iconX(top), workspaceSidebarTabLeadingPadding, "Tabs, New Tab, and search share the first column")
        var level = top
        for depth in 0..<3 {
            XCTAssertEqual(iconX(level.header), iconX(level), "A group's chevron sits on its level's column (depth \(depth))")
            XCTAssertEqual(iconX(level.children), iconX(level) + workspaceSidebarTabIndentStep,
                "Its rows, and its own icon, start one step in (depth \(depth))")
            XCTAssertEqual(level.children.depth, level.depth + 1)
            level = level.children
        }
    }

    func testCardsAndTheirRowsStayConcentric() {
        let top = WorkspaceSidebarTabIndent()
        XCTAssertEqual(top.rowCornerRadius, workspaceSidebarTabCornerRadius, "Rows outside a card keep the tab radius")
        XCTAssertEqual(top.cardCornerRadius, workspaceSidebarTabGroupCornerRadius)
        XCTAssertEqual(top.children.rowCornerRadius, top.cardCornerRadius - workspaceSidebarTabGroupInset)
        XCTAssertEqual(top.children.cardCornerRadius, top.cardCornerRadius - workspaceSidebarTabGroupInset,
            "A browser window's card inside a group follows the group's corners")
        XCTAssertGreaterThanOrEqual(top.children.children.children.rowCornerRadius, 6, "Deep nesting keeps a visible radius")
    }

    func testTheLineShowsOnlyOnTheTabAndGroupTheDropJoins() {
        var preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 1, label: "x", appName: "x", targetWorkspaceName: nil,
            targetsNewWorkspace: false, targetProjectId: workspaceProjectDefaultId, isTabGroup: false, windowCount: 1)
        preview.targetGap = WorkspaceSidebarTabGap(workspaceName: "a", isAfter: true, collectionId: "group")
        XCTAssertEqual(workspaceSidebarTabInsertionEdge(preview, workspaceName: "a", collectionId: "group",
            projectId: workspaceProjectDefaultId), .bottom)
        XCTAssertNil(workspaceSidebarTabInsertionEdge(preview, workspaceName: "a", collectionId: nil,
            projectId: workspaceProjectDefaultId), "The same tab outside that group")
        XCTAssertNil(workspaceSidebarTabInsertionEdge(preview, workspaceName: "b", collectionId: "group",
            projectId: workspaceProjectDefaultId))
        XCTAssertNil(workspaceSidebarTabInsertionEdge(preview, workspaceName: "a", collectionId: "group", projectId: "other"),
            "Another project's page")
        preview.targetGap = WorkspaceSidebarTabGap(workspaceName: "a", isAfter: false, collectionId: "group")
        XCTAssertEqual(workspaceSidebarTabInsertionEdge(preview, workspaceName: "a", collectionId: "group",
            projectId: workspaceProjectDefaultId), .top)
        XCTAssertNil(workspaceSidebarTabInsertionEdge(nil, workspaceName: "a", collectionId: nil, projectId: workspaceProjectDefaultId))
    }

    func testTheSpaceBelowTheTabsPutsADroppedTabLastOutsideAnyGroup() {
        let a = tab("a"), b = tab("b"), c = tab("c")
        let group = WorkspaceTabCollection(id: "g", projectId: workspaceProjectDefaultId, workspaceNames: ["b", "c"])
        let endsWithTab = workspaceSidebarTabsTailGap(sections: [.collection(group, [b, c]), .tab(a)])
        XCTAssertEqual(endsWithTab?.gap, WorkspaceSidebarTabGap(workspaceName: "a", isAfter: true))
        XCTAssertEqual(endsWithTab?.drawsOwnLine, false, "The last tab draws the line itself")
        let endsWithGroup = workspaceSidebarTabsTailGap(sections: [.tab(a), .collection(group, [b, c])])
        XCTAssertEqual(endsWithGroup?.gap, WorkspaceSidebarTabGap(workspaceName: "c", isAfter: true),
            "After the group's last tab, but not in the group")
        XCTAssertEqual(endsWithGroup?.drawsOwnLine, true, "The line goes below the group, not inside it")
        let empty = WorkspaceTabCollection(id: "e", projectId: workspaceProjectDefaultId)
        let beforeEmptyGroup = workspaceSidebarTabsTailGap(sections: [.tab(a), .collection(empty, [])])
        XCTAssertEqual(beforeEmptyGroup?.gap, WorkspaceSidebarTabGap(workspaceName: "a", isAfter: true),
            "An empty group, always listed last, has no tab to go after")
        XCTAssertEqual(beforeEmptyGroup?.drawsOwnLine, false)
        XCTAssertEqual(workspaceSidebarTabsTailGap(sections: [.collection(group, [b, c]), .collection(empty, [])])?.gap,
            WorkspaceSidebarTabGap(workspaceName: "c", isAfter: true))
        XCTAssertNil(workspaceSidebarTabsTailGap(sections: [.collection(empty, [])]))
        XCTAssertNil(workspaceSidebarTabsTailGap(sections: []))
    }

    func testPullingAWindowOutOfASplitPreviewsANewTabButAWholeTabBesideItselfDoesNothing() throws {
        let split = focus.workspace
        let left = TestWindow.new(id: 60, parent: split.rootTilingContainer)
        let right = TestWindow.new(id: 61, parent: split.rootTilingContainer)
        let single = Workspace.get(byName: "single")
        let alone = TestWindow.new(id: 62, parent: single.rootTilingContainer)
        XCTAssertTrue(workspaceTabDragLeavesWindowsBehind(right))
        XCTAssertFalse(workspaceTabDragLeavesWindowsBehind(alone))

        let beside = { (name: String) in
            WorkspaceSidebarDropTargetKind.tabGap(projectId: split.projectId,
                monitorScopeId: workspaceSidebarMonitorScopeId(for: split.workspaceMonitor),
                gap: WorkspaceSidebarTabGap(workspaceName: name, isAfter: true))
        }
        previewWorkspaceSidebarDrop(right.windowId, subject: .window, target: beside(split.name))
        let own = try XCTUnwrap(TrayMenuModel.shared.workspaceSidebarDropPreview, "A split half can leave beside its own tab")
        XCTAssertEqual(own.targetGap?.workspaceName, split.name)
        XCTAssertTrue(own.separatesFromTab, "The line says the window gets a new tab")

        previewWorkspaceSidebarDrop(left.windowId, subject: .window, target: beside(single.name))
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.separatesFromTab, true)

        previewWorkspaceSidebarDrop(alone.windowId, subject: .window, target: .tabGap(projectId: split.projectId,
            monitorScopeId: workspaceSidebarMonitorScopeId(for: split.workspaceMonitor),
            gap: WorkspaceSidebarTabGap(workspaceName: split.name, isAfter: false)))
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.separatesFromTab, false, "A whole tab just moves")

        previewWorkspaceSidebarDrop(alone.windowId, subject: .window, target: beside(single.name))
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "Beside itself, a whole tab stays put: no promise")
        previewWorkspaceSidebarDrop(alone.windowId, subject: .window, target: .tabGap(projectId: split.projectId,
            monitorScopeId: "another-display", gap: WorkspaceSidebarTabGap(workspaceName: single.name, isAfter: true)))
        XCTAssertNotNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "Another display's list moves it there")
    }

    func testAWholeTabIsOfferedOnlyGapsThatMoveIt() throws {
        let first = focus.workspace
        let second = Workspace.get(byName: "second")
        let third = Workspace.get(byName: "third")
        for (index, tab) in [first, second, third].enumerated() {
            _ = TestWindow.new(id: UInt32(70 + index), parent: tab.rootTilingContainer)
        }
        XCTAssertEqual(orderedWorkspaces(in: first.projectId).map(\.name), [first, second, third].map(\.name))
        let dragged = try XCTUnwrap(second.allLeafWindowsRecursive.first)
        let actionable = { (name: String, isAfter: Bool) -> Bool in
            previewWorkspaceSidebarDrop(dragged.windowId, subject: .window, target: .tabGap(projectId: first.projectId,
                monitorScopeId: workspaceSidebarMonitorScopeId(for: second.workspaceMonitor),
                gap: WorkspaceSidebarTabGap(workspaceName: name, isAfter: isAfter)))
            return TrayMenuModel.shared.workspaceSidebarDropPreview != nil
        }
        XCTAssertFalse(actionable(first.name, true), "Right after the tab it already follows")
        XCTAssertFalse(actionable(third.name, false), "Right before the tab it already precedes")
        XCTAssertFalse(actionable(second.name, true))
        XCTAssertTrue(actionable(first.name, false))
        XCTAssertTrue(actionable(third.name, true))
        let group = try workspaceSidebarOrganizationStore.create(projectId: first.projectId, workspaceNames: [first.name])
        previewWorkspaceSidebarDrop(dragged.windowId, subject: .window, target: .tabGap(projectId: first.projectId,
            monitorScopeId: workspaceSidebarMonitorScopeId(for: second.workspaceMonitor),
            gap: WorkspaceSidebarTabGap(workspaceName: first.name, isAfter: true, collectionId: group.id)))
        XCTAssertNotNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "The same spot inside a group joins the group")
    }

    func testAWindowPulledOutOfASplitGetsItsOwnTabAtTheGap() throws {
        let split = focus.workspace
        let left = TestWindow.new(id: 80, parent: split.rootTilingContainer)
        let right = TestWindow.new(id: 81, parent: split.rootTilingContainer)
        let other = Workspace.get(byName: "other")
        _ = TestWindow.new(id: 82, parent: other.rootTilingContainer)
        applyTabGapDrop(sourceNode: right, sourceWindow: right, projectId: split.projectId, monitor: split.workspaceMonitor,
            gap: WorkspaceSidebarTabGap(workspaceName: split.name, isAfter: true))
        let tab = try XCTUnwrap(right.nodeWorkspace)
        XCTAssertFalse(tab === split, "The window leaves the split for a tab of its own")
        XCTAssertEqual(split.allLeafWindowsRecursive, [left])
        XCTAssertEqual(orderedWorkspaces(in: split.projectId).map(\.name), [split.name, tab.name, other.name],
            "Right where the line was drawn")
    }

    func testAFolderInsideAGroupKeepsDropsAtItsEdgesInTheGroup() throws {
        var fixture = renderFixture()
        let a = WorkspaceSidebarWindowViewModel(windowId: 5, workspaceName: "stack", appName: "Notes", appBundleId: nil,
            appBundlePath: nil, title: "A", isFocused: false)
        let b = WorkspaceSidebarWindowViewModel(windowId: 6, workspaceName: "stack", appName: "Notes", appBundleId: nil,
            appBundlePath: nil, title: "B", isFocused: false)
        fixture.workspaces.append(.init(name: "stack", projectId: workspaceProjectDefaultId, displayName: "Stack",
            sidebarLabel: "Stack", isGeneratedName: false, monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: false,
            isVisible: false, items: [.init(kind: .tabGroup(.init(representativeWindowId: 5, workspaceName: "stack",
                title: "Notes", windowCount: 2, isFocused: false, tabs: [a, b], allWindows: [a, b])))]))
        fixture.configuration.tabCollections = [.init(id: "g", projectId: workspaceProjectDefaultId, name: "Group",
            workspaceNames: ["stack"])]
        let targets = try renderedDropTargets(fixture)
        // The folder's edge bands; the zone below all the tabs is outside every group.
        let gaps = targets.compactMap { target -> WorkspaceSidebarTabGap? in
            if case .tabGap(_, _, let gap) = target.kind, gap.workspaceName == "stack",
               target.frame.height < workspaceSidebarTabRowHeight { return gap }
            return nil
        }
        XCTAssertFalse(gaps.isEmpty, "The folder takes drops at its edges")
        XCTAssertTrue(gaps.allSatisfy { $0.collectionId == "g" }, "and they stay in its group, where its line is drawn")
    }

    func testASplitIsOfferedOnATabNotUsedSinceLaunch() async throws {
        let source = TestWindow.new(id: 110, parent: focus.workspace.rootTilingContainer)
        let target = Workspace.get(byName: "untouched")
        _ = TestWindow.new(id: 111, parent: target.rootTilingContainer)
        // Nothing there has been focused, and an empty macOS container is the workspace's last child.
        _ = target.macOsNativeHiddenAppsWindowsContainer
        XCTAssertNil(target.mostRecentWindowRecursive, "No window of the tab has been used yet")
        XCTAssertEqual(workspaceTabDropTargetWindow(target)?.windowId, 111)
        let drop = WorkspaceSidebarDropTarget(kind: .workspace(target.name),
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 36), acceptsSides: true,
            tabReorderDestination: .init(projectId: target.projectId, monitorScopeId: "row-display", collectionId: nil))
        let point = CGPoint(x: 40, y: 18)
        defer { WorkspaceSidebarTabSplitHoverController.shared.reset() }
        _ = workspaceSidebarDeliberateTabDropTarget(drop, sourceWindow: source, point: point)
        try await Task.sleep(for: .milliseconds(440))
        let armed = try XCTUnwrap(workspaceSidebarDeliberateTabDropTarget(drop, sourceWindow: source, point: point))
        XCTAssertEqual(armed.kind, drop.kind)
        XCTAssertTrue(armed.acceptsSides, "Holding over its left half offers Split left, as on any other tab")
        applyTabDrop(sourceNode: source, sourceWindow: source, targetWorkspace: target, placement: .left)
        XCTAssertEqual(target.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [110, 111],
            "and the drop lands on that side")
        let other = TestWindow.new(id: 112, parent: Workspace.get(byName: "elsewhere").rootTilingContainer)
        applyTabDrop(sourceNode: other, sourceWindow: other, targetWorkspace: target, placement: .right)
        XCTAssertEqual(target.rootTilingContainer.allLeafWindowsRecursive.last?.windowId, 112)
    }

    func testTheEmptySpaceUnderTheTabsTakesADropAsTheLastTab() throws {
        var fixture = WorkspaceSidebarSnapshot.empty
        fixture.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 44, expandedWidth: 280,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false, chromeStyle: .solid, solidChromeColor: .midnight,
            solidChromeCustomColor: "#191B20", showAppIcons: false, usesTabsList: true, alwaysExpanded: true)
        fixture.visibleWidth = 280
        fixture.targetMonitorScopeId = "monitor:0,0"
        fixture.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
        fixture.workspaces = [UInt32(1), 2].map { id in
            let window = WorkspaceSidebarWindowViewModel(windowId: id, workspaceName: "\(id)", appName: "Safari",
                appBundleId: "com.apple.Safari", appBundlePath: nil, title: "Tab \(id)", isFocused: id == 1)
            return .init(name: "\(id)", projectId: workspaceProjectDefaultId, displayName: "\(id)", sidebarLabel: "",
                isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: id == 1, isVisible: id == 1,
                items: [.init(kind: .window(window))])
        }
        let probe = TabLayoutDropTargetProbe()
        let view = WorkspaceSidebarView(snapshot: fixture, reduceMotionOverride: true, reduceTransparencyOverride: true)
        let host = NSHostingView(rootView: view.sidebarContent(expansionProgress: 1, layout: fixture.configuration)
            .coordinateSpace(name: "workspaceSidebarContent")
            .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { probe.targets = $0 }
            .frame(width: 280, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 620)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()

        let last = try XCTUnwrap(probe.targets.first { $0.kind == .workspace("2") })
        let tail = WorkspaceSidebarDropTargetKind.tabGap(projectId: workspaceProjectDefaultId, monitorScopeId: "monitor:0,0",
            gap: WorkspaceSidebarTabGap(workspaceName: "2", isAfter: true))
        let zone = try XCTUnwrap(probe.targets.first { $0.kind == tail && $0.frame.height > workspaceSidebarTabRowHeight })
        XCTAssertGreaterThanOrEqual(zone.frame.minY, last.frame.maxY - 0.5, "The zone starts below the last tab")
        XCTAssertGreaterThan(zone.frame.height, 150, "and fills the empty list below it")
        XCTAssertEqual(workspaceSidebarLocalDropTarget(at: CGPoint(x: zone.frame.midX, y: last.frame.maxY + 80),
            targets: probe.targets, surface: host.bounds)?.kind, tail)
    }

    func testOnlyTheSidebarPreviewsAndDropsATabsModeDragOverIt() {
        XCTAssertTrue(workspaceSidebarOwnsDrag(usesBrowserTabs: true, startedInSidebar: true, hasActiveSidebarDrag: true,
            isPointerInSidebar: true))
        XCTAssertFalse(workspaceSidebarOwnsDrag(usesBrowserTabs: true, startedInSidebar: true, hasActiveSidebarDrag: true,
            isPointerInSidebar: false), "Over the screen, the window drag's own targets apply")
        XCTAssertFalse(workspaceSidebarOwnsDrag(usesBrowserTabs: true, startedInSidebar: false, hasActiveSidebarDrag: false,
            isPointerInSidebar: true), "A window dragged in from the screen joins a tab as before")
        XCTAssertFalse(workspaceSidebarOwnsDrag(usesBrowserTabs: false, startedInSidebar: true, hasActiveSidebarDrag: true,
            isPointerInSidebar: true), "Dock and Sidebar modes are unchanged")
        XCTAssertTrue(workspaceSidebarOwnsDrag(usesBrowserTabs: false, startedInSidebar: true, hasActiveSidebarDrag: true,
            isPointerInSidebar: true, isPointerOnTemporarySurface: true), "Temporary drop UI owns it in every mode")
        XCTAssertFalse(workspaceSidebarOwnsDrag(usesBrowserTabs: false, startedInSidebar: false, hasActiveSidebarDrag: false,
            isPointerInSidebar: true, isPointerOnTemporarySurface: true), "Only the sidebar's own drags")
    }

    private func renderFixture() -> WorkspaceSidebarSnapshot {
        var fixture = WorkspaceSidebarSnapshot.empty
        fixture.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 44, expandedWidth: 280,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false, chromeStyle: .solid, solidChromeColor: .midnight,
            solidChromeCustomColor: "#191B20", showAppIcons: false, usesTabsList: true, alwaysExpanded: true)
        fixture.visibleWidth = 280
        fixture.targetMonitorScopeId = "monitor:0,0"
        fixture.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
        let window = WorkspaceSidebarWindowViewModel(windowId: 1, workspaceName: "1", appName: "Safari",
            appBundleId: "com.apple.Safari", appBundlePath: nil, title: "Tab", isFocused: true)
        fixture.workspaces = [.init(name: "1", projectId: workspaceProjectDefaultId, displayName: "1", sidebarLabel: "",
            isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: true, isVisible: true,
            items: [.init(kind: .window(window))])]
        return fixture
    }

    private func renderedDropTargets(_ fixture: WorkspaceSidebarSnapshot) throws -> [WorkspaceSidebarDropTargetFrame] {
        let probe = TabLayoutDropTargetProbe()
        let view = WorkspaceSidebarView(snapshot: fixture, reduceMotionOverride: true, reduceTransparencyOverride: true)
        let host = NSHostingView(rootView: view.sidebarContent(expansionProgress: 1, layout: fixture.configuration)
            .coordinateSpace(name: "workspaceSidebarContent")
            .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { probe.targets = $0 }
            .frame(width: 280, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 620)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
        return probe.targets
    }

    private func tab(_ name: String) -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: "", isGeneratedName: true,
            monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: false, isVisible: false, items: [])
    }
}

@MainActor
private final class TabLayoutDropTargetProbe {
    var targets: [WorkspaceSidebarDropTargetFrame] = []
}
