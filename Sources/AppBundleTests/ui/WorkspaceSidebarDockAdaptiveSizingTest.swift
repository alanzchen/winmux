import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarDockAdaptiveSizingTest: XCTestCase {
    func testNativeDockRestoresHitFramesAfterMagnificationIsReenabled() throws {
        var snapshot = fixture()
        snapshot.configuration.dockMagnification = true
        let sample = render(snapshot, height: 800)
        XCTAssertEqual(sample.probe.cachedIcons.count, 8)
        snapshot.configuration.dockMagnification = false
        sample.host.rootView = AdaptiveSizingContent(snapshot: snapshot, probe: sample.probe)
        sample.host.layoutSubtreeIfNeeded()
        XCTAssertTrue(sample.probe.cachedIcons.isEmpty)
        snapshot.configuration.dockMagnification = true
        sample.host.rootView = AdaptiveSizingContent(snapshot: snapshot, probe: sample.probe)
        sample.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(sample.probe.cachedIcons.count, 8)
        XCTAssertEqual(sample.probe.cachedIcons, sample.probe.icons)
    }

    func testRendererSwitchReplacesMagnifiedHitAndDropFramesOnEveryEdge() throws {
        for position: WorkspaceDockPosition in [.left, .right, .bottom] {
            var snapshot = fixture()
            snapshot.configuration.dockPosition = position
            snapshot.configuration.dockMagnification = true
            let sample = render(snapshot, height: 800)
            sample.host.frame.size.width = 800
            sample.host.layoutSubtreeIfNeeded()
            let resting = try XCTUnwrap(sample.probe.cachedIcons.first)
            sample.host.rootView = AdaptiveSizingContent(snapshot: snapshot, probe: sample.probe,
                pointer: CGPoint(x: resting.midX, y: resting.midY))
            sample.host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(try XCTUnwrap(sample.probe.cachedIcons.first).width, resting.width)

            snapshot.visibleWidth = snapshot.configuration.expandedWidth
            sample.host.rootView = AdaptiveSizingContent(snapshot: snapshot, probe: sample.probe)
            sample.host.layoutSubtreeIfNeeded()
            XCTAssertTrue(sample.probe.cachedIcons.isEmpty, "Expanded rows must discard compact icon hit regions")
            XCTAssertFalse(sample.probe.targets.isEmpty)

            snapshot.workspaces.removeLast()
            snapshot.visibleWidth = snapshot.configuration.expansionStartWidth
            sample.host.rootView = AdaptiveSizingContent(snapshot: snapshot, probe: sample.probe)
            sample.host.layoutSubtreeIfNeeded()
            XCTAssertEqual(sample.probe.cachedIcons.count, 4)
            XCTAssertTrue(sample.probe.targets.contains { $0.kind == .workspace("1") })
            XCTAssertFalse(sample.probe.targets.contains { $0.kind == .workspace("2") })
            XCTAssertEqual(try XCTUnwrap(sample.probe.cachedIcons.first).width, resting.width, accuracy: 0.01)
        }
    }

    func testConfiguredSizesKeepTheSameShelfRatioAndCenteredIcons() throws {
        for size: CGFloat in [24, 31, 40, 48] {
            var snapshot = fixture()
            snapshot.configuration.dockIconSize = size
            snapshot.visibleWidth = snapshot.configuration.compactRailWidth
            let sample = render(snapshot, height: 900)
            try assertIcons(sample.probe, count: 8, size: size, availableHeight: 900)
            let surface = try XCTUnwrap(sample.probe.surface)
            XCTAssertEqual(surface.minX, 0, accuracy: 0.01, "Fitting must not shift the surface within its panel")
            let icon = try XCTUnwrap(sample.probe.icons.first)
            XCTAssertEqual(icon.minX / size, 1 / 6, accuracy: 0.001)
        }
    }

    func testFittedShelfKeepsItsRestingWidthWhileProjectColumnsExpand() throws {
        let original = fixture()
        let fit = WorkspaceSidebarView(snapshot: original).dockLayout(availableHeight: 340)
        XCTAssertLessThan(fit.dockIconSize, original.configuration.dockIconSize)
        for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            var snapshot = original
            let start = snapshot.configuration.expansionStartWidth
            snapshot.visibleWidth = start + (snapshot.configuration.expandedWidth - start) * progress
            let sample = render(snapshot, height: 340)
            let surface = try XCTUnwrap(sample.probe.surface)
            XCTAssertEqual(surface.width, fit.compactRailWidth, accuracy: 0.01,
                "Floating project columns must not morph the Dock")
        }
    }

    func testPinnedFittedShelfMorphsContinuouslyToTheOriginalExpandedWidth() {
        var original = fixture()
        original.configuration.alwaysExpanded = true
        let fit = WorkspaceSidebarView(snapshot: original).dockLayout(availableHeight: 340)
        for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            var snapshot = original
            let start = snapshot.configuration.expansionStartWidth
            snapshot.visibleWidth = start + (snapshot.configuration.expandedWidth - start) * progress
            XCTAssertEqual(WorkspaceSidebarView(snapshot: snapshot).fittedVisibleWidth(layout: fit),
                fit.compactRailWidth + (snapshot.configuration.expandedWidth - fit.compactRailWidth) * progress,
                accuracy: 0.01)
        }
    }

    func testSmallestShelfKeepsTheIndicatorInsideAndUsesItsVisibleHoverRegion() {
        for size: CGFloat in [16, 24, 32, 48] {
            let rail = WorkspaceSidebarConfig.dockWidth(forIconSize: size)
            let leading = (rail - size) / 2
            let diameter = workspaceSidebarIndicatorDiameter(railWidth: rail)
            let dotLeft = leading + workspaceSidebarIndicatorLeadingOffset(tileSize: size, railWidth: rail)
            XCTAssertEqual(dotLeft + diameter / 2, leading / 2, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(dotLeft, 0)
            var settings = WorkspaceSidebarConfig()
            settings.mode = .dock
            XCTAssertTrue(settings.showAppIcons)
            let region = workspaceSidebarHoverRegion(surface: CGRect(x: 2, y: 100, width: rail, height: 400),
                displayMinX: 0, sidebarConfig: settings, exitTolerance: 0, fittedDockWidth: rail)
            XCTAssertEqual(region.width, rail)
            XCTAssertFalse(region.contains(CGPoint(x: rail + 3, y: 200)))
        }
    }

    func testAutoHiddenShelfRevealsProportionallyBeforeExpanding() throws {
        var snapshot = fixture()
        snapshot.configuration.collapsedWidth = 0
        let settings = WorkspaceSidebarConfig(autoHide: true, mode: .dock)
        let configuredWidth = snapshot.configuration.compactRailWidth
        for height: CGFloat in [280, 340, 900] {
            let fit = WorkspaceSidebarView(snapshot: snapshot).dockLayout(availableHeight: height)
            for progress: CGFloat in [0, 0.125, 0.25, 0.5, 0.75, 1] {
                snapshot.visibleWidth = configuredWidth * progress
                let sample = render(snapshot, height: height)
                let surface = try XCTUnwrap(sample.probe.surface)
                XCTAssertEqual(surface.width, fit.compactRailWidth * progress, accuracy: 0.01)
                let resting = try XCTUnwrap(sample.probe.restingWidth)
                XCTAssertEqual(resting, fit.compactRailWidth, accuracy: 0.01)
                let region = workspaceSidebarHoverRegion(surface: surface, displayMinX: 0, sidebarConfig: settings,
                    exitTolerance: 0, fittedDockWidth: resting)
                XCTAssertEqual(region.maxX, fit.compactRailWidth, accuracy: 0.01,
                    "The fitted hover target must stay stable throughout hide and reveal")
                XCTAssertTrue(region.contains(CGPoint(x: fit.compactRailWidth * 0.9, y: surface.midY)))
            }
        }
    }

    func testFittedMagnificationUsesMatchingOverflowAndCornerShape() {
        var snapshot = fixture()
        snapshot.configuration.dockMagnification = true
        let view = WorkspaceSidebarView(snapshot: snapshot)
        let fit = view.dockLayout(availableHeight: 340)
        XCTAssertLessThan(fit.dockIconSize, snapshot.configuration.dockIconSize)
        XCTAssertEqual(view.dockMagnificationOverflow(layout: fit), fit.dockMagnificationOverflow)
        let surface = CGRect(x: 0, y: 0, width: fit.compactRailWidth, height: 340)
        let fittedShape = RoundedRectangle(cornerRadius: fit.compactRailWidth / 3, style: .continuous).path(in: surface)
        for x: CGFloat in stride(from: 0, through: surface.maxX, by: 1) {
            for y: CGFloat in stride(from: 0, through: fit.compactRailWidth / 2, by: 1) {
                let point = CGPoint(x: x, y: y)
                XCTAssertEqual(view.dockMagnificationPointer(point, in: surface, layout: fit) != nil,
                    fittedShape.contains(point))
            }
        }
    }

    func testNativeDockProportionsPreview() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WINMUX_DOCK_PROPORTIONS_PREVIEW_DIRECTORY"] else {
            throw XCTSkip("Opt-in native Dock proportions preview")
        }
        let application = NSApplication.shared
        let oldPolicy = application.activationPolicy()
        application.setActivationPolicy(.accessory)
        let screen = try XCTUnwrap(NSScreen.main)
        let viewport = screen.visibleFrame
        let backing = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backing.isReleasedWhenClosed = false
        backing.contentView = NSHostingView(rootView: LinearGradient(colors: [.blue, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
        backing.orderFrontRegardless()
        var panels: [NSPanel] = []
        defer {
            for panel in panels { panel.close() }
            backing.close()
            application.setActivationPolicy(oldPolicy)
        }
        let icons = ["com.apple.finder", "com.apple.Safari", "com.apple.Terminal", "com.apple.Notes"].map { identifier in
            WorkspaceSidebarAppViewModel(name: identifier.components(separatedBy: ".").last!, bundleId: identifier,
                bundlePath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.path)
        }
        let panelWidth = (viewport.width - 80) / 4
        for (index, maximum) in [48, 32, 24, 48].enumerated() {
            var snapshot = fixture()
            snapshot.configuration.dockIconSize = CGFloat(maximum)
            snapshot.configuration.chromeStyle = .liquidGlass
            snapshot.configuration.showsClock = true
            snapshot.configuration.showsSeconds = true
            snapshot.visibleWidth = snapshot.configuration.compactRailWidth
            snapshot.workspaces[0].apps = index == 3 ? icons : Array(icons.prefix(1))
            snapshot.workspaces[1].apps = index == 3 ? icons : Array(icons.suffix(1))
            let height: CGFloat = index == 3 ? 240 : 400
            let fitted = WorkspaceSidebarView(snapshot: snapshot).dockLayout(availableHeight: height)
            let panel = NSPanel(contentRect: CGRect(x: viewport.minX + 20 + CGFloat(index) * (panelWidth + 20),
                y: viewport.minY + 4, width: panelWidth, height: 450),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 4) {
                Text(index == 3 ? "Adaptive" : "\(maximum) pt icons").font(.headline)
                Text("\(fitted.dockIconSize, specifier: "%.1f") / \(fitted.compactRailWidth, specifier: "%.1f") pt")
                    .font(.caption).monospacedDigit()
                WorkspaceSidebarView(snapshot: snapshot).frame(height: height)
                Spacer(minLength: 0)
            }.foregroundStyle(.white))
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        try await Task.sleep(for: .seconds(1))
        try "ready".write(toFile: directory + "/dock-preview-ready.txt", atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(20))
    }

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
        XCTAssertEqual(try XCTUnwrap(sample.probe.surface).width, layout.compactRailWidth, accuracy: 0.01,
            "Magnification must not widen the shelf")
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
        probe.host = host
        host.frame = CGRect(x: 0, y: 0, width: 240, height: height)
        host.layoutSubtreeIfNeeded()
        return (host, probe)
    }

    private func assertIcons(_ probe: AdaptiveSizingProbe, count: Int, size: CGFloat, availableHeight: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(probe.icons.count, count, "Every app and workspace number must be visible", file: file, line: line)
        let surface = try XCTUnwrap(probe.surface)
        XCTAssertEqual(try XCTUnwrap(probe.restingWidth), surface.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(surface.width / size, 4 / 3, accuracy: 0.001, file: file, line: line)
        for frame in probe.icons {
            XCTAssertEqual(frame.width, size, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(frame.height, size, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(frame.midX, surface.midX, accuracy: 0.01, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, availableHeight, file: file, line: line)
        }
    }
}

@MainActor
private final class AdaptiveSizingProbe {
    weak var host: NSView?
    var surface: CGRect?
    var restingWidth: CGFloat?
    var preferenceIcons: [CGRect] = []
    var cachedIcons: [CGRect] = []
    var targets: [WorkspaceSidebarDropTargetFrame] = []
    var icons: [CGRect] {
        func nativeDock(in view: NSView) -> WorkspaceSidebarNativeDockView? {
            if let dock = view as? WorkspaceSidebarNativeDockView { return dock }
            return view.subviews.lazy.compactMap { nativeDock(in: $0) }.first
        }
        // The layer renderer owns its geometry directly, including when the lens
        // is disabled. The expanded SwiftUI renderer still emits preferences.
        if let host, let geometry = nativeDock(in: host)?.geometry { return geometry.icons.flatMap { $0 } }
        return preferenceIcons
    }
}

private struct AdaptiveSizingContent: View {
    let snapshot: WorkspaceSidebarSnapshot
    let probe: AdaptiveSizingProbe
    var pointer: CGPoint? = nil

    var body: some View {
        WorkspaceSidebarView(snapshot: snapshot, actions: .init(setDropTargets: { probe.targets = $0 },
            setSurfaceFrame: { probe.surface = $0 }, setDockRestingWidth: { probe.restingWidth = $0 },
            setDockIconFrames: { probe.cachedIcons = $0 }), reduceMotionOverride: false)
            .environment(\.workspaceSidebarDockPointer, pointer)
            .onPreferenceChange(WorkspaceSidebarDockIconFramesPreference.self) { probe.preferenceIcons = $0 }
            .transaction { $0.disablesAnimations = true }
    }
}
