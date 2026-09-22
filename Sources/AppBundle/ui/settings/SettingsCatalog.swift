import AppKit
import Common

enum SettingsGroup: String, CaseIterable, Identifiable {
    case startup, menuBar, dockMode, placement, dockAppearance, sidebarAppearance, dockContent
    case newWindows, interaction, defaultLayout, windowChrome, windowTabs, gaps, projects, automation
    var id: String { rawValue }
    var title: String {
        switch self {
            case .startup: "Startup"
            case .menuBar: "Menu bar"
            case .dockMode: "Dock & Sidebar"
            case .placement: "Position & visibility"
            case .dockAppearance: "Compact Dock appearance"
            case .sidebarAppearance: "Sidebar / expanded panel appearance"
            case .dockContent: "Content"
            case .newWindows: "New windows"
            case .interaction: "Interaction"
            case .defaultLayout: "Default layout"
            case .windowChrome: "Window appearance"
            case .windowTabs: "Window tabs"
            case .gaps: "Tiling gaps"
            case .projects: "Projects & workspaces"
            case .automation: "Event actions"
        }
    }
    var page: SettingsSidebarItem {
        switch self {
            case .startup, .menuBar: .general
            case .dockMode, .placement, .dockAppearance, .sidebarAppearance, .dockContent: .appearance
            case .projects: .workspaces
            case .automation: .configuration
            default: .behavior
        }
    }
}

struct SettingsChoice: Identifiable {
    let title: String
    let value: String
    var id: String { value }
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
}

enum SettingsControl {
    case toggle, choice([SettingsChoice]), position, integer(ClosedRange<Int>), percentage, magnification, text, color
}

@MainActor
struct SettingsField: Identifiable {
    let group: SettingsGroup
    let section: String?
    let key: String
    let title: String
    let help: String
    let control: SettingsControl
    let read: (Config) -> SettingsValue
    var render: (SettingsValue) -> String = { $0.toml }
    var visible: (SettingsEditor) -> Bool = { _ in true }
    var unavailableReason: (SettingsEditor) -> String? = { _ in nil }
    var preservingDockAppearance = false
    var writePreference: ((SettingsValue) -> Void)?
    var preferenceDefault: SettingsValue?
    nonisolated var id: String { [section, key].compactMap { $0 }.joined(separator: ".") }
    var defaultValue: SettingsValue { preferenceDefault ?? read(defaultConfig) }
    var searchText: String { "\(title) \(help) \(id) \(group.title) \(group.page.label)" }
}

@MainActor
enum SettingsCatalog {
    static func field(_ key: String) -> SettingsField { (fields + automationFields).first { $0.id == key }! }
    static func matches(_ field: SettingsField, query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { field.searchText.localizedStandardContains(String($0)) }
    }
    static func results(_ query: String) -> [SettingsField] { (fields + automationFields).filter { matches($0, query: query) } }

    static func visibilityHint(for field: SettingsField, editor: SettingsEditor) -> String {
        let dock = editor.value(Self.field("workspace-sidebar.mode")).text == "dock"
        if field.group == .dockAppearance && !dock || ["dock-position", "dock-left-gap", "show-app-badges", "show-app-tooltips", "show-hidden-workspace-app-reminders"].contains(field.key) && !dock {
            return "Choose Dock mode to use this setting."
        }
        if ["collapsed-width", "stay-on-top"].contains(field.key) { return "Choose Sidebar mode to use this setting." }
        if field.key == "dock-magnification-amount" { return "Enable Magnify icons on hover to adjust the amount." }
        if ["show-seconds", "show-date", "show-weekday"].contains(field.key) { return "Enable Show clock to use this setting." }
        if field.key == "height" || field.key == "tab-group-padding" { return "Enable Show window tabs to use this setting." }
        if field.key == "glass-opacity" { return "Choose Liquid Glass as the compact Dock background style." }
        if field.key.contains("custom-color") { return "Choose Solid color, then Custom, to use this setting." }
        return "Choose Solid color as the background style to use this setting."
    }

    static let automationFields: [SettingsField] = {
        let events: [(String, String, (Config) -> [String])] = [
            ("exec-on-workspace-change", "On workspace change", { $0.execOnWorkspaceChange }),
            ("on-focus-changed", "On focus change", { $0.onFocusChanged.map { $0.args.description } }),
            ("on-focused-monitor-changed", "On focused monitor change", { $0.onFocusedMonitorChanged.map { $0.args.description } }),
            ("on-mode-changed", "On mode change", { $0.onModeChanged.map { $0.args.description } }),
        ]
        return events.map { key, title, read in
            SettingsField(group: .automation, section: nil, key: key, title: title,
                help: "One command per line. Apply saves and reloads this event action.", control: .text,
                read: { .text(read($0).joined(separator: "\n")) },
                render: { "[" + $0.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.map { SettingsValue.text($0).toml }.joined(separator: ", ") + "]" })
        }
    }()

    static func bool(_ group: SettingsGroup, _ key: String, _ title: String, _ help: String,
        section: String? = nil, path: KeyPath<Config, Bool>) -> SettingsField {
        SettingsField(group: group, section: section, key: key, title: title, help: help,
            control: .toggle, read: { .bool($0[keyPath: path]) })
    }
    static func int(_ group: SettingsGroup, _ key: String, _ title: String, _ help: String,
        section: String? = nil, range: ClosedRange<Int>, path: KeyPath<Config, Int>) -> SettingsField {
        SettingsField(group: group, section: section, key: key, title: title, help: help,
            control: .integer(range), read: { .integer($0[keyPath: path]) })
    }
    static func choice(_ group: SettingsGroup, _ key: String, _ title: String, _ help: String,
        section: String? = nil, options: [SettingsChoice], read: @escaping (Config) -> String) -> SettingsField {
        SettingsField(group: group, section: section, key: key, title: title, help: help,
            control: .choice(options), read: { .text(read($0)) })
    }

    static let fields: [SettingsField] = {
        let sidebar = "workspace-sidebar"
        let dock = "workspace-sidebar.dock-appearance"
        let expanded = "workspace-sidebar.sidebar-appearance"
        var result: [SettingsField] = [
            bool(.startup, "start-at-login", "Start at login", "Launch WinMux after you sign in.", path: \.startAtLogin),
            bool(.startup, "auto-reload-config", "Reload TOML automatically", "Apply valid configuration edits saved from another editor.", path: \.autoReloadConfig),
            bool(.dockMode, "enabled", "Show Dock or Sidebar", "Show the workspace rail on the configured displays.", section: sidebar, path: \.workspaceSidebar.enabled),
            choice(.dockMode, "mode", "Mode", "Dock shows workspace tiles and app icons. Sidebar shows a compact rail that expands into window details.", section: sidebar,
                options: [.init("Dock", "dock"), .init("Sidebar", "sidebar")], read: { $0.workspaceSidebar.mode.rawValue }),
            SettingsField(group: .placement, section: sidebar, key: "dock-position", title: "Position", help: "Bottom temporarily enables macOS Dock auto-hide and restores your previous setting afterward. WinMux hides only when the macOS Dock appears on the same edge of the same display.",
                control: .position, read: { .text($0.workspaceSidebar.dockPosition.rawValue) }),
            int(.placement, "dock-left-gap", "Edge gap", "Space from the selected display edge, in points. The gap closes when the panel expands.", section: sidebar, range: 0...24, path: \.workspaceSidebar.dockLeftGap),
            bool(.placement, "enable-focus", "Follow the active display", "Show the rail only on the focused display, within the configured monitor selection.", section: sidebar, path: \.workspaceSidebar.enableFocus),
            bool(.placement, "auto-hide", "Automatically hide the rail", "Reveal the compact rail when the pointer reaches its display edge.", section: sidebar, path: \.workspaceSidebar.autoHide),
            bool(.placement, "always-expanded", "Keep the panel expanded", "Reserve space for window details instead of collapsing to the compact rail.", section: sidebar, path: \.workspaceSidebar.alwaysExpanded),
            bool(.placement, "stay-on-top", "Keep above the macOS Dock", "Applies to Sidebar mode. Dock mode yields when the macOS Dock appears on the same edge of the same display.", section: sidebar, path: \.workspaceSidebar.stayOnTop),
            int(.placement, "menu-bar-reserve-height", "Menu bar space", "Space below the macOS menu bar, in points. Set to 0 when the menu bar auto-hides.", section: sidebar, range: 0...72, path: \.workspaceSidebar.menuBarReserveHeight),
            choice(.dockAppearance, "style", "Background style", "The compact Dock has its own appearance. Expanded panels use the separate Sidebar appearance below.", section: dock,
                options: [.init("Liquid Glass", "liquid-glass"), .init("Solid color", "solid")], read: { $0.workspaceSidebar.dockChromeStyle.rawValue }),
            SettingsField(group: .dockAppearance, section: dock, key: "glass-opacity", title: "Glass opacity", help: "Adjust the compact Dock background without fading icons or labels.", control: .percentage, read: { .number($0.workspaceSidebar.dockGlassOpacity) }),
            choice(.dockAppearance, "solid-color", "Solid color", "Choose an opaque Dock background.", section: dock,
                options: ChromeSolidColor.allCases.map { .init($0.title, $0.rawValue) }, read: { $0.workspaceSidebar.dockSolidColor.rawValue }),
            SettingsField(group: .dockAppearance, section: dock, key: "custom-color", title: "Custom color", help: "Choose the compact Dock background color.", control: .color, read: { .text($0.workspaceSidebar.dockCustomColor) }),
            int(.dockAppearance, "dock-icon-size", "Maximum icon size", "Icon canvas size in points. Icons shrink automatically when needed to fit; Dock thickness stays proportional.", section: sidebar, range: 24...48, path: \.workspaceSidebar.dockIconSize),
            choice(.dockAppearance, "dock-identity-labels", "Icon identity labels", "Show a short window or workspace label beneath app icons. Auto labels apps repeated across workspaces.", section: sidebar,
                options: [.init("Auto", "auto"), .init("Always", "always"), .init("Off", "off")], read: { $0.workspaceSidebar.dockIdentityLabels.rawValue }),
            bool(.dockAppearance, "dock-magnification", "Magnify icons on hover", "Enlarge nearby icons inward from the screen edge. Respects macOS Reduce Motion.", section: sidebar, path: \.workspaceSidebar.dockMagnification),
            SettingsField(group: .dockAppearance, section: sidebar, key: "dock-magnification-amount", title: "Magnification", help: "Maximum enlarged size relative to the resting icon size.", control: .magnification, read: { .number($0.workspaceSidebar.dockMagnificationAmount) }),
            bool(.dockContent, "show-workspace-tooltips", "Show workspace tooltips", "Show the full workspace name when hovering over its icon. Also controls workspace help in Sidebar mode.", section: sidebar, path: \.workspaceSidebar.showWorkspaceTooltips),
            bool(.dockContent, "show-app-tooltips", "Show app tooltips", "Show the app name and window title when hovering over an app icon.", section: sidebar, path: \.workspaceSidebar.showAppTooltips),
            bool(.dockContent, "show-hidden-workspace-app-reminders", "Show hidden workspace app reminders", "Show apps with Dock badges from workspaces outside the current Dock after the clock. Scroll to see more reminders.", section: sidebar, path: \.workspaceSidebar.showHiddenWorkspaceAppReminders),
            bool(.dockContent, "show-app-badges", "Show app badges", "Mirror unread labels exposed by the macOS Dock. Some apps do not expose badges.", section: sidebar, path: \.workspaceSidebar.showAppBadges),
            bool(.sidebarAppearance, "blur", "Blur background", "Use darker Liquid Glass behind window titles and search. Applies to Sidebar mode and the expanded Dock.", section: expanded, path: \.workspaceSidebar.sidebarAppearance.blur),
            SettingsField(group: .sidebarAppearance, section: expanded, key: "background-opacity", title: "Background darkness", help: "Darken the blurred backdrop for readable text; labels retain full opacity.", control: .percentage, read: { .number($0.workspaceSidebar.sidebarAppearance.backgroundOpacity) }),
            int(.sidebarAppearance, "width", "Expanded width", "Panel width in points for window details and search.", section: sidebar, range: 120...480, path: \.workspaceSidebar.width),
            int(.sidebarAppearance, "collapsed-width", "Collapsed width", "Compact rail width in Sidebar mode. Dock thickness follows icon size.", section: sidebar, range: 28...120, path: \.workspaceSidebar.collapsedWidth),
            bool(.dockContent, "show-status-pills", "Show status indicators", "Display workspace status information.", section: sidebar, path: \.workspaceSidebar.showStatusPills),
            bool(.dockContent, "show-clock", "Show clock", "Display time and optional date details in the rail.", section: sidebar, path: \.workspaceSidebar.showClock),
            bool(.dockContent, "show-seconds", "Show seconds", "Include seconds in the clock.", section: sidebar, path: \.workspaceSidebar.showSeconds),
            bool(.dockContent, "show-date", "Show date", "Include the current date.", section: sidebar, path: \.workspaceSidebar.showDate),
            bool(.dockContent, "show-weekday", "Show weekday", "Include the day of the week.", section: sidebar, path: \.workspaceSidebar.showWeekday),
            bool(.newWindows, "automatically-tile-new-windows", "Tile new windows automatically", "Place new windows into the tiled layout.", path: \.automaticallyTileNewWindows),
            bool(.newWindows, "auto-add-new-windows-to-tab-group", "Add new windows to the current tab group", "Keep new windows in the selected stack instead of creating a new tile.", path: \.autoAddNewWindowsToTabGroup),
            bool(.newWindows, "automatically-unhide-macos-hidden-apps", "Unhide macOS-hidden apps", "Restore apps macOS has hidden when they receive focus.", path: \.automaticallyUnhideMacosHiddenApps),
            bool(.interaction, "enable-shake-to-toggle-tiling", "Shake to toggle tiling", "Shake a window by its title bar to switch between floating and tiled.", path: \.enableShakeToToggleTiling),
            bool(.interaction, "enable-normalization-flatten-containers", "Flatten matching containers", "Simplify adjacent containers with the same layout orientation.", path: \.enableNormalizationFlattenContainers),
            bool(.interaction, "enable-normalization-opposite-orientation-for-nested-containers", "Normalize nested orientations", "Avoid nested tiled containers with the same orientation.", path: \.enableNormalizationOppositeOrientationForNestedContainers),
            choice(.defaultLayout, "default-root-container-layout", "Root layout", "Layout used for new workspaces.", options: [.init("Tiles", "tiles"), .init("Tab group", "tab-group")], read: { $0.defaultRootContainerLayout.rawValue }),
            choice(.defaultLayout, "default-root-container-orientation", "Root orientation", "How new tiled containers split.", options: [.init("Automatic", "auto"), .init("Horizontal", "horizontal"), .init("Vertical", "vertical")], read: { $0.defaultRootContainerOrientation.rawValue }),
            choice(.windowChrome, "chrome-style", "Window background style", "Appearance of window tab groups and the switcher, independent of the Dock.", section: sidebar,
                options: [.init("Liquid Glass", "liquid-glass"), .init("Solid color", "solid")], read: { $0.workspaceSidebar.chromeStyle.rawValue }),
            choice(.windowChrome, "solid-chrome-color", "Solid color", "Choose the background for window tabs and the switcher.", section: sidebar,
                options: ChromeSolidColor.allCases.map { .init($0.title, $0.rawValue) }, read: { $0.workspaceSidebar.solidChromeColor.rawValue }),
            SettingsField(group: .windowChrome, section: sidebar, key: "solid-chrome-custom-color", title: "Custom color", help: "Choose the window chrome color.", control: .color, read: { .text($0.workspaceSidebar.solidChromeCustomColor) }),
            bool(.windowTabs, "enabled", "Show window tabs", "Display browser-like tabs for stacked windows.", section: "window-tabs", path: \.windowTabs.enabled),
            int(.windowTabs, "height", "Tab height", "Height of the tab strip in points.", section: "window-tabs", range: 21...80, path: \.windowTabs.height),
            int(.windowTabs, "tab-group-padding", "Tab group padding", "Space around tab groups in points.", range: 0...80, path: \.tabGroupPadding),
            choice(.projects, "project-deletion-action", "Deleting projects", "Choose what happens to a project's windows when it is deleted.", section: sidebar,
                options: [.init("Close project windows", "close-windows"), .init("Move windows elsewhere", "move-windows-to-fallback")], read: { $0.workspaceSidebar.projectDeletionAction.rawValue }),
            SettingsField(group: .projects, section: nil, key: "persistent-workspaces", title: "Persistent workspaces", help: "Comma-separated names of workspaces to keep when empty. Press Return to save.", control: .text,
                read: { .text($0.persistentWorkspaces.joined(separator: ", ")) }, render: { "[" + $0.text.split(separator: ",").map { SettingsValue.text($0.trimmingCharacters(in: .whitespaces)).toml }.joined(separator: ", ") + "]" }),
            choice(.projects, "shortcuts-preset", "Shortcut preset", "Use your custom shortcuts or install the built-in Rectangle set.", options: [.init("Custom", "none"), .init("Rectangle", "rectangle")], read: { $0.shortcutsPreset.rawValue }),
        ]
        for (key, title, read) in gapReaders {
            result.append(SettingsField(group: .gaps, section: "gaps", key: key, title: title, help: "Spacing in points. Editing replaces any per-monitor values for this gap.", control: .integer(key.hasPrefix("inner") ? 0...80 : 0...120), read: { .integer(read($0)) }))
        }
        result += preferenceFields
        for index in result.indices {
            let id = result[index].id
            if result[index].group == .windowChrome { result[index].preservingDockAppearance = true }
            result[index].visible = { editor in isVisible(id, editor: editor) }
            result[index].unavailableReason = { editor in
                if id == "persistent-workspaces", editor.configuration.configVersion < 2 {
                    return "Requires config-version = 2. Update the configuration in the TOML Editor to use persistent workspaces."
                }
                if ["workspace-sidebar.dock-magnification", "workspace-sidebar.dock-magnification-amount"].contains(id),
                   editor.value(field("workspace-sidebar.always-expanded")).bool { return "Available when the panel can collapse." }
                if id == "workspace-sidebar.sidebar-appearance.background-opacity", !editor.value(field("workspace-sidebar.sidebar-appearance.blur")).bool { return "Enable background blur to adjust darkness." }
                return nil
            }
        }
        return result
    }()

    private static func isVisible(_ id: String, editor: SettingsEditor) -> Bool {
        func value(_ key: String) -> SettingsValue { editor.value(field(key)) }
        let dock = value("workspace-sidebar.mode").text == "dock"
        switch id {
            case "workspace-sidebar.dock-position", "workspace-sidebar.dock-left-gap", "workspace-sidebar.show-app-badges", "workspace-sidebar.show-app-tooltips", "workspace-sidebar.show-hidden-workspace-app-reminders": return dock
            case "workspace-sidebar.collapsed-width", "workspace-sidebar.stay-on-top": return !dock
            case "workspace-sidebar.dock-magnification-amount": return dock && value("workspace-sidebar.dock-magnification").bool
            case "workspace-sidebar.dock-appearance.glass-opacity": return dock && value("workspace-sidebar.dock-appearance.style").text == "liquid-glass"
            case "workspace-sidebar.dock-appearance.solid-color": return dock && value("workspace-sidebar.dock-appearance.style").text == "solid"
            case "workspace-sidebar.dock-appearance.custom-color": return dock && value("workspace-sidebar.dock-appearance.style").text == "solid" && value("workspace-sidebar.dock-appearance.solid-color").text == "custom"
            case "workspace-sidebar.solid-chrome-color": return value("workspace-sidebar.chrome-style").text == "solid"
            case "workspace-sidebar.solid-chrome-custom-color": return value("workspace-sidebar.chrome-style").text == "solid" && value("workspace-sidebar.solid-chrome-color").text == "custom"
            case "workspace-sidebar.show-seconds", "workspace-sidebar.show-date", "workspace-sidebar.show-weekday": return value("workspace-sidebar.show-clock").bool
            case "window-tabs.height", "tab-group-padding": return value("window-tabs.enabled").bool
            default: return field(id).group != .dockAppearance || dock
        }
    }

    private static let gapReaders: [(String, String, (Config) -> Int)] = [
        ("inner.horizontal", "Inner horizontal", { settingsConstantValue($0.gaps.inner.horizontal) }),
        ("inner.vertical", "Inner vertical", { settingsConstantValue($0.gaps.inner.vertical) }),
        ("outer.left", "Outer left", { settingsConstantValue($0.gaps.outer.left) }),
        ("outer.right", "Outer right", { settingsConstantValue($0.gaps.outer.right) }),
        ("outer.top", "Outer top", { settingsConstantValue($0.gaps.outer.top) }),
        ("outer.bottom", "Outer bottom", { settingsConstantValue($0.gaps.outer.bottom) }),
    ]

    private static var preferenceFields: [SettingsField] {
        var style = choice(.menuBar, "style", "Menu bar style", "Choose how workspaces appear in the menu bar.", section: "preferences.menu-bar", options: MenuBarStyle.allCases.map { .init($0.title, $0.rawValue) }, read: { _ in ExperimentalUISettings().displayStyle.rawValue })
        style.preferenceDefault = .text(MenuBarStyle.monospacedText.rawValue)
        style.writePreference = { value in
            guard let next = MenuBarStyle(rawValue: value.text) else { return }
            var settings = ExperimentalUISettings(); settings.displayStyle = next
            TrayMenuModel.shared.experimentalUISettings = settings; updateTrayText()
        }
        var icon = choice(.menuBar, "icon", "Menu bar icon", "Choose the WinMux status icon.", section: "preferences.menu-bar", options: MenuBarIconAppearance.allCases.map { .init($0.title, $0.rawValue) }, read: { _ in ExperimentalUISettings().iconAppearance.rawValue })
        icon.preferenceDefault = .text(MenuBarIconAppearance.color.rawValue)
        icon.writePreference = { value in
            guard let next = MenuBarIconAppearance(rawValue: value.text) else { return }
            var settings = ExperimentalUISettings(); settings.iconAppearance = next
            TrayMenuModel.shared.experimentalUISettings = settings
        }
        var pairs = SettingsField(group: .windowTabs, section: "preferences", key: "double-sided-windows", title: "Double-sided windows", help: "For two-window groups, Option-click or Option-Tab flips between sides. Three or more windows use tabs. Optional Screen Recording enables the rotation animation; respects Reduce Motion.", control: .toggle, read: { _ in .bool(ExperimentalUISettings().doubleSidedWindows) })
        pairs.preferenceDefault = .bool(false)
        pairs.writePreference = { value in
            var settings = ExperimentalUISettings(); settings.doubleSidedWindows = value.bool
            scheduleRefreshSession(.menuBarButton)
        }
        return [style, icon, pairs]
    }
}
