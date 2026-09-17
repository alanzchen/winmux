import AppKit
@testable import AppBundle
import QuartzCore
import SwiftUI
import XCTest

/// Opt-in CPU/layout benchmark; this does not claim to measure displayed GPU FPS.
@MainActor
final class WorkspaceSidebarDockPerformanceTest: XCTestCase {
    func testPointerSweepBenchmark() throws {
        guard ProcessInfo.processInfo.environment["WINMUX_DOCK_BENCHMARK"] == "1" else {
            throw XCTSkip("Run with WINMUX_DOCK_BENCHMARK=1 to measure hover layout work")
        }
        for workspaceCount in [3, 8] {
            let driver = DockBenchmarkPointer()
            let snapshot = dockBenchmarkSnapshot(workspaceCount: workspaceCount)
            var geometryUpdates = 0
            let actions = WorkspaceSidebarActions(setDockIconFrames: { _ in geometryUpdates += 1 })
            let host = NSHostingView(rootView: DockBenchmarkRoot(snapshot: snapshot, actions: actions, driver: driver))
            host.frame = CGRect(x: 0, y: 0, width: 480, height: 900)
            host.layoutSubtreeIfNeeded()
            var milliseconds: [Double] = []
            for step in 0..<140 {
                let start = CFAbsoluteTimeGetCurrent()
                driver.point = CGPoint(x: 32, y: 170 + Double(step % 100) * 5)
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                if step >= 20 { milliseconds.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }
            }
            milliseconds.sort()
            print("DOCK_BENCHMARK workspaces=\(workspaceCount) appsPerWorkspace=4 samples=\(milliseconds.count) p50_ms=\(milliseconds[milliseconds.count / 2]) p95_ms=\(milliseconds[Int(Double(milliseconds.count) * 0.95)]) p99_ms=\(milliseconds[Int(Double(milliseconds.count) * 0.99)]) max_ms=\(milliseconds.last!) geometryUpdates=\(geometryUpdates)")
            XCTAssertGreaterThan(geometryUpdates, 1, "The benchmark must actually update magnified geometry")
        }
    }

    /// Measures the real display-link path and layout deadlines in a visible glass Dock.
    /// Callback cadence is not proof that the GPU presented every frame.
    func testNativeDisplayPacingBenchmark() throws {
        guard ProcessInfo.processInfo.environment["WINMUX_DOCK_NATIVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Run with WINMUX_DOCK_NATIVE_BENCHMARK=1 on a physical display")
        }
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
            throw XCTSkip("Wake and unlock the display before measuring native frame pacing")
        }
        let screen = try XCTUnwrap(NSScreen.main)
        let previousConfig = config
        let previouslyEnabled = TrayMenuModel.shared.isEnabled
        defer {
            for panel in WorkspaceSidebarPanel.visiblePanels { panel.resetHiddenSidebarState() }
            config = previousConfig
            TrayMenuModel.shared.isEnabled = previouslyEnabled
        }
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .dock
        config.workspaceSidebar.alwaysExpanded = false
        config.workspaceSidebar.autoHide = false
        config.workspaceSidebar.dockMagnification = true
        config.workspaceSidebar.dockMagnificationAmount = 1
        TrayMenuModel.shared.isEnabled = true
        WorkspaceSidebarPanel.refreshAll()
        let panel = try XCTUnwrap(WorkspaceSidebarPanel.visiblePanels.first)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let stopRunLoop: @MainActor @Sendable () -> Void = {
            application.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0) {
                application.postEvent(event, atStart: true)
            }
        }
        for workspaceCount in [3, 8] {
            var snapshot = dockBenchmarkSnapshot(workspaceCount: workspaceCount, usesInstalledIcons: true)
            snapshot.configuration.chromeStyle = .liquidGlass
            let model = panel.viewModel
            model.workspaceSidebarWorkspaces = snapshot.workspaces
            model.workspaceSidebarProjects = []
            model.workspaceSidebarActiveProjectId = snapshot.activeProjectId
            model.workspaceSidebarSelectedMonitorScopeId = snapshot.selectedMonitorScopeId
            model.workspaceSidebarAppearance = snapshot.configuration
            model.workspaceSidebarVisibleWidth = snapshot.visibleWidth
            // Keep the production hosting view and actions adapter: preference changes
            // must exercise native hit geometry and deferred hover/passthrough work.
            let host = panel.hostingView
            let height = min(screen.visibleFrame.height - 40, 1_000)
            panel.setFrame(CGRect(x: screen.frame.maxX - 160, y: screen.visibleFrame.midY - height / 2,
                width: 140, height: height), display: true)
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            func displayView(in view: NSView) -> WorkspaceSidebarDockDisplayLinkView? {
                if let view = view as? WorkspaceSidebarDockDisplayLinkView { return view }
                return view.subviews.lazy.compactMap { displayView(in: $0) }.first
            }
            let clock = try XCTUnwrap(displayView(in: host))
            defer {
                clock.frameObserver = nil
                clock.reset()
                panel.orderOut(nil)
            }
            var timestamps: [Double] = []
            var arrivals: [Double] = []
            var layoutTimes: [Double] = []
            var count = 0
            clock.frameObserver = { timestamp in
                let start = CACurrentMediaTime()
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                if count >= 30 {
                    timestamps.append(timestamp)
                    arrivals.append(start)
                    layoutTimes.append((CACurrentMediaTime() - start) * 1_000)
                }
                count += 1
                // A changing root snapshot exercises the occasional-update path too.
                if count.isMultiple(of: 60) {
                    model.workspaceSidebarHoveredWorkspaceName = count.isMultiple(of: 120) ? "1" : "2"
                }
                let phase = Double(count) / Double(max(screen.maximumFramesPerSecond, 1))
                clock.receive(CGPoint(x: 32, y: 400 + 180 * sin(phase * 3)))
                if count >= screen.maximumFramesPerSecond * 4 + 30 { stopRunLoop() }
            }
            clock.receive(CGPoint(x: 32, y: 400))
            // Exercise AppKit's normal event loop while the visible fixture animates.
            let timeout = Timer(timeInterval: 8, repeats: false) { _ in
                MainActor.assumeIsolated { stopRunLoop() }
            }
            RunLoop.main.add(timeout, forMode: .common)
            application.run()
            timeout.invalidate()
            XCTAssertFalse(panel.localDropTargetFrames.isEmpty, "Measure real native drop-target callbacks")
            XCTAssertFalse(panel.dockIconFrames.isEmpty, "Measure real native icon-region callbacks")
            XCTAssertGreaterThan(timestamps.count, 60, "The visible Dock must receive real display callbacks")
            guard timestamps.count > 1 else { continue }
            let intervals = zip(timestamps.dropFirst(), timestamps).map { ($0 - $1) * 1_000 }.sorted()
            let deliveryIntervals = zip(arrivals.dropFirst(), arrivals).map { ($0 - $1) * 1_000 }.sorted()
            layoutTimes.sort()
            let budget = 1_000 / Double(screen.maximumFramesPerSecond)
            let misses = intervals.filter { $0 > budget * 1.5 }.count
            let fps = Double(timestamps.count - 1) / (timestamps.last! - timestamps.first!)
            print("DOCK_NATIVE_BENCHMARK real_panel=true workspaces=\(workspaceCount) display_max_fps=\(screen.maximumFramesPerSecond) callbacks_fps=\(fps) missed_intervals=\(misses) samples=\(layoutTimes.count) layout_p95_ms=\(layoutTimes[Int(Double(layoutTimes.count) * 0.95)]) layout_p99_ms=\(layoutTimes[Int(Double(layoutTimes.count) * 0.99)]) layout_max_ms=\(layoutTimes.last!) interval_p99_ms=\(intervals[Int(Double(intervals.count) * 0.99)]) delivery_p99_ms=\(deliveryIntervals[Int(Double(deliveryIntervals.count) * 0.99)]) delivery_max_ms=\(deliveryIntervals.last!)")
        }
    }
}

@MainActor
private final class DockBenchmarkPointer: ObservableObject {
    @Published var point: CGPoint?
}

private struct DockBenchmarkRoot: View {
    let snapshot: WorkspaceSidebarSnapshot
    let actions: WorkspaceSidebarActions
    @ObservedObject var driver: DockBenchmarkPointer
    var body: some View {
        WorkspaceSidebarView(snapshot: snapshot, actions: actions, reduceMotionOverride: false)
            .environment(\.workspaceSidebarDockPointer, driver.point)
    }
}

@MainActor
private func dockBenchmarkSnapshot(workspaceCount: Int, usesInstalledIcons: Bool = false) -> WorkspaceSidebarSnapshot {
    var snapshot = WorkspaceSidebarSnapshot.empty
    snapshot.visibleWidth = 64
    snapshot.configuration.collapsedWidth = 64
    snapshot.configuration.configuredCollapsedWidth = 64
    snapshot.configuration.expandedWidth = 240
    snapshot.configuration.showAppIcons = true
    snapshot.configuration.chromeStyle = .solid
    snapshot.configuration.dockMagnification = true
    snapshot.configuration.dockMagnificationAmount = 1
    snapshot.workspaces = (1...workspaceCount).map { index in
        let apps = usesInstalledIcons ? [
            ("Safari", "com.apple.Safari"), ("Terminal", "com.apple.Terminal"),
            ("TextEdit", "com.apple.TextEdit"), ("Settings", "com.apple.systempreferences"),
        ].map { name, bundle in
            WorkspaceSidebarAppViewModel(name: name, bundleId: bundle,
                bundlePath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.path)
        } : sidebarAppIconsTestApps(count: 4)
        return WorkspaceSidebarWorkspaceViewModel(name: "\(index)", projectId: workspaceProjectDefaultId,
            displayName: "\(index)", sidebarLabel: "", isGeneratedName: false,
            monitorScopeId: workspaceSidebarDefaultScopeId, monitorName: nil,
            isFocused: index == 1, isVisible: index == 1,
            items: apps.enumerated().map { offset, app in
                .init(kind: .window(.init(windowId: UInt32(index * 10 + offset), workspaceName: "\(index)",
                    appName: app.name, appBundleId: app.bundleId, appBundlePath: app.bundlePath,
                    title: "A document with a window title", isFocused: false)))
            }, apps: apps)
    }
    return snapshot
}
