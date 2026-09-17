import AppKit
@testable import AppBundle
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
            print("DOCK_BENCHMARK workspaces=\(workspaceCount) appsPerWorkspace=4 samples=\(milliseconds.count) p50_ms=\(milliseconds[milliseconds.count / 2]) p95_ms=\(milliseconds[Int(Double(milliseconds.count) * 0.95)]) geometryUpdates=\(geometryUpdates)")
            XCTAssertGreaterThan(geometryUpdates, 1, "The benchmark must actually update magnified geometry")
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
private func dockBenchmarkSnapshot(workspaceCount: Int) -> WorkspaceSidebarSnapshot {
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
        let apps = sidebarAppIconsTestApps(count: 4)
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
