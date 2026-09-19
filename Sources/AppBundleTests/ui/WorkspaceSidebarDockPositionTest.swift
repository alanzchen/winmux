@testable import AppBundle
import AppKit
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarDockPositionTest: XCTestCase {
    func testSettingsRoundTripAndSidebarKeepsOriginalEdge() {
        XCTAssertEqual(WorkspaceSidebarConfig().dockPosition, .left)
        for position in WorkspaceDockPosition.allCases {
            let text = updateSettingsScalarConfig(in: "[workspace-sidebar]\nmode = 'dock'\ndock-left-gap = 8\n",
                section: "workspace-sidebar", key: "dock-position", renderedValue: "'\(position.rawValue)'")
            var (parsed, errors) = parseConfig(text)
            XCTAssertTrue(errors.isEmpty)
            XCTAssertEqual(parsed.workspaceSidebar.effectiveDockPosition, position)
            XCTAssertEqual(parsed.workspaceSidebar.dockLeftGap, 8)
            parsed.workspaceSidebar.mode = .sidebar
            XCTAssertEqual(parsed.workspaceSidebar.effectiveDockPosition, .left)
            XCTAssertEqual(parsed.workspaceSidebar.dockPosition, position)
        }
        for invalid in ["'top'", "3", "true"] {
            let (_, errors) = parseConfig("[workspace-sidebar]\ndock-position = \(invalid)")
            XCTAssertEqual(errors.count, 1)
            XCTAssertTrue(errors[0].description.contains("dock-position"))
        }
    }

    func testPanelsStayInsideTheirDisplayAndReserveSelectedEdge() throws {
        for origin in [CGPoint(x: -1920, y: -400), .zero, CGPoint(x: 2560, y: 1080)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1920, height: 1080))
            for position in WorkspaceDockPosition.allCases {
                var settings = WorkspaceSidebarConfig(mode: .dock, dockPosition: position)
                let panel = try XCTUnwrap(workspaceSidebarPanelLayout(screenFrame: screen, sidebarConfig: settings))
                XCTAssertTrue(screen.contains(panel.frame))
                XCTAssertEqual(panel.frame.minY, screen.minY)
                if position == .right { XCTAssertEqual(panel.frame.maxX, screen.maxX) }
                if position == .bottom { XCTAssertEqual(panel.frame.width, screen.width) }
                XCTAssertEqual(workspaceSidebarReservedWidth(settings), 66)
                settings.autoHide = true
                XCTAssertEqual(workspaceSidebarReservedWidth(settings), 0)
                XCTAssertTrue(workspaceSidebarAllowsEdgeTrap(settings))
            }
        }
    }

    func testCrossDisplayEdgeHoldUsesSelectedEdgeAndPreservesPointerOrientation() {
        let display = Rect(topLeftX: -1920, topLeftY: -200, width: 1920, height: 1080)
        let neighbors: [WorkspaceDockPosition: Rect] = [
            .left: Rect(topLeftX: -3520, topLeftY: -200, width: 1600, height: 900),
            .right: Rect(topLeftX: 0, topLeftY: -200, width: 1600, height: 900),
            .bottom: Rect(topLeftX: -1920, topLeftY: 880, width: 1920, height: 1080)
        ]
        for position in WorkspaceDockPosition.allCases {
            let frame = workspaceSidebarEdgeRect(display, position: position)
            let point = CGPoint(x: frame.minX - 30, y: frame.midY)
            let previous = CGPoint(x: frame.minX + 40, y: frame.midY)
            XCTAssertTrue(workspaceSidebarHasAdjacentEdgeMonitor(frame: frame,
                otherFrames: neighbors.values.map { workspaceSidebarEdgeRect($0, position: position) }))
            XCTAssertTrue(workspaceSidebarCrossesEdge(point: point, previous: previous, frame: frame, band: 12))
            let held = CGPoint(x: frame.minX + 1, y: frame.midY)
            let physical = workspaceSidebarEdgePoint(held, position: position, inverse: true)
            XCTAssertEqual(workspaceSidebarEdgePoint(physical, position: position), held)
            switch position {
                case .left: XCTAssertEqual(physical.x, display.minX + 1)
                case .right: XCTAssertEqual(physical.x, display.maxX - 1)
                case .bottom: XCTAssertEqual(physical.y, display.maxY - 1)
            }
            XCTAssertFalse(workspaceSidebarCrossesEdge(point: CGPoint(x: frame.minX, y: frame.maxY + 100),
                previous: nil, frame: frame, band: 12))
        }
    }

    func testTiledWindowsReserveOnlyTheSelectedEdge() {
        let previous = config
        defer { config = previous; setMonitorsForTests(nil) }
        let frame = Rect(topLeftX: -1600, topLeftY: -200, width: 1600, height: 900)
        let monitor = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Display", rect: frame,
            visibleRect: frame, isMain: true)
        setMonitorsForTests([monitor])
        config.gaps = .zero
        config.workspaceSidebar = WorkspaceSidebarConfig(enabled: true, mode: .dock)
        for position in WorkspaceDockPosition.allCases {
            config.workspaceSidebar.dockPosition = position
            let result = monitor.visibleRectPaddedByOuterGaps
            XCTAssertEqual(result.topLeftX, frame.minX + (position == .left ? 66 : 0))
            XCTAssertEqual(result.topLeftY, frame.minY)
            XCTAssertEqual(result.width, frame.width - (position == .bottom ? 0 : 66))
            XCTAssertEqual(result.height, frame.height - (position == .bottom ? 66 : 0))
        }
        config.workspaceSidebar.alwaysExpanded = true
        config.workspaceSidebar.dockPosition = .bottom
        XCTAssertEqual(monitor.visibleRectPaddedByOuterGaps.height, 900 - (900 - 28) * 0.6, accuracy: 0.01)
        config.workspaceSidebar.mode = .sidebar
        XCTAssertEqual(monitor.visibleRectPaddedByOuterGaps.width, 1360)
        XCTAssertEqual(monitor.visibleRectPaddedByOuterGaps.height, 900)
    }

    func testPanelDoesNotInventDockHitRegionsBeforeItsFirstLayout() {
        let previous = config
        let panel = WorkspaceSidebarPanel.shared
        let previousSurface = panel.visibleSurfaceFrame
        defer { config = previous; panel.visibleSurfaceFrame = previousSurface }
        config.workspaceSidebar.mode = .dock
        panel.visibleSurfaceFrame = nil
        for position in WorkspaceDockPosition.allCases {
            config.workspaceSidebar.dockPosition = position
            XCTAssertEqual(panel.visibleSurfaceFrameInHostingView, .zero)
        }
        let measured = CGRect(x: 300, y: 600, width: 500, height: 64)
        panel.visibleSurfaceFrame = measured
        XCTAssertEqual(panel.visibleSurfaceFrameInHostingView, measured)
    }

    func testSurfaceAnchorsAndClosesGapDuringExpansion() {
        let size = CGSize(width: 1200, height: 800)
        for progress: CGFloat in [0, 0.25, 0.5, 1] {
            let width = 64 + 176 * progress
            for position in WorkspaceDockPosition.allCases {
                let frame = workspaceSidebarSurfaceFrame(availableSize: size, visibleWidth: width, compactHeight: 500,
                    expansionProgress: progress, fitsDockContent: true, compactLeftGap: 12, position: position)
                let gap = 12 * (1 - progress)
                switch position {
                    case .left: XCTAssertEqual(frame.minX, gap)
                    case .right: XCTAssertEqual(frame.maxX, size.width - gap)
                    case .bottom:
                        XCTAssertEqual(frame.maxY, size.height - gap)
                        XCTAssertEqual(frame.midX, size.width / 2)
                }
            }
        }
    }

    func testAutoHideRevealsAcrossGapAtBottomAndRightInAppKitCoordinates() {
        let display = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        for position in [WorkspaceDockPosition.right, .bottom] {
            let settings = WorkspaceSidebarConfig(autoHide: true, mode: .dock, dockPosition: position, dockLeftGap: 24)
            let surface = position == .right ? CGRect(x: -24, y: 100, width: 0, height: 500)
                : CGRect(x: -1200, y: -76, width: 500, height: 0)
            let region = workspaceSidebarHoverRegion(surface: surface, displayFrame: display,
                sidebarConfig: settings, exitTolerance: 20, fittedDockWidth: 32)
            let point = position == .right ? CGPoint(x: -0.5, y: 300) : CGPoint(x: -1000, y: -99.5)
            XCTAssertTrue(region.contains(point))
            XCTAssertTrue(workspaceSidebarHoverDepth(point: point, displayFrame: display, sidebarConfig: settings, thickness: 32))
            XCTAssertLessThanOrEqual(region.maxX, display.maxX)
            XCTAssertGreaterThanOrEqual(region.minY, display.minY)
        }
    }

    func testNativeLayoutsMagnifyInwardAndKeepDropTargetsOnGlass() throws {
        for position in [WorkspaceDockPosition.right, .bottom] {
            let probe = PlacementProbe()
            let snapshot = fixture(position: position)
            func view(_ pointer: CGPoint?) -> some View {
                WorkspaceSidebarView(snapshot: snapshot, actions: .init(setDropTargets: { probe.targets = $0 },
                    setSurfaceFrame: { probe.surface = $0 }, setDockIconFrames: { probe.icons = $0 }),
                    reduceMotionOverride: false)
                    .environment(\.workspaceSidebarDockPointer, pointer)
            }
            let host = NSHostingView(rootView: view(nil))
            host.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
            host.layoutSubtreeIfNeeded()
            let surface = try XCTUnwrap(probe.surface)
            let resting = try XCTUnwrap(probe.icons.first)
            XCTAssertEqual(probe.icons.count, 5)
            XCTAssertEqual(resting.width, 48, accuracy: 0.01)
            for target in probe.targets {
                XCTAssertTrue(surface.insetBy(dx: -0.01, dy: -0.01).contains(target.frame))
            }
            if position == .bottom {
                XCTAssertEqual(surface.height, 64, accuracy: 0.01)
                XCTAssertEqual(surface.maxY, 798, accuracy: 0.01)
                XCTAssertGreaterThan(probe.icons[1].minX, resting.maxX)
                XCTAssertEqual(probe.icons[1].midY, resting.midY, accuracy: 0.01)
            } else { XCTAssertEqual(surface.maxX, 998, accuracy: 0.01) }
            host.rootView = view(CGPoint(x: resting.midX, y: resting.midY))
            host.layoutSubtreeIfNeeded()
            let magnified = try XCTUnwrap(probe.icons.first)
            XCTAssertEqual(magnified.width, resting.width * 2, accuracy: 0.01)
            if position == .right { XCTAssertEqual(magnified.maxX, resting.maxX, accuracy: 0.01) }
            else { XCTAssertEqual(magnified.maxY, resting.maxY, accuracy: 0.01) }
            XCTAssertGreaterThan(magnified.width, surface.width == 64 ? surface.width : surface.height)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let sample = position == .right ? CGPoint(x: surface.minX - 10, y: magnified.midY)
                : CGPoint(x: magnified.midX, y: surface.minY - 10)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: Int(sample.x * scale), y: Int(sample.y * scale))).alphaComponent, 0.1,
                "Magnified artwork must survive scroll and surface clips")
            let directory = projectRoot.appendingPathComponent(".build/dock-placement-ui")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(position.rawValue)-magnified.png"))
        }
    }

    func testBottomNativeMotionTracksHorizontalMovementAndIgnoresPerpendicularJitter() throws {
        let snapshot = fixture(position: .bottom)
        let probe = PlacementProbe()
        let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: snapshot,
            actions: .init(setDockIconFrames: { probe.icons = $0 }), reduceMotionOverride: false))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        host.layoutSubtreeIfNeeded()
        func displayView(_ view: NSView) -> WorkspaceSidebarDockDisplayLinkView? {
            if let view = view as? WorkspaceSidebarDockDisplayLinkView { return view }
            return view.subviews.lazy.compactMap { displayView($0) }.first
        }
        let clock = try XCTUnwrap(displayView(host))
        XCTAssertTrue(clock.horizontal)
        let first = try XCTUnwrap(probe.icons.first)
        let pointer = CGPoint(x: first.midX, y: first.midY)
        clock.receive(pointer)
        for step in 0..<40 { clock.advance(to: Double(step) / 120) }
        host.layoutSubtreeIfNeeded()
        let firstPose = probe.icons
        let moved = CGPoint(x: pointer.x + 100, y: pointer.y)
        clock.receive(moved)
        for step in 40..<80 { clock.advance(to: Double(step) / 120) }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(clock.motion.target, moved)
        XCTAssertNotEqual(probe.icons, firstPose, "Moving horizontally must move the native lens")
        clock.receive(CGPoint(x: moved.x, y: moved.y + 1))
        XCTAssertEqual(clock.motion.target, moved, "Perpendicular jitter must not wake the display link")
    }

    func testBottomSizingLeavesRoomForAllControlsAndEveryWorkspaceIcon() throws {
        for projectCount in [1, 3, 9] {
            let probe = PlacementProbe()
            var snapshot = fixture(position: .bottom)
            snapshot.configuration.showsClock = true
            snapshot.configuration.showsSeconds = false
            snapshot.configuration.showsDate = true
            snapshot.configuration.showsWeekday = true
            snapshot.projects = (0..<projectCount).map { index in
                .init(id: index == 0 ? workspaceProjectDefaultId : WorkspaceProjectId(rawValue: "project-\(index)"),
                    displayName: "Project \(index)", colorHex: nil, emoji: "👩🏽‍💻")
            }
            snapshot.monitorScopes = [workspaceSidebarDefaultScopeId, "monitor:0,0", "monitor:1920,0"].map {
                .init(id: $0, displayName: "Long display name", subtitle: nil, systemImageName: "display", isFocusedMonitor: false)
            }
            let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: snapshot,
                actions: .init(setDropTargets: { probe.targets = $0 }, setSurfaceFrame: { probe.surface = $0 },
                    setDockIconFrames: { probe.icons = $0 }), reduceMotionOverride: false))
            host.frame = CGRect(x: 0, y: 0, width: 640, height: 800)
            host.layoutSubtreeIfNeeded()
            let surface = try XCTUnwrap(probe.surface)
            XCTAssertEqual(probe.icons.count, 5, "Controls must not push an app icon out of the viewport")
            XCTAssertLessThanOrEqual(surface.width, 640)
            for icon in probe.icons {
                XCTAssertEqual(icon.width, icon.height, accuracy: 0.01, "Partly clipped frames would stop being square")
                XCTAssertTrue(surface.insetBy(dx: -0.01, dy: -0.01).contains(icon))
            }
            let create = try XCTUnwrap(probe.targets.last)
            let projectSpace: CGFloat = projectCount > 1 ? CGFloat(min(projectCount, 5)) * 36 + 8 : 0
            XCTAssertEqual(create.frame.maxX + 10 + 32 + projectSpace + 120 + 6, surface.maxX, accuracy: 0.5,
                "Allow pixel rounding: fitted length must match the real create control, pager, clock, and outer padding")
        }
    }

    func testBottomExpansionReportsEachDropTargetExactlyOnce() {
        for width: CGFloat in [64, 108, 152, 196, 240] {
            let probe = PlacementProbe()
            var snapshot = fixture(position: .bottom)
            snapshot.visibleWidth = width
            let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: snapshot,
                actions: .init(setDropTargets: { probe.targets = $0 })))
            host.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(probe.targets.filter { $0.kind == .workspace("12") }.count, 1)
            XCTAssertEqual(probe.targets.filter { $0.kind == .workspace("2") }.count, 1)
        }
    }

    func testBottomExpandsToUprightSearchAndWorkspaceRows() throws {
        let probe = PlacementProbe()
        var snapshot = fixture(position: .bottom)
        snapshot.visibleWidth = 240
        let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: snapshot,
            actions: .init(setDropTargets: { probe.targets = $0 }, setSurfaceFrame: { probe.surface = $0 })))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        host.layoutSubtreeIfNeeded()
        let surface = try XCTUnwrap(probe.surface)
        XCTAssertEqual(surface, CGRect(x: 380, y: 320, width: 240, height: 480))
        let first = try XCTUnwrap(probe.targets.first { $0.kind == .workspace("12") })
        let second = try XCTUnwrap(probe.targets.first { $0.kind == .workspace("2") })
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 0.01)
        XCTAssertGreaterThan(second.frame.minY, first.frame.maxY)
    }

    private func fixture(position: WorkspaceDockPosition) -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        var workspace = sidebarAppIconsTestWorkspace()
        workspace.apps = sidebarAppIconsTestApps(count: 2)
        var second = WorkspaceSidebarWorkspaceViewModel(name: "2", projectId: workspaceProjectDefaultId,
            displayName: "2", sidebarLabel: "", isGeneratedName: false, monitorScopeId: workspaceSidebarDefaultScopeId,
            monitorName: nil, isFocused: false, isVisible: false, items: [])
        second.apps = sidebarAppIconsTestApps(count: 1)
        snapshot.workspaces = [workspace, second]
        snapshot.visibleWidth = 64
        snapshot.configuration.collapsedWidth = 64
        snapshot.configuration.expandedWidth = 240
        snapshot.configuration.showAppIcons = true
        snapshot.configuration.dockMagnification = true
        snapshot.configuration.dockMagnificationAmount = 1
        snapshot.configuration.compactLeftGap = 2
        snapshot.configuration.dockPosition = position
        snapshot.configuration.chromeStyle = .solid
        return snapshot
    }
}

@MainActor
private final class PlacementProbe {
    var surface: CGRect?
    var targets: [WorkspaceSidebarDropTargetFrame] = []
    var icons: [CGRect] = []
}
