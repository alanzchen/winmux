import Common

struct SidebarAppearanceConfig: ConvenienceCopyable, Equatable, Sendable {
    var backgroundOpacity: Double = 0.70
    var blur: Bool = true
}

/// Unspecified Dock appearance fields retain their legacy workspace-sidebar values.
struct DockAppearanceConfig: ConvenienceCopyable, Equatable, Sendable {
    var style: ChromeStyle?
    var glassOpacity: Double?
    var solidColor: ChromeSolidColor?
    var customColor: String?
}

extension WorkspaceSidebarConfig {
    var dockChromeStyle: ChromeStyle { dockAppearance.style ?? chromeStyle }
    var dockGlassOpacity: Double { dockAppearance.glassOpacity ?? glassOpacity }
    var dockSolidColor: ChromeSolidColor { dockAppearance.solidColor ?? solidChromeColor }
    var dockCustomColor: String { dockAppearance.customColor ?? solidChromeCustomColor }
}
