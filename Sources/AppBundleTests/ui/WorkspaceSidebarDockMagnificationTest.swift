import AppKit
import Combine
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarDockMagnificationTest: XCTestCase {
    func testAppearanceReloadPublishesWithoutPointerOrWorkspaceChanges() {
        let previous = config
        defer { config = previous }
        let model = TrayMenuModel()
        model.workspaceSidebarVisibleWidth = 64
        model.refreshWorkspaceSidebarAppearance()
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        config.workspaceSidebar.showAppIcons = true
        config.workspaceSidebar.alwaysExpanded = false
        config.workspaceSidebar.dockMagnification = true
        config.workspaceSidebar.dockIconSize = 48
        config.workspaceSidebar.glassOpacity = 0.27
        model.refreshWorkspaceSidebarAppearance()
        let snapshot = workspaceSidebarSnapshot(from: model)
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(snapshot.configuration.dockMagnification)
        XCTAssertEqual(snapshot.configuration.dockIconSize, 48)
        XCTAssertEqual(snapshot.configuration.glassOpacity, 0.27)
        XCTAssertEqual(snapshot.visibleWidth, 64)
        XCTAssertNil(snapshot.hoveredWorkspaceName)
        model.refreshWorkspaceSidebarAppearance()
        XCTAssertEqual(changes, 1, "Unchanged refreshes must not invalidate the animation tree")
        withExtendedLifetime(observation) {}
    }

    func testDefaultsAndSettingsRoundTrip() {
        XCTAssertFalse(WorkspaceSidebarConfig().dockMagnification)
        XCTAssertEqual(WorkspaceSidebarConfig().dockIconSize, 40)
        var text = "[workspace-sidebar]\nshow-app-icons = true\nstay-on-top = false\n"
        text = updateSettingsScalarConfig(in: text, section: "workspace-sidebar", key: "dock-magnification", renderedValue: "true")
        text = updateSettingsScalarConfig(in: text, section: "workspace-sidebar", key: "dock-icon-size", renderedValue: "48")
        let (parsed, errors) = parseConfig(text)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(parsed.workspaceSidebar.usesDockMagnification)
        XCTAssertEqual(parsed.workspaceSidebar.dockIconSize, 48)
        XCTAssertEqual(parsed.workspaceSidebar.effectiveCollapsedWidth, 64)
        XCTAssertFalse(parsed.workspaceSidebar.stayOnTop)
        var sidebar = parsed.workspaceSidebar
        sidebar.alwaysExpanded = true
        XCTAssertFalse(sidebar.usesDockMagnification)
        XCTAssertTrue(sidebar.dockMagnification, "Disabling Dock mode must preserve the saved preference")
        sidebar.alwaysExpanded = false
        sidebar.showAppIcons = false
        XCTAssertFalse(sidebar.usesDockMagnification)
    }

    func testInvalidIconSizesAreRejected() {
        for size in ["23", "49", "0", "-1", "40.5", "'large'"] {
            let (_, errors) = parseConfig("[workspace-sidebar]\ndock-icon-size = \(size)")
            XCTAssertFalse(errors.isEmpty, size)
        }
        for size in [24, 40, 48] {
            let (parsed, errors) = parseConfig("[workspace-sidebar]\ndock-icon-size = \(size)")
            XCTAssertTrue(errors.isEmpty)
            XCTAssertEqual(parsed.workspaceSidebar.dockIconSize, size)
        }
    }

    func testAutoHideRevealKeepsDockAtItsCompactEndpoint() {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration.showAppIcons = true
        snapshot.configuration.dockMagnification = true
        snapshot.configuration.collapsedWidth = 0
        snapshot.configuration.configuredCollapsedWidth = 64
        snapshot.configuration.expandedWidth = 240
        snapshot.visibleWidth = 64
        XCTAssertEqual(snapshot.configuration.expansionStartWidth, 64)
        XCTAssertEqual(WorkspaceSidebarView(snapshot: snapshot).dockSurfaceProgress, 0)
        XCTAssertEqual(workspaceSidebarCompactSectionWidth(layout: snapshot.configuration), 50)
        snapshot.visibleWidth = 240
        XCTAssertEqual(WorkspaceSidebarView(snapshot: snapshot).dockSurfaceProgress, 1)
    }

    func testPointerMagnifiesNeighborsWithoutChangingHeightOrOverlapping() {
        for size: CGFloat in [24, 32, 40, 48] {
            for count in [1, 2, 3, 5, 10, 30] {
                let layout = WorkspaceSidebarDockMagnification(itemSize: size, count: count, enabled: true)
                let height = layout.height
                for pointer in stride(from: CGFloat(-100), through: height + 100, by: 3) {
                    let frames = layout.frames(width: 50, pointerY: pointer)
                    XCTAssertGreaterThanOrEqual(frames.first!.minY, -0.001)
                    XCTAssertLessThanOrEqual(frames.last!.maxY, height + 0.001)
                    for frame in frames {
                        XCTAssertGreaterThanOrEqual(frame.width, size)
                        XCTAssertLessThanOrEqual(frame.width, min(size * 1.5, 52) + 0.001)
                        XCTAssertEqual(frame.midX, 25, accuracy: 0.001)
                    }
                    for pair in zip(frames, frames.dropFirst()) {
                        XCTAssertEqual(pair.1.minY - pair.0.maxY, 6, accuracy: 0.001)
                    }
                    XCTAssertEqual(layout.height, height)
                }
                XCTAssertEqual(layout.frames(width: 50, pointerY: nil).map(\.width), Array(repeating: size, count: count))
            }
        }
        let layout = WorkspaceSidebarDockMagnification(itemSize: 32, count: 5, enabled: true)
        let frames = layout.frames(width: 50, pointerY: layout.restingCenter(2))
        XCTAssertEqual(frames[2].width, 48, accuracy: 0.001)
        XCTAssertGreaterThan(frames[1].width, 32)
        XCTAssertEqual(frames[0].width, 32, accuracy: 0.001)
        let disabled = WorkspaceSidebarDockMagnification(itemSize: 40, count: 3, enabled: false)
        XCTAssertEqual(disabled.frames(width: 50, pointerY: 30), disabled.frames(width: 50, pointerY: nil))
    }

    func testDotRemainsCenteredInLeftGapAtEveryIconSize() {
        for size: CGFloat in [24, 32, 40, 48, 52] {
            let tileLeading = (64 - size) / 2
            let dotCenter = tileLeading + workspaceSidebarIndicatorLeadingOffset(tileSize: size, railWidth: 64) + 2
            XCTAssertEqual(dotCenter, tileLeading / 2, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(dotCenter - 2, 0)
        }
    }

    func testMagnificationRequiresPointerInsideVisibleDockSurface() {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration.showAppIcons = true
        snapshot.configuration.dockMagnification = true
        snapshot.configuration.configuredCollapsedWidth = 64
        snapshot.configuration.expandedWidth = 240
        snapshot.visibleWidth = 64
        let view = WorkspaceSidebarView(snapshot: snapshot)
        let surface = workspaceSidebarSurfaceFrame(availableSize: CGSize(width: 240, height: 900),
            visibleWidth: 64, compactHeight: 400, expansionProgress: 0, fitsDockContent: true)
        let inside = CGPoint(x: 32, y: surface.midY)
        XCTAssertEqual(view.dockMagnificationPointer(inside, in: surface), inside)
        let layout = WorkspaceSidebarDockMagnification(itemSize: 40, count: 3, enabled: true)
        for outside in [CGPoint(x: 65, y: inside.y), CGPoint(x: 230, y: inside.y),
                        CGPoint(x: -1, y: inside.y), CGPoint(x: 32, y: surface.minY - 1),
                        CGPoint(x: 32, y: surface.maxY + 1), CGPoint(x: 1, y: surface.minY + 1)] {
            let pointer = view.dockMagnificationPointer(outside, in: surface)
            XCTAssertNil(pointer, "Transparent panel space must not magnify icons: \(outside)")
            XCTAssertEqual(layout.frames(width: 50, pointerY: pointer?.y).map(\.width), [40, 40, 40])
        }
        XCTAssertNil(view.dockMagnificationPointer(nil, in: surface))
        snapshot.visibleWidth = 240
        XCTAssertNil(WorkspaceSidebarView(snapshot: snapshot).dockMagnificationPointer(inside, in: surface))
    }

    func testNativeIconAnchorsMatchMagnifiedRenderingForHitTargets() throws {
        var workspace = sidebarAppIconsTestWorkspace(displayName: "2")
        workspace.apps = sidebarAppIconsTestApps(count: 7)
        let layout = WorkspaceSidebarDockMagnification(itemSize: 40, count: 8, enabled: true)
        let pointerY = layout.restingCenter(1)
        let probe = DockAnchorProbe()
        let content = WorkspaceSidebarAppIconHeader(workspace: workspace, availableWidth: 50, isActive: true,
            magnificationEnabled: true, railWidth: 64, iconSize: 40)
            .overlayPreferenceValue(WorkspaceSidebarMorphPreference.self) { anchors in
                GeometryReader { geometry in probe.record(anchors.mapValues { geometry[$0] }) }
            }
            .environment(\.workspaceSidebarDockPointer, CGPoint(x: 25, y: pointerY))
            .coordinateSpace(name: "workspaceSidebarContent")
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 50, height: layout.height)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window)
        let expected = layout.frames(width: 50, pointerY: pointerY)
        for (index, app) in workspace.apps.enumerated() {
            let frame = try XCTUnwrap(probe.frames[.compactApp(app.id)])
            XCTAssertEqual(frame.width, expected[index + 1].width, accuracy: 0.1)
            XCTAssertEqual(frame.midY, expected[index + 1].midY, accuracy: 0.1)
        }
    }
}

@MainActor
private final class DockAnchorProbe {
    var frames: [WorkspaceSidebarMorphElement: CGRect] = [:]
    func record(_ frames: [WorkspaceSidebarMorphElement: CGRect]) -> Color {
        self.frames = frames
        return .clear
    }
}
