@testable import AppBundle
import Common
import XCTest

/// The setting and the menu entries: off by default, manual only in Tabs mode, and the TOML
/// and Settings toggle agreeing.
@MainActor
final class WorkspaceTopicSettingsTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TopicTestApps.reset()
    }

    override func tearDown() async throws {
        WorkspaceTopicTestEnvironment.tearDown()
        WorkspaceSidebarTabSelection.shared.clear()
        TopicTestApps.reset()
        try await super.tearDown()
    }

    func testOffByDefaultAndParsedFromItsTable() {
        XCTAssertEqual(defaultConfig.workspaceSidebar.intelligence, WorkspaceIntelligenceConfig())
        XCTAssertEqual(defaultConfig.workspaceSidebar.intelligence.mode, .off)
        XCTAssertFalse(defaultConfig.suggestsTopicGroups)
        let (parsed, errors) = parseConfig("""
            [workspace-sidebar]
            enabled = true
            mode = 'tabs'
            [workspace-sidebar.intelligence]
            mode = 'manual'
            excluded-apps = ['com.example.Secret', ' com.example.Secret ', 'com.apple.Notes']
            """)
        XCTAssertEqual(errors, [])
        XCTAssertEqual(parsed.workspaceSidebar.intelligence.mode, .manual)
        XCTAssertEqual(parsed.workspaceSidebar.intelligence.excludedApps, ["com.example.Secret", "com.apple.Notes"])
        XCTAssertTrue(parsed.suggestsTopicGroups)
    }

    func testBadValuesAreReported() {
        let (_, errors) = parseConfig("""
            [workspace-sidebar.intelligence]
            mode = 'automatic'
            excluded-apps = ['']
            unknown = 1
            """)
        XCTAssertEqual(errors.map(\.description).sorted(), [
            "workspace-sidebar.intelligence.excluded-apps: App bundle IDs can't be empty",
            "workspace-sidebar.intelligence.mode: Possible values: off, manual",
            "workspace-sidebar.intelligence.unknown: Unknown key",
        ])
    }

    func testManualOutsideTabsModeOffersNothing() {
        var configuration = defaultConfig
        configuration.workspaceSidebar.intelligence.mode = .manual
        configuration.workspaceSidebar.enabled = true
        configuration.workspaceSidebar.mode = .dock
        XCTAssertFalse(configuration.suggestsTopicGroups)
        configuration.workspaceSidebar.mode = .tabs
        XCTAssertTrue(configuration.suggestsTopicGroups)
        configuration.workspaceSidebar.enabled = false
        XCTAssertFalse(configuration.suggestsTopicGroups)
    }

    func testTheSettingsToggleWritesTheMode() throws {
        let field = SettingsCatalog.field("workspace-sidebar.intelligence.mode")
        XCTAssertEqual(field.modes, [.tabs], "Shown with the Tabs settings, and only there")
        XCTAssertEqual(field.read(defaultConfig), .bool(false))
        XCTAssertEqual(field.render(.bool(true)), "'manual'")
        var configuration = defaultConfig
        field.project?(&configuration, .bool(true))
        XCTAssertEqual(configuration.workspaceSidebar.intelligence.mode, .manual)
        let text = updateSettingsAppearanceConfig(in: "config-version = 2\n", section: "workspace-sidebar.intelligence",
            values: ["mode": field.render(.bool(true))])
        let (parsed, errors) = parseConfig(text)
        XCTAssertEqual(errors, [])
        XCTAssertEqual(parsed.workspaceSidebar.intelligence.mode, .manual)
        XCTAssertTrue(SettingsPanelLayout.sections(.tabs).flatMap(\.fields).contains(field.id))
        XCTAssertTrue(field.searchText.contains("Apple Intelligence"))
    }

    func testTheProjectAndSelectionMenusOfferSuggestionsOnlyWhenOn() async throws {
        for (name, id) in [("a", UInt32(500)), ("b", 501)] {
            TestWindow.new(id: id, parent: Workspace.get(byName: name).rootTilingContainer, app: TopicTestApps.xcode, title: "tiling-app \(name)")
        }
        _ = WorkspaceTopicTestEnvironment.setUp(provider: FakeWorkspaceTopicProvider())
        await updateWorkspaceSidebarModel()
        let project = TrayMenuModel.shared.workspaceSidebarActiveProjectId
        let scope = WorkspaceTopicTestEnvironment.scopeId
        func projectTitles() throws -> [String] {
            try XCTUnwrap(workspaceSidebarIdentityMenuModel(.project(project), targetMonitorScopeId: scope)).entries.map(\.title)
        }
        XCTAssertTrue(try projectTitles().contains(workspaceTopicSuggestMenuTitle))
        let selection = workspaceSidebarTabSelectionMenuEntries(["a", "b"], workspaces: TrayMenuModel.shared.workspaceSidebarWorkspaces,
            collections: [], send: { _ in }, clear: {}, suggest: { _, _ in })
        XCTAssertTrue(selection.map(\.title).contains(workspaceTopicSuggestMenuTitle))

        config.workspaceSidebar.intelligence.mode = .off
        XCTAssertFalse(try projectTitles().contains(workspaceTopicSuggestMenuTitle))
        WorkspaceSidebarTabSelection.shared.clear()
        _ = WorkspaceSidebarTabSelection.shared.handleClick(on: "a", modifiers: .command, order: ["a", "b"], active: nil)
        _ = WorkspaceSidebarTabSelection.shared.handleClick(on: "b", modifiers: .command, order: ["a", "b"], active: nil)
        let menu = try XCTUnwrap(workspaceSidebarTabSelectionMenu(containing: "a", scope: scope))
        XCTAssertFalse(menu.items.map(\.title).contains(workspaceTopicSuggestMenuTitle))
        config.workspaceSidebar.intelligence.mode = .manual
        let on = try XCTUnwrap(workspaceSidebarTabSelectionMenu(containing: "a", scope: scope))
        XCTAssertTrue(on.items.map(\.title).contains(workspaceTopicSuggestMenuTitle))
        XCTAssertEqual(config.workspaceSidebar.mode, .tabs)
    }
}
