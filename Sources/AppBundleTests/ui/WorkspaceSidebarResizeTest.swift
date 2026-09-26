import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceSidebarResizeTest: XCTestCase {
    func testOnlyAlwaysExpandedSidePanelsCanBeResized() {
        var sidebar = WorkspaceSidebarConfig(mode: .sidebar)
        XCTAssertFalse(workspaceSidebarAllowsResize(sidebar), "A collapsible rail opens over windows")
        sidebar.alwaysExpanded = true
        XCTAssertTrue(workspaceSidebarAllowsResize(sidebar))

        var dock = WorkspaceSidebarConfig(mode: .dock)
        dock.alwaysExpanded = true
        for (position, allowed) in [(WorkspaceDockPosition.left, true), (.right, true), (.bottom, false)] {
            dock.dockPosition = position
            XCTAssertEqual(workspaceSidebarAllowsResize(dock), allowed, "\(position)")
        }
    }

    func testDraggedWidthFollowsTheInnerEdgeAndStaysWithinTheSettingRange() {
        let bounds = 120...480
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 240, pointerDeltaX: 37.4, position: .left, paneCount: 1, bounds: bounds), 277)
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 240, pointerDeltaX: 40, position: .right, paneCount: 1, bounds: bounds), 200,
            "A right-side panel widens as its inner edge moves left")
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 240, pointerDeltaX: 60, position: .left, paneCount: 2, bounds: bounds), 270,
            "Each of two browsed panes takes half the travel, keeping the edge under the pointer")
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 240, pointerDeltaX: -500, position: .left, paneCount: 1, bounds: bounds), 120)
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 240, pointerDeltaX: 900, position: .left, paneCount: 1, bounds: bounds), 480)
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 240, pointerDeltaX: .nan, position: .left, paneCount: 1, bounds: bounds), 240)
    }

    func testMinimumDraggedWidthStaysAboveCollapsedWidth() {
        var sidebar = WorkspaceSidebarConfig(mode: .sidebar)
        sidebar.alwaysExpanded = true
        XCTAssertEqual(workspaceSidebarResizeWidthBounds(sidebar), workspaceSidebarResizableWidthRange)
        sidebar.collapsedWidth = 120
        XCTAssertEqual(workspaceSidebarResizeWidthBounds(sidebar), 121...480,
            "always-expanded rejects a width equal to collapsed-width")
        let (_, errors) = parseConfig("""
            [workspace-sidebar]
            always-expanded = true
            collapsed-width = 120
            width = \(workspaceSidebarResizeWidthBounds(sidebar).lowerBound)
            """)
        XCTAssertEqual(errors.descriptions, [])
    }

    func testHandleSitsInsideThePanelAlongItsInnerEdge() {
        let surface = CGRect(x: 10, y: 20, width: 240, height: 700)
        XCTAssertEqual(workspaceSidebarResizeHandleFrame(surface: surface, position: .left),
            CGRect(x: 250 - workspaceSidebarResizeHandleWidth, y: 20, width: workspaceSidebarResizeHandleWidth, height: 700))
        XCTAssertEqual(workspaceSidebarResizeHandleFrame(surface: surface, position: .right),
            CGRect(x: 10, y: 20, width: workspaceSidebarResizeHandleWidth, height: 700))
        XCTAssertNil(workspaceSidebarResizeHandleFrame(surface: surface, position: .bottom))
        XCTAssertNil(workspaceSidebarResizeHandleFrame(surface: .zero, position: .left))
    }

    func testDraggingTheInnerEdgeResizesTheSidebarLive() async throws {
        try await withAlwaysExpandedPanel { panel in
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 240)
            XCTAssertFalse(panel.resizeHandleView.isHidden)
            XCTAssertEqual(panel.resizeHandleView.frame.width, workspaceSidebarResizeHandleWidth)

            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            XCTAssertFalse(panel.beginSidebarResize(atScreenX: 500), "One drag at a time")
            XCTAssertFalse(panel.ignoresMouseEvents, "The drag keeps the pointer while the edge catches up")
            panel.updateSidebarResize(toScreenX: 560)
            XCTAssertEqual(config.workspaceSidebar.width, 300)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 300)
            XCTAssertEqual(panel.viewModel.workspaceSidebarAppearance.expandedWidth, 300)
            XCTAssertEqual(mainMonitor.workspaceSidebarInset, 300, "Tiled windows make room for the new width")

            panel.updateSidebarResize(toScreenX: 0)
            XCTAssertEqual(config.workspaceSidebar.width, workspaceSidebarResizableWidthRange.lowerBound)
            panel.endSidebarResize()
            XCTAssertNil(panel.sidebarResize)
            panel.updateSidebarResize(toScreenX: 700)
            XCTAssertEqual(config.workspaceSidebar.width, workspaceSidebarResizableWidthRange.lowerBound,
                "Movement after the drag ends does not resize")
        }
    }

    func testTurningOffAlwaysExpandedCancelsTheDragAndHidesTheHandle() async throws {
        try await withAlwaysExpandedPanel { panel in
            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            panel.updateSidebarResize(toScreenX: 540)
            XCTAssertEqual(config.workspaceSidebar.width, 280)
            config.workspaceSidebar.alwaysExpanded = false
            panel.updateSidebarResize(toScreenX: 600)
            XCTAssertNil(panel.sidebarResize)
            XCTAssertEqual(config.workspaceSidebar.width, 240, "An invalidated drag puts the old width back")
            panel.refresh(on: mainMonitor)
            XCTAssertTrue(panel.resizeHandleView.isHidden)
            XCTAssertFalse(panel.beginSidebarResize(atScreenX: 500))
        }
    }

    func testTabsSidebarRenderedEdgeFollowsRepeatedWidthDrags() async throws {
        try await withAlwaysExpandedPanel(mode: .tabs) { panel in
            for width in [360, 180, 320, 120, 480, 240] {
                XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
                let startWidth = config.workspaceSidebar.width
                panel.updateSidebarResize(toScreenX: 500 + CGFloat(width - startWidth))
                panel.endSidebarResize()
                try await Task.sleep(for: .milliseconds(50))
                panel.hostingView.layoutSubtreeIfNeeded()
                XCTAssertEqual(config.workspaceSidebar.width, width)
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, CGFloat(width))
                XCTAssertEqual(panel.visibleSurfaceFrameInHostingView.width, CGFloat(width), accuracy: 0.5)
                XCTAssertEqual(panel.visibleSurfaceFrameOnScreen.maxX,
                    panel.frame.minX + mainMonitor.workspaceSidebarInset, accuracy: 0.5)
            }
        }
    }

    func testSidebarWidthDragDoesNotBecomeAWindowDrag() async throws {
        setUpWorkspacesForTests()
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let previousApp = appForTests
        defer { appForTests = previousApp }
        window.nativeFocus()
        for mode in WorkspaceSidebarMode.allCases {
            try await withAlwaysExpandedPanel(mode: mode) { panel in
                XCTAssertTrue(canHandleWindowMouseManipulation(window, mouseButtonDown: true))
                XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
                panel.updateSidebarResize(toScreenX: 560)
                XCTAssertFalse(canHandleWindowMouseManipulation(window, mouseButtonDown: true),
                    "Moving the focused window to make room must not start a competing move or resize gesture")
                let isWindowGesture = try await isManipulatedWithMouse(window, mouseButtonDown: { true })
                XCTAssertFalse(isWindowGesture, "Both AX observers must reject the focused window's layout-driven movement")
                panel.endSidebarResize()
                XCTAssertTrue(canHandleWindowMouseManipulation(window, mouseButtonDown: true),
                    "A subsequent real window drag must still work")
                XCTAssertFalse(canHandleWindowMouseManipulation(window, mouseButtonDown: false))
                XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
                panel.cancelSidebarResize()
                XCTAssertTrue(canHandleWindowMouseManipulation(window, mouseButtonDown: true),
                    "Cancelling also releases the sidebar's mouse ownership")
            }
        }
    }

    func testWindowGestureEligibilityIsRecheckedAfterNativeFocusRead() async throws {
        setUpWorkspacesForTests()
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let previousApp = appForTests
        defer { appForTests = previousApp }
        try await withAlwaysExpandedPanel(mode: .tabs) { panel in
            var focusReads = 0
            appForTests = SidebarResizeFocusTestApp {
                focusReads += 1
                await Task.yield()
                XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
                return window
            }
            let windowGestureAfterSidebarBegan = try await isManipulatedWithMouse(window, mouseButtonDown: { true })
            XCTAssertFalse(windowGestureAfterSidebarBegan, "A sidebar drag can start while the native focus query is suspended")
            XCTAssertEqual(focusReads, 1)
            let duringSidebarDrag = try await isManipulatedWithMouse(window, mouseButtonDown: { true })
            XCTAssertFalse(duringSidebarDrag)
            XCTAssertEqual(focusReads, 1, "Layout-driven notifications must not query focus during the drag")
            panel.endSidebarResize()

            var mouseDown = true
            appForTests = SidebarResizeFocusTestApp {
                await Task.yield()
                mouseDown = false
                return window
            }
            let windowGestureAfterMouseUp = try await isManipulatedWithMouse(window, mouseButtonDown: { mouseDown })
            XCTAssertFalse(windowGestureAfterMouseUp, "A mouse-up during the native focus query must not start a stale gesture")

            window.nativeFocus()
            let nextWindowDrag = try await isManipulatedWithMouse(window, mouseButtonDown: { true })
            XCTAssertTrue(nextWindowDrag, "The next real window drag remains available")
        }
    }

    func testHidingThePanelMidDragDiscardsTheDrag() async throws {
        try await withAlwaysExpandedPanel { panel in
            var saves = 0
            workspaceSidebarWidthPersistenceForTests = fakePersistence(onWrite: { _ in saves += 1 })
            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            panel.updateSidebarResize(toScreenX: 560)
            panel.hideSidebar(.systemChrome, animated: false)
            XCTAssertNil(panel.sidebarResize)
            XCTAssertEqual(panel.autoHideReason, .systemChrome, "Cancelling must not reveal the panel it is hiding")
            XCTAssertEqual(config.workspaceSidebar.width, 240)
            XCTAssertEqual(saves, 0, "Fullscreen suppression mid-drag saves nothing")
        }
    }

    func testCancellingAfterReturningToTheStartWidthStillRefreshes() async throws {
        try await withAlwaysExpandedPanel { panel in
            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            panel.updateSidebarResize(toScreenX: 560)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 300)
            // Within the throttle interval, so this width only waits in the throttle.
            panel.updateSidebarResize(toScreenX: 500)
            panel.cancelSidebarResize()
            XCTAssertEqual(config.workspaceSidebar.width, 240)
            // The deferred refresh runs on the next turn of the main queue.
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 240, "The panel must not stay at the dropped width")
        }
    }

    func testAReloadDuringTheDragIsNotOverwrittenByCancelling() async throws {
        try await withAlwaysExpandedPanel { panel in
            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            panel.updateSidebarResize(toScreenX: 560)
            // Another editor saved a new width, and the reload replaced the drag's.
            config.workspaceSidebar.width = 333
            panel.cancelSidebarResize()
            XCTAssertEqual(config.workspaceSidebar.width, 333)
        }
    }

    func testReleasingSavesOnceThroughTheSettingsPath() async throws {
        try await withAlwaysExpandedPanel { panel in
            var written: [String] = []
            workspaceSidebarWidthPersistenceForTests = fakePersistence(onWrite: { written.append($0) })
            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            panel.updateSidebarResize(toScreenX: 530)
            panel.updateSidebarResize(toScreenX: 560)
            let save = try XCTUnwrap(panel.endSidebarResize())
            await save.value
            XCTAssertEqual(written.count, 1, "Only the release writes, never each step")
            XCTAssertTrue(written[0].contains("width = 300"), written[0])
            XCTAssertNil(panel.endSidebarResize(), "A second release has nothing to save")
            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            XCTAssertNil(panel.endSidebarResize(), "A click on the edge without moving saves nothing")
            XCTAssertEqual(written.count, 1)
        }
    }

    func testAFailedSavePutsTheOldWidthBack() async throws {
        try await withAlwaysExpandedPanel { panel in
            workspaceSidebarWidthPersistenceForTests = fakePersistence(onWrite: { _ in }, failsRead: true)
            let oldMessage = MessageModel.shared.message
            defer { MessageModel.shared.message = oldMessage }
            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            panel.updateSidebarResize(toScreenX: 560)
            let save = try XCTUnwrap(panel.endSidebarResize())
            XCTAssertEqual(config.workspaceSidebar.width, 300)
            await save.value
            XCTAssertEqual(config.workspaceSidebar.width, 240)
            XCTAssertEqual(MessageModel.shared.message?.description, "Workspace Sidebar Error")
        }
    }

    func testThrottledRefreshesFinishWithTheLatestWidth() {
        let throttle = WorkspaceSidebarThrottle(interval: 60)
        var runs: [Int] = []
        throttle.run { runs.append(1) }
        throttle.run { runs.append(2) }
        throttle.run { runs.append(3) }
        XCTAssertEqual(runs, [1], "Requests inside the interval wait")
        throttle.flush()
        XCTAssertEqual(runs, [1, 3], "Only the latest waiting request runs")
        throttle.flush()
        XCTAssertEqual(runs, [1, 3])
        throttle.run { runs.append(4) }
        throttle.reset()
        throttle.run { runs.append(5) }
        XCTAssertEqual(runs, [1, 3, 5], "Reset drops waiting work and runs the next request at once")
    }

    private func fakePersistence(onWrite: @escaping (String) -> Void, failsRead: Bool = false) -> SettingsPersistence {
        let url = URL(fileURLWithPath: "/tmp/winmux-sidebar-resize-test.toml")
        return SettingsPersistence(
            target: { url },
            read: { _ in
                if failsRead { throw SettingsEditError("unreadable") }
                return "[workspace-sidebar]\n    always-expanded = true\n    width = 240\n"
            },
            write: { _, text in onWrite(text) },
            reload: { _ in true },
        )
    }

    private func withAlwaysExpandedPanel(
        mode: WorkspaceSidebarMode = .sidebar,
        _ body: @MainActor (WorkspaceSidebarPanel) async throws -> Void,
    ) async throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let oldConfig = config
        let wasEnabled = TrayMenuModel.shared.isEnabled
        config.workspaceSidebar = WorkspaceSidebarConfig(mode: mode)
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.alwaysExpanded = true
        config.workspaceSidebar.dockPosition = .left
        config.workspaceSidebar.width = 240
        TrayMenuModel.shared.isEnabled = true
        // An earlier drag in this process must not defer the first live update.
        workspaceSidebarLiveResizeRefresh.reset()
        // Live resizing refreshes every display's panel, so drive the one refreshAll owns.
        WorkspaceSidebarPanel.refreshAll()
        let panel = try XCTUnwrap(WorkspaceSidebarPanel.panel(for: workspaceSidebarMonitorScopeId(for: mainMonitor)))
        let trackingDepth = panel.menuTrackingDepth
        // Native global pointer location must not drive these controlled transitions.
        panel.menuTrackingDepth = 1
        defer {
            panel.cancelSidebarResize()
            workspaceSidebarWidthPersistenceForTests = nil
            panel.menuTrackingDepth = trackingDepth
            TrayMenuModel.shared.isEnabled = wasEnabled
            config = oldConfig
            WorkspaceSidebarPanel.refreshAll()
        }
        panel.visibleSurfaceFrame = CGRect(x: 0, y: 0, width: 240, height: panel.hostingView.bounds.height)
        panel.updateResizeHandle()
        try await body(panel)
    }
}

private final class SidebarResizeFocusTestApp: AbstractApp {
    let pid: Int32 = 987655
    let rawAppBundleId: String? = "dev.winmux.sidebar-resize-test"
    let name: String? = "Sidebar resize test"
    let execPath: String? = nil
    let bundlePath: String? = nil
    private let onFocusRead: @MainActor () async -> Window?

    init(_ onFocusRead: @escaping @MainActor () async -> Window?) { self.onFocusRead = onFocusRead }

    @MainActor
    func getFocusedWindow() async throws -> Window? { await onFocusRead() }
}
