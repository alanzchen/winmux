import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarAppIconsRenderingTest: XCTestCase {
    func testNativePreviewShowsWorkspaceCardsAtAllSupportedWidths() throws {
        let widths: [CGFloat] = [28, 44, 120]
        let apps = [
            WorkspaceSidebarAppViewModel(name: "Safari", bundleId: "com.apple.Safari", bundlePath: nil),
            WorkspaceSidebarAppViewModel(name: "Terminal", bundleId: "com.apple.Terminal", bundlePath: nil),
            WorkspaceSidebarAppViewModel(name: "Notes", bundleId: "com.apple.Notes", bundlePath: nil),
            WorkspaceSidebarAppViewModel(name: "Finder", bundleId: "com.apple.finder", bundlePath: nil),
            WorkspaceSidebarAppViewModel(name: "Calendar", bundleId: "com.apple.iCal", bundlePath: nil),
        ]
        let preview = VStack(alignment: .leading, spacing: 16) {
            Text("Workspace app icons").font(.system(size: 20, weight: .semibold))
            Text("Compact rail: 28, 44, and 120 points").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 32) {
                ForEach(widths, id: \.self) { width in
                    VStack(spacing: 12) {
                        Text("\(Int(width)) pt").font(.system(size: 11, weight: .medium))
                        VStack(spacing: 8) {
                            self.previewSection(width: width, identifier: "1", apps: Array(apps.prefix(1)))
                            self.previewSection(width: width, identifier: "12", apps: apps)
                            self.previewSection(width: width, identifier: "104", apps: [])
                        }
                        .padding(.vertical, 10)
                        .frame(width: width)
                        .background(Color(red: 0.10, green: 0.11, blue: 0.14), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .frame(width: max(width, 64), alignment: .top)
                }
            }
        }
        .padding(24)
        .foregroundStyle(.white)
        .frame(width: 380, height: 350, alignment: .topLeading)
        .background(Color(red: 0.045, green: 0.05, blue: 0.065))
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: preview)
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 350)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try save(bitmap, name: "workspace-app-icons-preview")
    }

    func testCompactAppSummaryFitsMinimumDefaultAndWideRails() throws {
        for railWidth: CGFloat in [28, 44, 120] {
            let sectionWidth = railWidth - 14
            let innerInset = min(5, max((sectionWidth - 14) / 2, 0))
            let contentWidth = sectionWidth - innerInset * 2
            for appCount in [0, 1, 3, 6, 104] {
                var workspace = sidebarAppIconsTestWorkspace(displayName: "104")
                workspace.apps = sidebarAppIconsTestApps(count: appCount)
                let layout = WorkspaceSidebarAppIconLayout(appCount: appCount, availableWidth: contentWidth)
                let content = WorkspaceSidebarAppIconHeader(workspace: workspace, availableWidth: contentWidth, isActive: true)
                    .padding(.horizontal, innerInset)
                    .frame(width: sectionWidth)
                    .padding(.horizontal, 7)
                    .frame(width: railWidth, height: layout.height)
                    .padding(16)
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(x: 0, y: 0, width: railWidth + 32, height: layout.height + 32)
                host.layoutSubtreeIfNeeded()
                XCTAssertNil(host.window, "Rendering must not open or activate a window")
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try save(bitmap, name: "app-icons-rail-\(Int(railWidth))-count-\(appCount)")
                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                let allowed = CGRect(x: 15, y: 15, width: railWidth + 2, height: layout.height + 2)
                var painted = 0
                var overflow = 0
                for y in 0 ..< bitmap.pixelsHigh {
                    for x in 0 ..< bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.1 else { continue }
                        painted += 1
                        if !allowed.contains(CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale)) { overflow += 1 }
                    }
                }
                XCTAssertGreaterThan(painted, 10)
                XCTAssertEqual(overflow, 0, "\(appCount) apps must fit the \(railWidth)-point rail")
            }
        }
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String) throws {
        let directory = projectRoot.appendingPathComponent(".build/sidebar-appearance-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func previewSection(width: CGFloat, identifier: String, apps: [WorkspaceSidebarAppViewModel]) -> some View {
        var workspace = sidebarAppIconsTestWorkspace(displayName: identifier)
        workspace.apps = apps
        var layout = WorkspaceSidebarConfiguration.empty
        layout.collapsedWidth = width
        layout.expandedWidth = 240
        layout.showAppIcons = true
        layout.chromeStyle = .solid
        return WorkspaceSidebarWorkspaceSection(
            workspace: workspace,
            dragPreview: nil,
            expansionProgress: 0,
            layout: layout,
            emitsDropTarget: false,
            isFromOtherDisplay: false,
            isInUseOnOtherDisplay: false,
            isOnFocusedMonitor: true,
            allowsWorkspaceActivation: true,
            isPinnedActiveWorkspace: false,
            isActiveOnTargetMonitor: identifier == "1",
            projectContextLabel: nil,
            projectContextColor: nil,
            renamingWorkspaceName: .constant(nil),
            renamingWorkspaceText: .constant(""),
            onBeginRenameWorkspace: {},
            onCommitRenameWorkspace: {},
            onCancelRenameWorkspace: {},
            selectedSearchTarget: nil,
            isSearchFiltering: false,
            activeInUseOverrideWorkspaceName: .constant(nil),
            actions: .init(),
        )
        .padding(.horizontal, 7)
        .frame(width: width)
    }
}
