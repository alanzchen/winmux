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
            case .dockMode: "Workspace panel"
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
    /// Writes a draft into a copy of the configuration, so availability and the preview can
    /// respond before saving. Nil for preferences and values nothing else depends on.
    var project: ((inout Config, SettingsValue) -> Void)?
    /// Workspace panel modes that use this setting. Nil for settings outside the panel.
    var modes: Set<WorkspaceSidebarMode>?
    var requirements: [SettingsRequirement] = []
    var preservingDockAppearance = false
    var writePreference: ((SettingsValue) -> Void)?
    var preferenceDefault: SettingsValue?
    /// For a key whose default depends on other settings: its value while unset. Restoring
    /// the default removes the key instead of writing today's value into the file.
    var unsetValue: ((Config) -> SettingsValue)?
    /// Whether the file sets such a key, so restoring it has something to remove.
    var isSet: ((Config) -> Bool)?
    /// Removes such a key from a draft projection.
    var clear: ((inout Config) -> Void)?
    /// A label and help that name what a key shared by several modes does in the current one.
    var contextualTitle: ((Config) -> String)?
    var contextualHelp: ((Config) -> String)?
    /// Other labels search finds this setting by.
    var searchAliases: [String] = []
    nonisolated var id: String { [section, key].compactMap { $0 }.joined(separator: ".") }
    var defaultValue: SettingsValue { preferenceDefault ?? read(defaultConfig) }
    func defaultValue(for configuration: Config) -> SettingsValue { unsetValue?(configuration) ?? defaultValue }
    var searchText: String {
        let modeNames = modes.map { WorkspaceSidebarMode.settingsOrder.filter($0.contains).map(\.settingsTitle).joined(separator: " ") } ?? ""
        return "\(title) \(searchAliases.joined(separator: " ")) \(help) \(id) \(group.title) \(group.page.label) \(modeNames)"
    }
    func title(in configuration: Config) -> String { contextualTitle?(configuration) ?? title }
    func help(in configuration: Config) -> String { contextualHelp?(configuration) ?? help }
}

extension SettingsField {
    func withUnsetValue(_ value: @escaping (Config) -> SettingsValue, isSet: @escaping (Config) -> Bool,
                        clear: @escaping (inout Config) -> Void) -> SettingsField {
        var field = self
        field.unsetValue = value
        field.isSet = isSet
        field.clear = clear
        return field
    }

    func projecting(_ project: @escaping (inout Config, SettingsValue) -> Void) -> SettingsField {
        var field = self
        field.project = project
        return field
    }

    /// A Dock that can collapse sizes each floating project column; kept expanded, its panel.
    func dockWidthTitle() -> SettingsField {
        var field = self
        let title = field.contextualTitle, help = field.contextualHelp
        let column = ("Project column width", "Width of each project column in the Dock's floating view, in points.")
        let panel = ("Panel width", "Width of the kept-expanded Dock, in points. On the left or right, you can also drag its inner edge.")
        field.contextualTitle = { $0.workspaceSidebar.mode == .dock ? ($0.workspaceSidebar.pinsSidebarOpen ? panel.0 : column.0) : title?($0) ?? field.title }
        field.contextualHelp = { $0.workspaceSidebar.mode == .dock ? ($0.workspaceSidebar.pinsSidebarOpen ? panel.1 : column.1) : help?($0) ?? field.help }
        field.searchAliases += [column.0, panel.0]
        return field
    }

    /// Per-mode label and help for a key several modes share. Search finds every label.
    func titled(by mode: [WorkspaceSidebarMode: (title: String, help: String)]) -> SettingsField {
        var field = self
        field.contextualTitle = { mode[$0.workspaceSidebar.mode]?.title ?? field.title }
        field.contextualHelp = { mode[$0.workspaceSidebar.mode]?.help ?? field.help }
        field.searchAliases += mode.values.map(\.title)
        return field
    }
}

@MainActor
enum SettingsCatalog {
    static let allFields = fields + automationFields
    static func field(_ key: String) -> SettingsField { allFields.first { $0.id == key }! }
    static func matches(_ field: SettingsField, query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { field.searchText.localizedStandardContains(String($0)) }
    }
    static func results(_ query: String) -> [SettingsField] { allFields.filter { matches($0, query: query) } }

    /// Why a page section has no rows in the current configuration.
    static func emptyGroupNotice(_ group: SettingsGroup, in configuration: Config) -> String? {
        group == .windowTabs && configuration.usesBrowserTabs ? SettingsRequirement.hasWindowStacks.text : nil
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
            control: .toggle, read: { .bool($0[keyPath: path]) },
            project: (path as? WritableKeyPath<Config, Bool>).map { path in SettingsProjection.write(path) { $0.bool } })
    }
    static func int(_ group: SettingsGroup, _ key: String, _ title: String, _ help: String,
        section: String? = nil, range: ClosedRange<Int>, path: KeyPath<Config, Int>) -> SettingsField {
        SettingsField(group: group, section: section, key: key, title: title, help: help,
            control: .integer(range), read: { .integer($0[keyPath: path]) },
            project: (path as? WritableKeyPath<Config, Int>).map { path in SettingsProjection.write(path) { $0.integer } })
    }
    static func choice(_ group: SettingsGroup, _ key: String, _ title: String, _ help: String,
        section: String? = nil, options: [SettingsChoice], read: @escaping (Config) -> String,
        project: ((inout Config, SettingsValue) -> Void)? = nil) -> SettingsField {
        SettingsField(group: group, section: section, key: key, title: title, help: help,
            control: .choice(options), read: { .text(read($0)) }, project: project)
    }

    static let fields: [SettingsField] = {
        let sidebar = "workspace-sidebar"
        let dock = "workspace-sidebar.dock-appearance"
        let expanded = "workspace-sidebar.sidebar-appearance"
        let dockOnly: Set<WorkspaceSidebarMode> = [.dock]
        let collapsibleRails: Set<WorkspaceSidebarMode> = [.dock, .sidebar]
        let dockStyle = { (configuration: Config) in configuration.workspaceSidebar.dockChromeStyle }
        let chromeStyle = { (configuration: Config) in configuration.workspaceSidebar.chromeStyle }
        var result: [SettingsField] = [
            bool(.startup, "start-at-login", "Start at login", "Launch WinMux after you sign in.", path: \.startAtLogin),
            bool(.startup, "auto-reload-config", "Reload TOML automatically", "Apply valid configuration edits saved from another editor.", path: \.autoReloadConfig),
            bool(.dockMode, "enabled", "Show the workspace panel", "Show the Dock, Sidebar, or Tabs panel on the configured displays.", section: sidebar, path: \.workspaceSidebar.enabled),
            choice(.dockMode, "mode", "Mode", "Dock shows workspace tiles and app icons. Sidebar shows a compact rail that expands into window details. Tabs opens a full sidebar with optional color groups and split windows sharing a row.", section: sidebar,
                options: [.init("Dock", "dock"), .init("Sidebar", "sidebar"), .init("Tabs", "tabs")], read: { $0.workspaceSidebar.mode.rawValue },
                project: SettingsProjection.raw(\.workspaceSidebar.mode)),
            SettingsField(group: .placement, section: sidebar, key: "dock-position", title: "Position", help: "Bottom temporarily enables macOS Dock auto-hide and restores your previous setting afterward. WinMux hides only when the macOS Dock appears on the same edge of the same display.",
                control: .position, read: { .text($0.workspaceSidebar.dockPosition.rawValue) }, project: SettingsProjection.raw(\.workspaceSidebar.dockPosition))
                .used(in: dockOnly),
            int(.placement, "dock-left-gap", "Edge gap", "Space from the selected display edge, in points. The gap closes when the panel expands.", section: sidebar, range: 0...24, path: \.workspaceSidebar.dockLeftGap)
                .used(in: dockOnly).requiring(.dockCanCollapse),
            bool(.placement, "enable-focus", "Show Focused filter", "Add a Focused choice to each panel's display menu. It lists only the focused workspace.", section: sidebar, path: \.workspaceSidebar.enableFocus)
                .used(in: .allModes),
            choice(.placement, "display-filter", "Show workspaces from", "This display lists only the workspaces on the display each Dock, Sidebar, or Tabs panel is on. When the panel appears on only some displays, it lists all of them. A panel's display menu overrides this until WinMux quits, the chosen display disconnects, or this setting changes.", section: sidebar,
                options: [.init("This display", "this-display"), .init("All displays", "all-displays")], read: { $0.workspaceSidebar.displayFilter.rawValue },
                project: SettingsProjection.raw(\.workspaceSidebar.displayFilter))
                .used(in: .allModes),
            bool(.placement, "auto-hide", "Automatically hide the rail", "Reveal the compact rail when the pointer reaches its display edge.", section: sidebar, path: \.workspaceSidebar.autoHide)
                .used(in: .allModes).requiring(.panelCanCollapse)
                .titled(by: [.dock: ("Automatically hide the Dock", "Reveal the Dock when the pointer reaches its display edge."),
                             .tabs: ("Automatically hide the collapsed rail", "Reveal the collapsed tab rail when the pointer reaches the left edge of its display.")]),
            bool(.placement, "always-expanded", "Keep the panel expanded", "Reserve space for window details instead of collapsing to the compact rail.", section: sidebar, path: \.workspaceSidebar.alwaysExpanded)
                .used(in: collapsibleRails)
                .titled(by: [.dock: ("Keep the Dock expanded", "Replace the compact Dock with a reserved panel of window details."),
                             .sidebar: ("Keep the Sidebar expanded", "Reserve space for window details instead of collapsing to the compact rail.")]),
            bool(.placement, "tabs-always-expanded", "Keep the tab sidebar expanded", "Keep the browser-style sidebar open in Tabs mode. This setting is independent of Dock and Sidebar modes.", section: sidebar, path: \.workspaceSidebar.tabsAlwaysExpanded)
                .used(in: [.tabs]),
            bool(.dockContent, "browser-tabs", "Show browser tabs", "List and select tabs inside Safari and compatible Chrome, Brave, and Edge windows. Applies to the expanded Tabs sidebar.", section: sidebar, path: \.workspaceSidebar.browserTabs)
                .used(in: [.tabs]),
            bool(.dockContent, "browser-tab-icons", "Website icons for Chrome-family tabs", "Read the selected tab's address in each listed Chrome, Chromium, Brave or Edge window and download its icon directly, without cookies. Includes Incognito and does not use browser proxy or VPN extensions or secure DNS. Icons appear as tabs are selected. Safari uses its app icon.", section: sidebar, path: \.workspaceSidebar.browserTabIcons)
                .used(in: [.tabs]).requiring(.disables("Turn on Show browser tabs to use website icons.") { $0.workspaceSidebar.browserTabs }),
            bool(.dockContent, "music-player-at-bottom", "Keep the Music player at the bottom", "Show Apple Music's player at the bottom of the expanded Tabs sidebar while Music is open, whichever tab or project is showing, instead of under Music's tab.", section: sidebar, path: \.workspaceSidebar.musicPlayerAtBottom)
                .used(in: [.tabs]),
            bool(.placement, "stay-on-top", "Keep above the macOS Dock", "Keep the panel above the macOS Dock and other floating windows. When off, system UI such as the macOS Dock can appear above it. A Dock-mode panel still yields when the macOS Dock appears on the same edge of the same display.", section: sidebar, path: \.workspaceSidebar.stayOnTop)
                .used(in: .allModes),
            int(.placement, "menu-bar-reserve-height", "Menu bar space", "Space below the macOS menu bar, in points. Set to 0 when the menu bar auto-hides.", section: sidebar, range: 0...72, path: \.workspaceSidebar.menuBarReserveHeight)
                .used(in: .allModes),
            choice(.dockAppearance, "style", "Background style", "Background of the compact Dock. When the Dock expands, it uses the Expanded view settings.", section: dock,
                options: [.init("Liquid Glass", "liquid-glass"), .init("Solid color", "solid")], read: { $0.workspaceSidebar.dockChromeStyle.rawValue },
                project: SettingsProjection.raw(\.workspaceSidebar.dockAppearance.style))
                .used(in: dockOnly).requiring(.dockCanCollapse),
            SettingsField(group: .dockAppearance, section: dock, key: "glass-opacity", title: "Glass opacity", help: "Adjust the compact Dock background without fading icons or labels.", control: .percentage,
                read: { .number($0.workspaceSidebar.dockGlassOpacity) }, project: SettingsProjection.number(\.workspaceSidebar.dockAppearance.glassOpacity))
                .used(in: dockOnly).requiring(.hides("Choose Liquid Glass as the compact Dock background style.") { dockStyle($0) == .liquidGlass }, .dockCanCollapse),
            choice(.dockAppearance, "solid-color", "Solid color", "Choose an opaque Dock background.", section: dock,
                options: ChromeSolidColor.allCases.map { .init($0.title, $0.rawValue) }, read: { $0.workspaceSidebar.dockSolidColor.rawValue },
                project: SettingsProjection.raw(\.workspaceSidebar.dockAppearance.solidColor))
                .used(in: dockOnly).requiring(.hides("Choose Solid color as the background style to use this setting.") { dockStyle($0) == .solid }, .dockCanCollapse),
            SettingsField(group: .dockAppearance, section: dock, key: "custom-color", title: "Custom color", help: "Choose the compact Dock background color.", control: .color,
                read: { .text($0.workspaceSidebar.dockCustomColor) }, project: SettingsProjection.text(\.workspaceSidebar.dockAppearance.customColor))
                .used(in: dockOnly).requiring(.hides("Choose Solid color, then Custom, to use this setting.") {
                    dockStyle($0) == .solid && $0.workspaceSidebar.dockSolidColor == .custom
                }, .dockCanCollapse),
            int(.dockAppearance, "dock-icon-size", "Maximum icon size", "Icon canvas size in points. Icons shrink automatically when needed to fit; Dock thickness stays proportional.", section: sidebar, range: 24...48, path: \.workspaceSidebar.dockIconSize)
                .used(in: dockOnly).requiring(.dockCanCollapse),
            choice(.dockAppearance, "dock-identity-labels", "Icon identity labels", "Show a short window or workspace label beneath app icons. Auto labels apps repeated across workspaces.", section: sidebar,
                options: [.init("Auto", "auto"), .init("Always", "always"), .init("Off", "off")], read: { $0.workspaceSidebar.dockIdentityLabels.rawValue },
                project: SettingsProjection.raw(\.workspaceSidebar.dockIdentityLabels))
                .used(in: dockOnly).requiring(.dockCanCollapse),
            bool(.dockAppearance, "dock-magnification", "Magnify icons on hover", "Enlarge nearby icons inward from the screen edge. Respects macOS Reduce Motion.", section: sidebar, path: \.workspaceSidebar.dockMagnification)
                .used(in: dockOnly).requiring(.dockCanCollapse),
            SettingsField(group: .dockAppearance, section: sidebar, key: "dock-magnification-amount", title: "Magnification", help: "Maximum enlarged size relative to the resting icon size.", control: .magnification,
                read: { .number($0.workspaceSidebar.dockMagnificationAmount) }, project: SettingsProjection.number(\.workspaceSidebar.dockMagnificationAmount))
                .used(in: dockOnly).requiring(.dockCanCollapse, .disables("Turn on Magnify icons on hover to adjust the amount.") { $0.workspaceSidebar.dockMagnification }),
            bool(.dockContent, "show-workspace-tooltips", "Show workspace tooltips", "Show the full workspace name when hovering over its icon. Also controls workspace help in Sidebar mode.", section: sidebar, path: \.workspaceSidebar.showWorkspaceTooltips)
                .used(in: collapsibleRails),
            bool(.dockContent, "show-app-tooltips", "Show app tooltips", "Show the app name and window title when hovering over an app icon.", section: sidebar, path: \.workspaceSidebar.showAppTooltips)
                .used(in: dockOnly),
            bool(.dockContent, "show-hidden-workspace-app-reminders", "Show hidden workspace app reminders", "Show apps with Dock badges from workspaces outside the current Dock after the clock. Scroll to see more reminders.", section: sidebar, path: \.workspaceSidebar.showHiddenWorkspaceAppReminders)
                .used(in: dockOnly).requiring(.dockCanCollapse),
            bool(.dockContent, "show-app-badges", "Show app badges", "Mirror unread labels exposed by the macOS Dock. Some apps do not expose badges.", section: sidebar, path: \.workspaceSidebar.showAppBadges)
                .used(in: [.dock, .tabs]),
            bool(.sidebarAppearance, "blur", "Blur background", "Use darker Liquid Glass behind window titles and search. Applies to the whole Sidebar-mode panel and to the Dock's expanded view.", section: expanded, path: \.workspaceSidebar.sidebarAppearance.blur)
                .used(in: collapsibleRails),
            SettingsField(group: .sidebarAppearance, section: expanded, key: "background-opacity", title: "Background darkness", help: "Darken the blurred backdrop for readable text; labels retain full opacity.", control: .percentage,
                read: { .number($0.workspaceSidebar.sidebarAppearance.backgroundOpacity) }, project: SettingsProjection.number(\.workspaceSidebar.sidebarAppearance.backgroundOpacity))
                .used(in: collapsibleRails).requiring(.disables("Turn on Blur background to adjust darkness.") { $0.workspaceSidebar.sidebarAppearance.blur }),
            int(.sidebarAppearance, "width", "Expanded width", "Width in points of the expanded panel, or of each project column in the Dock's floating view. When the panel is kept expanded, you can also drag its inner edge.", section: sidebar, range: workspaceSidebarResizableWidthRange, path: \.workspaceSidebar.width)
                .used(in: .allModes)
                .titled(by: [.sidebar: ("Expanded width", "Width of the expanded Sidebar, in points. While it's kept expanded, you can also drag its inner edge. With Remember width for each display, a display you've resized keeps its own width."),
                             .tabs: ("Sidebar width", "Width of the open tab sidebar, in points. While it's kept open, you can also drag its inner edge. With Remember width for each display, a display you've resized keeps its own width.")])
                .dockWidthTitle(),
            bool(.sidebarAppearance, "width-per-display", "Remember width for each display", "Dragging the panel's inner edge changes only that display's width, and the display keeps it. Displays you haven't resized use the width above. Double-click the edge to put a display back on it.", section: sidebar, path: \.workspaceSidebar.widthPerDisplay)
                .used(in: [.sidebar, .tabs]),
            int(.sidebarAppearance, "collapsed-width", "Collapsed width", "Compact rail width in Sidebar and Tabs modes. Dock thickness follows icon size.", section: sidebar, range: 28...120, path: \.workspaceSidebar.collapsedWidth)
                .used(in: [.sidebar, .tabs]).requiring(.panelCanCollapse)
                .titled(by: [.sidebar: ("Collapsed width", "Width of the compact rail, in points."),
                             .tabs: ("Collapsed rail width", "Width of the collapsed tab rail, in points.")]),
            bool(.dockContent, "show-clock", "Show clock", "Display time and optional date details in the rail.", section: sidebar, path: \.workspaceSidebar.showClock)
                .used(in: collapsibleRails),
            bool(.dockContent, "show-seconds", "Show seconds", "Include seconds in the clock.", section: sidebar, path: \.workspaceSidebar.showSeconds)
                .used(in: collapsibleRails).requiring(.showsClock),
            bool(.dockContent, "show-date", "Show date", "Include the current date. On a bottom Dock, it appears when the Dock is tall enough.", section: sidebar, path: \.workspaceSidebar.showDate)
                .used(in: collapsibleRails).requiring(.showsClock, .showsClockDate),
            bool(.dockContent, "show-weekday", "Show weekday", "Include the day of the week. On a bottom Dock, it appears when the Dock is tall enough.", section: sidebar, path: \.workspaceSidebar.showWeekday)
                .used(in: collapsibleRails).requiring(.showsClock, .showsClockDate),
            bool(.newWindows, "automatically-tile-new-windows", "Tile new windows automatically", "Place new windows into the tiled layout.", path: \.automaticallyTileNewWindows),
            bool(.newWindows, "auto-add-new-windows-to-tab-group", "Add new windows to the current tab group", "Keep new windows in the selected stack instead of creating a new tile.", path: \.autoAddNewWindowsToTabGroup)
                .requiring(.hasWindowStacks),
            bool(.newWindows, "open-new-windows-in-new-workspace", "Open new windows in a new workspace", "Give each window you open its own empty workspace in the current project, right after the current one in Tabs mode, where this is on unless you turn it off. Dialogs, restored windows, and windows that on-window-detected rules move to another workspace stay where they are. Takes precedence over adding to the current tab group.", path: \.opensNewWindowsInNewWorkspace)
                .withUnsetValue({ .bool($0.usesBrowserTabs) }, isSet: { $0.openNewWindowsInNewWorkspace != nil },
                    clear: { $0.openNewWindowsInNewWorkspace = nil })
                .projecting(SettingsProjection.write(\.openNewWindowsInNewWorkspace) { $0.bool }),
            bool(.newWindows, "automatically-unhide-macos-hidden-apps", "Unhide macOS-hidden apps", "Restore apps macOS has hidden when they receive focus.", path: \.automaticallyUnhideMacosHiddenApps),
            bool(.interaction, "enable-shake-to-toggle-tiling", "Shake to toggle tiling", "Shake a window by its title bar to switch between floating and tiled.", path: \.enableShakeToToggleTiling),
            bool(.interaction, "middle-click-closes-windows", "Middle-click closes windows", "Middle-click a window tab, or a window in the expanded sidebar, to close it. Apps can still ask to save changes first.", path: \.middleClickClosesWindows),
            bool(.interaction, "enable-normalization-flatten-containers", "Flatten matching containers", "Simplify adjacent containers with the same layout orientation.", path: \.enableNormalizationFlattenContainers),
            bool(.interaction, "enable-normalization-opposite-orientation-for-nested-containers", "Normalize nested orientations", "Avoid nested tiled containers with the same orientation.", path: \.enableNormalizationOppositeOrientationForNestedContainers),
            choice(.defaultLayout, "default-root-container-layout", "Root layout", "Layout used for new workspaces.", options: [.init("Tiles", "tiles"), .init("Tab group", "tab-group")], read: { $0.defaultRootContainerLayout.rawValue },
                project: SettingsProjection.raw(\.defaultRootContainerLayout))
                .requiring(.hasWindowStacks),
            choice(.defaultLayout, "default-root-container-orientation", "Root orientation", "How new tiled containers split.", options: [.init("Automatic", "auto"), .init("Horizontal", "horizontal"), .init("Vertical", "vertical")], read: { $0.defaultRootContainerOrientation.rawValue },
                project: SettingsProjection.raw(\.defaultRootContainerOrientation)),
            choice(.windowChrome, "chrome-style", "Window background style", "Background of window tabs, the window switcher, the app launcher and drag previews. The compact Dock has its own background.", section: sidebar,
                options: [.init("Liquid Glass", "liquid-glass"), .init("Solid color", "solid")], read: { $0.workspaceSidebar.chromeStyle.rawValue },
                project: SettingsProjection.raw(\.workspaceSidebar.chromeStyle)),
            choice(.windowChrome, "solid-chrome-color", "Solid color", "Choose the background for window tabs and the switcher.", section: sidebar,
                options: ChromeSolidColor.allCases.map { .init($0.title, $0.rawValue) }, read: { $0.workspaceSidebar.solidChromeColor.rawValue },
                project: SettingsProjection.raw(\.workspaceSidebar.solidChromeColor))
                .requiring(.hides("Choose Solid color as the background style to use this setting.") { chromeStyle($0) == .solid }),
            SettingsField(group: .windowChrome, section: sidebar, key: "solid-chrome-custom-color", title: "Custom color", help: "Choose the window chrome color.", control: .color,
                read: { .text($0.workspaceSidebar.solidChromeCustomColor) }, project: SettingsProjection.text(\.workspaceSidebar.solidChromeCustomColor))
                .requiring(.hides("Choose Solid color, then Custom, to use this setting.") {
                    chromeStyle($0) == .solid && $0.workspaceSidebar.solidChromeColor == .custom
                }),
            bool(.windowTabs, "enabled", "Show window tabs", "Display browser-like tabs for stacked windows.", section: "window-tabs", path: \.windowTabs.enabled)
                .requiring(.hasWindowStacks),
            int(.windowTabs, "height", "Tab height", "Height of the tab strip in points.", section: "window-tabs", range: 21...80, path: \.windowTabs.height)
                .requiring(.hasWindowStacks, .showsWindowTabs),
            int(.windowTabs, "tab-group-padding", "Tab group padding", "Without window tabs, stacked windows are inset by this many points so the edges of the others stay visible.", range: 0...80, path: \.tabGroupPadding)
                .requiring(.hasWindowStacks, .disables("Applies when Show window tabs is off.") { !$0.windowTabs.enabled }),
            choice(.projects, "project-deletion-action", "Deleting projects", "Choose what happens to a project's windows when it is deleted.", section: sidebar,
                options: [.init("Close project windows", "close-windows"), .init("Move windows elsewhere", "move-windows-to-fallback")], read: { $0.workspaceSidebar.projectDeletionAction.rawValue },
                project: SettingsProjection.raw(\.workspaceSidebar.projectDeletionAction)),
            bool(.projects, "save-named-workspaces", "Save workspaces when you name them", "A named workspace keeps its layout and apps, and returns to its display, after WinMux or your Mac restarts. Choose Forget Saved Workspace in the workspace menu to stop.", section: sidebar, path: \.workspaceSidebar.saveNamedWorkspaces),
            bool(.projects, "open-saved-workspace-apps-at-startup", "Open saved workspace apps at startup", "Opens the apps saved workspaces are waiting for when WinMux starts. When off, use Open Missing Apps in the workspace menu.", section: sidebar, path: \.workspaceSidebar.openSavedWorkspaceAppsAtStartup),
            bool(.projects, "new-workspace-launcher", "Show app launcher after creating a workspace", "New Workspace opens a launcher in the empty workspace. Picking an app opens a new window of it there, even if the app is already running elsewhere.", section: sidebar, path: \.workspaceSidebar.newWorkspaceLauncher)
                .requiring(.forces("In Tabs mode, New Tab always opens the launcher.") { !$0.usesBrowserTabs }),
            bool(.projects, "launcher-menu-fallback", "Use an app's New Window menu", "For apps WinMux has no tested adapter for, the launcher presses the app's own New Window menu item. Without it, the launcher says they can't open a new window.", section: sidebar, path: \.workspaceSidebar.launcherMenuFallback),
            SettingsField(group: .projects, section: nil, key: "persistent-workspaces", title: "Persistent workspaces", help: "Comma-separated names of workspaces to keep when empty. Press Return to save.", control: .text,
                read: { .text($0.persistentWorkspaces.joined(separator: ", ")) }, render: { "[" + $0.text.split(separator: ",").map { SettingsValue.text($0.trimmingCharacters(in: .whitespaces)).toml }.joined(separator: ", ") + "]" })
                .requiring(.disables("Requires config-version = 2. Update the configuration in the TOML Editor to use persistent workspaces.") { $0.configVersion >= 2 }),
            choice(.projects, "shortcuts-preset", "Shortcut preset", "Use your custom shortcuts or install the built-in Rectangle set.", options: [.init("Custom", "none"), .init("Rectangle", "rectangle")], read: { $0.shortcutsPreset.rawValue },
                project: SettingsProjection.raw(\.shortcutsPreset)),
        ]
        for (key, title, path) in gapPaths {
            result.append(SettingsField(group: .gaps, section: "gaps", key: key, title: title, help: "Spacing in points. Editing replaces any per-monitor values for this gap.", control: .integer(key.hasPrefix("inner") ? 0...80 : 0...120),
                read: { .integer(settingsConstantValue($0[keyPath: path])) }, project: SettingsProjection.write(path) { .constant($0.integer) }))
        }
        result += preferenceFields
        for index in result.indices where result[index].group == .windowChrome { result[index].preservingDockAppearance = true }
        return result
    }()

    private static let gapPaths: [(String, String, WritableKeyPath<Config, DynamicConfigValue<Int>>)] = [
        ("inner.horizontal", "Inner horizontal", \.gaps.inner.horizontal),
        ("inner.vertical", "Inner vertical", \.gaps.inner.vertical),
        ("outer.left", "Outer left", \.gaps.outer.left),
        ("outer.right", "Outer right", \.gaps.outer.right),
        ("outer.top", "Outer top", \.gaps.outer.top),
        ("outer.bottom", "Outer bottom", \.gaps.outer.bottom),
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
            .requiring(.hasWindowStacks, .showsWindowTabs)
        pairs.preferenceDefault = .bool(false)
        pairs.writePreference = { value in
            var settings = ExperimentalUISettings(); settings.doubleSidedWindows = value.bool
            scheduleRefreshSession(.menuBarButton)
        }
        return [style, icon, pairs]
    }
}
