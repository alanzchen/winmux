import Common

/// One card on the Workspace Panel page. Each mode lists only the settings it uses; the
/// shared section holds those every mode uses the same way.
struct SettingsPanelSection: Identifiable, Equatable {
    let id: String
    let title: String
    var note: String? = nil
    let fields: [String]
}

/// A search result the Workspace Panel page can't show in place: another mode's setting,
/// or any panel setting while the panel is off.
struct SettingsPanelCallout: Equatable {
    enum Action: Hashable { case useMode(WorkspaceSidebarMode), turnOnPanel }
    let field: String
    let actions: [Action]
}

@MainActor
enum SettingsPanelLayout {
    static let enabledField = "workspace-sidebar.enabled"
    static let modeField = "workspace-sidebar.mode"
    static let tabsContentSection = "tabs.content"

    static func sections(_ mode: WorkspaceSidebarMode) -> [SettingsPanelSection] {
        func ids(_ keys: [String]) -> [String] { keys.map { "workspace-sidebar." + $0 } }
        let clock = SettingsPanelSection(id: "\(mode.rawValue).clock", title: "Clock",
            fields: ids(["show-clock", "show-seconds", "show-date", "show-weekday"]))
        switch mode {
            case .dock:
                return [
                    .init(id: "dock.behavior", title: "Position & behavior", fields: ids(["dock-position", "dock-left-gap",
                        "always-expanded", "auto-hide", "dock-magnification", "dock-magnification-amount"])),
                    .init(id: "dock.icons", title: "Icons", fields: ids(["dock-icon-size", "dock-identity-labels", "show-app-badges",
                        "show-app-tooltips", "show-workspace-tooltips", "show-hidden-workspace-app-reminders"])),
                    .init(id: "dock.appearance", title: "Compact Dock appearance", fields: ids(["dock-appearance.style",
                        "dock-appearance.glass-opacity", "dock-appearance.solid-color", "dock-appearance.custom-color"])),
                    .init(id: "dock.expanded", title: "Expanded view",
                        note: "Shown when the Dock opens its project columns, or while it's kept expanded.",
                        fields: ids(["width", "sidebar-appearance.blur", "sidebar-appearance.background-opacity"])),
                    clock,
                ]
            case .sidebar:
                return [
                    .init(id: "sidebar.behavior", title: "Behavior", fields: ids(["always-expanded", "auto-hide", "collapsed-width",
                        "width", "width-per-display", "show-workspace-tooltips"])),
                    .init(id: "sidebar.appearance", title: "Appearance",
                        fields: ids(["sidebar-appearance.blur", "sidebar-appearance.background-opacity"])),
                    clock,
                ]
            case .tabs:
                return [
                    .init(id: "tabs.behavior", title: "Behavior", fields: ids(["tabs-always-expanded", "auto-hide", "collapsed-width", "width",
                        "width-per-display"])),
                    .init(id: tabsContentSection, title: "Content",
                        note: "The tab sidebar takes on the current project's color. Right-click a project to change it.",
                        fields: ids(["share-pinned-tabs", "browser-tabs", "browser-tab-icons", "music-player-at-bottom",
                            "show-app-badges", "intelligence.mode"])),
                ]
        }
    }

    static let shared = SettingsPanelSection(id: "shared", title: "Shared across modes",
        fields: ["workspace-sidebar.display-filter", "workspace-sidebar.enable-focus",
                 "workspace-sidebar.menu-bar-reserve-height", "workspace-sidebar.stay-on-top"])

    static func allSections(_ mode: WorkspaceSidebarMode) -> [SettingsPanelSection] { sections(mode) + [shared] }

    /// The mode a search result belongs to: the active one if it uses the setting.
    static func home(of field: SettingsField, activeMode: WorkspaceSidebarMode) -> WorkspaceSidebarMode? {
        guard let modes = field.modes else { return nil }
        return modes.contains(activeMode) ? activeMode : WorkspaceSidebarMode.settingsOrder.first(where: modes.contains)
    }

    static func breadcrumb(for field: SettingsField, activeMode: WorkspaceSidebarMode) -> String {
        let page = field.group.page.label
        guard field.group.page == .appearance else { return "\(page) › \(field.group.title)" }
        guard let mode = home(of: field, activeMode: activeMode) else { return page }
        if shared.fields.contains(field.id) { return "\(page) › \(shared.title)" }
        let section = sections(mode).first { $0.fields.contains(field.id) }
        return ([page, mode.settingsTitle] + [section?.title].compactMap { $0 }).joined(separator: " › ")
    }

    static func callout(target: String?, in configuration: Config) -> SettingsPanelCallout? {
        guard let target, let field = (SettingsCatalog.fields.first { $0.id == target }), let modes = field.modes else { return nil }
        let sidebar = configuration.workspaceSidebar
        var actions: [SettingsPanelCallout.Action] = []
        if !modes.contains(sidebar.mode), let mode = home(of: field, activeMode: sidebar.mode) { actions.append(.useMode(mode)) }
        if !sidebar.enabled { actions.append(.turnOnPanel) }
        return actions.isEmpty ? nil : SettingsPanelCallout(field: target, actions: actions)
    }

    /// Other modes a setting on `mode`'s page also changes.
    static func sharedNote(for field: SettingsField, in mode: WorkspaceSidebarMode) -> String? {
        guard let modes = field.modes, !shared.fields.contains(field.id) else { return nil }
        let others = modes.subtracting([mode])
        return others.isEmpty ? nil : "Also changes \(settingsModesText(others))."
    }

    /// Which displays get a panel (`monitor`, which Settings doesn't edit), from the displays
    /// the running app resolves it to: `resolved` is empty when nothing matches.
    static func monitorSummary(configured: [MonitorDescription], resolved: [String], all: [String], main: String) -> String {
        if configured.isEmpty || !resolved.isEmpty && resolved.count >= all.count { return "Panels appear on every display." }
        if resolved.isEmpty { return "No display matches the monitor setting, so the panel appears on the main display, \(main)." }
        let names = resolved.count == 1 ? resolved[0] : resolved.dropLast().joined(separator: ", ") + " and " + resolved.last!
        return "Panels appear on \(names). While a display has no panel, every panel lists all displays' workspaces."
    }

    @MainActor
    static func monitorSummary(_ sidebar: WorkspaceSidebarConfig) -> String {
        monitorSummary(configured: sidebar.monitor, resolved: sidebar.resolvedMonitors(sortedMonitors: sortedMonitors).map(\.name),
            all: sortedMonitors.map(\.name), main: mainMonitor.name)
    }
}
