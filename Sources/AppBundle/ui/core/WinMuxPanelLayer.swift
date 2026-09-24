import AppKit

enum WinMuxPanelLayer: CaseIterable {
    case windowChrome
    case windowIntentPreview
    case overlay
    case dragCursorProxy
    case workspaceSidebar

    var level: NSWindow.Level {
        switch self {
            case .windowChrome:
                .normal
            case .windowIntentPreview:
                .statusBar
            case .overlay:
                .statusBar
            case .dragCursorProxy:
                NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            case .workspaceSidebar:
                NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        }
    }
}

extension NSPanelHud {
    func applyWinMuxLayer(_ layer: WinMuxPanelLayer) {
        level = layer.level
    }

    /// A panel the user has opened stays above System Settings while in use.
    func applyWorkspaceSidebarLayer(stayOnTop: Bool, yieldsToSystemWindows: Bool = true) {
        var yieldsTo: SystemFrontWindow?
        if yieldsToSystemWindows, !systemFrontWindows.isEmpty {
            // Window-server coordinates: the flip uses the menu-bar display, which is the origin.
            let panelFrame = CGRect(x: frame.minX, y: mainMonitor.height - frame.maxY, width: frame.width, height: frame.height)
            yieldsTo = workspaceSidebarPanelYieldTarget(systemFrontWindows, panelFrame: panelFrame)
        }
        level = workspaceSidebarPanelLevel(stayOnTop: stayOnTop, yieldingToLayer: yieldsTo?.layer)
        if let yieldsTo, level.rawValue == yieldsTo.layer, isVisible {
            order(.below, relativeTo: Int(yieldsTo.id))
        }
    }
}

/// The lowest-level system window sharing the panel's area; among several at that level, the
/// rearmost. Staying beneath it keeps the panel beneath every one of them.
func workspaceSidebarPanelYieldTarget(_ windows: [SystemFrontWindow], panelFrame: CGRect) -> SystemFrontWindow? {
    let sharing = windows.filter { $0.frame.intersects(panelFrame) }
    guard let lowest = sharing.map(\.layer).min() else { return nil }
    return sharing.last { $0.layer == lowest }
}

/// Beneath System Settings or a permission prompt that shares the panel's area, the panel takes
/// the highest level below it: floating under an Automation prompt, normal (and ordered
/// behind) under System Settings or an Accessibility prompt. See `SystemFrontWindows.swift`.
func workspaceSidebarPanelLevel(stayOnTop: Bool, yieldingToLayer layer: Int? = nil) -> NSWindow.Level {
    let configured = stayOnTop ? WinMuxPanelLayer.workspaceSidebar.level : NSWindow.Level.floating
    guard let layer, layer <= configured.rawValue else { return configured }
    return layer > NSWindow.Level.floating.rawValue ? .floating : .normal
}
