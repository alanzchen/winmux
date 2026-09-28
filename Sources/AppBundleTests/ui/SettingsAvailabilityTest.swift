import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class SettingsAvailabilityTest: XCTestCase {
    private enum Kind: String { case available, hidden, disabled, forced }

    private func kind(_ id: String, _ setup: (inout Config) -> Void = { _ in }) -> Kind {
        var configuration = defaultConfig
        configuration.workspaceSidebar.enabled = true
        setup(&configuration)
        return switch SettingsCatalog.field(id).availability(in: configuration) {
            case .available: .available
            case .hidden: .hidden
            case .disabled: .disabled
            case .forced: .forced
        }
    }

    private func mode(_ mode: WorkspaceSidebarMode, _ more: @escaping (inout Config) -> Void = { _ in }) -> (inout Config) -> Void {
        { $0.workspaceSidebar.mode = mode; more(&$0) }
    }

    /// Each row follows runtime-truth-table.md: what the running panel reads in each mode.
    func testPanelSettingsFollowTheModesThatUseThem() {
        let expectations: [(String, [WorkspaceSidebarMode: Kind])] = [
            ("workspace-sidebar.dock-position", [.dock: .available, .sidebar: .hidden, .tabs: .hidden]),
            ("workspace-sidebar.dock-icon-size", [.dock: .available, .sidebar: .hidden, .tabs: .hidden]),
            ("workspace-sidebar.dock-appearance.style", [.dock: .available, .sidebar: .hidden, .tabs: .hidden]),
            ("workspace-sidebar.show-app-tooltips", [.dock: .available, .sidebar: .hidden, .tabs: .hidden]),
            ("workspace-sidebar.show-hidden-workspace-app-reminders", [.dock: .available, .sidebar: .hidden, .tabs: .hidden]),
            ("workspace-sidebar.show-app-badges", [.dock: .available, .sidebar: .hidden, .tabs: .available]),
            ("workspace-sidebar.stay-on-top", [.dock: .available, .sidebar: .available, .tabs: .available]),
            ("workspace-sidebar.always-expanded", [.dock: .available, .sidebar: .available, .tabs: .hidden]),
            ("workspace-sidebar.tabs-always-expanded", [.dock: .hidden, .sidebar: .hidden, .tabs: .available]),
            ("workspace-sidebar.browser-tabs", [.dock: .hidden, .sidebar: .hidden, .tabs: .available]),
            ("workspace-sidebar.show-workspace-tooltips", [.dock: .available, .sidebar: .available, .tabs: .hidden]),
            ("workspace-sidebar.show-clock", [.dock: .available, .sidebar: .available, .tabs: .hidden]),
            ("workspace-sidebar.sidebar-appearance.blur", [.dock: .available, .sidebar: .available, .tabs: .hidden]),
            ("workspace-sidebar.width", [.dock: .available, .sidebar: .available, .tabs: .available]),
            ("workspace-sidebar.display-filter", [.dock: .available, .sidebar: .available, .tabs: .available]),
            ("workspace-sidebar.menu-bar-reserve-height", [.dock: .available, .sidebar: .available, .tabs: .available]),
            // Tabs keeps its sidebar open by default, so its collapsed rail settings wait for that to be off.
            ("workspace-sidebar.collapsed-width", [.dock: .hidden, .sidebar: .available, .tabs: .disabled]),
            ("workspace-sidebar.auto-hide", [.dock: .available, .sidebar: .available, .tabs: .disabled]),
        ]
        for (id, modes) in expectations {
            for (panelMode, expected) in modes {
                XCTAssertEqual(kind(id, mode(panelMode)), expected, "\(id) in \(panelMode)")
            }
        }
        XCTAssertFalse(SettingsCatalog.fields.contains { $0.key == "show-status-pills" }, "No view reads status pills")
        XCTAssertTrue(parseConfig("[workspace-sidebar]\nshow-status-pills = false\n").errors.isEmpty, "The key still parses")
    }

    func testKeepingThePanelOpenDisablesCollapsedRailSettings() {
        let pinnedDock = mode(.dock) { $0.workspaceSidebar.alwaysExpanded = true }
        for id in ["dock-left-gap", "dock-appearance.style", "dock-icon-size", "dock-identity-labels", "dock-magnification",
                   "dock-magnification-amount", "show-hidden-workspace-app-reminders", "auto-hide"] {
            XCTAssertEqual(kind("workspace-sidebar.\(id)", pinnedDock), .disabled, id)
        }
        for id in ["width", "sidebar-appearance.blur", "show-clock", "show-app-badges", "show-app-tooltips"] {
            XCTAssertEqual(kind("workspace-sidebar.\(id)", pinnedDock), .available, id)
        }
        XCTAssertEqual(kind("workspace-sidebar.collapsed-width", mode(.sidebar) { $0.workspaceSidebar.alwaysExpanded = true }), .disabled)
        XCTAssertEqual(kind("workspace-sidebar.collapsed-width", mode(.tabs) { $0.workspaceSidebar.tabsAlwaysExpanded = false }), .available)
        // Auto-hide still reveals the rail from a strip as wide as the collapsed rail.
        XCTAssertEqual(kind("workspace-sidebar.collapsed-width", mode(.sidebar) { $0.workspaceSidebar.autoHide = true }), .available)
        // Tabs' own toggle is independent of the Dock/Sidebar one.
        XCTAssertEqual(kind("workspace-sidebar.auto-hide", mode(.tabs) {
            $0.workspaceSidebar.tabsAlwaysExpanded = false; $0.workspaceSidebar.alwaysExpanded = true
        }), .available)
    }

    func testAlternativesHideAndDependentsDisable() {
        let solidDock = mode(.dock) { $0.workspaceSidebar.dockAppearance.style = .solid }
        XCTAssertEqual(kind("workspace-sidebar.dock-appearance.glass-opacity", solidDock), .hidden)
        XCTAssertEqual(kind("workspace-sidebar.dock-appearance.solid-color", solidDock), .available)
        XCTAssertEqual(kind("workspace-sidebar.dock-appearance.custom-color", solidDock), .hidden)
        XCTAssertEqual(kind("workspace-sidebar.dock-appearance.custom-color", mode(.dock) {
            $0.workspaceSidebar.dockAppearance.style = .solid; $0.workspaceSidebar.dockAppearance.solidColor = .custom
        }), .available)
        // An unselected alternative stays hidden even when the whole group is unavailable.
        XCTAssertEqual(kind("workspace-sidebar.dock-appearance.glass-opacity", mode(.dock) {
            $0.workspaceSidebar.dockAppearance.style = .solid; $0.workspaceSidebar.alwaysExpanded = true
        }), .hidden)
        // The Dock inherits the window chrome style while its own is unset.
        XCTAssertEqual(kind("workspace-sidebar.dock-appearance.glass-opacity", mode(.dock) { $0.workspaceSidebar.chromeStyle = .solid }), .hidden)
        XCTAssertEqual(kind("workspace-sidebar.solid-chrome-color", { $0.workspaceSidebar.chromeStyle = .solid }), .available)
        XCTAssertEqual(kind("workspace-sidebar.solid-chrome-color"), .hidden)

        XCTAssertEqual(kind("workspace-sidebar.dock-magnification-amount", mode(.dock)), .disabled, "Magnification is off by default")
        XCTAssertEqual(kind("workspace-sidebar.dock-magnification-amount", mode(.dock) { $0.workspaceSidebar.dockMagnification = true }), .available)
        XCTAssertEqual(kind("workspace-sidebar.show-seconds", mode(.sidebar) { $0.workspaceSidebar.showClock = false }), .disabled)
        XCTAssertEqual(kind("workspace-sidebar.sidebar-appearance.background-opacity", mode(.sidebar) {
            $0.workspaceSidebar.sidebarAppearance.blur = false
        }), .disabled)
        XCTAssertEqual(kind("workspace-sidebar.browser-tab-icons", mode(.tabs) { $0.workspaceSidebar.browserTabs = false }), .disabled)
    }

    func testClockDateFollowsWhereTheClockCanShowIt() {
        // The default configuration turns the clock off.
        func clock(_ panelMode: WorkspaceSidebarMode, _ more: @escaping (inout WorkspaceSidebarConfig) -> Void = { _ in }) -> (inout Config) -> Void {
            mode(panelMode) { $0.workspaceSidebar.showClock = true; more(&$0.workspaceSidebar) }
        }
        let collapsibleSideDock = clock(.dock) { $0.dockPosition = .right }
        XCTAssertEqual(kind("workspace-sidebar.show-date", collapsibleSideDock), .disabled)
        XCTAssertEqual(kind("workspace-sidebar.show-weekday", collapsibleSideDock), .disabled)
        XCTAssertEqual(kind("workspace-sidebar.show-seconds", collapsibleSideDock), .available)
        XCTAssertEqual(kind("workspace-sidebar.show-date", clock(.dock) { $0.dockPosition = .bottom }), .available)
        XCTAssertEqual(kind("workspace-sidebar.show-date", clock(.dock) { $0.alwaysExpanded = true }), .available)
        XCTAssertEqual(kind("workspace-sidebar.show-date", clock(.sidebar)), .available, "Expanding the Sidebar shows the date")
        XCTAssertEqual(SettingsCatalog.field("workspace-sidebar.show-date").availability(in: {
            var configuration = defaultConfig
            configuration.workspaceSidebar.enabled = true
            configuration.workspaceSidebar.mode = .dock
            return configuration
        }()), .disabled("Turn on Show clock to use this setting."), "The clock's own switch comes first")
    }

    func testTabsModeHasNoWindowStacksOnlyWhileItsPanelIsOn() {
        let stackIds = ["window-tabs.enabled", "window-tabs.height", "tab-group-padding", "preferences.double-sided-windows",
                        "auto-add-new-windows-to-tab-group", "default-root-container-layout"]
        for id in stackIds {
            XCTAssertEqual(kind(id, mode(.tabs)), .hidden, id)
            XCTAssertNotEqual(kind(id, mode(.tabs) { $0.workspaceSidebar.enabled = false }), .hidden,
                "\(id): with the panel off, Tabs mode keeps window stacks")
        }
        XCTAssertEqual(kind("default-root-container-orientation", mode(.tabs)), .available)
        XCTAssertEqual(kind("workspace-sidebar.new-workspace-launcher", mode(.tabs)), .forced)
        XCTAssertEqual(kind("workspace-sidebar.new-workspace-launcher", mode(.tabs) { $0.workspaceSidebar.enabled = false }), .available)
        XCTAssertEqual(kind("workspace-sidebar.new-workspace-launcher", mode(.dock)), .available)
        XCTAssertEqual(kind("workspace-sidebar.chrome-style", mode(.tabs)), .available, "The switcher and launcher still use it")
    }

    func testTabGroupPaddingAppliesOnlyWithoutWindowTabs() {
        let tabsOn = mode(.dock) { $0.windowTabs.enabled = true }
        let tabsOff = mode(.dock) { $0.windowTabs.enabled = false }
        XCTAssertEqual(kind("tab-group-padding", tabsOn), .disabled)
        XCTAssertEqual(kind("tab-group-padding", tabsOff), .available)
        XCTAssertEqual(kind("window-tabs.height", tabsOn), .available)
        XCTAssertEqual(kind("window-tabs.height", tabsOff), .disabled)
        XCTAssertEqual(kind("preferences.double-sided-windows", tabsOn), .available)
        XCTAssertEqual(kind("preferences.double-sided-windows", tabsOff), .disabled)
    }

    func testPanelOffDisablesPanelPresentationOnly() {
        let off = mode(.dock) { $0.workspaceSidebar.enabled = false }
        for id in ["workspace-sidebar.dock-position", "workspace-sidebar.width", "workspace-sidebar.stay-on-top",
                   "workspace-sidebar.display-filter", "workspace-sidebar.show-clock"] {
            XCTAssertEqual(kind(id, off), .disabled, id)
        }
        for id in ["workspace-sidebar.enabled", "workspace-sidebar.mode", "workspace-sidebar.chrome-style",
                   "workspace-sidebar.save-named-workspaces", "workspace-sidebar.project-deletion-action",
                   "workspace-sidebar.new-workspace-launcher", "window-tabs.enabled"] {
            XCTAssertEqual(kind(id, off), .available, id)
        }
        // Another mode's setting, and an unselected alternative, stay hidden rather than disabled.
        XCTAssertEqual(kind("workspace-sidebar.browser-tabs", off), .hidden)
        XCTAssertEqual(kind("workspace-sidebar.dock-appearance.solid-color", off), .hidden)
        XCTAssertEqual(kind("workspace-sidebar.dock-appearance.custom-color", off), .hidden)
        XCTAssertEqual(kind("workspace-sidebar.dock-appearance.glass-opacity", off), .disabled)
    }

    func testWindowTabsGroupExplainsWhyItIsEmptyInTabsMode() {
        var configuration = defaultConfig
        configuration.workspaceSidebar.mode = .tabs
        XCTAssertEqual(SettingsCatalog.emptyGroupNotice(.windowTabs, in: configuration), SettingsRequirement.hasWindowStacks.text)
        XCTAssertTrue(SettingsCatalog.fields.filter { $0.group == .windowTabs }.allSatisfy { !$0.availability(in: configuration).isShown })
        XCTAssertNil(SettingsCatalog.emptyGroupNotice(.gaps, in: configuration))
        configuration.workspaceSidebar.enabled = false
        XCTAssertNil(SettingsCatalog.emptyGroupNotice(.windowTabs, in: configuration))
    }

    func testDraftsProjectOntoTheConfigurationBeforeSaving() {
        let editor = SettingsEditor(configuration: defaultConfig)
        let mode = SettingsCatalog.field("workspace-sidebar.mode")
        editor.setDraft(.bool(true), for: SettingsCatalog.field("workspace-sidebar.enabled"))
        editor.setDraft(.text("tabs"), for: mode)
        XCTAssertTrue(editor.projection.usesBrowserTabs)
        XCTAssertFalse(editor.configuration.usesBrowserTabs, "Drafts don't change the saved configuration")
        XCTAssertEqual(SettingsCatalog.field("window-tabs.enabled").availability(editor), .hidden(
            "Tabs mode has no window stacks. Choose Dock or Sidebar to use this setting."))
        XCTAssertTrue(editor.projection.opensNewWindowsInNewWorkspace, "An unset default follows the drafted mode")
        XCTAssertEqual(editor.value(SettingsCatalog.field("open-new-windows-in-new-workspace")), .bool(true),
            "The switch shows what the drafted mode would do")
        editor.setDraft(.text("dock"), for: mode)
        XCTAssertEqual(editor.value(SettingsCatalog.field("open-new-windows-in-new-workspace")), .bool(false))
    }

    /// Every file-backed field has a writer, and it writes what `read` reads back.
    func testEveryFileSettingProjectsItsOwnValue() {
        let exempt: Set<String> = ["persistent-workspaces"] // Nothing depends on it before saving.
        for field in SettingsCatalog.fields where field.writePreference == nil && !exempt.contains(field.id) {
            guard let project = field.project else { XCTFail("\(field.id) has no draft writer"); continue }
            let sample: SettingsValue = switch field.control {
                case .toggle: .bool(!field.defaultValue.bool)
                case .choice(let options): .text(options.last { $0.value != field.defaultValue.text }?.value ?? field.defaultValue.text)
                case .position: .text("right")
                case .integer(let range): .integer(range.lowerBound == field.defaultValue.integer ? range.upperBound : range.lowerBound)
                case .percentage, .magnification: .number(0.25)
                case .color: .text("#123456")
                case .text: field.defaultValue
            }
            var configuration = defaultConfig
            project(&configuration, sample)
            XCTAssertEqual(field.read(configuration), sample, field.id)
        }
    }

    /// The projection shows exactly what saving produces, including the Dock keeping the
    /// window chrome look it inherited when that chrome changes.
    func testProjectionMatchesWhatSavingProduces() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        disk.text += "[workspace-sidebar]\n    enabled = true\n    mode = 'dock'\n    chrome-style = 'liquid-glass'\n    glass-opacity = 0.4\n"
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        let edits: [(String, SettingsValue)] = [
            ("workspace-sidebar.chrome-style", .text("solid")),
            ("workspace-sidebar.solid-chrome-color", .text("custom")),
            ("workspace-sidebar.solid-chrome-custom-color", .text("#2A3B4C")),
            ("workspace-sidebar.dock-appearance.solid-color", .text("slate")),
            ("workspace-sidebar.always-expanded", .bool(true)),
            ("workspace-sidebar.mode", .text("tabs")),
            ("window-tabs.enabled", .bool(false)),
        ]
        for (id, value) in edits {
            let field = SettingsCatalog.field(id)
            editor.setDraft(value, for: field)
            let projected = editor.projection
            editor.commit(field)
            await editor.waitUntilIdle()
            XCTAssertNil(editor.error, id)
            XCTAssertEqual(projected.workspaceSidebar, config.workspaceSidebar, "after \(id)")
            XCTAssertEqual(projected.windowTabs, config.windowTabs, "after \(id)")
        }
        XCTAssertEqual(config.workspaceSidebar.dockChromeStyle, .liquidGlass, "The Dock kept its inherited glass")
        XCTAssertEqual(config.workspaceSidebar.dockGlassOpacity, 0.4)

        editor.reset(.windowChrome)
        let projected = editor.projection
        await editor.waitUntilIdle()
        XCTAssertEqual(projected.workspaceSidebar, config.workspaceSidebar, "after restoring window chrome defaults")
    }

    /// Restoring a default that follows the mode removes its key; the projection must too.
    func testRestoringAModeDependentDefaultProjectsItAsUnset() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        disk.text += "open-new-windows-in-new-workspace = false\n[workspace-sidebar]\n    enabled = true\n    mode = 'tabs'\n"
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        let newWorkspace = SettingsCatalog.field("open-new-windows-in-new-workspace")
        disk.failWrites = true
        editor.reset(.newWindows)
        await editor.waitUntilIdle()
        XCTAssertNotNil(editor.error)
        XCTAssertNil(editor.projection.openNewWindowsInNewWorkspace, "A failed restore keeps its unset intent")
        XCTAssertEqual(editor.value(newWorkspace), .bool(true), "Unset follows Tabs")
        let mode = SettingsCatalog.field("workspace-sidebar.mode")
        editor.setDraft(.text("dock"), for: mode)
        XCTAssertEqual(editor.value(newWorkspace), .bool(false), "Unset follows the drafted mode")
        disk.failWrites = false
        editor.retry()
        editor.commit(mode)
        await editor.waitUntilIdle()
        XCTAssertNil(editor.error)
        XCTAssertNil(config.openNewWindowsInNewWorkspace)
        XCTAssertEqual(editor.projection.openNewWindowsInNewWorkspace, config.openNewWindowsInNewWorkspace)
        XCTAssertFalse(config.opensNewWindowsInNewWorkspace)
        XCTAssertTrue(editor.unsetDrafts.isEmpty)

        editor.setDraft(.bool(true), for: newWorkspace)
        XCTAssertEqual(editor.projection.openNewWindowsInNewWorkspace, true, "An explicit edit replaces the unset intent")
    }
}
