@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WorkspaceSidebarAppIconsTest: XCTestCase {
    func testAppSummaryIncludesNestedTabLeavesAndFloatingWindows() {
        setUpWorkspacesForTests()
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let tabs = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tabGroup, index: INDEX_BIND_LAST)
        let nested = TilingContainer(parent: tabs, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST)
        TestWindow.new(id: 2, parent: nested)
        TestWindow.new(id: 3, parent: nested)
        TestWindow.new(id: 4, parent: tabs)
        TestWindow.new(id: 5, parent: workspace)
        TestWindow.new(id: 6, parent: workspace.macOsNativeHiddenAppsWindowsContainer)
        TestWindow.new(id: 7, parent: workspace.macOsNativeFullscreenWindowsContainer)
        let removed = TestWindow.new(id: 8, parent: root)
        removed.unbindFromParent()

        XCTAssertEqual(workspaceSidebarWindowsForAppSummary(workspace).map(\.windowId), [1, 2, 3, 4, 5])
        XCTAssertEqual(buildWorkspaceSidebarAppSummaries(for: workspace).count, 1, "Multiple windows from one app share an icon")
    }

    func testAppSummaryDeduplicatesIdentityAndSortsByName() {
        let browser = WorkspaceSidebarAppViewModel(name: "Zen", bundleId: "app.zen", bundlePath: "/Applications/Zen.app")
        let secondBrowser = WorkspaceSidebarAppViewModel(name: "Zen", bundleId: "app.zen", bundlePath: "/Other/Zen.app")
        let pathOnly = WorkspaceSidebarAppViewModel(name: "Editor", bundleId: nil, bundlePath: "/Applications/Editor.app")
        let unnamed = WorkspaceSidebarAppViewModel(name: "Unknown App", bundleId: nil, bundlePath: nil)
        let apps = uniqueWorkspaceSidebarApps([browser, pathOnly, secondBrowser, unnamed, pathOnly, unnamed])
        XCTAssertEqual(apps, [pathOnly, unnamed, browser])
    }

    func testNumericAndGeneratedWorkspaceIdentifiersAreNotTruncated() {
        XCTAssertEqual(workspaceSidebarAppSummaryIdentifier(sidebarAppIconsTestWorkspace(displayName: "12")), "12")
        XCTAssertEqual(workspaceSidebarAppSummaryIdentifier(sidebarAppIconsTestWorkspace(displayName: "104")), "104")
        XCTAssertEqual(workspaceSidebarAppSummaryIdentifier(sidebarAppIconsTestWorkspace(displayName: "Workspace 12", generated: true)), "12")
        XCTAssertEqual(workspaceSidebarAppSummaryIdentifier(sidebarAppIconsTestWorkspace(displayName: "Research", generated: true, label: "Research")), "R")
    }

    func testSearchKeepsCompleteAppSummaryWhenFilteringWindowRows() {
        var workspace = sidebarAppIconsTestWorkspace()
        workspace.apps = sidebarAppIconsTestApps(count: 5)
        let filtered = workspaceSidebarFilteredWorkspacesByProject(
            [workspaceProjectDefaultId: [workspace]],
            projects: [],
            query: "document",
        )
        XCTAssertEqual(filtered[workspaceProjectDefaultId]?.first?.apps, workspace.apps)
        XCTAssertEqual(filtered[workspaceProjectDefaultId]?.first?.items.count, 1)
    }

    func testDockSummaryKeepsAppOverflowAtEverySupportedWidth() {
        for width: CGFloat in [14, 30, 106] {
            for appCount in [0, 1, 3, 6, 104] {
                let layout = WorkspaceSidebarAppIconLayout(appCount: appCount, availableWidth: width)
                XCTAssertEqual(layout.visibleAppCount + layout.overflowCount, appCount)
                XCTAssertEqual(layout.visibleAppCount, min(appCount, 3))
                XCTAssertGreaterThan(layout.itemSize, 0)
                XCTAssertLessThanOrEqual(layout.itemSize, width, "Dock tiles must fit the configured rail")
            }
        }
    }

    func testAccessibilitySummaryIncludesAppsHiddenByOverflow() {
        var workspace = sidebarAppIconsTestWorkspace(displayName: "12")
        workspace.apps = sidebarAppIconsTestApps(count: 6)
        let label = workspaceSidebarAppSummaryLabel(workspace)
        XCTAssertTrue(label.hasPrefix("12, "))
        for app in workspace.apps { XCTAssertTrue(label.contains(app.name)) }
    }
}

func sidebarAppIconsTestApps(count: Int) -> [WorkspaceSidebarAppViewModel] {
    (0 ..< count).map { index in
        WorkspaceSidebarAppViewModel(name: "App \(index + 1)", bundleId: "test.app.\(index)", bundlePath: nil)
    }
}

func sidebarAppIconsTestWorkspace(
    displayName: String = "12",
    generated: Bool = false,
    label: String = "",
) -> WorkspaceSidebarWorkspaceViewModel {
    WorkspaceSidebarWorkspaceViewModel(
        name: "12",
        projectId: workspaceProjectDefaultId,
        displayName: displayName,
        sidebarLabel: label,
        isGeneratedName: generated,
        monitorScopeId: workspaceSidebarDefaultScopeId,
        monitorName: nil,
        isFocused: true,
        isVisible: true,
        items: [.init(kind: .window(.init(
            windowId: 1,
            workspaceName: "12",
            appName: "Editor",
            appBundleId: "test.editor",
            appBundlePath: nil,
            title: "A document",
            isFocused: true,
        )))],
    )
}
