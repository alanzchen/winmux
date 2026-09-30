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

    func testTheEdgeStopsAtTheModesMinimumWidth() {
        var tabs = WorkspaceSidebarConfig(mode: .tabs)
        XCTAssertEqual(workspaceSidebarResizeWidthBounds(tabs), 160...480)
        tabs.collapsedWidth = 170
        XCTAssertEqual(workspaceSidebarResizeWidthBounds(tabs), 171...480)
        XCTAssertEqual(workspaceSidebarResizeWidthBounds(WorkspaceSidebarConfig(mode: .sidebar)), 120...480)
        XCTAssertEqual(workspaceSidebarResizeWidthBounds(WorkspaceSidebarConfig(mode: .dock)), 120...480)
        XCTAssertEqual(workspaceSidebarResizedWidth(startWidth: 200, pointerDeltaX: -300, position: .left, paneCount: 1,
            bounds: workspaceSidebarResizeWidthBounds(WorkspaceSidebarConfig(mode: .tabs))), 160)
    }

    func testANarrowConfiguredTabsWidthIsWidenedWithoutRewritingTheFile() async throws {
        try await withAlwaysExpandedPanel(mode: .tabs) { panel in
            let disk = SidebarWidthTestDisk(width: 130, extra: "    width-per-display = false\n# Keep this comment\n")
            let original = disk.text
            workspaceSidebarWidthPersistenceForTests = disk.persistence
            config.workspaceSidebar = parseConfig(disk.text).config.workspaceSidebar
            WorkspaceSidebarPanel.refreshAll()
            XCTAssertEqual(config.workspaceSidebar.width, 160)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 160)
            XCTAssertEqual(mainMonitor.workspaceSidebarInset, 160, "Tiled windows make room for the wider panel")

            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            XCTAssertNil(panel.endSidebarResize(), "A click on the edge saves nothing")
            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            panel.updateSidebarResize(toScreenX: 300)
            XCTAssertEqual(config.workspaceSidebar.width, 160, "The edge stops at the minimum")
            XCTAssertNil(panel.endSidebarResize())
            XCTAssertEqual(disk.writes, [], "Loading, clicking and dragging past the minimum leave the file alone")
            XCTAssertEqual(disk.text, original)

            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            panel.updateSidebarResize(toScreenX: 540)
            await panel.endSidebarResize()?.value
            XCTAssertEqual(disk.writes.count, 1)
            XCTAssertEqual(disk.text, original.replacingOccurrences(of: "width = 130", with: "width = 200"),
                "A drag writes only the width it set")
            XCTAssertEqual(config.workspaceSidebar.width, 200)
        }
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
            for width in [360, 180, 320, 160, 480, 240] {
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

    func testHoverDuringPendingResizeDoesNotDoubleTheSidebarWidth() async throws {
        for (isHovering, width) in [(true, 300), (false, 300), (true, 180), (false, 180)] {
            try await withAlwaysExpandedPanel(mode: .tabs) { panel in
                XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
                workspaceSidebarLiveResizeRefresh.reset()
                // Occupy the leading refresh so the nested update waits in the throttle.
                workspaceSidebarLiveResizeRefresh.run {
                    panel.updateSidebarResize(toScreenX: 500 + CGFloat(width - 240))
                }
                XCTAssertEqual(config.workspaceSidebar.width, width)
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 240,
                    "The throttled panel refresh has not run yet")
                panel.menuTrackingDepth = 0
                panel.setHovering(isHovering)
                panel.menuTrackingDepth = 1
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, max(240, CGFloat(width)),
                    "Hover can apply the new width before the resize refresh")
                panel.endSidebarResize()
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, CGFloat(width),
                    "A wider single pane is not two-project browsing")
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, mainMonitor.workspaceSidebarInset,
                    "The sidebar must not cover the space occupied by the app window")
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

    func testResizingTwoProjectPanesKeepsTheirCombinedEdgeUnderThePointer() async throws {
        try await withAlwaysExpandedPanel(mode: .tabs) { panel in
            defer { panel.isBrowsingSecondProject = false }
            XCTAssertTrue(panel.updateProjectBrowsing(true, expandedWidth: 240, collapsedWidth: 80))
            panel.refresh(on: mainMonitor)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 480)
            XCTAssertTrue(panel.beginSidebarResize(atScreenX: 500))
            panel.updateSidebarResize(toScreenX: 620)
            panel.endSidebarResize()
            XCTAssertEqual(config.workspaceSidebar.width, 300, "The pointer delta is shared by the two panes")
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 600)
            XCTAssertEqual(mainMonitor.workspaceSidebarInset, 300, "The second project temporarily overlays the app")
            XCTAssertTrue(panel.updateProjectBrowsing(false, expandedWidth: 300, collapsedWidth: 80))
            panel.refresh(on: mainMonitor)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 300)
        }
    }

    func testClosingProjectBrowsingWhileCollapsedDoesNotReopenTheSecondPane() async throws {
        try await withAlwaysExpandedPanel(mode: .tabs) { panel in
            XCTAssertTrue(panel.updateProjectBrowsing(true, expandedWidth: 240, collapsedWidth: 80))
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 480)
            panel.viewModel.workspaceSidebarVisibleWidth = 80
            XCTAssertFalse(panel.updateProjectBrowsing(false, expandedWidth: 240, collapsedWidth: 80))
            XCTAssertEqual(panel.splitBrowseCollapseSuppressedUntil, .distantPast)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 80, "A navigation reset must not reopen a collapsed sidebar")
            panel.refresh(on: mainMonitor)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 240)
            panel.updateProjectBrowsing(true, expandedWidth: 240, collapsedWidth: 80)
            panel.clearHiddenSidebarContent()
            XCTAssertEqual(panel.splitBrowseCollapseSuppressedUntil, .distantPast)
            panel.refresh(on: mainMonitor)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 240, "Hidden panels drop transient browsing")
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

    func testDraggingOneDisplaysEdgeResizesOnlyThatDisplay() async throws {
        try await withTwoDisplays { left, right in
            var written: [String] = []
            workspaceSidebarWidthPersistenceForTests = fakePersistence(onWrite: { written.append($0) })
            XCTAssertTrue(right.beginSidebarResize(atScreenX: 2400))
            right.updateSidebarResize(toScreenX: 2460)
            XCTAssertEqual(config.workspaceSidebar.displayWidths, ["Right": 300])
            XCTAssertEqual(config.workspaceSidebar.width, 240, "Other displays keep the shared width")
            XCTAssertEqual(right.viewModel.workspaceSidebarVisibleWidth, 300)
            XCTAssertEqual(right.viewModel.workspaceSidebarAppearance.expandedWidth, 300)
            XCTAssertEqual(left.viewModel.workspaceSidebarVisibleWidth, 240)
            XCTAssertEqual(left.viewModel.workspaceSidebarAppearance.expandedWidth, 240)
            XCTAssertEqual(self.monitor(named: "Right").workspaceSidebarInset, 300)
            XCTAssertEqual(self.monitor(named: "Left").workspaceSidebarInset, 240)

            let save = try XCTUnwrap(right.endSidebarResize())
            await save.value
            XCTAssertEqual(written.count, 1)
            let saved = parseConfig(written[0])
            XCTAssertEqual(saved.errors.descriptions, [])
            XCTAssertEqual(saved.config.workspaceSidebar.displayWidths, ["Right": 300], written[0])
            XCTAssertEqual(saved.config.workspaceSidebar.width, 240, written[0])

            // The next drag on the other display starts from its own width.
            XCTAssertTrue(left.beginSidebarResize(atScreenX: 500))
            left.updateSidebarResize(toScreenX: 440)
            XCTAssertEqual(config.workspaceSidebar.displayWidths, ["Right": 300, "Left": 180])
            XCTAssertEqual(right.viewModel.workspaceSidebarVisibleWidth, 300)
            left.cancelSidebarResize()
            XCTAssertEqual(config.workspaceSidebar.displayWidths, ["Right": 300],
                "Cancelling leaves a display without its own width on the shared one")
        }
    }

    func testReturningToTheStartWidthGivesTheDisplayNoWidthOfItsOwn() async throws {
        try await withTwoDisplays { left, _ in
            var written: [String] = []
            workspaceSidebarWidthPersistenceForTests = fakePersistence(onWrite: { written.append($0) })
            XCTAssertTrue(left.beginSidebarResize(atScreenX: 500))
            left.updateSidebarResize(toScreenX: 500)
            XCTAssertEqual(config.workspaceSidebar.displayWidths, [:], "A click on the edge must not pin the shared width")
            left.updateSidebarResize(toScreenX: 560)
            XCTAssertEqual(config.workspaceSidebar.displayWidths, ["Left": 300])
            left.updateSidebarResize(toScreenX: 500)
            XCTAssertEqual(config.workspaceSidebar.displayWidths, [:], "Back at the start, it follows the shared width again")
            XCTAssertNil(left.endSidebarResize())
            XCTAssertEqual(written, [])
        }
    }

    func testDoubleClickingTheEdgePutsTheDisplayBackOnTheSharedWidth() async throws {
        try await withTwoDisplays { left, right in
            var written: [String] = []
            workspaceSidebarWidthPersistenceForTests = fakePersistence(onWrite: { written.append($0) },
                text: "[workspace-sidebar.display-widths]\n\"Left\" = 300\n\"Right\" = 320\n")
            config.workspaceSidebar.displayWidths = ["Left": 300, "Right": 320]
            WorkspaceSidebarPanel.refreshAll()
            XCTAssertEqual(left.viewModel.workspaceSidebarVisibleWidth, 300)

            let save = try XCTUnwrap(left.resetSidebarDisplayWidth())
            XCTAssertEqual(config.workspaceSidebar.displayWidths, ["Right": 320])
            XCTAssertEqual(left.viewModel.workspaceSidebarVisibleWidth, 240)
            XCTAssertEqual(right.viewModel.workspaceSidebarVisibleWidth, 320)
            await save.value
            XCTAssertEqual(written.count, 1)
            XCTAssertEqual(parseConfig(written[0]).config.workspaceSidebar.displayWidths, ["Right": 320], written[0])
            XCTAssertNil(left.resetSidebarDisplayWidth(), "A display already on the shared width has nothing to reset")

            config.workspaceSidebar.widthPerDisplay = false
            XCTAssertNil(right.resetSidebarDisplayWidth(), "With one shared width, double-clicking changes nothing")
            XCTAssertEqual(written.count, 1)
        }
    }

    func testTurningOffWidthPerDisplayMidDragCancelsTheDrag() async throws {
        try await withTwoDisplays { left, _ in
            XCTAssertTrue(left.beginSidebarResize(atScreenX: 500))
            left.updateSidebarResize(toScreenX: 560)
            XCTAssertEqual(config.workspaceSidebar.displayWidths, ["Left": 300])
            // A reload turned the setting off, so this edge now sets the shared width.
            config.workspaceSidebar.widthPerDisplay = false
            left.updateSidebarResize(toScreenX: 600)
            XCTAssertNil(left.sidebarResize)
            XCTAssertEqual(config.workspaceSidebar.displayWidths, [:])
            XCTAssertEqual(config.workspaceSidebar.width, 240)
        }
    }

    func testAFailedDisplayWidthSaveRemovesTheDraggedWidth() async throws {
        try await withTwoDisplays { left, _ in
            workspaceSidebarWidthPersistenceForTests = fakePersistence(onWrite: { _ in }, failsRead: true)
            let oldMessage = MessageModel.shared.message
            defer { MessageModel.shared.message = oldMessage }
            XCTAssertTrue(left.beginSidebarResize(atScreenX: 500))
            left.updateSidebarResize(toScreenX: 560)
            let save = try XCTUnwrap(left.endSidebarResize())
            XCTAssertEqual(config.workspaceSidebar.displayWidths, ["Left": 300])
            await save.value
            XCTAssertEqual(config.workspaceSidebar.displayWidths, [:])
            XCTAssertEqual(left.viewModel.workspaceSidebarVisibleWidth, 240)
            XCTAssertEqual(MessageModel.shared.message?.description, "Workspace Sidebar Error")
        }
    }

    func testDisplayWidthsSurviveTheSaveAndReload() async throws {
        try await withTwoDisplays { left, right in
            let disk = SidebarWidthTestDisk()
            workspaceSidebarWidthPersistenceForTests = disk.persistence
            XCTAssertTrue(right.beginSidebarResize(atScreenX: 2400))
            right.updateSidebarResize(toScreenX: 2460)
            await right.endSidebarResize()?.value
            XCTAssertEqual(disk.writes.count, 1)
            XCTAssertEqual(config.workspaceSidebar.displayWidths, ["Right": 300], "The reloaded file keeps the width")
            XCTAssertEqual(right.viewModel.workspaceSidebarVisibleWidth, 300)
            XCTAssertEqual(left.viewModel.workspaceSidebarVisibleWidth, 240)

            // Dragging a display that has its own width changes that width.
            XCTAssertTrue(right.beginSidebarResize(atScreenX: 2400))
            right.updateSidebarResize(toScreenX: 2340)
            await right.endSidebarResize()?.value
            XCTAssertEqual(config.workspaceSidebar.displayWidths, ["Right": 240],
                "Dragged to the shared width, the display still keeps a width of its own")
            XCTAssertEqual(disk.writes.count, 2)

            await right.resetSidebarDisplayWidth()?.value
            XCTAssertEqual(config.workspaceSidebar.displayWidths, [:])
            XCTAssertFalse(disk.text.contains("display-widths"), disk.text)
        }
    }

    func testDoubleClickingTheHandleResetsWithoutStartingADrag() async throws {
        try await withTwoDisplays { left, _ in
            let disk = SidebarWidthTestDisk(extra: "\n[workspace-sidebar.display-widths]\n\"Left\" = 300\n")
            workspaceSidebarWidthPersistenceForTests = disk.persistence
            config.workspaceSidebar.displayWidths = ["Left": 300]
            WorkspaceSidebarPanel.refreshAll()
            let handle = left.resizeHandleView
            func click(_ count: Int) throws -> (down: NSEvent, up: NSEvent) {
                let event = { (type: NSEvent.EventType) in
                    NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: left.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
                }
                return (try XCTUnwrap(event(.leftMouseDown)), try XCTUnwrap(event(.leftMouseUp)))
            }
            let first = try click(1)
            handle.mouseDown(with: first.down)
            XCTAssertNotNil(left.sidebarResize, "The first click starts a drag")
            handle.mouseUp(with: first.up)
            XCTAssertNil(left.sidebarResize)
            XCTAssertEqual(disk.writes.count, 0, "A click without moving saves nothing")

            let second = try click(2)
            handle.mouseDown(with: second.down)
            XCTAssertNil(left.sidebarResize, "The second click resets instead of dragging")
            XCTAssertEqual(config.workspaceSidebar.displayWidths, [:])
            XCTAssertEqual(left.viewModel.workspaceSidebarVisibleWidth, 240)
            handle.mouseUp(with: second.up)
            for _ in 0 ..< 50 where disk.writes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(disk.writes.count, 1)
            XCTAssertFalse(disk.text.contains("display-widths"), disk.text)
        }
    }

    func testAnInlineWidthTableIsNotSilentlyLeftBehind() async throws {
        try await withTwoDisplays { left, right in
            let disk = SidebarWidthTestDisk(extra: "    display-widths = { \"Left\" = 300 }\n")
            workspaceSidebarWidthPersistenceForTests = disk.persistence
            let oldMessage = MessageModel.shared.message
            defer { MessageModel.shared.message = oldMessage }
            config.workspaceSidebar.displayWidths = ["Left": 300]
            WorkspaceSidebarPanel.refreshAll()
            let original = disk.text

            await left.resetSidebarDisplayWidth()?.value
            XCTAssertEqual(config.workspaceSidebar.displayWidths, ["Left": 300],
                "A reset the file can't take puts the width back instead of reporting success")
            XCTAssertEqual(MessageModel.shared.message?.description, "Workspace Sidebar Error")

            MessageModel.shared.message = nil
            XCTAssertTrue(right.beginSidebarResize(atScreenX: 2400))
            right.updateSidebarResize(toScreenX: 2460)
            await right.endSidebarResize()?.value
            XCTAssertEqual(config.workspaceSidebar.displayWidths, ["Left": 300])
            XCTAssertEqual(MessageModel.shared.message?.description, "Workspace Sidebar Error")
            XCTAssertEqual(disk.text, original)
            XCTAssertEqual(disk.writes.count, 0)
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

    private func fakePersistence(onWrite: @escaping (String) -> Void, failsRead: Bool = false,
                                 text: String = "") -> SettingsPersistence {
        let url = URL(fileURLWithPath: "/tmp/winmux-sidebar-resize-test.toml")
        return SettingsPersistence(
            target: { url },
            read: { _ in
                if failsRead { throw SettingsEditError("unreadable") }
                return "[workspace-sidebar]\n    always-expanded = true\n    width = 240\n" + text
            },
            write: { _, text in onWrite(text) },
            reload: { _ in true },
        )
    }

    private func monitor(named name: String) -> Monitor {
        monitors.first { $0.name == name }!
    }

    /// A Tabs panel on each of two displays, which remember their own widths.
    private func withTwoDisplays(
        _ body: @MainActor (_ left: WorkspaceSidebarPanel, _ right: WorkspaceSidebarPanel) async throws -> Void,
    ) async throws {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: nil)
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: nil)
        setMonitorsForTests([left, right])
        defer { setMonitorsForTests(nil) }
        try await withAlwaysExpandedPanel(mode: .tabs, widthPerDisplay: true) { leftPanel in
            let rightPanel = try XCTUnwrap(WorkspaceSidebarPanel.panel(for: workspaceSidebarMonitorScopeId(for: right)))
            let trackingDepth = rightPanel.menuTrackingDepth
            rightPanel.menuTrackingDepth = 1
            defer {
                rightPanel.cancelSidebarResize()
                rightPanel.menuTrackingDepth = trackingDepth
            }
            XCTAssertEqual(leftPanel.sidebarDisplayName, "Left")
            XCTAssertEqual(rightPanel.sidebarDisplayName, "Right")
            try await body(leftPanel, rightPanel)
        }
    }

    /// Most tests drive the shared width; the per-display tests turn on `widthPerDisplay`.
    private func withAlwaysExpandedPanel(
        mode: WorkspaceSidebarMode = .sidebar,
        widthPerDisplay: Bool = false,
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
        config.workspaceSidebar.widthPerDisplay = widthPerDisplay
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

/// A config file that keeps what the sidebar writes and reloads it into the running config.
@MainActor
private final class SidebarWidthTestDisk {
    var text: String
    var writes: [String] = []

    init(width: Int = 240, extra: String = "") {
        text = "[workspace-sidebar]\n    enabled = true\n    mode = 'tabs'\n    always-expanded = true\n    width = \(width)\n" + extra
    }

    var persistence: SettingsPersistence {
        SettingsPersistence(
            target: { URL(fileURLWithPath: "/tmp/winmux-sidebar-width-disk-test.toml") },
            read: { [unowned self] _ in text },
            write: { [unowned self] _, text in
                self.text = text
                writes.append(text)
            },
            reload: { [unowned self] _ in
                let parsed = parseConfig(text)
                guard parsed.errors.isEmpty else { return false }
                config.workspaceSidebar = parsed.config.workspaceSidebar
                WorkspaceSidebarPanel.refreshAll()
                return true
            },
        )
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
