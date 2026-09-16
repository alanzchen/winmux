import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarMorphRenderingTest: XCTestCase {
    private let progressValues: [CGFloat] = [0, 0.25, 0.57, 0.59, 0.75, 1]

    func testNativeSectionHeightMorphsContinuouslyForEmptySingleAndGroupedWorkspaces() throws {
        let fixtures: [(String, WorkspaceSidebarWorkspaceViewModel, CGFloat, CGFloat)] = [
            ("empty", workspace(appCount: 0), 38, 40),
            ("single", workspace(appCount: 1), 46, 67),
            ("grouped", workspace(appCount: 6, tabGroup: true), 97, 219),
        ]
        for (name, workspace, compactHeight, expandedHeight) in fixtures {
            var heights: [CGFloat: CGFloat] = [:]
            for progress in progressValues {
                let sample = renderSection(workspace, progress: progress)
                heights[progress] = sample.size.height
                XCTAssertNil(sample.host.window, "Offscreen measurement must not open or activate a window")
                // NSHostingView rounds fractional fitting dimensions up to whole AppKit points.
                XCTAssertEqual(sample.size.width, sample.section.sectionWidth.rounded(.up), accuracy: 0.01)
                XCTAssertEqual(
                    sample.size.height,
                    compactHeight + (expandedHeight - compactHeight) * progress,
                    accuracy: 1,
                    "\(name) at \(progress) must interpolate the measured endpoint heights",
                )
            }
            let beforeThreshold = try XCTUnwrap(heights[0.57])
            let afterThreshold = try XCTUnwrap(heights[0.59])
            XCTAssertLessThan(
                abs(afterThreshold - beforeThreshold),
                4,
                "\(name) must not swap complete layouts at the former 0.58 reveal threshold",
            )
        }
    }

    func testNativeCompactWidthAndIconAnchorsStayFixedThroughoutExpansion() throws {
        for appCount in [1, 3, 6] {
            let workspace = workspace(appCount: appCount, tabGroup: appCount > 3)
            let compact = renderSection(workspace, progress: 0)
            XCTAssertEqual(compact.size.width + 14, 44, accuracy: 0.01)
            let compactTitle = try XCTUnwrap(compact.frames[.compactTitle])
            let visibleApps = workspace.apps.prefix(3)
            for progress in progressValues {
                let sample = renderSection(workspace, progress: progress)
                let title = try XCTUnwrap(sample.frames[.compactTitle])
                XCTAssertEqual(title.width, compactTitle.width, accuracy: 0.01)
                XCTAssertEqual(title.height, compactTitle.height, accuracy: 0.01)
                for app in visibleApps {
                    let initial = try XCTUnwrap(compact.frames[.compactApp(app.id)])
                    let current = try XCTUnwrap(sample.frames[.compactApp(app.id)])
                    let destination = try XCTUnwrap(sample.frames[.expandedApp(app.id)])
                    XCTAssertEqual(current.width, initial.width, accuracy: 0.01)
                    XCTAssertEqual(current.height, initial.height, accuracy: 0.01)
                    XCTAssertEqual(current.midX - title.midX, initial.midX - compactTitle.midX, accuracy: 0.01)
                    XCTAssertEqual(current.midY - title.midY, initial.midY - compactTitle.midY, accuracy: 0.01)
                    XCTAssertGreaterThan(destination.width, 0)
                    XCTAssertGreaterThan(destination.height, 0)
                    XCTAssertTrue(destination.midX.isFinite && destination.midY.isFinite)
                }
                XCTAssertNotNil(sample.frames[.expandedTitle], "Both title endpoints must remain mounted")
            }
        }
    }

    func testNativeLongWorkspaceNamesFitMinimumAndDefaultExpandedWidths() throws {
        let workspace = workspace(appCount: 3, displayName: "Research and Development")
        for expandedWidth: CGFloat in [160, 240] {
            for progress in progressValues {
                let sample = renderSection(workspace, progress: progress, expandedWidth: expandedWidth)
                let compactTitle = try XCTUnwrap(sample.frames[.compactTitle])
                let expandedTitle = try XCTUnwrap(sample.frames[.expandedTitle])
                XCTAssertGreaterThan(compactTitle.width, 0)
                if progress == 1 {
                    XCTAssertGreaterThan(expandedTitle.width, 0)
                    XCTAssertLessThanOrEqual(expandedTitle.maxX, sample.size.width + 0.5)
                }
                XCTAssertEqual(sample.size.width, sample.section.sectionWidth.rounded(.up), accuracy: 0.01)
            }
            let compact = renderSection(workspace, progress: 0, expandedWidth: expandedWidth)
            XCTAssertEqual(compact.size.width + 14, 44, accuracy: 0.01)
        }
    }

    func testNumericWorkspaceTitleRemainsReadableDuringNativeMorph() throws {
        let workspace = workspace(appCount: 3)
        for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let sample = renderSection(workspace, progress: progress)
            let compact = try XCTUnwrap(sample.frames[.compactTitle])
            let expanded = try XCTUnwrap(sample.frames[.expandedTitle])
            let titleRect = CGRect(
                x: compact.minX + (expanded.minX - compact.minX) * progress,
                y: compact.minY + (expanded.minY - compact.minY) * progress,
                width: compact.width + (expanded.width - compact.width) * progress,
                height: compact.height + (expanded.height - compact.height) * progress,
            )
            let bitmap = try XCTUnwrap(sample.host.bitmapImageRepForCachingDisplay(in: sample.host.bounds))
            sample.host.cacheDisplay(in: sample.host.bounds, to: bitmap)
            let scaleX = CGFloat(bitmap.pixelsWide) / sample.host.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / sample.host.bounds.height
            let pixelRect = CGRect(
                x: titleRect.minX * scaleX,
                y: titleRect.minY * scaleY,
                width: titleRect.width * scaleX,
                height: titleRect.height * scaleY,
            ).integral.intersection(CGRect(x: 0, y: 0, width: CGFloat(bitmap.pixelsWide), height: CGFloat(bitmap.pixelsHigh)))
            var brightRows: [Int] = []
            for y in Int(pixelRect.minY) ..< Int(pixelRect.maxY) {
                for x in Int(pixelRect.minX) ..< Int(pixelRect.maxX) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.alphaComponent > 0.85,
                          min(color.redComponent, min(color.greenComponent, color.blueComponent)) > 0.82
                    else { continue }
                    brightRows.append(y)
                    break
                }
            }
            let textSpan = brightRows.first.flatMap { first in
                brightRows.last.map { CGFloat($0 - first + 1) / scaleY }
            } ?? 0
            // Numerals have tall strokes; a substituted ellipsis paints only a few bottom rows.
            // Requiring opaque, bright pixels excludes the translucent card edge and background.
            XCTAssertGreaterThan(
                textSpan,
                6,
                "Workspace 12 must remain numerals at progress \(progress); compact=\(compact), expanded=\(expanded), crop=\(titleRect)",
            )
            let image = try XCTUnwrap(bitmap.cgImage?.cropping(to: pixelRect))
            let crop = NSBitmapImageRep(cgImage: image)
            let directory = projectRoot.appendingPathComponent(".build/sidebar-morph-ui", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(crop.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("numeric-title-morph-\(Int(progress * 100)).png"))
        }
    }

    func testNativePreviewShowsActualRowsMorphingFromCompactAppIcons() throws {
        let workspace = workspace(appCount: 3)
        let namedWorkspace = self.workspace(appCount: 3, displayName: "Research and Development")
        let progressValues: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
        let preview = VStack(alignment: .leading, spacing: 16) {
            Text("Compact → Expanded")
                .font(.system(size: 20, weight: .semibold))
            Text("Fixed 44-point compact rail · 240-point expanded sidebar")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 22) {
                ForEach(progressValues, id: \.self) { progress in
                    let section = self.section(workspace, progress: progress)
                    let namedSection = self.section(namedWorkspace, progress: progress)
                    let outerInset = 7 + 5 * progress
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 11, weight: .medium))
                        section
                            .frame(width: section.sectionWidth)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, outerInset)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.10, green: 0.11, blue: 0.14), in: RoundedRectangle(cornerRadius: 12))
                        namedSection
                            .frame(width: namedSection.sectionWidth)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, outerInset)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.10, green: 0.11, blue: 0.14), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .frame(width: max(section.sectionWidth + outerInset * 2, 60), alignment: .leading)
                }
            }
        }
        .padding(24)
        .foregroundStyle(.white)
        .frame(width: 930, height: 430, alignment: .topLeading)
        .background(Color(red: 0.045, green: 0.05, blue: 0.065))
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: preview)
        host.frame = NSRect(x: 0, y: 0, width: 930, height: 430)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = projectRoot.appendingPathComponent(".build/sidebar-morph-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("workspace-app-icons-morph-preview.png"))
    }

    private func renderSection(
        _ workspace: WorkspaceSidebarWorkspaceViewModel,
        progress: CGFloat,
        expandedWidth: CGFloat = 240,
    ) -> NativeSectionSample {
        let section = section(workspace, progress: progress, expandedWidth: expandedWidth)
        let probe = MorphAnchorProbe()
        let content = section
            .frame(width: section.sectionWidth)
            .fixedSize(horizontal: false, vertical: true)
            .overlayPreferenceValue(WorkspaceSidebarMorphPreference.self) { anchors in
                GeometryReader { geometry in
                    probe.record(anchors.mapValues { geometry[$0] })
                }
            }
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return NativeSectionSample(host: host, section: section, size: size, frames: probe.frames)
    }

    private func section(
        _ workspace: WorkspaceSidebarWorkspaceViewModel,
        progress: CGFloat,
        expandedWidth: CGFloat = 240,
    ) -> WorkspaceSidebarWorkspaceSection {
        var layout = WorkspaceSidebarConfiguration.empty
        layout.collapsedWidth = 44
        layout.expandedWidth = expandedWidth
        layout.showAppIcons = true
        layout.chromeStyle = .solid
        return WorkspaceSidebarWorkspaceSection(
            workspace: workspace,
            dragPreview: nil,
            expansionProgress: progress,
            layout: layout,
            emitsDropTarget: false,
            isFromOtherDisplay: false,
            isInUseOnOtherDisplay: false,
            isOnFocusedMonitor: true,
            allowsWorkspaceActivation: true,
            isPinnedActiveWorkspace: false,
            isActiveOnTargetMonitor: true,
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
    }

    private func workspace(
        appCount: Int,
        tabGroup: Bool = false,
        displayName: String = "12",
    ) -> WorkspaceSidebarWorkspaceViewModel {
        let apps = Array([
            WorkspaceSidebarAppViewModel(name: "Safari", bundleId: "com.apple.Safari", bundlePath: nil),
            WorkspaceSidebarAppViewModel(name: "Terminal", bundleId: "com.apple.Terminal", bundlePath: nil),
            WorkspaceSidebarAppViewModel(name: "Notes", bundleId: "com.apple.Notes", bundlePath: nil),
            WorkspaceSidebarAppViewModel(name: "Finder", bundleId: "com.apple.finder", bundlePath: nil),
            WorkspaceSidebarAppViewModel(name: "Calendar", bundleId: "com.apple.iCal", bundlePath: nil),
            WorkspaceSidebarAppViewModel(name: "Preview", bundleId: "com.apple.Preview", bundlePath: nil),
        ].prefix(appCount))
        let titles = ["Research and documentation", "Development server", "Release checklist", "Project files", "Planning", "Design reference"]
        let windows = apps.enumerated().map { index, app in
            WorkspaceSidebarWindowViewModel(
                windowId: UInt32(index + 1),
                workspaceName: "12",
                appName: app.name,
                appBundleId: app.bundleId,
                appBundlePath: app.bundlePath,
                title: titles[index],
                isFocused: index == 0,
            )
        }
        let items: [WorkspaceSidebarItemViewModel]
        if tabGroup {
            items = [.init(kind: .tabGroup(.init(
                representativeWindowId: 1,
                workspaceName: "12",
                title: "Project windows",
                windowCount: windows.count,
                isFocused: true,
                tabs: windows,
            )))]
        } else {
            items = windows.map { .init(kind: .window($0)) }
        }
        return WorkspaceSidebarWorkspaceViewModel(
            name: "12",
            projectId: workspaceProjectDefaultId,
            displayName: displayName,
            sidebarLabel: "",
            isGeneratedName: false,
            monitorScopeId: workspaceSidebarDefaultScopeId,
            monitorName: nil,
            isFocused: true,
            isVisible: true,
            items: items,
            apps: apps,
        )
    }
}

@MainActor
private final class MorphAnchorProbe {
    var frames: [WorkspaceSidebarMorphElement: CGRect] = [:]

    func record(_ frames: [WorkspaceSidebarMorphElement: CGRect]) -> Color {
        self.frames = frames
        return .clear
    }
}

@MainActor
private struct NativeSectionSample {
    let host: NSView
    let section: WorkspaceSidebarWorkspaceSection
    let size: CGSize
    let frames: [WorkspaceSidebarMorphElement: CGRect]
}
