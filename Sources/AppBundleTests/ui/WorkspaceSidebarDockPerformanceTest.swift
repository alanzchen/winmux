import AppKit
@testable import AppBundle
import QuartzCore
import SwiftUI
import XCTest

/// Opt-in CPU/layout benchmark; this does not claim to measure displayed GPU FPS.
@MainActor
final class WorkspaceSidebarDockPerformanceTest: XCTestCase {
    func testPerformanceCaptureOverhead() throws {
        guard ProcessInfo.processInfo.environment["WINMUX_DOCK_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in numeric recorder overhead measurement")
        }
        var microseconds: [Double] = []
        for enabled in [false, true] {
            let view = WorkspaceSidebarDockDisplayLinkView()
            view.performanceTrace = enabled ? DockPerformanceTrace() : nil
            view.onFrame = { _ in }
            let start = CACurrentMediaTime()
            for step in 0..<20_000 {
                let now = CACurrentMediaTime()
                view.receive(CGPoint(x: 32, y: 100 + step % 300))
                view.advance(to: now + 1 / 120, displayTimestamp: now, displayDuration: 1 / 120)
                view.performanceTrace?.beforeWaiting(at: CACurrentMediaTime())
            }
            microseconds.append((CACurrentMediaTime() - start) * 1_000_000 / 20_000)
        }
        print("DOCK_CAPTURE_OVERHEAD disabled_us=\(microseconds[0]) enabled_us=\(microseconds[1]) added_us=\(microseconds[1] - microseconds[0])")
    }

    /// Runs through the production native event handler and ordinary deferred layout. Unlike the
    /// layout microbenchmark, neither input nor layout is driven by a frame callback.
    func testNativeHoverCapture() async throws {
        guard ProcessInfo.processInfo.environment["WINMUX_DOCK_INPUT_BENCHMARK"] == "1" else {
            throw XCTSkip("Run with WINMUX_DOCK_INPUT_BENCHMARK=1 on an unlocked test desktop")
        }
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { throw XCTSkip("Display is asleep") }
        let systemInput = ProcessInfo.processInfo.environment["WINMUX_DOCK_SYSTEM_INPUT"] == "1"
        if systemInput && !CGPreflightPostEventAccess() { throw XCTSkip("WindowServer input posting is not permitted") }
        let screen = try XCTUnwrap(NSScreen.main)
        let quartzOriginY = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let application = NSApplication.shared
        var localPackets = 0
        var globalPackets = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            MainActor.assumeIsolated { localPackets += 1 }
            GlobalObserver.onPointerActivity(event)
            return event
        }
        let globalMonitor = systemInput ? NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { event in
            MainActor.assumeIsolated { globalPackets += 1 }
            GlobalObserver.onPointerActivity(event)
        } : nil
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        }
        let previousConfig = config
        let previouslyEnabled = TrayMenuModel.shared.isEnabled
        let previousPointer = NSEvent.mouseLocation
        let previousActivationPolicy = application.activationPolicy()
        defer {
            DockPerformanceRecorder.shared.stop()
            for panel in WorkspaceSidebarPanel.visiblePanels { panel.resetHiddenSidebarState() }
            config = previousConfig
            TrayMenuModel.shared.isEnabled = previouslyEnabled
            NSApp.setActivationPolicy(previousActivationPolicy)
            CGWarpMouseCursorPosition(CGPoint(x: previousPointer.x, y: quartzOriginY - previousPointer.y))
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
        var snapshot = dockBenchmarkSnapshot(appCounts: [8, 0], usesInstalledIcons: true)
        snapshot.configuration.chromeStyle = .liquidGlass
        snapshot.configuration.showsClock = ProcessInfo.processInfo.environment["WINMUX_DOCK_BENCHMARK_CLOCK"] == "1"
        snapshot.configuration.showsSeconds = snapshot.configuration.showsClock
        let model = panel.viewModel
        model.workspaceSidebarWorkspaces = snapshot.workspaces
        model.workspaceSidebarProjects = []
        model.workspaceSidebarActiveProjectId = snapshot.activeProjectId
        model.workspaceSidebarSelectedMonitorScopeId = snapshot.selectedMonitorScopeId
        model.workspaceSidebarAppearance = snapshot.configuration
        model.workspaceSidebarVisibleWidth = snapshot.visibleWidth
        let height = min(screen.visibleFrame.height - 40, 1_000)
        panel.setFrame(CGRect(x: screen.frame.maxX - 180, y: screen.visibleFrame.midY - height / 2,
            width: 140, height: height), display: true)
        panel.acceptsMouseMovedEvents = true
        panel.orderFrontRegardless()
        panel.hostingView.layoutSubtreeIfNeeded() // Initial layout only.
        // Exercise a non-key Dock while our app is active, then while Finder is
        // active. Synthetic postEvent delivery alone cannot verify this contract.
        let keyWindow = NSWindow(contentRect: CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY,
            width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        keyWindow.isReleasedWhenClosed = false
        defer { keyWindow.close() }
        if systemInput {
            keyWindow.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
        }
        var switchedApplication = false
        let recorder = DockPerformanceRecorder.shared
        recorder.start()
        let started = CACurrentMediaTime()
        var events = 0
        var injectionTimes: [Double] = []
        injectionTimes.reserveCapacity(2_400)
        // A separate input timer creates rapid sweeps, reversals and periodic exits. It fires on the
        // main run loop and touches the panel only inside assumeIsolated.
        nonisolated(unsafe) let timerPanel = panel
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                let inputStart = CACurrentMediaTime()
                let elapsed = CACurrentMediaTime() - started
                if systemInput && elapsed > 7 && !switchedApplication {
                    switchedApplication = true
                    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?
                        .activate(options: [])
                }
                let phase = elapsed.truncatingRemainder(dividingBy: 1.5) / 1.5
                let fraction = phase < 0.5 ? phase * 2 : 2 - phase * 2
                let surface = timerPanel.visibleSurfaceFrameOnScreen
                let exit = Int(elapsed).isMultiple(of: 5) && elapsed > 1
                let screenPoint = CGPoint(x: surface.minX + (exit ? -12 : 32),
                    y: surface.minY + 45 + fraction * max(surface.height - 90, 1))
                // Quartz global coordinates start at the main display's top-left.
                let quartzPoint = CGPoint(x: screenPoint.x, y: quartzOriginY - screenPoint.y)
                if systemInput {
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: quartzPoint,
                        mouseButton: .left)?.post(tap: .cghidEventTap)
                } else {
                    CGWarpMouseCursorPosition(quartzPoint)
                    let event = NSEvent.mouseEvent(with: .mouseMoved,
                        location: timerPanel.convertPoint(fromScreen: screenPoint), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: timerPanel.windowNumber,
                        context: nil, eventNumber: events, clickCount: 0, pressure: 0)
                    if let event { NSApp.postEvent(event, atStart: false) }
                }
                events += 1
                injectionTimes.append((CACurrentMediaTime() - inputStart) * 1_000)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        application.setActivationPolicy(.accessory)
        let timeout = Timer(timeInterval: 15, repeats: false) { _ in
            MainActor.assumeIsolated {
                application.stop(nil)
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    subtype: 0, data1: 0, data2: 0) { application.postEvent(event, atStart: true) }
            }
        }
        RunLoop.main.add(timeout, forMode: .common)
        application.run()
        timer.invalidate()
        timeout.invalidate()
        recorder.stop()
        let deadline = Date().addingTimeInterval(5)
        while recorder.isSaving && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let file = try XCTUnwrap(recorder.lastReport)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DockPerformanceReport.self, from: Data(contentsOf: file))
        let frames = report.panels.reduce(0) { $0 + $1.summary.changedPoses }
        XCTAssertGreaterThan(frames, 100, "Native input must drive the display link without direct receive calls")
        XCTAssertGreaterThan(report.panels.reduce(0) { $0 + ($1.input?.acceptedNativeEvents ?? 0) }, 100)
        XCTAssertGreaterThan(report.panels.reduce(0) { $0 + ($1.input?.changedNativeTargets ?? 0) }, 100)
        if systemInput {
            XCTAssertGreaterThan(localPackets, 100, "The non-key Dock must receive native movement in our app")
            XCTAssertGreaterThan(globalPackets, 100, "Movement must also reach the monitor while another app is active")
        }
        injectionTimes.sort()
        print("DOCK_INPUT_BENCHMARK systemInput=\(systemInput) events=\(events) local=\(localPackets) global=\(globalPackets) changedPoses=\(frames) panels=\(report.panels.count) injection_p99_ms=\(injectionTimes[Int(Double(injectionTimes.count - 1) * 0.99)]) report=\(file.path)")
        if let destination = ProcessInfo.processInfo.environment["WINMUX_DOCK_CAPTURE_DIR"] {
            try FileManager.default.copyItem(at: file,
                to: URL(fileURLWithPath: destination).appendingPathComponent(file.lastPathComponent))
        }
    }

    func testPointerSweepBenchmark() throws {
        guard ProcessInfo.processInfo.environment["WINMUX_DOCK_BENCHMARK"] == "1" else {
            throw XCTSkip("Run with WINMUX_DOCK_BENCHMARK=1 to measure hover layout work")
        }
        let rapid = ProcessInfo.processInfo.environment["WINMUX_DOCK_SWEEP"] == "rapid"
        for counts in [[8, 0], [4, 4, 4], Array(repeating: 4, count: 8)] {
            let driver = DockBenchmarkPointer()
            let snapshot = dockBenchmarkSnapshot(appCounts: counts)
            var geometryUpdates = 0
            let actions = WorkspaceSidebarActions(setDockIconFrames: { _ in geometryUpdates += 1 })
            let host = NSHostingView(rootView: DockBenchmarkRoot(snapshot: snapshot, actions: actions, driver: driver))
            host.frame = CGRect(x: 0, y: 0, width: 480, height: 900)
            host.layoutSubtreeIfNeeded()
            var milliseconds: [Double] = []
            for step in 0..<140 {
                let start = CFAbsoluteTimeGetCurrent()
                let phase = step % 24
                let y = rapid ? 170 + Double(phase < 12 ? phase : 24 - phase) * 40 : 170 + Double(step % 100) * 5
                driver.point = CGPoint(x: 32, y: y)
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                if step >= 20 { milliseconds.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }
            }
            milliseconds.sort()
            print("DOCK_BENCHMARK rapid=\(rapid) appCounts=\(counts) samples=\(milliseconds.count) p50_ms=\(milliseconds[milliseconds.count / 2]) p95_ms=\(milliseconds[Int(Double(milliseconds.count) * 0.95)]) p99_ms=\(milliseconds[Int(Double(milliseconds.count) * 0.99)]) max_ms=\(milliseconds.last!) geometryUpdates=\(geometryUpdates)")
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
        let rapid = ProcessInfo.processInfo.environment["WINMUX_DOCK_SWEEP"] == "rapid"
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
            var snapshot = dockBenchmarkSnapshot(appCounts: Array(repeating: 4, count: workspaceCount), usesInstalledIcons: true)
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
                if rapid {
                    // High-rate pointer packets still produce only one pose per display tick.
                    for packet in 0..<8 {
                        let phase = Double((count * 8 + packet) % 192) / 8
                        clock.receive(CGPoint(x: 32, y: 170 + (phase < 12 ? phase : 24 - phase) * 40))
                    }
                } else {
                    let phase = Double(count) / Double(max(screen.maximumFramesPerSecond, 1))
                    clock.receive(CGPoint(x: 32, y: 400 + 180 * sin(phase * 3)))
                }
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
            print("DOCK_NATIVE_BENCHMARK rapid=\(rapid) real_panel=true workspaces=\(workspaceCount) display_max_fps=\(screen.maximumFramesPerSecond) callbacks_fps=\(fps) missed_intervals=\(misses) samples=\(layoutTimes.count) layout_p95_ms=\(layoutTimes[Int(Double(layoutTimes.count) * 0.95)]) layout_p99_ms=\(layoutTimes[Int(Double(layoutTimes.count) * 0.99)]) layout_max_ms=\(layoutTimes.last!) interval_p99_ms=\(intervals[Int(Double(intervals.count) * 0.99)]) delivery_p99_ms=\(deliveryIntervals[Int(Double(deliveryIntervals.count) * 0.99)]) delivery_max_ms=\(deliveryIntervals.last!)")
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
private func dockBenchmarkSnapshot(appCounts: [Int], usesInstalledIcons: Bool = false) -> WorkspaceSidebarSnapshot {
    var snapshot = WorkspaceSidebarSnapshot.empty
    snapshot.visibleWidth = 64
    snapshot.configuration.collapsedWidth = 64
    snapshot.configuration.configuredCollapsedWidth = 64
    snapshot.configuration.expandedWidth = 240
    snapshot.configuration.showAppIcons = true
    snapshot.configuration.chromeStyle = .solid
    snapshot.configuration.dockMagnification = true
    snapshot.configuration.dockMagnificationAmount = 1
    snapshot.workspaces = appCounts.enumerated().map { offset, count in
        let index = offset + 1
        let apps = usesInstalledIcons ? [
            ("Safari", "com.apple.Safari"), ("Terminal", "com.apple.Terminal"),
            ("TextEdit", "com.apple.TextEdit"), ("Settings", "com.apple.systempreferences"),
            ("Preview", "com.apple.Preview"), ("Messages", "com.apple.MobileSMS"),
            ("Calendar", "com.apple.iCal"), ("Contacts", "com.apple.AddressBook"),
        ].prefix(count).map { name, bundle in
            WorkspaceSidebarAppViewModel(name: name, bundleId: bundle,
                bundlePath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.path)
        } : sidebarAppIconsTestApps(count: count)
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
