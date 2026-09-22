@testable import AppBundle
import AppKit
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarAppMenuTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws { setMonitorsForTests(nil) }

    private func workspace(_ name: String, title: String?, appId: String = "test") -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: "",
            isGeneratedName: false, monitorScopeId: "main", monitorName: nil, isFocused: false,
            isVisible: false, items: [], apps: [.init(name: "Editor", bundleId: appId, bundlePath: nil, contextTitle: title)])
    }

    func testLabelsOnlyAppearForRepeatedAppsAndDisambiguateCollisions() {
        let input = [workspace("B", title: "workspace — Editor"), workspace("A", title: "working — Editor"),
            workspace("C", title: "unique", appId: "other")]
        let labeled = workspaceSidebarIdentityLabels(input, mode: .auto)
        XCTAssertEqual(labeled.map { $0.apps[0].identityLabel }, ["wor2", "work", nil])
        XCTAssertEqual(workspaceSidebarIdentityLabels(input.reversed(), mode: .auto).reversed().map { $0.apps[0].identityLabel },
            labeled.map { $0.apps[0].identityLabel })
        XCTAssertTrue(workspaceSidebarIdentityLabels(labeled, mode: .off).allSatisfy { $0.apps[0].identityLabel == nil })
        XCTAssertEqual(workspaceSidebarIdentityLabels(input, mode: .always)[2].apps[0].identityLabel, "uniq")
    }

    func testLabelsFallBackToWorkspaceAndPreserveGraphemes() {
        let input = [workspace("Research", title: "Editor"), workspace("Planning", title: nil),
            workspace("Unicode", title: "👩🏽‍💻日本語稿")]
        XCTAssertEqual(workspaceSidebarIdentityLabels(input, mode: .always).map { $0.apps[0].identityLabel },
            ["rese", "plan", "👩🏽‍💻日本語"])
        XCTAssertEqual(workspaceSidebarIdentityTitle(" Editor — project ", appName: "Editor"), "project")
        XCTAssertEqual(workspaceSidebarIdentityTitle("Editor — Editor", appName: "Editor"), "")
        XCTAssertEqual(workspaceSidebarIdentityTitle("EDITOR — project — editor", appName: "Editor"), "project")
    }

    func testMenuSeparatesAppActionsAndOtherWorkspaceWindows() throws {
        let first = Workspace.get(byName: "one")
        let second = Workspace.get(byName: "two")
        let window = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        TestWindow.new(id: 2, parent: second.rootTilingContainer)
        let app = try XCTUnwrap(buildWorkspaceSidebarAppSummaries(for: first).first)
        let entries = workspaceSidebarAppMenu(workspaceName: first.name, app: app)
        XCTAssertTrue(entries.contains { $0.title == "Other Workspaces" && $0.children.count == 1 })
        XCTAssertFalse(entries.contains { $0.title == "Delete Workspace" || $0.title == "Rename Workspace" })
        XCTAssertTrue(workspaceSidebarMenuWindowIsCurrent(window, workspaceName: first.name))
        window.bind(to: second.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertFalse(workspaceSidebarMenuWindowIsCurrent(window, workspaceName: first.name))
        XCTAssertTrue(workspaceSidebarAppMenu(workspaceName: "missing", app: app).isEmpty)
    }

    func testMinimizedOwnedWindowKeepsAppSummary() throws {
        let owner = Workspace.get(byName: "one")
        let window = TestWindow.new(id: 1, parent: owner.rootTilingContainer)
        window.rememberMacOsLayoutOrigin()
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertEqual(workspaceSidebarWindowsForAppSummary(owner).map(\.windowId), [1])
        XCTAssertEqual(buildWorkspaceSidebarAppSummaries(for: owner).count, 1)
        XCTAssertNil(workspaceSidebarAppWindow(in: owner, appId: "bundle:bobko.WinMux.test-app"))
    }

    func testSingleWindowTitleAndMultipleWindowWorkspaceFallback() async {
        let owner = Workspace.get(byName: "context-test")
        let first = TestWindow.new(id: 51, parent: owner.rootTilingContainer)
        _ = await getCachedWindowTitle(first)
        XCTAssertEqual(buildWorkspaceSidebarAppSummaries(for: owner).first?.contextTitle, "TestWindow(51)")
        TestWindow.new(id: 52, parent: owner.rootTilingContainer)
        XCTAssertNil(buildWorkspaceSidebarAppSummaries(for: owner).first?.contextTitle)
    }

    func testHiddenAndFullscreenOnlyWorkspacesRemainInDockSnapshot() async {
        let hidden = Workspace.get(byName: "hidden-only")
        TestWindow.new(id: 61, parent: hidden.macOsNativeHiddenAppsWindowsContainer)
        let fullscreen = Workspace.get(byName: "fullscreen-only")
        TestWindow.new(id: 62, parent: fullscreen.macOsNativeFullscreenWindowsContainer)
        let snapshot = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus,
            workspaceLabels: [:], availableMonitors: sortedMonitors)
        XCTAssertEqual(snapshot.first { $0.name == hidden.name }?.apps.count, 1)
        XCTAssertEqual(snapshot.first { $0.name == fullscreen.name }?.apps.count, 1)
        XCTAssertFalse(isUserFacingWorkspace(hidden), "Preserve CLI workspace-selection semantics")
        XCTAssertFalse(isUserFacingWorkspace(fullscreen))
    }

    func testContextDescriptionDoesNotRepeatAppOrWorkspace() {
        var app = WorkspaceSidebarAppViewModel(name: "Editor", bundleId: "test", bundlePath: nil)
        XCTAssertEqual(workspaceSidebarAppContextDescription(app, workspaceDisplayName: "Code"), "Editor · Workspace Code")
        app.contextTitle = "Editor"
        XCTAssertEqual(workspaceSidebarAppContextDescription(app, workspaceDisplayName: "Code"), "Editor · Workspace Code")
        app.contextTitle = "document"
        XCTAssertEqual(workspaceSidebarAppContextDescription(app, workspaceDisplayName: "Code"), "Editor · document · Workspace Code")
    }

    func testMinimizeRequiresAnOrdinaryWindow() {
        let owner = Workspace.get(byName: "minimize-eligibility")
        let window = TestWindow.new(id: 71, parent: owner)
        XCTAssertTrue(workspaceSidebarCanMinimize(window))
        window.rememberMacOsLayoutOrigin()
        window.bind(to: owner.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertFalse(workspaceSidebarCanMinimize(window))
        window.bind(to: owner.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertFalse(workspaceSidebarCanMinimize(window))
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertFalse(workspaceSidebarCanMinimize(window))
    }

    func testMoveValidationRejectsWindowMinimizedWhileMenuWasOpen() {
        let source = Workspace.get(byName: "move-source")
        let destination = Workspace.get(byName: "move-destination")
        let window = TestWindow.new(id: 81, parent: source.rootTilingContainer)
        XCTAssertTrue(workspaceSidebarMenuCanMove(window, workspaceName: source.name, destination: destination))
        window.rememberMacOsLayoutOrigin()
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertFalse(workspaceSidebarMenuCanMove(window, workspaceName: source.name, destination: destination))
    }

    func testIdentityLabelRenderingAtSmallAndDefaultSizes() throws {
        let preview = HStack(spacing: 24) {
            ForEach([CGFloat(24), 36, 48], id: \.self) { size in
                VStack(spacing: 16) {
                    Text("\(Int(size)) pt").font(.system(size: 12))
                    ForEach(["winm", "webs", "wor2"], id: \.self) { label in
                        WorkspaceSidebarWorkspaceIconBackground(isActive: true)
                            .overlay(Image(systemName: "terminal").font(.system(size: size * 0.45)))
                            .frame(width: size, height: size)
                            .overlay(WorkspaceSidebarIdentityLabel(label: label, size: size))
                    }
                }
            }
        }
        .padding(24).foregroundStyle(.white).background(Color(white: 0.08))
        let renderer = ImageRenderer(content: preview)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/reviews/dock-identity")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("identity-labels.png"))
    }

    func testNativeMenuPreservesDisabledHeadersCheckmarksAndSubmenus() {
        var invoked = false
        let menu = workspaceSidebarNativeAppMenu([
            .init(title: "Header", enabled: false), .separator,
            .init(title: "Windows", children: [.init(title: "Document", checked: true, perform: { invoked = true })])
        ])
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].submenu?.items[0].state, .on)
        menu.items[2].submenu?.performActionForItem(at: 0)
        XCTAssertTrue(invoked)
    }
}
