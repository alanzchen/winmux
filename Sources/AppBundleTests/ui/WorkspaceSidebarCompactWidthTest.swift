import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarCompactWidthTest: XCTestCase {
    func testSidebarKeepsItsLegacyBadgeWidthFloor() {
        for (width, expected): (CGFloat, CGFloat) in [(28, 32), (44, 32), (120, 106)] {
            var layout = WorkspaceSidebarConfiguration.empty
            layout.collapsedWidth = width
            layout.showAppIcons = false
            XCTAssertEqual(workspaceSidebarCompactSectionWidth(layout: layout), expected)
        }
    }

    func testCompactRailKeepsConfiguredWidthAsAppsAndWindowsChange() {
        for railWidth: CGFloat in [32, 44, 64] {
            for expandedWidth: CGFloat in [120, 160, 240, 480] {
                for appCount in [0, 1, 6, 104] {
                    for windowCount in [0, 1, 8] {
                        let compact = section(
                            railWidth: railWidth,
                            expandedWidth: expandedWidth,
                            progress: 0,
                            appCount: appCount,
                            windowCount: windowCount,
                        )
                        let outerWidth = compact.sectionWidth +
                            workspaceSidebarOuterLeadingPadding(isCompact: true, layout: compact.layout) +
                            workspaceSidebarOuterTrailingPadding(isCompact: true, layout: compact.layout)
                        XCTAssertEqual(
                            outerWidth,
                            railWidth,
                            accuracy: 0.001,
                            "App and window counts must not widen the configured compact rail",
                        )
                        XCTAssertLessThanOrEqual(compact.appSummaryWidth, compact.sectionWidth)
                    }
                }
            }
        }
    }

    func testExpansionWidthIsIndependentOfWorkspaceContentsAndReturnsToCompactWidth() {
        for railWidth: CGFloat in [32, 44, 64] {
            var previousWidth: CGFloat = 0
            for progress: CGFloat in [0, 0.2, 0.5, 0.8, 1] {
                let empty = section(railWidth: railWidth, progress: progress, appCount: 0, windowCount: 0)
                XCTAssertGreaterThanOrEqual(empty.sectionWidth, previousWidth)
                for appCount in [1, 6, 104] {
                    let populated = section(railWidth: railWidth, progress: progress, appCount: appCount, windowCount: 8)
                    XCTAssertEqual(populated.sectionWidth, empty.sectionWidth, accuracy: 0.001)
                }
                previousWidth = empty.sectionWidth
            }

            let expanded = section(railWidth: railWidth, progress: 1, appCount: 104, windowCount: 8)
            XCTAssertEqual(
                expanded.sectionWidth +
                    workspaceSidebarOuterLeadingPadding(isCompact: false) +
                    workspaceSidebarOuterTrailingPadding(isCompact: false),
                240,
                accuracy: 0.001,
            )
            let collapsed = section(railWidth: railWidth, progress: 0, appCount: 104, windowCount: 8)
            XCTAssertEqual(
                collapsed.sectionWidth +
                    workspaceSidebarOuterLeadingPadding(isCompact: true, layout: collapsed.layout) +
                    workspaceSidebarOuterTrailingPadding(isCompact: true, layout: collapsed.layout),
                railWidth,
                accuracy: 0.001,
            )
        }
    }

    func testAppSummaryKeepsItsCompactColumnWhileSidebarMorphsIntoExpandedMode() {
        for railWidth: CGFloat in [32, 44, 64] {
            for appCount in [0, 1, 6, 104] {
                let compact = section(railWidth: railWidth, progress: 0, appCount: appCount, windowCount: 8)
                let compactIcons = WorkspaceSidebarAppIconLayout(appCount: appCount, availableWidth: compact.appSummaryWidth)
                for progress: CGFloat in [0, 0.25, 0.57, 0.59, 0.75, 1] {
                    let expanding = section(railWidth: railWidth, progress: progress, appCount: appCount, windowCount: 8)
                    let icons = WorkspaceSidebarAppIconLayout(appCount: appCount, availableWidth: expanding.appSummaryWidth)
                    XCTAssertEqual(
                        expanding.appSummaryWidth,
                        compact.appSummaryWidth,
                        accuracy: 0.001,
                        "Compact app icons must not reflow as the sidebar expands",
                    )
                    XCTAssertEqual(icons.itemSize, compactIcons.itemSize, accuracy: 0.001)
                    XCTAssertEqual(icons.height, compactIcons.height, accuracy: 0.001)
                    XCTAssertEqual(icons.visibleAppCount, compactIcons.visibleAppCount)
                }
            }
        }
    }

    func testDockModeUsesDefaultProportionalPanelWidthAndRestoresLegacyWidth() {
        let previousConfig = config
        setUpWorkspacesForTests()
        defer {
            for window in focus.workspace.allLeafWindowsRecursive { window.unbindFromParent() }
            config = previousConfig
            setMonitorsForTests(nil)
        }
        let monitor = TestMonitor(
            monitorAppKitNsScreenScreensId: 1,
            name: "Main",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            isMain: true,
        )
        setMonitorsForTests([monitor])
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.monitor = [.main]
        config.workspaceSidebar.width = 240
        config.gaps = .zero

        for windowCount in [0, 1, 8] {
            for window in focus.workspace.allLeafWindowsRecursive { window.unbindFromParent() }
            for index in 0 ..< windowCount {
                TestWindow.new(id: UInt32(index + 1), parent: focus.workspace.rootTilingContainer)
            }
            for storedWidth in [28, 44, 120] {
                config.workspaceSidebar.collapsedWidth = storedWidth
                for showAppIcons in [false, true, false] {
                    config.workspaceSidebar.showAppIcons = showAppIcons
                    let railWidth = CGFloat(showAppIcons ? 64 : storedWidth)
                    for (autoHide, alwaysExpanded, expectedInset, expectedContentWidth) in [
                        (false, false, railWidth, railWidth),
                        (true, false, CGFloat(0), CGFloat(0)),
                        (false, true, CGFloat(240), railWidth),
                        (true, true, CGFloat(240), railWidth),
                    ] {
                        config.workspaceSidebar.autoHide = autoHide
                        config.workspaceSidebar.alwaysExpanded = alwaysExpanded
                        let snapshot = workspaceSidebarConfiguration()
                        XCTAssertEqual(snapshot.collapsedWidth, expectedContentWidth)
                        XCTAssertEqual(snapshot.compactRailWidth, railWidth, "Auto-hide must retain the resolved compact layout width")
                        XCTAssertEqual(snapshot.expandedWidth, 240)
                        XCTAssertEqual(workspaceSidebarRestingWidth(config.workspaceSidebar), expectedInset)
                        let reservedInset = expectedInset + (showAppIcons && !alwaysExpanded && expectedInset > 0 ? 2 : 0)
                        XCTAssertEqual(monitor.workspaceSidebarInset, reservedInset)
                        XCTAssertEqual(monitor.visibleRectPaddedByOuterGaps.topLeftX, reservedInset)
                        XCTAssertEqual(monitor.visibleRectPaddedByOuterGaps.width, 1920 - reservedInset)
                        XCTAssertEqual(
                            workspaceSidebarHoverActivationWidth(config.workspaceSidebar),
                            alwaysExpanded ? 240 : railWidth,
                        )
                        XCTAssertEqual(config.workspaceSidebar.collapsedWidth, storedWidth)
                    }
                }
            }
        }
    }

    func testMorphTargetsIncludeEveryAppInCompactRail() {
        let apps = sidebarAppIconsTestApps(count: 6)
        let windows = apps.enumerated().map { window(id: UInt32($0.offset + 1), app: $0.element) }
        let workspace = self.workspace(apps: apps, items: windows.map { .init(kind: .window($0)) })

        for railWidth: CGFloat in [32, 44, 64] {
            let view = section(workspace: workspace, railWidth: railWidth)
            XCTAssertEqual(Set(view.appMorphTargets.keys), Set(apps.map(\.id)))
            for (index, window) in windows.enumerated() {
                XCTAssertEqual(view.morphAppId(for: window), apps[index].id)
            }
        }
    }

    func testDuplicateWindowsPairAnAppWithItsFirstRenderedRowOnly() {
        let app = sidebarAppIconsTestApps(count: 1)[0]
        let first = window(id: 20, app: app)
        let duplicate = window(id: 10, app: app)
        let view = section(workspace: workspace(apps: [app], items: [
            .init(kind: .window(first)),
            .init(kind: .window(duplicate)),
        ]))

        XCTAssertEqual(view.appMorphTargets.count, 1)
        XCTAssertEqual(view.appMorphTargets[app.id]?.windowId, first.windowId)
        XCTAssertEqual(view.appMorphTargets[app.id]?.opacity, 1)
        XCTAssertEqual(view.morphAppId(for: first), app.id)
        XCTAssertNil(view.morphAppId(for: duplicate))
    }

    func testSummaryAppWithoutRenderedWindowDoesNotCreateMorphTarget() {
        let apps = sidebarAppIconsTestApps(count: 2)
        let rendered = window(id: 1, app: apps[0])
        let summaryOnly = window(id: 2, app: apps[1])
        let view = section(workspace: workspace(apps: apps, items: [.init(kind: .window(rendered))]))

        XCTAssertEqual(Set(view.appMorphTargets.keys), Set([apps[0].id]))
        XCTAssertEqual(view.morphAppId(for: rendered), apps[0].id)
        XCTAssertNil(view.appMorphTargets[apps[1].id])
        XCTAssertNil(view.morphAppId(for: summaryOnly))
    }

    func testTabGroupMorphTargetsUseOnlySearchVisibleTabsAndChildOpacity() {
        let apps = sidebarAppIconsTestApps(count: 3)
        let hiddenFirst = window(id: 1, app: apps[0])
        let hiddenOtherApp = window(id: 2, app: apps[1])
        let visible = window(id: 3, app: apps[0])
        let visibleOtherApp = window(id: 4, app: apps[2])
        let tabs = [hiddenFirst, hiddenOtherApp, visible, visibleOtherApp]
        let group = WorkspaceSidebarTabGroupViewModel(
            representativeWindowId: hiddenFirst.windowId,
            workspaceName: "104",
            title: "Documents",
            windowCount: tabs.count,
            isFocused: false,
            tabs: tabs,
            searchVisibleTabs: [visible, visibleOtherApp],
        )
        let view = section(workspace: workspace(apps: apps, items: [.init(kind: .tabGroup(group))]))

        XCTAssertEqual(Set(view.appMorphTargets.keys), Set([apps[0].id, apps[2].id]))
        XCTAssertEqual(view.appMorphTargets[apps[0].id]?.windowId, visible.windowId)
        XCTAssertEqual(view.morphAppId(for: visible), apps[0].id)
        XCTAssertEqual(view.morphAppId(for: visibleOtherApp), apps[2].id)
        XCTAssertNil(view.morphAppId(for: hiddenFirst))
        XCTAssertNil(view.morphAppId(for: hiddenOtherApp))
        for target in view.appMorphTargets.values { XCTAssertEqual(target.opacity, 0.56, accuracy: 0.001) }

        var emptySearch = group
        emptySearch.searchVisibleTabs = []
        let noMatches = section(workspace: workspace(apps: apps, items: [.init(kind: .tabGroup(emptySearch))]))
        XCTAssertTrue(noMatches.appMorphTargets.isEmpty, "An empty filtered group must not fall back to hidden tabs")

        var unfilteredGroup = group
        unfilteredGroup.searchVisibleTabs = nil
        let unfiltered = section(workspace: workspace(apps: apps, items: [.init(kind: .tabGroup(unfilteredGroup))]))
        XCTAssertEqual(unfiltered.appMorphTargets[apps[0].id]?.windowId, hiddenFirst.windowId)
        XCTAssertEqual(unfiltered.appMorphTargets[apps[1].id]?.windowId, hiddenOtherApp.windowId)
        XCTAssertNil(unfiltered.morphAppId(for: visible))
    }

    private func window(id: UInt32, app: WorkspaceSidebarAppViewModel) -> WorkspaceSidebarWindowViewModel {
        WorkspaceSidebarWindowViewModel(
            windowId: id,
            workspaceName: "104",
            appName: app.name,
            appBundleId: app.bundleId,
            appBundlePath: app.bundlePath,
            title: "Document \(id)",
            isFocused: false,
        )
    }

    private func workspace(
        apps: [WorkspaceSidebarAppViewModel],
        items: [WorkspaceSidebarItemViewModel],
    ) -> WorkspaceSidebarWorkspaceViewModel {
        WorkspaceSidebarWorkspaceViewModel(
            name: "104",
            projectId: workspaceProjectDefaultId,
            displayName: "104",
            sidebarLabel: "",
            isGeneratedName: false,
            monitorScopeId: workspaceSidebarDefaultScopeId,
            monitorName: nil,
            isFocused: true,
            isVisible: true,
            items: items,
            apps: apps,
        )
    }

    private func section(
        railWidth: CGFloat,
        expandedWidth: CGFloat = 240,
        progress: CGFloat,
        appCount: Int,
        windowCount: Int,
    ) -> WorkspaceSidebarWorkspaceSection {
        let items = (0 ..< windowCount).map { index in
            WorkspaceSidebarItemViewModel(kind: .window(.init(
                windowId: UInt32(index + 1),
                workspaceName: "104",
                appName: "Application with a long descriptive name \(index)",
                appBundleId: "test.app.\(index)",
                appBundlePath: nil,
                title: "A long document title that must not widen the compact rail",
                isFocused: index == 0,
            )))
        }
        let workspace = WorkspaceSidebarWorkspaceViewModel(
            name: "104",
            projectId: workspaceProjectDefaultId,
            displayName: "104",
            sidebarLabel: "",
            isGeneratedName: false,
            monitorScopeId: workspaceSidebarDefaultScopeId,
            monitorName: nil,
            isFocused: true,
            isVisible: true,
            items: items,
            apps: sidebarAppIconsTestApps(count: appCount),
        )
        return section(workspace: workspace, railWidth: railWidth, expandedWidth: expandedWidth, progress: progress)
    }

    private func section(
        workspace: WorkspaceSidebarWorkspaceViewModel,
        railWidth: CGFloat = 44,
        expandedWidth: CGFloat = 240,
        progress: CGFloat = 0.5,
    ) -> WorkspaceSidebarWorkspaceSection {
        var layout = WorkspaceSidebarConfiguration.empty
        layout.collapsedWidth = railWidth
        layout.dockIconSize = railWidth * 3 / 4
        layout.expandedWidth = expandedWidth
        layout.showAppIcons = true
        return WorkspaceSidebarWorkspaceSection(
            workspace: workspace,
            dragPreview: nil,
            expansionProgress: progress,
            layout: layout,
            emitsDropTarget: false,
            isFromOtherDisplay: false,
            isInUseOnOtherDisplay: false,
            isOnFocusedMonitor: true,
            allowsWorkspaceActivation: true,
            isPinnedActiveWorkspace: false,
            isActiveOnTargetMonitor: true,
            projectContextLabel: nil,
            projectContextColor: nil,
            renamingWorkspaceName: .constant(nil),
            renamingWorkspaceText: .constant(""),
            onBeginRenameWorkspace: {},
            onCommitRenameWorkspace: {},
            onCancelRenameWorkspace: {},
            selectedSearchTarget: nil,
            isSearchFiltering: false,
            activeInUseOverrideWorkspaceName: .constant(nil),
            pendingInUseOverrideAppId: .constant(nil),
            actions: .init(),
        )
    }
}
