import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

/// A narrow Sidebar or Tabs panel fits its content instead of cutting it off.
@MainActor
final class WorkspaceSidebarNarrowWidthTest: XCTestCase {
    override func tearDown() async throws {
        config = defaultConfig
        workspaceSidebarOrganizationStore = .init()
        try await super.tearDown()
    }

    func testNothingInTheTabsSidebarRunsPastItsEdge() async throws {
        let badges = try await badgeModel()
        defer { badges.setEnabled(false) }
        let music = runningMusic()
        for width: CGFloat in [160, 180, 200, 240, 320] {
            let probe = NarrowWidthProbe()
            let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: tabsFixture(width: width),
                actions: .init(setDropTargets: { probe.targets = $0 }), reduceMotionOverride: true,
                reduceTransparencyOverride: true, dockBadgeModel: badges, browserTabsModel: BrowserTabsModel(snapshots: [:]),
                musicPlayerModel: music)
                .transaction { $0.animation = nil })
            host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            host.layoutSubtreeIfNeeded()
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
            }
            let groups = probe.targets.filter { if case .tabCollection = $0.kind { true } else { false } }
            XCTAssertTrue(probe.targets.contains { $0.kind == .workspace("pin") && $0.tabReorderDestination?.arrangesPins == true },
                "\(width): the pinned tile")
            XCTAssertTrue(probe.targets.contains { $0.kind == .workspace("t2") }, "\(width): a tab")
            XCTAssertEqual(groups.count, 2, "\(width)")
            for target in probe.targets {
                XCTAssertGreaterThanOrEqual(target.frame.minX, -0.5, "\(width): \(target.kind)")
                XCTAssertLessThanOrEqual(target.frame.maxX, width + 0.5, "\(width): \(target.kind) at \(target.frame)")
            }
        }
    }

    func testTheMusicPlayerPutsItsControlsUnderTheTrackWhenNarrow() {
        let music = runningMusic()
        func size(_ width: CGFloat) -> CGSize {
            NSHostingController(rootView: WorkspaceSidebarBottomMusicPlayer(onSelect: {}, model: music)
                .environment(\.workspaceSidebarReducesMotion, true))
                .sizeThatFits(in: CGSize(width: width, height: 1000))
        }
        for width: CGFloat in [120, 140, 160, 200, 240, 320] {
            XCTAssertLessThanOrEqual(size(width).width, width + 0.5, "The player fits \(width) points")
        }
        XCTAssertGreaterThan(size(160).height, size(320).height, "Narrow, the controls take a row of their own")
        XCTAssertFalse(WorkspaceSidebarNowPlayingHeaderLayout.placesControlsBeside(width: 180, controlsWidth: 82))
        XCTAssertTrue(WorkspaceSidebarNowPlayingHeaderLayout.placesControlsBeside(width: 196, controlsWidth: 82),
            "Beside the controls, the title keeps its minimum room")
    }

    func testTheProjectSwitcherFitsItsProjectsBeforeItScrolls() {
        typealias Density = WorkspaceSidebarProjectTrackDensity
        XCTAssertEqual(workspaceSidebarProjectTrackDensity(projectCount: 4, trackWidth: 200), .regular)
        XCTAssertEqual(workspaceSidebarProjectTrackDensity(projectCount: 4, trackWidth: 142), .tight(buttonWidth: 32))
        XCTAssertEqual(workspaceSidebarProjectTrackDensity(projectCount: 3, trackWidth: 94), .tight(buttonWidth: 27),
            "Three emoji still fit the reported 152-point sidebar")
        XCTAssertEqual(workspaceSidebarProjectTrackDensity(projectCount: 4, trackWidth: 102), .dots(dotWidth: 12))
        XCTAssertEqual(workspaceSidebarProjectTrackDensity(projectCount: 4, trackWidth: 62), .dots(dotWidth: 6))
        XCTAssertEqual(workspaceSidebarProjectTrackDensity(projectCount: 1, trackWidth: 20), .regular)

        // Every width a Tabs or Sidebar panel can take shows a typical set of projects whole.
        for (mode, counts) in [(WorkspaceSidebarMode.tabs, 2...6), (.sidebar, 2...4)] {
            for width in stride(from: mode.minimumExpandedWidth!, through: 480, by: 4) {
                for count in counts {
                    let pager = pager(width: CGFloat(width), projectCount: count, tabs: mode == .tabs)
                    guard !pager.usesProjectChips else { continue }
                    XCTAssertLessThanOrEqual(pager.trackDensity.contentWidth(projectCount: count), pager.projectTrackWidth,
                        "\(mode) \(width) points, \(count) projects: \(pager.trackDensity)")
                }
            }
        }
        // The current project's named pill leaves room for a project on either side in both modes.
        let sidebar = pager(width: 200, projectCount: 4, tabs: false)
        XCTAssertFalse(sidebar.usesProjectChips)
        XCTAssertLessThanOrEqual(sidebar.currentProjectPillMaxWidth + 80 + 8, sidebar.projectTrackWidth)
        XCTAssertTrue(pager(width: 240, projectCount: 3, tabs: false).usesProjectChips)
    }

    func testTheSidebarClockShrinksToFitItsCard() {
        XCTAssertEqual(workspaceSidebarExpandedClockScale(time: "02:15", seconds: "30", availableWidth: 188), 1)
        let narrow = workspaceSidebarExpandedClockScale(time: "02:15", seconds: "30", availableWidth: 68)
        XCTAssertLessThan(narrow, 1)
        XCTAssertGreaterThan(narrow, 0.3)
        XCTAssertLessThan(narrow, workspaceSidebarExpandedClockScale(time: "02:15", seconds: nil, availableWidth: 68),
            "Seconds take room from the time")
    }

    // MARK: - Fixtures

    private func pager(width: CGFloat, projectCount: Int, tabs: Bool) -> WorkspaceSidebarProjectPager {
        var layout = WorkspaceSidebarConfiguration.empty
        layout.collapsedWidth = 44
        layout.expandedWidth = width
        layout.usesTabsList = tabs
        let projects = (0..<projectCount).map {
            WorkspaceSidebarProjectViewModel(id: WorkspaceProjectId(rawValue: "p\($0)"), displayName: "Project \($0)",
                colorHex: nil, emoji: "🔬")
        }
        return WorkspaceSidebarProjectPager(projects: projects, selectedProjectId: projects[0].id, expansionProgress: 1,
            layout: layout, renamingProjectId: .constant(nil), renamingProjectText: .constant(""), onSelectProject: { _ in },
            onCreateProject: {}, onBeginRenameProject: { _ in }, onCommitRenameProject: {}, onCancelRenameProject: {},
            onSetProjectColor: { _, _ in }, onDeleteProject: { _ in })
    }

    private func runningMusic() -> AppleMusicNowPlayingModel {
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in nil }, requestArtwork: { .failed })
        model.receive(AppleMusicNowPlaying(state: .playing, title: "Clair de Lune", artist: "Claude Debussy",
            album: "Suite bergamasque", duration: 300, position: 95, positionDate: Date()))
        return model
    }

    private func badgeModel() async throws -> WorkspaceSidebarDockBadgeModel {
        let badges = WorkspaceSidebarDockBadgeModel(read: { .init(labelsByPath: ["/System/Applications/Messages.app": "12"]) })
        badges.setEnabled(true, showsAppBadges: true)
        for _ in 0..<100 where badges.snapshot.labelsByPath.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        return badges
    }

    /// The reported sidebar: one pin with a badge, Music at the bottom, several projects, and groups.
    private func tabsFixture(width: CGFloat) -> WorkspaceSidebarSnapshot {
        func window(_ id: UInt32, _ workspace: String, _ app: String, _ path: String, _ title: String) -> WorkspaceSidebarWindowViewModel {
            .init(windowId: id, workspaceName: workspace, appName: app, appBundleId: nil, appBundlePath: path, title: title,
                isFocused: false)
        }
        func workspace(_ name: String, _ windows: [WorkspaceSidebarWindowViewModel], pinned: Bool = false) -> WorkspaceSidebarWorkspaceViewModel {
            .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: "", isGeneratedName: true,
                monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: false, isVisible: name == "t1",
                items: windows.map { .init(kind: .window($0)) }, appearance: .init(isFavorite: pinned))
        }
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 44, expandedWidth: width, topPadding: 12,
            showMonitorSelector: false, showsClock: false, showsSeconds: false, showsDate: false, showsWeekday: false,
            showsStatusPills: false, chromeStyle: .solid, solidChromeColor: .fog, solidChromeCustomColor: "#D8E3EE",
            usesTabsList: true, alwaysExpanded: true)
        snapshot.configuration.musicPlayerAtBottom = true
        snapshot.configuration.tabCollections = [
            .init(id: "open", projectId: workspaceProjectDefaultId, name: "Reading for the thesis", colorHex: "#3FB8A5",
                workspaceNames: ["g1", "g2"]),
            .init(id: "closed", projectId: workspaceProjectDefaultId, name: "Admin and errands", colorHex: "#D08040",
                workspaceNames: ["g3", "g4"], isCollapsed: true),
        ]
        snapshot.visibleWidth = width
        snapshot.targetMonitorScopeId = "monitor:0,0"
        snapshot.selectedMonitorScopeId = "monitor:0,0"
        snapshot.monitorScopes = [
            .init(id: "monitor:0,0", displayName: "Built-in Retina Display", subtitle: nil, systemImageName: "display",
                isFocusedMonitor: true),
            .init(id: "monitor:1512,0", displayName: "DELL U3224KB", subtitle: nil, systemImageName: "display",
                isFocusedMonitor: false),
        ]
        snapshot.projects = [
            .init(id: WorkspaceProjectId(rawValue: "home"), displayName: "Home", colorHex: "#E0A040", emoji: "🐣"),
            .init(id: workspaceProjectDefaultId, displayName: "Research and Development Notes", colorHex: "#7BA3C9", emoji: "🔬"),
            .init(id: WorkspaceProjectId(rawValue: "teach"), displayName: "Teaching", colorHex: "#9A6BD0", emoji: "👨‍🏫"),
            .init(id: WorkspaceProjectId(rawValue: "errands"), displayName: "Errands", colorHex: "#50B070"),
        ]
        let messages = "/System/Applications/Messages.app", notes = "/System/Applications/Notes.app"
        snapshot.workspaces = [
            workspace("pin", [window(1, "pin", "Messages", messages, "Chat")], pinned: true),
            workspace("t1", [window(10, "t1", "Safari", "/Applications/Safari.app", "Release WinMux 0.6.377 · GitHub")]),
            workspace("t2", [window(11, "t2", "Notes", notes, "Narrow sidebar ideas")]),
            workspace("g1", [window(20, "g1", "Notes", notes, "Swift docs")]),
            workspace("g2", [window(21, "g2", "Notes", notes, "Reading list")]),
            workspace("g3", [window(22, "g3", "Messages", messages, "Newsletter")]),
            workspace("g4", [window(23, "g4", "Notes", notes, "Week")]),
        ]
        return snapshot
    }
}

@MainActor
private final class NarrowWidthProbe {
    var targets: [WorkspaceSidebarDropTargetFrame] = []
}
