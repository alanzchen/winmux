import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarDockAdaptiveSizingTest: XCTestCase {
    func testLargestFittingSizeReservesAllNonIconControls() {
        for maximum: CGFloat in [24, 32, 48] {
            var configuration = fixture().configuration
            configuration.dockIconSize = maximum
            configuration.showsClock = true
            configuration.showsSeconds = true
            configuration.dockMagnification = true
            let counts = [2, 3]
            func height(_ size: CGFloat) -> CGFloat {
                var layout = configuration
                layout.dockIconSize = size
                return workspaceSidebarDockContentHeight(appCounts: counts, configuration: layout,
                    showsCreateWorkspace: true, showsMonitorSelector: true, projectCount: 3)
                    + WorkspaceSidebarDockColumnMagnification.maximumGrowth(
                        appCounts: counts, itemSize: size, amount: layout.dockMagnificationAmount)
            }
            let available = height(maximum) - 43.75
            let size = workspaceSidebarFittedDockIconSize(appCounts: counts, configuration: configuration,
                availableHeight: available, showsCreateWorkspace: true, showsMonitorSelector: true, projectCount: 3)
            XCTAssertLessThan(size, maximum)
            XCTAssertGreaterThanOrEqual(size, 16)
            XCTAssertLessThanOrEqual(height(size), available)
            XCTAssertGreaterThan(height(size + 0.5), available, "Use the largest fitting half-point size")
            XCTAssertEqual(configuration.dockIconSize, maximum, "Fitting must not rewrite the saved size")
        }
    }

    func testHoverReserveBoundsGrowthAcrossWorkspaceSeparators() {
        for counts in [[0], [1], [0, 0], [2, 3], [4, 0, 2, 1]] {
            for size: CGFloat in [16, 32, 48] {
                for amount in [0.0, 0.25, 1.0] {
                    let reserve = WorkspaceSidebarDockColumnMagnification.maximumGrowth(
                        appCounts: counts, itemSize: size, amount: amount)
                    for pointer: CGFloat in stride(from: -200, through: 1_200, by: 13) {
                        let column = WorkspaceSidebarDockColumnMagnification(
                            appCounts: counts, itemSize: size, amount: amount, pointerY: pointer)
                        XCTAssertLessThanOrEqual(column.growth, reserve + 0.000_001)
                    }
                }
            }
        }
        XCTAssertEqual(WorkspaceSidebarDockColumnMagnification.maximumGrowth(appCounts: [], itemSize: 48, amount: 1), 0)
        XCTAssertEqual(WorkspaceSidebarDockColumnMagnification.maximumGrowth(appCounts: [0], itemSize: 48, amount: 1), 48, accuracy: 0.001)
    }

    func testMinimumKeepsExtremeColumnsScrollableAndSidebarUnchanged() {
        var configuration = fixture().configuration
        let size = workspaceSidebarFittedDockIconSize(appCounts: [100], configuration: configuration,
            availableHeight: 200, showsCreateWorkspace: true, showsMonitorSelector: false, projectCount: 1)
        XCTAssertEqual(size, 16)
        let icons = WorkspaceSidebarAppIconLayout(appCount: 100, availableWidth: 50, iconSize: size)
        XCTAssertEqual(icons.visibleAppCount, 100)
        XCTAssertGreaterThan(icons.height, 200)
        configuration.showAppIcons = false
        XCTAssertEqual(workspaceSidebarFittedDockIconSize(appCounts: [100], configuration: configuration,
            availableHeight: 200, showsCreateWorkspace: true, showsMonitorSelector: false, projectCount: 1), 48)
    }

    func testNativeLayoutFitsEveryIconAndRestoresConfiguredSizeOnResize() throws {
        let snapshot = fixture()
        let sample = render(snapshot, height: 340)
        let smallSize = WorkspaceSidebarView(snapshot: snapshot).dockLayout(availableHeight: 340).dockIconSize
        XCTAssertLessThan(smallSize, 48)
        try assertIcons(sample.probe, count: 8, size: smallSize, availableHeight: 340)
        for height: CGFloat in [700, 339, 340, 700] {
            sample.host.frame.size.height = height
            sample.host.layoutSubtreeIfNeeded()
            let expected = WorkspaceSidebarView(snapshot: snapshot).dockLayout(availableHeight: height).dockIconSize
            try assertIcons(sample.probe, count: 8, size: expected, availableHeight: height)
        }
        XCTAssertEqual(snapshot.configuration.dockIconSize, 48)
    }

    func testLiveAppCountChangesRefitWithoutPointerInput() throws {
        var snapshot = fixture()
        let sample = render(snapshot, height: 340)
        let initialSize = try XCTUnwrap(sample.probe.icons.first).width
        snapshot.workspaces = [workspace("1", appCount: 1), workspace("2", appCount: 1)]
        sample.host.rootView = AdaptiveSizingContent(snapshot: snapshot, probe: sample.probe)
        sample.host.layoutSubtreeIfNeeded()
        try assertIcons(sample.probe, count: 4, size: 48, availableHeight: 340)
        snapshot = fixture()
        sample.host.rootView = AdaptiveSizingContent(snapshot: snapshot, probe: sample.probe)
        sample.host.layoutSubtreeIfNeeded()
        try assertIcons(sample.probe, count: 8, size: initialSize, availableHeight: 340)
    }

    func testNativeControlsAndMagnificationUseFittedGeometry() throws {
        var snapshot = fixture()
        snapshot.configuration.showsClock = true
        snapshot.configuration.showsSeconds = true
        snapshot.configuration.dockMagnification = true
        snapshot.projects = [workspaceProjectDefaultId, WorkspaceProjectId("two"), WorkspaceProjectId("three")].map {
            .init(id: $0, displayName: $0.rawValue, colorHex: nil)
        }
        snapshot.monitorScopes = ["monitor:0.0,0.0", "monitor:1920.0,0.0"].map {
            .init(id: $0, displayName: $0, subtitle: nil, systemImageName: "display", isFocusedMonitor: false)
        }
        let view = WorkspaceSidebarView(snapshot: snapshot)
        let layout = view.dockLayout(availableHeight: 520)
        XCTAssertLessThan(layout.dockIconSize, 48)
        let sample = render(snapshot, height: 520)
        try assertIcons(sample.probe, count: 8, size: layout.dockIconSize, availableHeight: 520)
        let resting = try XCTUnwrap(sample.probe.icons.first)
        let pointer = CGPoint(x: resting.midX, y: resting.midY)
        sample.host.rootView = AdaptiveSizingContent(snapshot: snapshot, probe: sample.probe, pointer: pointer)
        sample.host.layoutSubtreeIfNeeded()
        let enlarged = try XCTUnwrap(sample.probe.icons.first)
        XCTAssertEqual(enlarged.width, resting.width * 1.5, accuracy: 0.01)
        XCTAssertEqual(enlarged.minX, resting.minX, accuracy: 0.01)
        XCTAssertEqual(view.dockLayout(availableHeight: 520), layout, "Hover must not refit the resting column")
    }

    func testMagnificationKeepsEveryFittedIconAboveBottomControls() throws {
        for amount in [0.25, 0.5, 1.0] {
            var snapshot = fixture()
            snapshot.configuration.dockMagnification = true
            snapshot.configuration.dockMagnificationAmount = amount
            let sample = render(snapshot, height: 340)
            let restingIcons = sample.probe.icons
            XCTAssertEqual(restingIcons.count, 8)
            for resting in restingIcons {
                for y in [resting.minY, resting.midY, resting.maxY - 0.25, resting.maxY + 2] {
                    sample.host.rootView = AdaptiveSizingContent(snapshot: snapshot, probe: sample.probe,
                        pointer: CGPoint(x: resting.midX, y: y))
                    sample.host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(sample.probe.icons.count, 8, "Hover must not push fitted icons below the viewport")
                    for frame in sample.probe.icons {
                        XCTAssertEqual(frame.height, frame.width, accuracy: 0.01,
                            "A shortened hit frame means the square icon was cut by the scroll viewport")
                    }
                }
            }
            if amount == 1, let path = ProcessInfo.processInfo.environment["WINMUX_DOCK_CAPTURE_DIRECTORY"] {
                let bitmap = try XCTUnwrap(sample.host.bitmapImageRepForCachingDisplay(in: sample.host.bounds))
                sample.host.cacheDisplay(in: sample.host.bounds, to: bitmap)
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("dock-bottom-hover.png"))
            }
        }
    }

    func testOtherProjectsAndFilteredDisplaysDoNotShrinkCurrentDock() {
        var snapshot = fixture()
        snapshot.workspaces = [workspace("1", appCount: 1), workspace("2", appCount: 20, project: "other"),
                               workspace("3", appCount: 20, scope: "display-b")]
        snapshot.selectedMonitorScopeId = "display-a"
        XCTAssertEqual(WorkspaceSidebarView(snapshot: snapshot).dockLayout(availableHeight: 340).dockIconSize, 48)
        snapshot.selectedMonitorScopeId = workspaceSidebarDefaultScopeId
        XCTAssertLessThan(WorkspaceSidebarView(snapshot: snapshot).dockLayout(availableHeight: 340).dockIconSize, 48)
        snapshot.configuration.showAppIcons = false
        XCTAssertEqual(WorkspaceSidebarView(snapshot: snapshot).dockLayout(availableHeight: 340), snapshot.configuration)
    }

    func testDragProjectionCannotResizeItsOwnHoverTargets() {
        var snapshot = fixture()
        let size = WorkspaceSidebarView(snapshot: snapshot).dockLayout(availableHeight: 340).dockIconSize
        snapshot.dockRestingAppCounts = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.name, $0.apps.count) })
        snapshot.workspaces[0].apps.removeLast()
        XCTAssertEqual(WorkspaceSidebarView(snapshot: snapshot).dockLayout(availableHeight: 340).dockIconSize, size)
        snapshot.workspaces[1].apps = sidebarAppIconsTestApps(count: 7)
        XCTAssertEqual(WorkspaceSidebarView(snapshot: snapshot).dockLayout(availableHeight: 340).dockIconSize, size)
        snapshot.dockRestingAppCounts = nil
        XCTAssertLessThan(WorkspaceSidebarView(snapshot: snapshot).dockLayout(availableHeight: 340).dockIconSize, size)
    }

    private func fixture() -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.workspaces = [workspace("1", appCount: 3), workspace("2", appCount: 3)]
        snapshot.visibleWidth = 64
        snapshot.targetMonitorScopeId = "display-a"
        snapshot.configuration.collapsedWidth = 64
        snapshot.configuration.configuredCollapsedWidth = 64
        snapshot.configuration.expandedWidth = 240
        snapshot.configuration.showAppIcons = true
        snapshot.configuration.chromeStyle = .solid
        return snapshot
    }

    private func workspace(_ name: String, appCount: Int, project: WorkspaceProjectId = workspaceProjectDefaultId,
                           scope: String = "display-a") -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: name, projectId: project, displayName: name, sidebarLabel: name, isGeneratedName: false,
              monitorScopeId: scope, monitorName: nil, isFocused: name == "1", isVisible: name == "1",
              items: [], apps: sidebarAppIconsTestApps(count: appCount))
    }

    private func render(_ snapshot: WorkspaceSidebarSnapshot, height: CGFloat)
        -> (host: NSHostingView<AdaptiveSizingContent>, probe: AdaptiveSizingProbe) {
        let probe = AdaptiveSizingProbe()
        let host = NSHostingView(rootView: AdaptiveSizingContent(snapshot: snapshot, probe: probe))
        host.frame = CGRect(x: 0, y: 0, width: 240, height: height)
        host.layoutSubtreeIfNeeded()
        return (host, probe)
    }

    private func assertIcons(_ probe: AdaptiveSizingProbe, count: Int, size: CGFloat, availableHeight: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(probe.icons.count, count, "Every app and workspace number must be visible", file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(probe.surface).width, 64, file: file, line: line)
        for frame in probe.icons {
            XCTAssertEqual(frame.width, size, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(frame.height, size, accuracy: 0.01, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, availableHeight, file: file, line: line)
        }
    }
}

@MainActor
private final class AdaptiveSizingProbe {
    var surface: CGRect?
    var icons: [CGRect] = []
}

private struct AdaptiveSizingContent: View {
    let snapshot: WorkspaceSidebarSnapshot
    let probe: AdaptiveSizingProbe
    var pointer: CGPoint? = nil

    var body: some View {
        WorkspaceSidebarView(snapshot: snapshot, actions: .init(setSurfaceFrame: { probe.surface = $0 }), reduceMotionOverride: false)
            .environment(\.workspaceSidebarDockPointer, pointer)
            .onPreferenceChange(WorkspaceSidebarDockIconFramesPreference.self) { probe.icons = $0 }
            .transaction { $0.disablesAnimations = true }
    }
}
