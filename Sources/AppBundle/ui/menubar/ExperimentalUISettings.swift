import SwiftUI

struct ExperimentalUISettings {
    var doubleSidedWindows: Bool {
        get { UserDefaults.standard.bool(forKey: "doubleSidedWindows") }
        set { UserDefaults.standard.set(newValue, forKey: "doubleSidedWindows") }
    }

    var iconAppearance: MenuBarIconAppearance {
        get {
            guard let value = UserDefaults.standard.string(forKey: ExperimentalUISettingsItems.iconAppearance.rawValue) else {
                return .color
            }
            return MenuBarIconAppearance(rawValue: value) ?? .color
        }
        set {
            UserDefaults.standard.setValue(newValue.rawValue, forKey: ExperimentalUISettingsItems.iconAppearance.rawValue)
            UserDefaults.standard.synchronize()
        }
    }
}

enum MenuBarIconAppearance: String, CaseIterable, Identifiable, Equatable, Hashable {
    case color
    case monochrome

    var id: String { rawValue }

    var title: String {
        switch self {
            case .color: "Color"
            case .monochrome: "Monochrome"
        }
    }
}

enum ExperimentalUISettingsItems: String {
    case iconAppearance
}
