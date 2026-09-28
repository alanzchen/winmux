import Foundation

/// Whether a settings row can be used with the draft configuration, and what to tell the user.
/// Alternatives and other modes' settings hide; settings that depend on another setting are
/// shown disabled; a behavior the mode fixes replaces its control with text.
enum SettingsAvailability: Equatable {
    case available
    /// Search can still reveal a hidden row. It then appears disabled with this reason.
    case hidden(String)
    case disabled(String)
    case forced(String)

    var isShown: Bool { if case .hidden = self { return false }; return true }
    var isAvailable: Bool { self == .available }
    var reason: String? {
        switch self {
            case .available: nil
            case .hidden(let text), .disabled(let text), .forced(let text): text
        }
    }
}

/// A condition on the draft configuration. When it isn't met, the row takes `effect`.
@MainActor
struct SettingsRequirement {
    enum Effect { case hide, disable, force }
    let effect: Effect
    let text: String
    let isMet: (Config) -> Bool
    /// Wording that names the current mode's own control.
    var contextualText: ((Config) -> String)? = nil

    static func hides(_ text: String, unless isMet: @escaping (Config) -> Bool) -> Self { .init(effect: .hide, text: text, isMet: isMet) }
    static func disables(_ text: String, unless isMet: @escaping (Config) -> Bool) -> Self { .init(effect: .disable, text: text, isMet: isMet) }
    static func forces(_ text: String, unless isMet: @escaping (Config) -> Bool) -> Self { .init(effect: .force, text: text, isMet: isMet) }

    func result(in configuration: Config) -> SettingsAvailability {
        let text = contextualText?(configuration) ?? text
        return switch effect {
            case .hide: .hidden(text)
            case .disable: .disabled(text)
            case .force: .forced(text)
        }
    }

    // Tabs mode has no window stacks (`Config.usesBrowserTabs`, which also needs the panel on).
    static let hasWindowStacks = hides("Tabs mode has no window stacks. Choose Dock or Sidebar to use this setting.") { !$0.usesBrowserTabs }
    static let showsWindowTabs = disables("Turn on Show window tabs to use this setting.") { $0.windowTabs.enabled }
    static let panelCanCollapse = {
        var requirement = disables("Available when the panel isn't kept expanded.") { !$0.workspaceSidebar.pinsSidebarOpen }
        requirement.contextualText = { configuration in
            let toggle = switch configuration.workspaceSidebar.mode {
                case .dock: "Keep the Dock expanded"
                case .sidebar: "Keep the Sidebar expanded"
                case .tabs: "Keep the tab sidebar expanded"
            }
            return "Turn off \(toggle) to use this setting."
        }
        return requirement
    }()
    static let dockCanCollapse = disables("Applies while the Dock can collapse. Turn off Keep the Dock expanded to use it.") { !$0.workspaceSidebar.pinsSidebarOpen }
    static let showsClock = disables("Turn on Show clock to use this setting.") { $0.workspaceSidebar.showClock }
    // A collapsible side Dock keeps its compact clock even while its project columns are open.
    static let showsClockDate = disables("A side Dock that can collapse shows only the time. Keep the panel expanded or move the Dock to the bottom to show it.") {
        let sidebar = $0.workspaceSidebar
        return sidebar.mode != .dock || sidebar.pinsSidebarOpen || sidebar.dockPosition == .bottom
    }
}

extension WorkspaceSidebarMode {
    var settingsTitle: String {
        switch self {
            case .dock: "Dock"
            case .sidebar: "Sidebar"
            case .tabs: "Tabs"
        }
    }
    /// Picker and prose order.
    static let settingsOrder: [Self] = [.dock, .sidebar, .tabs]
}

func settingsModesText(_ modes: Set<WorkspaceSidebarMode>) -> String {
    let names = WorkspaceSidebarMode.settingsOrder.filter(modes.contains).map(\.settingsTitle)
    return names.count == 1 ? "\(names[0]) mode" : names.dropLast().joined(separator: ", ") + " and \(names.last!) modes"
}

extension WorkspaceSidebarConfig {
    /// A Settings save of window chrome first writes the Dock values it inherited, so the Dock
    /// keeps its look (`updateSettingsAppearanceConfig`). Draft projection does the same.
    mutating func freezeInheritedDockAppearance() {
        dockAppearance = DockAppearanceConfig(style: dockChromeStyle, glassOpacity: dockGlassOpacity,
            solidColor: dockSolidColor, customColor: dockCustomColor)
    }
}

@MainActor
extension SettingsField {
    /// A workspace panel setting used in `modes`. It hides in other modes and is disabled
    /// while the panel is off.
    func used(in modes: Set<WorkspaceSidebarMode>) -> SettingsField {
        var field = self
        field.modes = modes
        return field
    }

    func requiring(_ requirements: SettingsRequirement...) -> SettingsField {
        var field = self
        field.requirements += requirements
        return field
    }

    /// Another mode's setting hides, then an unselected alternative, before the panel being
    /// off disables what remains.
    func availability(in configuration: Config) -> SettingsAvailability {
        let sidebar = configuration.workspaceSidebar
        if let modes, !modes.contains(sidebar.mode) { return .hidden("Used in \(settingsModesText(modes)).") }
        if let alternative = requirements.first(where: { $0.effect == .hide && !$0.isMet(configuration) }) { return alternative.result(in: configuration) }
        if modes != nil, !sidebar.enabled { return .disabled("Turn on Show the workspace panel to use this setting.") }
        return requirements.first { !$0.isMet(configuration) }?.result(in: configuration) ?? .available
    }

    func availability(_ editor: SettingsEditor) -> SettingsAvailability { availability(in: editor.projection) }
}

extension Set where Element == WorkspaceSidebarMode {
    static let allModes: Self = [.dock, .sidebar, .tabs]
}

/// Draft writers for `SettingsField.project`.
@MainActor
enum SettingsProjection {
    static func write<Value>(_ path: WritableKeyPath<Config, Value>, _ convert: @escaping (SettingsValue) -> Value?) -> (inout Config, SettingsValue) -> Void {
        { configuration, value in if let converted = convert(value) { configuration[keyPath: path] = converted } }
    }
    static func raw<Value: RawRepresentable>(_ path: WritableKeyPath<Config, Value>) -> (inout Config, SettingsValue) -> Void where Value.RawValue == String {
        write(path) { Value(rawValue: $0.text) }
    }
    static func raw<Value: RawRepresentable>(_ path: WritableKeyPath<Config, Value?>) -> (inout Config, SettingsValue) -> Void where Value.RawValue == String {
        write(path) { Value(rawValue: $0.text).map(Optional.some) }
    }
    static func number(_ path: WritableKeyPath<Config, Double>) -> (inout Config, SettingsValue) -> Void { write(path) { $0.number } }
    static func number(_ path: WritableKeyPath<Config, Double?>) -> (inout Config, SettingsValue) -> Void { write(path) { $0.number } }
    static func text(_ path: WritableKeyPath<Config, String>) -> (inout Config, SettingsValue) -> Void { write(path) { $0.text } }
    static func text(_ path: WritableKeyPath<Config, String?>) -> (inout Config, SettingsValue) -> Void { write(path) { $0.text } }

    /// Applies drafts in catalog order, mirroring how the save queue edits the file. Restoring a
    /// setting whose default depends on others removes its key, so `unsetting` clears it.
    static func apply(_ drafts: [String: SettingsValue], unsetting: Set<String> = [], to base: Config) -> Config {
        guard !drafts.isEmpty || !unsetting.isEmpty else { return base }
        var result = base
        for field in SettingsCatalog.allFields {
            if unsetting.contains(field.id), let clear = field.clear { clear(&result); continue }
            guard let value = drafts[field.id], let project = field.project else { continue }
            if field.preservingDockAppearance { result.workspaceSidebar.freezeInheritedDockAppearance() }
            project(&result, value)
        }
        return result
    }
}
