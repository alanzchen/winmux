import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceSidebarModeTest: XCTestCase {
    func testModeDefaultsAndLegacyMigration() {
        for (text, expected) in [("", WorkspaceSidebarMode.sidebar),
                                 ("show-app-icons = true", .dock),
                                 ("show-app-icons = false", .sidebar)] {
            let (parsed, errors) = parseConfig("[workspace-sidebar]\n" + text)
            XCTAssertTrue(errors.isEmpty)
            XCTAssertEqual(parsed.workspaceSidebar.mode, expected)
        }
    }

    func testExplicitModeWinsOverLegacyAliasInEitherOrder() {
        for mode in WorkspaceSidebarMode.allCases {
            let legacy = "show-app-icons = \(mode == .sidebar)"
            let modern = "mode = '\(mode.rawValue)'"
            for fields in ["\(legacy)\n\(modern)", "\(modern)\n\(legacy)"] {
                let (parsed, errors) = parseConfig("[workspace-sidebar]\n" + fields)
                XCTAssertTrue(errors.isEmpty)
                XCTAssertEqual(parsed.workspaceSidebar.mode, mode)
            }
        }
        for invalid in ["'compact'", "true", "4"] {
            XCTAssertFalse(parseConfig("[workspace-sidebar]\nmode = \(invalid)").errors.isEmpty)
        }
    }

    func testSettingsModeSwitchPreservesDockPreferencesAndSidebarWidth() {
        var text = """
        [workspace-sidebar]
        show-app-icons = true
        stay-on-top = false
        collapsed-width = 50
        dock-icon-size = 48
        dock-magnification = true
        glass-opacity = 0.25
        """
        for mode in [WorkspaceSidebarMode.sidebar, .dock, .sidebar] {
            text = updateSettingsScalarConfig(in: text, section: "workspace-sidebar", key: "mode", renderedValue: "'\(mode.rawValue)'")
            let (parsed, errors) = parseConfig(text)
            XCTAssertTrue(errors.isEmpty)
            let sidebar = parsed.workspaceSidebar
            XCTAssertEqual(sidebar.mode, mode)
            XCTAssertEqual(sidebar.effectiveCollapsedWidth, mode == .dock ? 64 : 50)
            XCTAssertEqual(sidebar.usesDockMagnification, mode == .dock)
            XCTAssertEqual(sidebar.dockIconSize, 48)
            XCTAssertEqual(sidebar.glassOpacity, 0.25)
            XCTAssertFalse(sidebar.stayOnTop)
        }
    }

    func testLiveModeSwitchRestoresDarkSidebarWithoutDiscardingDockOpacity() {
        let previous = config
        defer { config = previous }
        config.workspaceSidebar.glassOpacity = 0.25
        config.workspaceSidebar.collapsedWidth = 50
        config.workspaceSidebar.chromeStyle = .liquidGlass
        config.workspaceSidebar.autoHide = false
        let model = TrayMenuModel()
        for mode in [WorkspaceSidebarMode.dock, .sidebar, .dock] {
            config.workspaceSidebar.mode = mode
            model.refreshWorkspaceSidebarAppearance()
            let snapshot = workspaceSidebarSnapshot(from: model).configuration
            XCTAssertEqual(snapshot.showAppIcons, mode == .dock)
            XCTAssertEqual(snapshot.effectiveGlassOpacity, mode == .dock ? 0.25 : 1)
            XCTAssertEqual(snapshot.compactRailWidth, mode == .dock ? 64 : 50)
        }
        config.workspaceSidebar.mode = .sidebar
        config.workspaceSidebar.chromeStyle = .solid
        model.refreshWorkspaceSidebarAppearance()
        XCTAssertEqual(model.workspaceSidebarAppearance.effectiveChromeStyle, .liquidGlass)
        XCTAssertEqual(config.workspaceSidebar.chromeStyle, .solid, "Other chrome retains its saved style")
    }
}
