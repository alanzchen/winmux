@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class WorkspaceSidebarAppActionsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws { setMonitorsForTests(nil) }

    private var appId: String { "bundle:bobko.WinMux.test-app" }

    func testCurrentMatchingWindowWinsOverAnotherMostRecentChild() {
        let workspace = focus.workspace
        let current = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let other = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        XCTAssertTrue(current.focusWindow())
        other.markAsMostRecentChild()

        XCTAssertTrue(workspaceSidebarAppWindow(in: workspace, appId: appId) === current)
    }

    func testMostRecentAppWindowIncludesNestedTabLeavesAndFloatingWindows() {
        let workspace = Workspace.get(byName: "target")
        let tabs = TilingContainer(parent: workspace.rootTilingContainer, adaptiveWeight: 1, .h, .tabGroup, index: INDEX_BIND_LAST)
        let nested = TilingContainer(parent: tabs, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST)
        let first = TestWindow.new(id: 1, parent: nested)
        let second = TestWindow.new(id: 2, parent: nested)
        TestWindow.new(id: 3, parent: tabs)
        let floating = TestWindow.new(id: 4, parent: workspace)

        first.markAsMostRecentChild()
        XCTAssertTrue(workspaceSidebarAppWindow(in: workspace, appId: appId) === first)
        floating.markAsMostRecentChild()
        XCTAssertTrue(workspaceSidebarAppWindow(in: workspace, appId: appId) === floating)
        second.markAsMostRecentChild()
        XCTAssertTrue(workspaceSidebarAppWindow(in: workspace, appId: appId) === second)
        XCTAssertEqual(focus.workspace.name, "setUpWorkspacesForTests", "Resolving a target must not focus it")
    }

    func testAppIdentityMatchesBundleThenPathThenName() {
        let workspace = Workspace.get(byName: "target")
        let apps = [
            SidebarSelectionTestApp(pid: 101, name: "Same name", bundleId: "test.one", bundlePath: "/Apps/One.app"),
            SidebarSelectionTestApp(pid: 102, name: "Same name", bundleId: "test.two", bundlePath: "/Apps/Two.app"),
            SidebarSelectionTestApp(pid: 103, name: "Path app", bundleId: nil, bundlePath: "/Apps/Path.app"),
            SidebarSelectionTestApp(pid: 104, name: "Name app", bundleId: nil, bundlePath: nil),
        ]
        let windows = apps.enumerated().map { index, app in
            Window(id: UInt32(index + 1), app, lastFloatingSize: nil, parent: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        }
        for (index, identity) in ["bundle:test.one", "bundle:test.two", "path:/Apps/Path.app", "name:Name app"].enumerated() {
            XCTAssertTrue(workspaceSidebarAppWindow(in: workspace, appId: identity) === windows[index])
        }
        XCTAssertNil(workspaceSidebarAppWindow(in: workspace, appId: "name:Same name"))
        XCTAssertNil(workspaceSidebarAppWindow(in: workspace, appId: "path:/Apps/One.app"))
    }

    func testUnavailableWindowsNeverBecomeAppClickTargets() {
        let workspace = Workspace.get(byName: "target")
        TestWindow.new(id: 1, parent: workspace.macOsNativeHiddenAppsWindowsContainer)
        TestWindow.new(id: 2, parent: workspace.macOsNativeFullscreenWindowsContainer)
        let popup = TestWindow.new(id: 3, parent: macosPopupWindowsContainer)
        defer { popup.unbindFromParent() }
        TestWindow.new(id: 4, parent: macosMinimizedWindowsContainer)
        let closed = TestWindow.new(id: 5, parent: workspace.rootTilingContainer)
        closed.unbindFromParent()
        let transitioning = TestWindow.new(id: 6, parent: workspace.rootTilingContainer)
        transitioning.recordObservedNativeState(fullscreen: false, minimized: true, token: transitioning.nativeStateObservationToken())
        XCTAssertNil(workspaceSidebarAppWindow(in: workspace, appId: appId))
        transitioning.recordObservedNativeState(fullscreen: true, minimized: false, token: transitioning.nativeStateObservationToken())
        XCTAssertNil(workspaceSidebarAppWindow(in: workspace, appId: appId))
    }

    func testMovedWindowAndMissingWorkspaceAreNoOps() {
        let target = Workspace.get(byName: "target")
        let moved = TestWindow.new(id: 1, parent: target.rootTilingContainer)
        let destination = Workspace.get(byName: "destination")
        moved.bind(to: destination.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let previousFocus = focus.workspace

        XCTAssertNil(selectWorkspaceSidebarAppWindow(workspaceName: target.name, appId: appId))
        XCTAssertNil(selectWorkspaceSidebarAppWindow(workspaceName: "missing", appId: appId))
        XCTAssertNil(Workspace.existing(byName: "missing"))
        XCTAssertEqual(focus.workspace, previousFocus)
        XCTAssertEqual(moved.nodeWorkspace, destination)
    }

    func testOccupiedWorkspaceRequiresExplicitOverrideAndThenFocusesClickedApp() {
        let (main, secondary, mainWorkspace, otherWorkspace) = twoDisplayScenario()
        let target = TestWindow.new(id: 1, parent: otherWorkspace.rootTilingContainer)
        let scope = workspaceSidebarMonitorScopeId(for: main)

        XCTAssertNil(selectWorkspaceSidebarAppWindow(workspaceName: otherWorkspace.name, appId: appId, targetMonitorScopeId: scope))
        XCTAssertEqual(main.activeWorkspace, mainWorkspace)
        XCTAssertEqual(secondary.activeWorkspace, otherWorkspace)
        XCTAssertEqual(focus.workspace, mainWorkspace)

        XCTAssertTrue(selectWorkspaceSidebarAppWindow(
            workspaceName: otherWorkspace.name,
            appId: appId,
            targetMonitorScopeId: scope,
            overrideWorkspaceInUse: true,
        ) === target)
        XCTAssertEqual(main.activeWorkspace, otherWorkspace)
        XCTAssertNotEqual(secondary.activeWorkspace, otherWorkspace)
        XCTAssertTrue(focus.windowOrNil === target)
        XCTAssertEqual(focus.workspace, otherWorkspace)
    }

    func testHiddenWorkspaceOpensOnClickedPanelMonitor() {
        let (main, secondary, mainWorkspace, _) = twoDisplayScenario()
        let hidden = Workspace.get(byName: "hidden")
        let target = TestWindow.new(id: 1, parent: hidden.rootTilingContainer)

        XCTAssertTrue(selectWorkspaceSidebarAppWindow(
            workspaceName: hidden.name,
            appId: appId,
            targetMonitorScopeId: workspaceSidebarMonitorScopeId(for: secondary),
        ) === target)
        XCTAssertEqual(main.activeWorkspace, mainWorkspace)
        XCTAssertEqual(secondary.activeWorkspace, hidden)
        XCTAssertTrue(focus.windowOrNil === target)
    }

    func testUnavailableAppDoesNotMoveWorkspaceEvenAfterOverrideWasRequested() {
        let (main, secondary, mainWorkspace, otherWorkspace) = twoDisplayScenario()
        let closed = TestWindow.new(id: 1, parent: otherWorkspace.rootTilingContainer)
        closed.unbindFromParent()

        XCTAssertNil(selectWorkspaceSidebarAppWindow(
            workspaceName: otherWorkspace.name,
            appId: appId,
            targetMonitorScopeId: workspaceSidebarMonitorScopeId(for: main),
            overrideWorkspaceInUse: true,
        ))
        XCTAssertEqual(main.activeWorkspace, mainWorkspace)
        XCTAssertEqual(secondary.activeWorkspace, otherWorkspace)
        XCTAssertEqual(focus.workspace, mainWorkspace)
    }

    func testDisconnectedPanelAndForcedMonitorAssignmentRejectAppClicks() {
        let (main, secondary, mainWorkspace, otherWorkspace) = twoDisplayScenario()
        TestWindow.new(id: 1, parent: otherWorkspace.rootTilingContainer)
        config.workspaceToMonitorForceAssignment[otherWorkspace.name] = [.sequenceNumber(2)]
        for overrideWorkspace in [false, true] {
            for scope in [workspaceSidebarMonitorScopeId(for: main), "monitor:3840.0,0.0"] {
                XCTAssertNil(selectWorkspaceSidebarAppWindow(
                    workspaceName: otherWorkspace.name,
                    appId: appId,
                    targetMonitorScopeId: scope,
                    overrideWorkspaceInUse: overrideWorkspace,
                ))
                XCTAssertEqual(main.activeWorkspace, mainWorkspace)
                XCTAssertEqual(secondary.activeWorkspace, otherWorkspace)
                XCTAssertEqual(focus.workspace, mainWorkspace)
            }
        }
    }

    func testExplicitAppClickPerformsNativeFocusWhenLogicalFocusAlreadyMatches() throws {
        let workspace = focus.workspace
        let target = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertTrue(target.focusWindow())
        XCTAssertNil(TestApp.shared.focusedWindow)
        let selected = try XCTUnwrap(selectWorkspaceSidebarAppWindow(workspaceName: workspace.name, appId: appId))

        raiseWorkspaceSidebarAppWindow(selected)

        XCTAssertTrue(focus.windowOrNil === target)
        XCTAssertTrue(TestApp.shared.focusedWindow === target)
    }

    func testSidebarAfterLayoutRunsAfterOrdinaryNativeFocusSynchronization() async throws {
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
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let otherWorkspace = Workspace.get(byName: "clicked")
        let target = TestWindow.new(id: 2, parent: otherWorkspace.rootTilingContainer)
        XCTAssertTrue(first.focusWindow())
        first.nativeFocus()
        var selected: Window?
        var stages: [String] = []

        let task = try XCTUnwrap(runWorkspaceSidebarSession(afterLayout: {
            stages.append("after-layout")
            XCTAssertTrue(focus.windowOrNil === target)
            XCTAssertTrue(TestApp.shared.focusedWindow === target, "The ordinary session focus must finish before an explicit raise is queued")
            if let selected {
                raiseWorkspaceSidebarAppWindow(selected, expectedWorkspaceName: otherWorkspace.name)
            }
        }) {
            stages.append("body")
            selected = selectWorkspaceSidebarAppWindow(workspaceName: otherWorkspace.name, appId: self.appId)
            XCTAssertTrue(selected === target)
            XCTAssertTrue(TestApp.shared.focusedWindow === first, "Logical selection should leave native focus to the session and final raise")
        })
        await task.value

        XCTAssertEqual(stages, ["body", "after-layout"])
        XCTAssertTrue(TestApp.shared.focusedWindow === target)
    }

    func testFinalRaiseDoesNotOverrideNewFocusOrClosedWindow() {
        let workspace = focus.workspace
        let clicked = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let newer = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        XCTAssertTrue(clicked.focusWindow())
        XCTAssertTrue(newer.focusWindow())

        raiseWorkspaceSidebarAppWindow(clicked, expectedWorkspaceName: workspace.name)
        XCTAssertNil(TestApp.shared.focusedWindow)

        XCTAssertTrue(clicked.focusWindow())
        clicked.unbindFromParent()
        raiseWorkspaceSidebarAppWindow(clicked, expectedWorkspaceName: workspace.name)
        XCTAssertNil(TestApp.shared.focusedWindow)
    }

    func testFinalRaiseRechecksNativeEligibilityVisibilityAndOriginalWorkspace() {
        let original = focus.workspace
        let clicked = TestWindow.new(id: 1, parent: original.rootTilingContainer)
        XCTAssertTrue(clicked.focusWindow())
        clicked.recordObservedNativeState(fullscreen: false, minimized: true, token: clicked.nativeStateObservationToken())
        raiseWorkspaceSidebarAppWindow(clicked, expectedWorkspaceName: original.name)
        XCTAssertNil(TestApp.shared.focusedWindow)
        clicked.recordObservedNativeState(fullscreen: true, minimized: false, token: clicked.nativeStateObservationToken())
        raiseWorkspaceSidebarAppWindow(clicked, expectedWorkspaceName: original.name)
        XCTAssertNil(TestApp.shared.focusedWindow)
        clicked.recordObservedNativeState(fullscreen: false, minimized: false, token: clicked.nativeStateObservationToken())

        let destination = Workspace.get(byName: "destination")
        XCTAssertTrue(mainMonitor.setActiveWorkspace(destination))
        raiseWorkspaceSidebarAppWindow(clicked, expectedWorkspaceName: original.name)
        XCTAssertNil(TestApp.shared.focusedWindow, "A hidden workspace must not receive a delayed raise")

        clicked.bind(to: destination.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertTrue(clicked.focusWindow())
        raiseWorkspaceSidebarAppWindow(clicked, expectedWorkspaceName: original.name)
        XCTAssertNil(TestApp.shared.focusedWindow, "Moving the window invalidates the original click request")
    }

    private func twoDisplayScenario() -> (TestMonitor, TestMonitor, Workspace, Workspace) {
        let mainRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let otherRect = Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080)
        let main = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Main", rect: mainRect, visibleRect: mainRect, isMain: true)
        let secondary = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Secondary", rect: otherRect, visibleRect: otherRect, isMain: false)
        setMonitorsForTests([main, secondary])
        let mainWorkspace = Workspace.get(byName: "main")
        let otherWorkspace = Workspace.get(byName: "secondary")
        XCTAssertTrue(main.setActiveWorkspace(mainWorkspace))
        XCTAssertTrue(secondary.setActiveWorkspace(otherWorkspace))
        XCTAssertTrue(mainWorkspace.focusWorkspace())
        return (main, secondary, mainWorkspace, otherWorkspace)
    }
}

private final class SidebarSelectionTestApp: AbstractApp {
    let pid: Int32
    let name: String?
    let rawAppBundleId: String?
    let bundlePath: String?
    let execPath: String? = nil

    init(pid: Int32, name: String, bundleId: String?, bundlePath: String?) {
        self.pid = pid
        self.name = name
        self.rawAppBundleId = bundleId
        self.bundlePath = bundlePath
    }

    @MainActor func getFocusedWindow() -> Window? { nil }
}
