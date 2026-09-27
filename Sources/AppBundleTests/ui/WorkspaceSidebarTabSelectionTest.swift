import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarTabSelectionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        WorkspaceSidebarTabSelection.shared.clear()
    }

    override func tearDown() async throws {
        WorkspaceSidebarTabSelection.shared.clear()
        WorkspaceSidebarTabDragState.shared.set(false)
        clearWorkspaceSidebarDropPreview()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
        try await super.tearDown()
    }

    func testShiftSelectsARangeCommandTogglesAndAPlainClickOpensOneTab() {
        let selection = WorkspaceSidebarTabSelection()
        let order = ["a", "b", "c", "d", "e"]
        func click(_ name: String, _ modifiers: NSEvent.ModifierFlags, in order: [String] = order) -> Bool {
            selection.handleClick(on: name, modifiers: modifiers, order: order, active: "b")
        }
        XCTAssertTrue(click("d", .shift))
        XCTAssertEqual(selection.names, ["b", "c", "d"], "From the tab on screen")
        XCTAssertTrue(click("a", .shift))
        XCTAssertEqual(selection.names, ["a", "b"], "Shift ranges keep their anchor")
        XCTAssertTrue(click("e", .command))
        XCTAssertEqual(selection.names, ["a", "b", "e"], "Command adds, in list order")
        XCTAssertTrue(click("b", .command))
        XCTAssertEqual(selection.names, ["a", "e"], "and removes")
        XCTAssertFalse(click("c", []), "A plain click opens the tab")
        XCTAssertEqual(selection.names, [])

        XCTAssertTrue(click("d", .command))
        XCTAssertEqual(selection.names, ["b", "d"], "The first Command click keeps the tab on screen chosen")
        XCTAssertTrue(click("x", .command, in: ["x", "y"]))
        XCTAssertEqual(selection.names, ["x"], "Another page's tabs start a selection of their own")
        XCTAssertTrue(click("y", .shift, in: ["x", "y"]))
        XCTAssertEqual(selection.names, ["x", "y"])
    }

    func testClosingSeveralTabsStopsAtTheFirstThatWontClose() async throws {
        let refusing = Workspace.get(byName: "refusing")
        let empty = Workspace.get(byName: "empty-after")
        _ = TestWindow.new(id: 150, parent: refusing.rootTilingContainer)
        _ = TestWindow.new(id: 151, parent: Workspace.get(byName: "other").rootTilingContainer)
        try saveWorkspaceSidebarIdentity(empty)
        var asked: [UInt32] = []
        await closeWorkspaceSidebarTabs([refusing.name, empty.name]) { asked.append($0.windowId); return false }?.value
        XCTAssertEqual(asked, [150])
        XCTAssertTrue(Workspace.existing(byName: empty.name) === empty,
            "A save prompt in the first tab keeps the rest, even an empty saved tab")
        await closeWorkspaceSidebarTabs([empty.name]) { _ in true }?.value
        XCTAssertNil(Workspace.existing(byName: empty.name), "Closing it alone does close it")
    }

    func testTheSelectionsMenuGroupsPinsAndClosesTogether() {
        let tabs = ["a", "b"].map { name in
            WorkspaceSidebarWorkspaceViewModel(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: "",
                isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: false, isVisible: false,
                items: [], appearance: .init(isFavorite: name == "a"))
        }
        let group = WorkspaceTabCollection(id: "g", projectId: workspaceProjectDefaultId, name: "Work", workspaceNames: ["a", "b"])
        var sent: [WorkspaceSidebarAction] = []
        var cleared = 0
        let entries = workspaceSidebarTabSelectionMenuEntries(["a", "b", "gone"], workspaces: tabs, collections: [group],
            send: { sent.append($0) }, clear: { cleared += 1 })
        XCTAssertEqual(entries.map(\.title).filter { !$0.isEmpty },
            ["2 Tabs", "New Group with 2 Tabs", "Add to Group", "Pin 2 Tabs", "Close 2 Tabs", "Deselect Tabs"],
            "Pinning until every chosen tab is pinned")
        let add = try? XCTUnwrap(entries.first { $0.title == "Add to Group" })
        XCTAssertEqual(add?.children.first?.checked, true, "Both are already in Work")
        XCTAssertEqual(add?.children.last?.title, "Remove from Group")
        entries.first { $0.title == "New Group with 2 Tabs" }?.perform?()
        entries.first { $0.title == "Pin 2 Tabs" }?.perform?()
        XCTAssertEqual(cleared, 2, "Acting on the tabs ends the selection")
        guard case .createTabCollectionFromTabs(let grouped) = sent.first, case .setTabsFavorite(let pinned, true) = sent.last else {
            return XCTFail("\(sent)")
        }
        XCTAssertEqual(grouped, ["a", "b"])
        XCTAssertEqual(pinned, ["a", "b"])
        XCTAssertTrue(workspaceSidebarTabSelectionMenuEntries(["a"], workspaces: tabs, collections: [], send: { _ in },
            clear: {}).isEmpty, "One tab keeps its own menu")
    }

    func testGroupingAndPinningSeveralTabsAtOnce() async throws {
        let names = ["one", "two", "three"]
        for (index, name) in names.enumerated() {
            _ = TestWindow.new(id: UInt32(130 + index), parent: Workspace.get(byName: name).rootTilingContainer)
        }
        await handleWorkspaceSidebarOrganizationAction(.createTabCollectionFromTabs(["one", "two"]))?.value
        let group = try XCTUnwrap(workspaceSidebarOrganizationStore.state.collections.first)
        XCTAssertEqual(group.workspaceNames, ["one", "two"])
        await handleWorkspaceSidebarOrganizationAction(.assignTabsToCollection(["three"], group.id))?.value
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: "three")?.id, group.id)
        await handleWorkspaceSidebarOrganizationAction(.setTabsFavorite(["one", "three"], true))?.value
        let pinned = workspaceSidebarOrganizationStore.state.workspaces.filter { $0.value.isFavorite }.map(\.key).sorted()
        XCTAssertEqual(pinned, ["one", "three"])
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections.first?.workspaceNames, ["two"],
            "Pinned tabs leave their group, as one pinned tab does")
    }

    func testDroppingOnThePinnedTilesPinsATabThatIsntPinnedYet() throws {
        let split = focus.workspace
        _ = TestWindow.new(id: 140, parent: split.rootTilingContainer)
        let half = TestWindow.new(id: 141, parent: split.rootTilingContainer)
        let single = Workspace.get(byName: "single")
        let alone = TestWindow.new(id: 142, parent: single.rootTilingContainer)
        let pins = WorkspaceSidebarDropTargetKind.pinnedTabs(projectId: split.projectId)
        previewWorkspaceSidebarDrop(alone.windowId, subject: .window, target: pins)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetsPinned, true)
        try setWorkspaceSidebarTabFavorite(single, true)
        previewWorkspaceSidebarDrop(alone.windowId, subject: .window, target: pins)
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "Already pinned: nothing to promise")
        previewWorkspaceSidebarDrop(half.windowId, subject: .window, target: pins)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetsPinned, true,
            "A window from a split gets a pinned tab of its own")
        previewWorkspaceSidebarDrop(half.windowId, subject: .window, target: .pinnedTabs(projectId: "another"))
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "Another project's pins")
    }

    func testWithNothingPinnedADragOffersAPlaceToPin() throws {
        var fixture = WorkspaceSidebarSnapshot.empty
        fixture.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 44, expandedWidth: 280,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false, chromeStyle: .solid, solidChromeColor: .midnight,
            solidChromeCustomColor: "#191B20", showAppIcons: false, usesTabsList: true, alwaysExpanded: true)
        fixture.visibleWidth = 280
        fixture.targetMonitorScopeId = "monitor:0,0"
        fixture.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
        let window = WorkspaceSidebarWindowViewModel(windowId: 1, workspaceName: "1", appName: "Safari",
            appBundleId: "com.apple.Safari", appBundlePath: nil, title: "Tab", isFocused: true)
        fixture.workspaces = [.init(name: "1", projectId: workspaceProjectDefaultId, displayName: "1", sidebarLabel: "",
            isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: true, isVisible: true,
            items: [.init(kind: .window(window))])]
        let pins = WorkspaceSidebarDropTargetKind.pinnedTabs(projectId: workspaceProjectDefaultId)
        XCTAssertFalse(try renderedDropTargets(fixture).contains { $0.kind == pins }, "Not while nothing is dragged")
        WorkspaceSidebarTabDragState.shared.set(true)
        XCTAssertTrue(try renderedDropTargets(fixture).contains { $0.kind == pins })
    }

    private func renderedDropTargets(_ fixture: WorkspaceSidebarSnapshot) throws -> [WorkspaceSidebarDropTargetFrame] {
        let probe = TabSelectionDropTargetProbe()
        let view = WorkspaceSidebarView(snapshot: fixture, reduceMotionOverride: true, reduceTransparencyOverride: true)
        let host = NSHostingView(rootView: view.sidebarContent(expansionProgress: 1, layout: fixture.configuration)
            .coordinateSpace(name: "workspaceSidebarContent")
            .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { probe.targets = $0 }
            .frame(width: 280, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 620)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
        return probe.targets
    }
}

@MainActor
private final class TabSelectionDropTargetProbe {
    var targets: [WorkspaceSidebarDropTargetFrame] = []
}
