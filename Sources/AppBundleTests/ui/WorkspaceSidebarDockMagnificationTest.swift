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
        config.workspaceSidebar.dockMagnificationAmount = 0.35
        config.workspaceSidebar.dockIconSize = 48
        config.workspaceSidebar.glassOpacity = 0.27
        model.refreshWorkspaceSidebarAppearance()
        let snapshot = workspaceSidebarSnapshot(from: model)
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(snapshot.configuration.dockMagnification)
        XCTAssertEqual(snapshot.configuration.dockMagnificationAmount, 0.35)
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
        XCTAssertEqual(WorkspaceSidebarConfig().dockMagnificationAmount, 0.5)
        XCTAssertEqual(WorkspaceSidebarConfig().dockIconSize, 48)
        var text = "[workspace-sidebar]\nshow-app-icons = true\nstay-on-top = false\n"
        text = updateSettingsScalarConfig(in: text, section: "workspace-sidebar", key: "dock-magnification", renderedValue: "true")
        text = updateSettingsScalarConfig(in: text, section: "workspace-sidebar", key: "dock-magnification-amount", renderedValue: "0.65")
        text = updateSettingsScalarConfig(in: text, section: "workspace-sidebar", key: "dock-icon-size", renderedValue: "40")
        let (parsed, errors) = parseConfig(text)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(parsed.workspaceSidebar.usesDockMagnification)
        XCTAssertEqual(parsed.workspaceSidebar.dockMagnificationAmount, 0.65)
        XCTAssertEqual(parsed.workspaceSidebar.dockIconSize, 40, "A saved icon size must override the larger default")
        XCTAssertEqual(parsed.workspaceSidebar.effectiveCollapsedWidth, 64)
        XCTAssertFalse(parsed.workspaceSidebar.stayOnTop)
        var sidebar = parsed.workspaceSidebar
        sidebar.alwaysExpanded = true
        XCTAssertFalse(sidebar.usesDockMagnification)
        XCTAssertTrue(sidebar.dockMagnification, "Disabling Dock mode must preserve the saved preference")
        sidebar.alwaysExpanded = false
        sidebar.showAppIcons = false
        XCTAssertFalse(sidebar.usesDockMagnification)
        XCTAssertEqual(sidebar.dockMagnificationAmount, 0.65)
    }

    func testMagnificationAmountValidation() {
        for amount in ["-0.01", "1.01", "nan", "inf", "-inf", "true", "'high'"] {
            let (_, errors) = parseConfig("[workspace-sidebar]\ndock-magnification-amount = \(amount)")
            XCTAssertFalse(errors.isEmpty, amount)
        }
        for amount in ["0", "0.25", "1"] {
            let (parsed, errors) = parseConfig("[workspace-sidebar]\ndock-magnification-amount = \(amount)")
            XCTAssertTrue(errors.isEmpty, amount)
            XCTAssertEqual(parsed.workspaceSidebar.dockMagnificationAmount, Double(amount))
        }
    }

    func testMagnificationAmountScalesGrowthBeyondFixedGlassRail() {
        for size in 24...48 {
            let maximum = WorkspaceSidebarDockMagnification(itemSize: CGFloat(size), count: 5, enabled: true, amount: 1)
            for amount in [0.0, 0.25, 0.5, 1.0] {
                let layout = WorkspaceSidebarDockMagnification(itemSize: CGFloat(size), count: 5, enabled: true, amount: amount)
                let resting = layout.frames(width: 50, pointerY: nil)
                for index in 0..<5 {
                    let frames = layout.frames(width: 50, pointerY: layout.restingCenter(index))
                    XCTAssertEqual(frames[index].width - CGFloat(size), maximum.maximumGrowth * amount, accuracy: 0.001)
                    for frame in frames {
                        XCTAssertEqual(frame.minX, resting[0].minX, accuracy: 0.001)
                        XCTAssertLessThanOrEqual(frame.maxX + 7, 104.001)
                    }
                    XCTAssertGreaterThanOrEqual(frames[0].minY, -0.001)
                    XCTAssertLessThanOrEqual(frames[4].maxY, layout.renderedHeight(pointerY: layout.restingCenter(index)) + 0.001)
                }
                let appLayout = WorkspaceSidebarAppIconLayout(appCount: 4, availableWidth: 50,
                    magnificationEnabled: true, iconSize: CGFloat(size), magnificationAmount: amount)
                XCTAssertEqual(appLayout.height, layout.height)
                if amount == 0 {
                    XCTAssertEqual(layout.renderedHeight(pointerY: 40), layout.height)
                    XCTAssertEqual(layout.frames(width: 50, pointerY: 40), resting)
                }
            }
        }
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

    func testEdgeMappingMagnifiesNeighborsWithoutOverlapOrRestingPadding() {
        for size: CGFloat in [24, 32, 40, 48] {
            for count in [1, 2, 3, 5, 10, 30] {
                let layout = WorkspaceSidebarDockMagnification(itemSize: size, count: count, enabled: true)
                let height = layout.height
                for pointer in stride(from: CGFloat(-100), through: height + 100, by: 3) {
                    let frames = layout.frames(width: 50, pointerY: pointer)
                    XCTAssertGreaterThanOrEqual(frames.first!.minY, -0.001)
                    XCTAssertEqual(frames.last!.maxY, layout.renderedHeight(pointerY: pointer), accuracy: 0.001)
                    for frame in frames {
                        XCTAssertGreaterThanOrEqual(frame.width, size - 0.001)
                        XCTAssertLessThanOrEqual(frame.width, size * 1.5 + 0.001)
                        XCTAssertEqual(frame.minX, (50 - size) / 2, accuracy: 0.001)
                        XCTAssertLessThanOrEqual(frame.maxX + 7, 80.001, "Default magnification must fit the transparent panel beside the rail")
                    }
                    for pair in zip(frames, frames.dropFirst()) {
                        XCTAssertGreaterThanOrEqual(pair.1.minY - pair.0.maxY, WorkspaceSidebarAppIconLayout.spacing - 0.001)
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
        XCTAssertLessThan(frames[0].width, frames[1].width)
        let disabled = WorkspaceSidebarDockMagnification(itemSize: 40, count: 3, enabled: false)
        XCTAssertEqual(disabled.frames(width: 50, pointerY: 30), disabled.frames(width: 50, pointerY: nil))
    }

    func testDotRemainsCenteredInLeftGapAtEveryIconSize() {
        for size: CGFloat in [24, 32, 40, 48] {
            let tileLeading = (64 - size) / 2
            let dotCenter = tileLeading + workspaceSidebarIndicatorLeadingOffset(tileSize: size, railWidth: 64) + 2
            XCTAssertEqual(dotCenter, tileLeading / 2, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(dotCenter - 2, 0)
            let layout = WorkspaceSidebarDockMagnification(itemSize: size, count: 1, enabled: true)
            for pointer in stride(from: CGFloat(0), through: layout.height, by: 3) {
                let magnifiedLeading = layout.frames(width: 64, pointerY: pointer)[0].minX
                let magnifiedDotCenter = magnifiedLeading + workspaceSidebarIndicatorLeadingOffset(tileSize: size, railWidth: 64) + 2
                XCTAssertEqual(magnifiedDotCenter, dotCenter, accuracy: 0.001)
            }
        }
    }

    func testRestingWorkspaceHeightsAndSeparatorGapsIgnoreMagnificationAmount() {
        for amount in [0.0, 0.25, 0.5, 1.0] {
            let column = WorkspaceSidebarDockColumnMagnification(appCounts: [2, 0, 5], itemSize: 40, amount: amount, pointerY: nil)
            XCTAssertEqual(column.growth, 0)
            XCTAssertTrue(column.sections.allSatisfy { $0.pointerY == nil })
            let header = WorkspaceSidebarAppIconLayout(appCount: 2, availableWidth: 50,
                magnificationEnabled: true, iconSize: 40, magnificationAmount: amount)
            XCTAssertEqual(header.height, 128, "No per-workspace magnification reserve")
        }
    }

    func testColumnUsesRestingCoordinatesAcrossWorkspaceSeparator() {
        // First header: 3...87. Next header begins at 99, after the 12pt separator gap.
        let column = WorkspaceSidebarDockColumnMagnification(appCounts: [1, 1], itemSize: 40, amount: 1, pointerY: 93)
        XCTAssertEqual(column.sections[0].pointerY, 90)
        XCTAssertEqual(column.sections[1].pointerY, -6)
        let header = WorkspaceSidebarDockMagnification(itemSize: 40, count: 2, enabled: true, amount: 1)
        let first = header.frames(width: 50, pointerY: column.sections[0].pointerY)
        let second = header.frames(width: 50, pointerY: column.sections[1].pointerY)
        XCTAssertGreaterThan(first[1].width, 40)
        XCTAssertGreaterThan(second[0].width, 40)
        XCTAssertEqual(first[1].width, second[0].width, accuracy: 0.001)
        XCTAssertGreaterThan(column.growth, 0)
    }

    func testSectionsOutsideLensKeepStableInputsAndRestingGeometry() {
        let first = WorkspaceSidebarDockColumnMagnification(appCounts: [4, 4, 4, 4], itemSize: 40,
            amount: 1, pointerY: 30, strength: 0.4)
        let next = WorkspaceSidebarDockColumnMagnification(appCounts: [4, 4, 4, 4], itemSize: 40,
            amount: 1, pointerY: 40, strength: 0.7)
        XCTAssertNotEqual(first.sections[0], next.sections[0])
        for index in 1..<4 {
            XCTAssertEqual(first.sections[index], next.sections[index])
            XCTAssertNil(next.sections[index].pointerY)
        }
        // Verify dropping the saturated translation preserves the original geometry.
        let layout = WorkspaceSidebarDockMagnification(itemSize: 40, count: 5, enabled: true, amount: 1)
        for pointer: CGFloat in [-1000, -92, layout.height + 92, layout.height + 1000] {
            let original = layout.frames(width: 50, pointerY: pointer)
            let resting = layout.frames(width: 50, pointerY: nil)
            for (a, b) in zip(original, resting) {
                XCTAssertEqual(a.minY, b.minY, accuracy: 0.000_001)
                XCTAssertEqual(a.height, b.height, accuracy: 0.000_001)
            }
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
        let protrudingIcon = CGRect(x: 12, y: inside.y - 40, width: 80, height: 80)
        let onIcon = CGPoint(x: 80, y: inside.y)
        XCTAssertEqual(view.dockMagnificationPointer(onIcon, in: surface, iconFrames: [protrudingIcon]), onIcon)
        XCTAssertNil(view.dockMagnificationPointer(CGPoint(x: 95, y: inside.y), in: surface, iconFrames: [protrudingIcon]))
        XCTAssertNil(view.dockMagnificationPointer(CGPoint(x: 80, y: inside.y + 50), in: surface, iconFrames: [protrudingIcon]))
        snapshot.visibleWidth = 240
        XCTAssertNil(WorkspaceSidebarView(snapshot: snapshot).dockMagnificationPointer(inside, in: surface, iconFrames: [protrudingIcon]))
    }

    func testNativeIconAnchorsMatchMagnifiedRenderingForHitTargets() throws {
        var workspace = sidebarAppIconsTestWorkspace(displayName: "2")
        workspace.apps = sidebarAppIconsTestApps(count: 7)
        let layout = WorkspaceSidebarDockMagnification(itemSize: 40, count: 8, enabled: true, amount: 0.5)
        let pointerY = layout.restingCenter(1)
        let probe = DockAnchorProbe()
        let content = WorkspaceSidebarAppIconHeader(workspace: workspace, availableWidth: 50, isActive: true,
            magnificationEnabled: true, railWidth: 64, iconSize: 40, magnificationAmount: 0.5)
            .overlayPreferenceValue(WorkspaceSidebarMorphPreference.self) { anchors in
                GeometryReader { geometry in probe.record(anchors.mapValues { geometry[$0] }) }
            }
            .environment(\.workspaceSidebarDockSectionMagnification, .init(pointerY: pointerY))
            .coordinateSpace(name: "workspaceSidebarContent")
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 50, height: layout.renderedHeight(pointerY: pointerY))
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window)
        let expected = layout.frames(width: 50, pointerY: pointerY)
        // An unattached hosting view lays out on a 1x pixel grid. The sine mapping
        // produces fractional sizes; rendered anchors may round by half a point.
        let pixelRoundingTolerance: CGFloat = 0.501
        for (index, app) in workspace.apps.enumerated() {
            let frame = try XCTUnwrap(probe.frames[.compactApp(app.id)])
            XCTAssertEqual(frame.width, expected[index + 1].width, accuracy: pixelRoundingTolerance)
            XCTAssertEqual(frame.minX, expected[index + 1].minX, accuracy: 0.1)
            XCTAssertEqual(frame.midY, expected[index + 1].midY, accuracy: pixelRoundingTolerance)
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
