import AppKit
@testable import AppBundle
import Common
import XCTest

/// Temporary drop UI during a drag: the topmost surface under the pointer decides, a drop there
/// never reaches the panel underneath, and it owns its preview, which no display's panel lights.
@MainActor
final class WorkspaceSidebarDropSurfaceTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
    }

    override func tearDown() async throws {
        WorkspaceSidebarTemporaryDropSurfaces.shared.removeAll()
        WorkspaceSidebarTabSplitHoverController.shared.reset()
        clearWorkspaceSidebarDropPreview()
        setWorkspaceSidebarDropPreviewOwnerScopeIdForTests(nil)
        MousePointerTracker.shared.reset()
        setMonitorsForTests(nil)
        config = defaultConfig
        try await super.tearDown()
    }

    func testTheTopmostTemporarySurfaceDecidesWithoutFallingThrough() {
        let column = FakeDropSurface(generation: 7, order: 1, rect: Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 400),
            targets: [(.workspace("one"), Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 40))])
        let hints = FakeDropSurface(generation: 7, order: 2, rect: Rect(topLeftX: 100, topLeftY: 100, width: 60, height: 60),
            targets: [])
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(column)
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(hints)

        let onRow = workspaceSidebarSurfaceHit(at: CGPoint(x: 200, y: 120))
        XCTAssertEqual(onRow.target?.kind, .workspace("one"))
        XCTAssertEqual(onRow.target?.surface, .dropDestination(generation: 7), "The target names its surface")
        XCTAssertEqual(onRow.surface, .dropDestination(generation: 7))
        XCTAssertTrue(onRow.isOnTemporarySurface)
        XCTAssertEqual(workspaceSidebarDropTarget(at: CGPoint(x: 200, y: 120))?.kind, .workspace("one"))

        let onHint = workspaceSidebarSurfaceHit(at: CGPoint(x: 120, y: 120))
        XCTAssertNil(onHint.target, "The hints above the row take no drop, and don't pass it down")
        XCTAssertFalse(onHint.isOutside)
        XCTAssertEqual(hints.lookups, 1)
        XCTAssertEqual(column.lookups, 2, "The hint's hit didn't look in the column")

        let blank = workspaceSidebarSurfaceHit(at: CGPoint(x: 200, y: 400))
        XCTAssertNil(blank.target, "Blank space in the list is inside it, with no drop")
        XCTAssertFalse(blank.isOutside)
        XCTAssertEqual(workspaceSidebarSurface(at: CGPoint(x: 200, y: 400))?.rect, column.rect)

        XCTAssertTrue(workspaceSidebarSurfaceHit(at: CGPoint(x: 900, y: 900)).isOutside)
        XCTAssertNil(workspaceSidebarSurface(at: CGPoint(x: 900, y: 900)))

        WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(column)
        WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(hints)
        XCTAssertTrue(WorkspaceSidebarTemporaryDropSurfaces.shared.isEmpty)
        XCTAssertTrue(workspaceSidebarSurfaceHit(at: CGPoint(x: 200, y: 120)).isOutside, "Gone with its surfaces")
    }

    /// The inward column lies over the source sidebar: a point over both is the column's.
    func testTemporaryUIOverASidebarBlocksItsDrops() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let wasEnabled = TrayMenuModel.shared.isEnabled
        defer { TrayMenuModel.shared.isEnabled = wasEnabled }
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        config.workspaceSidebar.alwaysExpanded = true
        config.workspaceSidebar.tabsAlwaysExpanded = true
        WorkspaceSidebarPanel.refreshAll()
        defer {
            config = defaultConfig
            WorkspaceSidebarPanel.refreshAll()
        }
        let panel = try XCTUnwrap(WorkspaceSidebarPanel.panel(for: workspaceSidebarMonitorScopeId(for: mainMonitor)))
        panel.orderFront(nil)
        // The surface SwiftUI would report after its first layout.
        panel.visibleSurfaceFrame = CGRect(x: 0, y: 0, width: 280, height: 600)
        defer { panel.visibleSurfaceFrame = nil }
        let rect = panel.visibleSurfaceFrameOnScreen.monitorFrameNormalized()
        let point = rect.center
        XCTAssertEqual(workspaceSidebarSurfaceHit(at: point).surface, panel.surfaceRef, "Without temporary UI, the sidebar")

        let column = FakeDropSurface(generation: 3, order: 1, rect: rect, targets: [])
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(column)
        let hit = workspaceSidebarSurfaceHit(at: point)
        XCTAssertEqual(hit.surface, .dropDestination(generation: 3))
        XCTAssertNil(hit.target, "The sidebar underneath takes nothing")
        XCTAssertNil(workspaceSidebarDropTarget(at: point))
    }

    func testAWindowDragGetsNoIntentOverTemporaryUI() {
        let workspace = Workspace.get(byName: "one")
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let column = FakeDropSurface(generation: 1, order: 1, rect: Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 300),
            targets: [(.workspace("two"), Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 40))])
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(column)
        XCTAssertNil(currentSidebarWorkspaceDropDestination(sourceWindow: window, mouseLocation: CGPoint(x: 100, y: 20),
            subject: .window), "Only the sidebar's own drop, never a window drag's")
        XCTAssertNil(currentSidebarWorkspaceDropDestination(sourceWindow: window, mouseLocation: CGPoint(x: 100, y: 200),
            subject: .window))
    }

    func testAPreviewOnTemporaryUILightsNoPanel() {
        let preview = targetedPreview()
        setWorkspaceSidebarDropPreviewIfChanged(preview, owner: .dropDestination(generation: 4))
        XCTAssertEqual(currentWorkspaceSidebarDropPreviewOwnerScopeId(), "drop-destination:4")
        let shown = workspaceSidebarPanelDropPreview(TrayMenuModel.shared.workspaceSidebarDropPreview,
            ownerId: currentWorkspaceSidebarDropPreviewOwnerScopeId())
        XCTAssertEqual(shown, preview.sourceOnly, "The panels keep only what's dragged")
        XCTAssertFalse(workspaceSidebarDropPreviewBelongs(toPanel: "monitor:0.0,0.0", preview: preview,
            ownerScopeId: currentWorkspaceSidebarDropPreviewOwnerScopeId()), "No panel going away takes it")

        setWorkspaceSidebarDropPreviewIfChanged(preview, owner: .panel(monitorScopeId: "monitor:0.0,0.0"))
        XCTAssertEqual(currentWorkspaceSidebarDropPreviewOwnerScopeId(), "monitor:0.0,0.0",
            "An equal preview moving to a panel takes that owner")
        XCTAssertEqual(workspaceSidebarPanelDropPreview(preview, ownerId: "monitor:0.0,0.0"), preview)
        XCTAssertNil(workspaceSidebarPanelDropPreview(nil, ownerId: "drop-destination:4"))
        setWorkspaceSidebarDropPreviewIfChanged(nil, owner: .dropDestination(generation: 4))
        XCTAssertNil(currentWorkspaceSidebarDropPreviewOwnerScopeId(), "No preview, no owner")
    }

    func testTheOwnerFollowsTheSurfaceUnderThePointerByDefault() {
        let column = FakeDropSurface(generation: 9, order: 1, rect: Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 300),
            targets: [])
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(column)
        MousePointerTracker.shared.note(point: CGPoint(x: 10, y: 10))
        setWorkspaceSidebarDropPreviewIfChanged(targetedPreview())
        XCTAssertEqual(currentWorkspaceSidebarDropPreviewOwnerScopeId(), "drop-destination:9")
    }

    func testASourceOnlyPreviewKeepsWhatsDraggedAndDropsWhereItGoes() {
        var preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 5, label: "Notes", appName: "Notes",
            appBundleIdentifier: "com.apple.Notes", appBundlePath: "/Applications/Notes.app", targetWorkspaceName: "one",
            targetsNewWorkspace: true, targetProjectId: workspaceProjectDefaultId, targetMonitorScopeId: "monitor:0.0,0.0",
            isTabGroup: true, windowCount: 2, tabItems: [.init(title: "Notes", appName: "Notes", appBundleIdentifier: nil, appBundlePath: nil)])
        preview.targetCollectionId = "c"
        preview.targetPlacement = .left
        preview.targetGap = .init(workspaceName: "one", isAfter: true)
        preview.separatesFromTab = true
        preview.targetsPinned = true
        preview.targetPinnedGap = .init(workspaceName: "one", isAfter: false)
        let source = preview.sourceOnly
        XCTAssertEqual(source.sourceWindowId, 5)
        XCTAssertEqual(source.label, "Notes")
        XCTAssertEqual(source.appBundleIdentifier, "com.apple.Notes")
        XCTAssertEqual(source.appBundlePath, "/Applications/Notes.app")
        XCTAssertTrue(source.isTabGroup)
        XCTAssertEqual(source.windowCount, 2)
        XCTAssertEqual(source.tabItems, preview.tabItems)
        XCTAssertNil(source.targetWorkspaceName)
        XCTAssertFalse(source.targetsNewWorkspace)
        XCTAssertNil(source.targetCollectionId)
        XCTAssertNil(source.targetPlacement)
        XCTAssertNil(source.targetLabelSlot)
        XCTAssertNil(source.targetGap)
        XCTAssertFalse(source.separatesFromTab)
        XCTAssertFalse(source.targetsPinned)
        XCTAssertNil(source.targetPinnedGap)
    }

    /// Tabs mode commits only what the last preview showed; the same kind and rect on another
    /// surface isn't it.
    func testAReleaseCommitsOnlyOnTheSurfaceThePreviewWasOn() {
        config.workspaceSidebar.mode = .tabs
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 40)
        let shown = WorkspaceSidebarDropTarget(kind: .workspace("one"), rect: rect, surface: .dropDestination(generation: 2))
        let hover = WorkspaceSidebarTabSplitHoverController.shared
        hover.noteDisplayed(source: 1, hitKind: shown.kind, target: shown, placement: nil)
        XCTAssertNotNil(hover.commitTarget(source: 1, hitTarget: shown, point: rect.center))
        var elsewhere = shown
        elsewhere.surface = .dropDestination(generation: 3)
        XCTAssertNil(hover.commitTarget(source: 1, hitTarget: elsewhere, point: rect.center), "A reopened list")
        elsewhere.surface = .panel(monitorScopeId: "monitor:0.0,0.0")
        XCTAssertNil(hover.commitTarget(source: 1, hitTarget: elsewhere, point: rect.center), "The sidebar underneath")
    }

    private func targetedPreview() -> WorkspaceSidebarDropPreviewViewModel {
        WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 1, label: "a", appName: "App",
            targetWorkspaceName: "one", targetsNewWorkspace: false, isTabGroup: false, windowCount: 1)
    }
}

@MainActor
private final class FakeDropSurface: WorkspaceSidebarTemporaryDropSurface {
    let surfaceRef: WorkspaceSidebarSurfaceRef
    let stackingOrder: Int
    let rect: Rect
    let targets: [(WorkspaceSidebarDropTargetKind, Rect)]
    private(set) var lookups = 0

    init(generation: UInt64, order: Int, rect: Rect, targets: [(WorkspaceSidebarDropTargetKind, Rect)]) {
        surfaceRef = .dropDestination(generation: generation)
        stackingOrder = order
        self.rect = rect
        self.targets = targets
    }

    func surfaceRectNormalized(containing point: CGPoint) -> Rect? {
        rect.contains(point) ? rect : nil
    }

    func dropTarget(atNormalizedPoint point: CGPoint, hitSlop _: NSEdgeInsets,
                    includesTabGaps _: Bool) -> WorkspaceSidebarDropTarget? {
        lookups += 1
        return targets.first { $0.1.contains(point) }.map { .init(kind: $0.0, rect: $0.1) }
    }
}
