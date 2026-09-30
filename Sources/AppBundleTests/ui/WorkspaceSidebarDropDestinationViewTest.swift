import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

/// The other display's list is a picture of that display's sidebar: its tabs, its project's pins,
/// and drop targets that all name that display. It shows only the drop it owns.
@MainActor
final class WorkspaceSidebarDropDestinationViewTest: XCTestCase {
    private let here = "monitor:0.0,0.0"
    private let there = "monitor:1920.0,0.0"
    private let surface = WorkspaceSidebarSurfaceRef.dropDestination(generation: 3)

    func testItListsTheOtherDisplaysTabsAndItsProjectsPins() {
        for shares in [false, true] {
            let snapshot = fixture(sharesPins: shares)
            XCTAssertEqual(snapshot.tabSections.map(\.id), ["tab:t1", "collection:g1", "tab:t3"], "Only that display's tabs")
            XCTAssertEqual(snapshot.pins.map(\.name), shares ? ["pinHere", "pinThere"] : ["pinThere"],
                "Its pins, and with shared pins every pin of its project")
        }
    }

    func testItShowsOnlyTheDropItOwns() {
        let preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 9, label: "a", appName: "App",
            targetWorkspaceName: "t1", targetsNewWorkspace: false, isTabGroup: false, windowCount: 1)
        XCTAssertEqual(workspaceSidebarDropDestinationPreview(preview, surface: surface, ownerId: surface.ownerId), preview)
        XCTAssertEqual(workspaceSidebarDropDestinationPreview(preview, surface: surface, ownerId: here), preview.sourceOnly)
        XCTAssertEqual(workspaceSidebarDropDestinationPreview(preview, surface: surface, ownerId: "drop-destination:2"),
            preview.sourceOnly, "A list opened before this one")
        XCTAssertNil(workspaceSidebarDropDestinationPreview(nil, surface: surface, ownerId: surface.ownerId))
    }

    /// Hosted: every target the list reports is for the other display, and rows scrolled away
    /// report none.
    func testEveryDropTargetNamesTheOtherDisplay() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let model = WorkspaceSidebarDropDestinationColumnModel()
        let scroll = WorkspaceSidebarDropDestinationScrollModel()
        model.set(fixture(sharesPins: true))
        var targets: [WorkspaceSidebarDropTargetFrame] = []
        let host = NSHostingView(rootView: WorkspaceSidebarDropDestinationView(model: model, scroll: scroll) { targets = $1 }
            .frame(width: 280, height: 420)
            .transaction { $0.animation = nil })
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 420)
        settle(host)

        let kinds = targets.map(\.kind)
        XCTAssertTrue(kinds.contains(.workspace("t1")))
        XCTAssertTrue(kinds.contains(.workspace("pinHere")), "A pin from another display, joined where it is")
        XCTAssertTrue(kinds.contains(.newWorkspace(projectId: workspaceProjectDefaultId, monitorScopeId: there)))
        XCTAssertTrue(kinds.contains(.tabCollection("g1", monitorScopeId: there)))
        XCTAssertFalse(kinds.contains(.workspace("elsewhere")), "Not this display's own tabs")
        for kind in kinds {
            switch kind {
                case .tabGap(_, let scope, _), .newWorkspace(_, let scope):
                    XCTAssertEqual(scope, there, "\(kind)")
                case .pinnedTabs(_, _, let scope), .tabCollection(_, let scope):
                    XCTAssertEqual(scope, there, "\(kind)")
                case .workspace, .monitor:
                    break
            }
        }
        for target in targets where target.tabReorderDestination != nil {
            XCTAssertEqual(target.tabReorderDestination?.monitorScopeId, there)
        }
        XCTAssertGreaterThan(scroll.contentHeight, 0)

        // Scrolled all the way, the rows at the top take no drops.
        scroll.offset = max(scroll.maxOffset, 200)
        settle(host)
        XCTAssertFalse(targets.map(\.kind).contains(.newWorkspace(projectId: workspaceProjectDefaultId, monitorScopeId: there)))
        let viewportTop = workspaceSidebarDropDestinationHeaderHeight
        XCTAssertTrue(targets.allSatisfy { $0.frame.minY >= viewportTop - 0.5 }, "Clipped below the header")
    }

    /// Review round 1: a list that got shorter doesn't stay scrolled past its end.
    func testTheScrollStaysWithinTheList() {
        let scroll = WorkspaceSidebarDropDestinationScrollModel()
        scroll.measure(contentHeight: 1000, viewportHeight: 400)
        scroll.offset = 600
        scroll.measure(contentHeight: 500)
        XCTAssertEqual(scroll.offset, 100)
        scroll.measure(viewportHeight: 600)
        XCTAssertEqual(scroll.offset, 0, "Nor a taller view")
    }

    // MARK: Helpers

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        for _ in 0 ..< 4 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            host.layoutSubtreeIfNeeded()
        }
    }

    private func fixture(sharesPins: Bool) -> WorkspaceSidebarDropDestinationSnapshot {
        var projection = WorkspaceSidebarSnapshot.empty
        projection.workspaces = [
            tab("pinHere", on: here, window: 1, pinned: true),
            tab("pinThere", on: there, window: 2, pinned: true),
            tab("t1", on: there, window: 3, visible: true),
            tab("g1a", on: there, window: 4),
            tab("t3", on: there, window: 5),
            tab("elsewhere", on: here, window: 6, visible: true),
        ]
        projection.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: "🔬")]
        projection.selectedMonitorScopeId = there
        projection.targetMonitorScopeId = there
        projection.focusedMonitorScopeId = here
        projection.configuration.usesTabsList = true
        projection.configuration.sharesPinnedTabs = sharesPins
        projection.configuration.tabCollections = [.init(id: "g1", projectId: workspaceProjectDefaultId, name: "Group",
            colorHex: "#3FB8A5", workspaceNames: ["g1a"], isCollapsed: false)]
        let hint = WorkspaceSidebarDropDestinationHint(id: there, name: "Right", direction: .right)
        return .init(hint: hint, surface: surface, projection: projection, width: 280)
    }

    private func tab(_ name: String, on scope: String, window: UInt32, pinned: Bool = false,
                     visible: Bool = false) -> WorkspaceSidebarWorkspaceViewModel {
        var workspace = WorkspaceSidebarWorkspaceViewModel(name: name, projectId: workspaceProjectDefaultId, displayName: name,
            sidebarLabel: name, isGeneratedName: false, monitorScopeId: scope, monitorName: nil, isFocused: false,
            isVisible: visible, items: [.init(kind: .window(.init(windowId: window, workspaceName: name, appName: "Notes",
                appBundleId: nil, appBundlePath: "/System/Applications/Notes.app", title: name, isFocused: false)))])
        workspace.appearance.isFavorite = pinned
        return workspace
    }
}
