@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class PostDragFrameCacheTest: XCTestCase {
    /// An app minimum keeps the window wider than its tile. Re-sending the unchanged tile doesn't
    /// move it, so no event would re-warm a dropped cache.
    func testRelayoutToTheSameFrameKeepsCachedRectOfClampedWindow() async throws {
        setUpWorkspacesForTests()
        cancelManipulatedWithMouseState()
        let workspace = Workspace.get(byName: "post-drag")
        let left = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let right = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        for window in [left, right] {
            window.recordsFrameOnSetAxFrame = false
        }

        try await workspace.layoutWorkspace()
        let tileRect = try XCTUnwrap(left.lastAppliedLayoutPhysicalRect)
        let clampedRect = Rect(
            topLeftX: tileRect.topLeftX,
            topLeftY: tileRect.topLeftY,
            width: tileRect.width + 120,
            height: tileRect.height,
        )
        left.recordAuthoritativeActualRect(clampedRect)
        let setAxFrameCount = left.setAxFrameCount
        try await workspace.layoutWorkspace()

        // With no refresh session event, layout re-sends every tile instead of reusing it.
        XCTAssertEqual(left.setAxFrameCount, setAxFrameCount + 1)
        XCTAssertEqual(left.lastKnownActualRect, clampedRect)
    }

    /// The next resize must preview the passive window at its new tile, not at the frame it
    /// had before the previous resize.
    func testResizePreviewFollowsRelayoutAfterPreviousResize() async throws {
        setUpWorkspacesForTests()
        cancelManipulatedWithMouseState()
        let workspace = Workspace.get(byName: "post-drag")
        let root = workspace.rootTilingContainer
        root.changeOrientation(.h)
        root.layout = .tiles
        let left = TestWindow.new(id: 1, parent: root)
        let right = TestWindow.new(id: 2, parent: root)
        for window in [left, right] {
            window.recordsFrameOnSetAxFrame = false
        }

        try await workspace.layoutWorkspace()
        _ = try await right.getAxRect()
        let leftRect = try XCTUnwrap(left.lastAppliedLayoutPhysicalRect)
        let draggedRect = Rect(
            topLeftX: leftRect.topLeftX,
            topLeftY: leftRect.topLeftY,
            width: leftRect.width + 200,
            height: leftRect.height,
        )
        // Resize calibration observed the frame the user dragged the window to.
        left.recordAuthoritativeActualRect(draggedRect)
        let session = WindowMouseInteractionDriver.ResizeSession(windowId: left.windowId)
        WindowMouseInteractionDriver.shared.resizeSession = session
        applyResizeWithMouse(left, rect: draggedRect)
        WindowMouseInteractionDriver.shared.finishResizeFlush(session: session)
        XCTAssertNil(left.lastKnownActualRect)
        cancelManipulatedWithMouseState()
        try await workspace.layoutWorkspace()

        XCTAssertNil(left.lastKnownActualRect)
        XCTAssertNil(right.lastKnownActualRect)

        let newLeftRect = try XCTUnwrap(left.lastAppliedLayoutPhysicalRect)
        let newRightRect = try XCTUnwrap(right.lastAppliedLayoutPhysicalRect)
        let resizeDelta: CGFloat = 40
        let proposedLeftRect = Rect(
            topLeftX: newLeftRect.topLeftX,
            topLeftY: newLeftRect.topLeftY,
            width: newLeftRect.width - resizeDelta,
            height: newLeftRect.height,
        )
        let weightMap = try XCTUnwrap(proposedResizeWeightMap(left, rect: proposedLeftRect))
        let items = windowResizePreviewItems(
            in: workspace,
            weightMap: weightMap,
            excludingActiveWindowId: left.windowId,
        )

        let expectedFrame = Rect(
            topLeftX: newRightRect.topLeftX - resizeDelta,
            topLeftY: newRightRect.topLeftY,
            width: newRightRect.width + resizeDelta,
            height: newRightRect.height,
        ).toAppKitScreenRect.alignedToBackingPixels()
        XCTAssertEqual(items.map(\.frame), [expectedFrame])
        cancelManipulatedWithMouseState()
    }

    /// A drag that ends without applying (cancelled, or dropped on its own tile) leaves a tiled
    /// window where layout reasserts it, not where the user left it. A floating window stays.
    func testEndedDragDropsTiledWindowFrameButKeepsFloatingOne() {
        setUpWorkspacesForTests()
        cancelManipulatedWithMouseState()
        let workspace = Workspace.get(byName: "post-drag")
        let tiled = TestWindow.new(
            id: 1,
            parent: workspace.rootTilingContainer,
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 480),
        )
        let floatingRect = Rect(topLeftX: 200, topLeftY: 150, width: 400, height: 300)
        let floating = TestWindow.new(id: 2, parent: workspace, rect: floatingRect)
        let driver = WindowMouseInteractionDriver.shared

        driver.moveSession = .init(windowId: floating.windowId, subject: .window, detachOrigin: .window, startedInSidebar: false)
        cancelManipulatedWithMouseState()
        XCTAssertEqual(floating.lastKnownActualRect, floatingRect)

        driver.moveSession = .init(windowId: tiled.windowId, subject: .group, detachOrigin: .window, startedInSidebar: false)
        cancelManipulatedWithMouseState()
        XCTAssertNil(driver.moveSession)
        XCTAssertNil(tiled.lastKnownActualRect)

        tiled.recordAuthoritativeActualRect(Rect(topLeftX: 40, topLeftY: 0, width: 600, height: 480))
        driver.resizeSession = .init(windowId: tiled.windowId)
        cancelManipulatedWithMouseState()
        XCTAssertNil(driver.resizeSession)
        XCTAssertNil(tiled.lastKnownActualRect)
    }

    /// Frame snapshots are drag state. A keyboard or CLI tab stack mustn't leave them behind,
    /// or they stand in for frames that layout later drops.
    func testTabStackLeavesNoDragFrameSnapshots() {
        setUpWorkspacesForTests()
        cancelManipulatedWithMouseState()
        let workspace = Workspace.get(byName: "post-drag")
        let root = workspace.rootTilingContainer
        let target = TestWindow.new(id: 1, parent: root, rect: Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 400))
        let source = TestWindow.new(id: 2, parent: root, rect: Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 400))
        for window in [target, source] {
            window.recordsFrameOnSetAxFrame = false
        }
        target.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 400)

        createOrAppendWindowTabStack(sourceWindow: source, onto: target)

        XCTAssertTrue(windowDragActualRectCache.isEmpty)
        XCTAssertEqual(source.lastKnownActualRect, source.lastAppliedLayoutPhysicalRect)
    }

    /// A tab group sat above another window until a drop moved that window to its right.
    /// The drop's relayout must not leave the tab's pre-drop frame (top half, full width)
    /// cached, or the next resize previews the tab group from it. Flipping the root stands in
    /// for the drop's rebind: only the resulting geometry matters here.
    func testTabGroupResizePreviewFollowsRelayoutAfterDrop() async throws {
        setUpWorkspacesForTests()
        cancelManipulatedWithMouseState()
        let workspace = Workspace.get(byName: "post-drag")
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        root.layout = .tiles
        let tabGroup = TilingContainer(parent: root, adaptiveWeight: WEIGHT_AUTO, .h, .tabGroup, index: INDEX_BIND_LAST)
        let tabs = (1 ... 4).map { TestWindow.new(id: UInt32($0), parent: tabGroup) }
        let activeTab = tabs[2]
        let side = TestWindow.new(id: 5, parent: root)
        for window in tabs + [side] {
            window.recordsFrameOnSetAxFrame = false
        }
        activeTab.markAsMostRecentChild()

        try await workspace.layoutWorkspace()
        // The drag-start refresh observes the frames before the drop.
        let preDropRect = try await activeTab.getAxRect()
        XCTAssertEqual(preDropRect, activeTab.lastAppliedLayoutPhysicalRect)

        root.changeOrientation(.h)
        try await workspace.layoutWorkspace()
        XCTAssertNil(activeTab.lastKnownActualRect)

        let tabRect = try XCTUnwrap(activeTab.lastAppliedLayoutPhysicalRect)
        let sideRect = try XCTUnwrap(side.lastAppliedLayoutPhysicalRect)
        let resizeDelta: CGFloat = 28
        let proposedSideRect = Rect(
            topLeftX: sideRect.topLeftX + resizeDelta,
            topLeftY: sideRect.topLeftY,
            width: sideRect.width - resizeDelta,
            height: sideRect.height,
        )
        let weightMap = try XCTUnwrap(proposedResizeWeightMap(side, rect: proposedSideRect))
        let items = windowResizePreviewItems(
            in: workspace,
            weightMap: weightMap,
            excludingActiveWindowId: side.windowId,
        )

        let expectedFrame = Rect(
            topLeftX: tabRect.topLeftX,
            topLeftY: tabRect.topLeftY,
            width: tabRect.width + resizeDelta,
            height: tabRect.height,
        ).toAppKitScreenRect.alignedToBackingPixels()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.isTabGroup, true)
        XCTAssertEqual(items.first?.frame, expectedFrame)
        cancelManipulatedWithMouseState()
    }
}
