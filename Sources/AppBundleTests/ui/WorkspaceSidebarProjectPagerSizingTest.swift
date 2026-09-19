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

    private func pager(iconSize: CGFloat, showAppIcons: Bool = true, progress: CGFloat = 0,
                       hoveredProjectId: WorkspaceProjectId? = nil) -> WorkspaceSidebarProjectPager {
        var layout = WorkspaceSidebarConfiguration.empty
        layout.showAppIcons = showAppIcons
        layout.dockIconSize = iconSize
        layout.collapsedWidth = 44
        layout.expandedWidth = 240
        return WorkspaceSidebarProjectPager(
            projects: [.init(id: workspaceProjectDefaultId, displayName: "Default", colorHex: nil),
                       .init(id: WorkspaceProjectId("second"), displayName: "Second", colorHex: nil)],
            selectedProjectId: workspaceProjectDefaultId,
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
