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
            // The expanded switcher widens only the current project to show its name.
            let index = showAppIcons ? 1 : 0
            let host = NSHostingView(rootView: pager.projectDot(pager.projects[index], index: index)
                .fixedSize(horizontal: true, vertical: true))
            XCTAssertEqual(host.fittingSize.width, 36)
            XCTAssertEqual(host.fittingSize.height, workspaceSidebarProjectDotFrameHeight)
        }
    }

    func testExpandedSwitcherNamesTheCurrentProjectBesideTheNewProjectButton() {
        for showAppIcons in [false, true] {
            for projectCount in [1, 3] {
                let pager = expandedPager(showAppIcons: showAppIcons, projectCount: projectCount)
                XCTAssertEqual(pager.pagerHeight, workspaceSidebarPagerHeight, "One row, with no project menu above it")
                XCTAssertEqual(pager.projectTrackWidth + pager.projectControlsSpacing + pager.projectCreateButtonWidth,
                    pager.sectionWidth, "The New Project button shares the switcher's row")
                XCTAssertTrue(pager.showsProjectName(isCurrent: true))
                XCTAssertFalse(pager.showsProjectName(isCurrent: false))
            }
        }
        let collapsed = pager(iconSize: 24, showAppIcons: false, progress: 0)
        XCTAssertFalse(collapsed.showsProjectName(isCurrent: true), "The collapsed rail has no room for names")
    }

    func testCurrentProjectPillFitsItsNameUpToALimit() {
        func width(_ name: String) -> CGFloat {
            let pager = expandedPager(showAppIcons: false, projectCount: 2, firstName: name)
            return NSHostingView(rootView: pager.projectDot(pager.projects[0], index: 0).fixedSize()).fittingSize.width
        }
        XCTAssertGreaterThan(width("Research"), 36)
        XCTAssertLessThan(width("Research"), workspaceSidebarCurrentProjectPillMaxWidth)
        XCTAssertEqual(width(String(repeating: "Platform Paper ", count: 6)), workspaceSidebarCurrentProjectPillMaxWidth,
            "Long names truncate instead of pushing other projects out of view")
    }

    func testExpandedSwitcherShowsProjectEmojiInBothModes() {
        for showAppIcons in [false, true] {
            let pager = expandedPager(showAppIcons: showAppIcons, projectCount: 3)
            XCTAssertTrue(pager.showsProjectEmoji(pager.projects[1]))
            XCTAssertFalse(pager.showsProjectEmoji(pager.projects[2]), "A project without an emoji keeps its color bar")
        }
        let sidebarRail = pager(iconSize: 24, showAppIcons: false, progress: 0, emoji: "🔬")
        XCTAssertFalse(sidebarRail.showsProjectEmoji(sidebarRail.projects[0]), "The collapsed Sidebar rail keeps its bars")
    }

    func testExpandedSwitcherRendersInsideItsRow() throws {
        var previews: [NSImage] = []
        for showAppIcons in [false, true] {
            let pager = expandedPager(showAppIcons: showAppIcons, projectCount: 5)
            let host = NSHostingView(rootView: pager.projectControls
                .padding(8)
                .background(Color(white: 0.16)))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, pager.sectionWidth + 16)
            XCTAssertEqual(host.bounds.height, workspaceSidebarPagerHeight + 16)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            previews.append(NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: host.bounds.size))
        }
        let content = VStack(spacing: 12) {
            ForEach(Array(previews.enumerated()), id: \.offset) { _, image in Image(nsImage: image) }
        }
        .padding(20).background(Color(white: 0.1))
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = projectRoot.appendingPathComponent(".build/sidebar-appearance-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("project-switcher.png"))
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

    private func expandedPager(showAppIcons: Bool, projectCount: Int, firstName: String = "Research") -> WorkspaceSidebarProjectPager {
        var layout = WorkspaceSidebarConfiguration.empty
        layout.showAppIcons = showAppIcons
        layout.dockIconSize = 48
        layout.collapsedWidth = 44
        layout.expandedWidth = 240
        let projects: [WorkspaceSidebarProjectViewModel] = [
            .init(id: workspaceProjectDefaultId, displayName: firstName, colorHex: "#7BA3C9", emoji: "🔬"),
            .init(id: WorkspaceProjectId("itss"), displayName: "ITSS", colorHex: "#7DBF8E", emoji: "🛰️"),
            .init(id: WorkspaceProjectId("replika"), displayName: "Replika", colorHex: "#BF8AAE"),
            .init(id: WorkspaceProjectId("paper"), displayName: "Platform Paper", colorHex: "#9B8FC4", emoji: "📄"),
            .init(id: WorkspaceProjectId("base"), displayName: "Base", colorHex: nil),
        ]
        return WorkspaceSidebarProjectPager(
            projects: Array(projects.prefix(projectCount)),
            selectedProjectId: workspaceProjectDefaultId,
            expansionProgress: 1,
            layout: layout,
            renamingProjectId: .constant(nil),
            renamingProjectText: .constant(""),
            onSelectProject: { _ in },
            onCreateProject: {},
            onBeginRenameProject: { _ in },
            onCommitRenameProject: {},
            onCancelRenameProject: {},
            onSetProjectColor: { _, _ in },
            onDeleteProject: { _ in },
        )
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
