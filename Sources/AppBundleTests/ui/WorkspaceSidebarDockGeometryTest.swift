import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarDockGeometryTest: XCTestCase {
    func testMagnifiedIconsRenderOutsideGlassAndKeepExactNativeHitRegions() throws {
        var snapshot = fixture()
        snapshot.configuration.dockMagnification = true
        snapshot.configuration.dockMagnificationAmount = 1
        let resting = render(snapshot, height: 800)
        let restingTitle = try XCTUnwrap(resting.probe.icons.first)
        let probe = DockGeometryProbe()
        let view = WorkspaceSidebarView(snapshot: snapshot, actions: .init(
            setSurfaceFrame: { probe.surface = $0 }, setDockIconFrames: { probe.icons = $0 }), reduceMotionOverride: false)
            .environment(\.workspaceSidebarDockPointer, CGPoint(x: 32, y: restingTitle.midY))
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 240, height: 800)
        host.layoutSubtreeIfNeeded()
        let surface = try XCTUnwrap(probe.surface)
        let title = try XCTUnwrap(probe.icons.first)
        XCTAssertEqual(surface.width, 64)
        XCTAssertEqual(title.minX, restingTitle.minX, accuracy: 0.1)
        XCTAssertEqual(title.width, 80, accuracy: 0.1)
        XCTAssertGreaterThan(title.maxX, surface.maxX)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        func alpha(x: CGFloat, y: CGFloat) throws -> CGFloat {
            try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))).alphaComponent
        }
        XCTAssertGreaterThan(try alpha(x: 75, y: title.midY), 0.1, "Magnified pixels must survive every section, scroll, pager, and surface clip")
        XCTAssertLessThan(try alpha(x: 110, y: title.midY), 0.01, "The glass background must keep its fixed width")
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/issue-fixes-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("dock-native-magnification.png"))
    }

    func testRepeatedHoverReturnsToStableGeometryWithoutLayoutFeedback() throws {
        var snapshot = fixture()
        snapshot.configuration.dockMagnification = true
        snapshot.configuration.dockMagnificationAmount = 1
        let resting = render(snapshot, height: 800)
        let pointerY = try XCTUnwrap(resting.probe.icons.first).midY
        let probe = DockGeometryProbe()
        let actions = WorkspaceSidebarActions(setSurfaceFrame: { probe.surface = $0 }, setDockIconFrames: { probe.icons = $0 })
        func content(_ y: CGFloat) -> some View {
            WorkspaceSidebarView(snapshot: snapshot, actions: actions, reduceMotionOverride: false)
                .environment(\.workspaceSidebarDockPointer, CGPoint(x: 32, y: y))
        }
        let host = NSHostingView(rootView: content(pointerY))
        host.frame = CGRect(x: 0, y: 0, width: 240, height: 800)
        host.layoutSubtreeIfNeeded()
        let expectedSurface = try XCTUnwrap(probe.surface)
        let expectedIcons = probe.icons
        XCTAssertFalse(expectedIcons.isEmpty)
        for _ in 0..<10 {
            host.rootView = content(pointerY + 10)
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            XCTAssertNotEqual(probe.icons, expectedIcons, "The test must actually move the magnification lens")
            host.rootView = content(pointerY)
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(probe.surface, expectedSurface, "Shelf growth cannot move the pointer's resting reference")
            XCTAssertEqual(probe.icons, expectedIcons, "Repeated hover must not drift or oscillate")
        }
    }

    func testReduceMotionSuppressesMagnificationHitRegions() {
        var snapshot = fixture()
        snapshot.configuration.dockMagnification = true
        let sample = render(snapshot, height: 800, reduceMotion: true)
        XCTAssertNotNil(sample.probe.surface)
        XCTAssertTrue(sample.probe.icons.isEmpty)
    }

    func testTallMagnifiedDockClipsIconHitRegionsToScrollViewport() throws {
        var snapshot = fixture()
        snapshot.configuration.dockMagnification = true
        snapshot.configuration.dockMagnificationAmount = 1
        snapshot.workspaces[0].apps = sidebarAppIconsTestApps(count: 12)
        let sample = render(snapshot, height: 200)
        XCTAssertFalse(sample.probe.icons.isEmpty)
        XCTAssertLessThan(sample.probe.icons.count, 13)
        for frame in sample.probe.icons {
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxY, 200 - 32 - 6)
        }
    }

    func testCompactSurfaceCentersAndExpandsToFullHeightWithoutChangingWidth() {
        let available = CGSize(width: 480, height: 800)
        for progress: CGFloat in [0, 0.25, 0.57, 0.59, 0.75, 1] {
            let width = 64 + 176 * progress
            let frame = workspaceSidebarSurfaceFrame(
                availableSize: available,
                visibleWidth: width,
                compactHeight: 220,
                expansionProgress: progress,
                fitsDockContent: true
            )
            XCTAssertEqual(frame.width, width)
            XCTAssertEqual(frame.midY, 400)
            XCTAssertEqual(frame.height, 220 + 580 * progress, accuracy: 0.001)
        }
        for fitsDock in [false, true] {
            let frame = workspaceSidebarSurfaceFrame(
                availableSize: available,
                visibleWidth: 64,
                compactHeight: 1_000,
                expansionProgress: 0,
                fitsDockContent: fitsDock
            )
            XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 64, height: 800), "Tall content must scroll within the available height")
        }
        let legacy = workspaceSidebarSurfaceFrame(
            availableSize: available, visibleWidth: 44, compactHeight: 120, expansionProgress: 0, fitsDockContent: false
        )
        XCTAssertEqual(legacy.height, 800, "Legacy mode keeps the full panel height")
    }

    func testNativeSurfaceAndDropTargetsUseTheSameCenteredCoordinates() throws {
        var snapshot = fixture()
        let expectedCompactHeight = WorkspaceSidebarView(snapshot: snapshot).compactDockContentHeight
        XCTAssertLessThan(expectedCompactHeight, 800)
        for progress: CGFloat in [0, 0.25, 1] {
            snapshot.visibleWidth = 64 + 176 * progress
            let sample = render(snapshot, height: 800)
            let frame = try XCTUnwrap(sample.probe.surface)
            XCTAssertEqual(frame.midY, 400, accuracy: 0.5)
            XCTAssertEqual(frame.width, snapshot.visibleWidth, accuracy: 0.5)
            XCTAssertEqual(frame.height, expectedCompactHeight + (800 - expectedCompactHeight) * progress, accuracy: 0.5)
            XCTAssertFalse(sample.probe.targets.isEmpty)
            for target in sample.probe.targets {
                XCTAssertTrue(frame.insetBy(dx: -0.5, dy: -0.5).contains(target.frame))
            }
            let workspace = try XCTUnwrap(sample.probe.targets.first { $0.kind == .workspace("12") })
            XCTAssertGreaterThanOrEqual(workspace.frame.minY, frame.minY + snapshot.configuration.topPadding - 0.5)
            if progress == 0 {
                let create = try XCTUnwrap(sample.probe.targets.first {
                    if case .newWorkspace = $0.kind { return true }
                    return false
                })
                XCTAssertEqual(frame.maxY - create.frame.maxY, 16, accuracy: 0.5, "The compact surface fits its rows plus page/footer padding")
            }
            XCTAssertNil(sample.host.window, "Geometry validation must not open a native window")
        }
    }

    func testTallNativeDockClipsHiddenDropTargetsToItsScrollingViewport() throws {
        var snapshot = fixture()
        snapshot.workspaces[0].apps = sidebarAppIconsTestApps(count: 6)
        let sample = render(snapshot, height: 130)
        let frame = try XCTUnwrap(sample.probe.surface)
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 64, height: 130))
        XCTAssertFalse(sample.probe.targets.isEmpty)
        XCTAssertFalse(sample.probe.targets.contains {
            if case .newWorkspace = $0.kind { return true }
            return false
        }, "The create button below the scroll viewport cannot be a drop target")
        for target in sample.probe.targets {
            XCTAssertLessThanOrEqual(target.frame.maxY, frame.maxY - 6 + 0.5, "The footer is outside the page's drop region; an empty project pager has no reserve")
        }
    }

    func testCompactHeightIncludesClockMonitorAndProjectControls() {
        var configuration = fixture().configuration
        let base = workspaceSidebarDockContentHeight(
            appCounts: [1], configuration: configuration, showsCreateWorkspace: true, showsMonitorSelector: false, projectCount: 1
        )
        configuration.showsClock = true
        configuration.showsSeconds = true
        let controls = workspaceSidebarDockContentHeight(
            appCounts: [1], configuration: configuration, showsCreateWorkspace: true, showsMonitorSelector: true, projectCount: 9
        )
        XCTAssertEqual(controls - base, 33 + 168 + 107 - 6, accuracy: 0.001)
        configuration.showsSeconds = false
        let fewerSeconds = workspaceSidebarDockContentHeight(
            appCounts: [1], configuration: configuration, showsCreateWorkspace: true, showsMonitorSelector: true, projectCount: 9
        )
        XCTAssertEqual(controls - fewerSeconds, 24)
    }

    func testNativeDragPreviewDoesNotMoveTheSurfaceOrLoseItsExistingTarget() throws {
        var snapshot = fixture()
        let initial = render(snapshot, height: 800)
        let initialSurface = try XCTUnwrap(initial.probe.surface)
        let initialTarget = try XCTUnwrap(initial.probe.targets.first { $0.kind == .workspace("12") })
        snapshot.dropPreview = WorkspaceSidebarDropPreviewViewModel(
            sourceWindowId: 900,
            label: "Dragged window",
            appName: "Editor",
            targetWorkspaceName: "12",
            targetsNewWorkspace: false,
            isTabGroup: false,
            windowCount: 1
        )
        let preview = render(snapshot, height: 800)
        let previewSurface = try XCTUnwrap(preview.probe.surface)
        let previewTarget = try XCTUnwrap(preview.probe.targets.first { $0.kind == .workspace("12") })
        XCTAssertEqual(previewSurface, initialSurface, "Entering a target cannot expand or recenter the Dock")
        XCTAssertEqual(previewTarget.frame.minY, initialTarget.frame.minY, accuracy: 0.5)
        XCTAssertTrue(previewTarget.frame.contains(CGPoint(x: initialTarget.frame.midX, y: initialTarget.frame.midY)))
    }

    func testDropClippingRemovesInvisibleTargetsAndRetainsVisiblePortions() {
        let viewport = CGRect(x: 7, y: 250, width: 50, height: 100)
        let targets = [
            WorkspaceSidebarDropTargetFrame(kind: .workspace("above"), frame: CGRect(x: 7, y: 100, width: 50, height: 30)),
            WorkspaceSidebarDropTargetFrame(kind: .workspace("partial"), frame: CGRect(x: 7, y: 230, width: 50, height: 50)),
            WorkspaceSidebarDropTargetFrame(kind: .workspace("inside"), frame: CGRect(x: 7, y: 300, width: 50, height: 30)),
            WorkspaceSidebarDropTargetFrame(kind: .workspace("below"), frame: CGRect(x: 7, y: 370, width: 50, height: 30)),
        ]
        let clipped = workspaceSidebarClippedDropTargets(targets, to: viewport)
        XCTAssertEqual(clipped.map(\.kind), [.workspace("partial"), .workspace("inside")])
        XCTAssertEqual(clipped[0].frame, CGRect(x: 7, y: 250, width: 50, height: 30))
        XCTAssertTrue(workspaceSidebarClippedDropTargets(targets, to: .zero).isEmpty)
    }

    private func fixture() -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        var workspace = sidebarAppIconsTestWorkspace()
        workspace.apps = sidebarAppIconsTestApps(count: 1)
        snapshot.workspaces = [workspace]
        snapshot.visibleWidth = 64
        snapshot.configuration.collapsedWidth = 64
        snapshot.configuration.configuredCollapsedWidth = 64
        snapshot.configuration.expandedWidth = 240
        snapshot.configuration.showAppIcons = true
        snapshot.configuration.chromeStyle = .solid
        return snapshot
    }

    private func render(_ snapshot: WorkspaceSidebarSnapshot, height: CGFloat, reduceMotion: Bool = false) -> (host: NSHostingView<WorkspaceSidebarView>, probe: DockGeometryProbe) {
        let probe = DockGeometryProbe()
        let view = WorkspaceSidebarView(snapshot: snapshot, actions: .init(
            setDropTargets: { probe.targets = $0 },
            setSurfaceFrame: { probe.surface = $0 },
            setDockIconFrames: { probe.icons = $0 }
        ), reduceMotionOverride: reduceMotion)
        // Headless macOS runners may enable Reduce Motion. Geometry tests must
        // select their intended accessibility state instead of inheriting the host.
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 480, height: height)
        host.layoutSubtreeIfNeeded()
        return (host, probe)
    }
}

@MainActor
private final class DockGeometryProbe {
    var surface: CGRect?
    var targets: [WorkspaceSidebarDropTargetFrame] = []
    var icons: [CGRect] = []
}
