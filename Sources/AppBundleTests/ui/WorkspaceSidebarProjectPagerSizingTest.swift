import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarProjectPagerSizingTest: XCTestCase {
    func testCompactDockProjectButtonsFitEveryRestingSize() throws {
        for size: CGFloat in [16, 24, 31, 48] {
            let projects = pager(iconSize: size).projects
            for (index, project) in projects.enumerated() {
                var restingPaintCount = 0
                for hovered in [false, true] {
                    let pager = pager(iconSize: size, hoveredProjectId: hovered ? project.id : nil)
                    let host = NSHostingView(rootView: pager.projectDot(project, index: index)
                        .fixedSize(horizontal: true, vertical: true))
                    let measured = host.fittingSize
                    XCTAssertLessThanOrEqual(measured.width, pager.sectionWidth.rounded(.up),
                        "Project buttons must fit the scrolling track at \(size)pt")
                    XCTAssertEqual(measured.height, workspaceSidebarProjectDotFrameHeight)
                    // Deliberately omit clipping: catch capsule and hover artwork that
                    // would otherwise be cut off by the real scrolling track.
                    let painted = NSHostingView(rootView: pager.projectDot(project, index: index)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(width: pager.sectionWidth).padding(8))
                    painted.frame = CGRect(origin: .zero, size: painted.fittingSize)
                    painted.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(painted.bitmapImageRepForCachingDisplay(in: painted.bounds))
                    painted.cacheDisplay(in: painted.bounds, to: bitmap)
                    let backingScale = CGFloat(bitmap.pixelsWide) / painted.bounds.width
                    var paintCount = 0
                    var overflowCount = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.05 else { continue }
                            paintCount += 1
                            let pointX = CGFloat(x) / backingScale
                            if pointX < 7.5 || pointX > 8.5 + pager.sectionWidth { overflowCount += 1 }
                        }
                    }
                    XCTAssertGreaterThan(paintCount, 0)
                    XCTAssertEqual(overflowCount, 0, "Project artwork must fit the track, hovered=\(hovered)")
                    if hovered {
                        XCTAssertGreaterThan(paintCount, restingPaintCount, "Exercise the visible hover background")
                    } else {
                        restingPaintCount = paintCount
                    }
                }
            }
        }
    }

    func testNativeCompactScrollTrackStaysInsideThePager() throws {
        for size: CGFloat in [16, 24, 31, 48] {
            let pager = pager(iconSize: size)
            let host = NSHostingView(rootView: pager)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            func scrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            let scroll = try XCTUnwrap(scrollView(in: host))
            let frame = scroll.convert(scroll.bounds, to: host)
            // AppKit rounds the native scroll view's fitting width up to whole points.
            XCTAssertEqual(frame.width, pager.sectionWidth.rounded(.up), accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
            XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX + 0.5,
                "Symmetric outer padding must not push the actual track outside the pager")
        }
    }

    func testExpandedAndSidebarProjectButtonsKeepTheirOriginalSize() {
        for showAppIcons in [false, true] {
            let pager = pager(iconSize: 16, showAppIcons: showAppIcons, progress: showAppIcons ? 1 : 0)
            let host = NSHostingView(rootView: pager.projectDot(pager.projects[0], index: 0)
                .fixedSize(horizontal: true, vertical: true))
            XCTAssertEqual(host.fittingSize.width, 36)
            XCTAssertEqual(host.fittingSize.height, workspaceSidebarProjectDotFrameHeight)
        }
    }

    func testEmojiIndicatorsFitAdaptiveWidthsAndSidebarKeepsBars() throws {
        var previews: [NSImage] = []
        for size: CGFloat in [16, 24, 48] {
            for dock in [false, true] {
                var images: [Data] = []
                for emoji: String? in [nil, "👩🏽‍💻"] {
                    let pager = pager(iconSize: size, showAppIcons: dock, emoji: emoji)
                    let host = NSHostingView(rootView: pager.projectDot(pager.projects[0], index: 0)
                        .fixedSize().frame(width: pager.sectionWidth).padding(8))
                    host.frame = CGRect(origin: .zero, size: host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                    var painted = 0
                    var overflow = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.05 else { continue }
                            painted += 1
                            let px = CGFloat(x) / scale
                            let py = CGFloat(y) / scale
                            if px < 7.5 || px > 8.5 + pager.sectionWidth || py < 7.5 || py > 8.5 + workspaceSidebarProjectDotFrameHeight {
                                overflow += 1
                            }
                        }
                    }
                    XCTAssertGreaterThan(painted, 0)
                    XCTAssertEqual(overflow, 0, "Emoji/bar paints outside its slot at \(size) points")
                    images.append(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
                    if dock, emoji != nil { previews.append(NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: host.bounds.size)) }
                }
                if dock {
                    XCTAssertNotEqual(images[0], images[1], "Configured Dock emoji must replace the bar")
                } else {
                    XCTAssertEqual(images[0], images[1], "Sidebar mode must keep its original indicator")
                }
            }
        }
        let content = HStack(alignment: .top, spacing: 24) {
            ForEach(Array(previews.enumerated()), id: \.offset) { index, image in
                VStack {
                    Text(["16 pt", "24 pt", "48 pt"][index]).font(.caption)
                    Image(nsImage: image)
                }
            }
        }
        .padding(20).foregroundStyle(.white).background(Color(white: 0.16))
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = projectRoot.appendingPathComponent(".build/sidebar-appearance-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("project-emojis.png"))
    }

    func testEmojiSelectionAndHoverHaveDistinctNativeAppearance() throws {
        var states: Set<Data> = []
        for selected in [false, true] {
            for hovered in [false, true] {
                let pager = pager(iconSize: 24, hoveredProjectId: hovered ? workspaceProjectDefaultId : nil,
                                  emoji: "🏠", selectedProjectId: selected ? workspaceProjectDefaultId : "second")
                let host = NSHostingView(rootView: pager.projectDot(pager.projects[0], index: 0).fixedSize().padding(8))
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                states.insert(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
            }
        }
        XCTAssertEqual(states.count, 4, "Both selected and unselected emoji need visible hover feedback")
    }

    private func pager(iconSize: CGFloat, showAppIcons: Bool = true, progress: CGFloat = 0,
                       hoveredProjectId: WorkspaceProjectId? = nil, emoji: String? = nil,
                       selectedProjectId: WorkspaceProjectId = workspaceProjectDefaultId) -> WorkspaceSidebarProjectPager {
        var layout = WorkspaceSidebarConfiguration.empty
        layout.showAppIcons = showAppIcons
        layout.dockIconSize = iconSize
        layout.collapsedWidth = 44
        layout.expandedWidth = 240
        return WorkspaceSidebarProjectPager(
            projects: [.init(id: workspaceProjectDefaultId, displayName: "Default", colorHex: nil, emoji: emoji),
                       .init(id: WorkspaceProjectId("second"), displayName: "Second", colorHex: nil)],
            selectedProjectId: selectedProjectId,
            expansionProgress: progress,
            layout: layout,
            isProjectMenuOpen: .constant(false),
            renamingProjectId: .constant(nil),
            renamingProjectText: .constant(""),
            onSelectProject: { _ in },
            onCreateProject: {},
            onBeginRenameProject: { _ in },
            onCommitRenameProject: {},
            onCancelRenameProject: {},
            onSetProjectColor: { _, _ in },
            onDeleteProject: { _ in },
            hoveredProjectDotId: hoveredProjectId
        )
    }
}
