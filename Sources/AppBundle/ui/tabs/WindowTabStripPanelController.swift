import Foundation

@MainActor
final class WindowTabStripPanelController {
    static let shared = WindowTabStripPanelController()

    enum MouseInteractionChromeMode: Equatable {
        case frameOnly
        case hidden
    }

    var visualPanels: [ObjectIdentifier: WindowTabGroupVisualPanel] = [:]
    var stripPanels: [ObjectIdentifier: WindowTabStripPanel] = [:]
    var mouseInteractionChromeMode: MouseInteractionChromeMode? = nil
    var hiddenPassiveTabGroupChromeIds: Set<ObjectIdentifier> = []

    private init() {}
}

extension WindowTabStripPanelController {
    func visualPanel(for id: ObjectIdentifier) -> WindowTabGroupVisualPanel {
        let panel = visualPanels[id] ?? WindowTabGroupVisualPanel(id: id)
        visualPanels[id] = panel
        return panel
    }

    func stripPanel(for id: ObjectIdentifier) -> WindowTabStripPanel {
        let panel = stripPanels[id] ?? WindowTabStripPanel(id: id)
        stripPanels[id] = panel
        return panel
    }

    func orderOutPanels(id: ObjectIdentifier) {
        orderOutIfVisible(visualPanels[id])
        orderOutIfVisible(stripPanels[id])
    }

    func removeStalePanels(activeIds: Set<ObjectIdentifier>) {
        removeStaleVisualPanels(activeIds: activeIds)
        removeStaleStripPanels(activeIds: activeIds)
    }

    func removeStaleVisualPanels(activeIds: Set<ObjectIdentifier>) {
        for staleId in visualPanels.keys where !activeIds.contains(staleId) {
            orderOutIfVisible(visualPanels[staleId])
            visualPanels.removeValue(forKey: staleId)
        }
    }

    func removeStaleStripPanels(activeIds: Set<ObjectIdentifier>) {
        for staleId in stripPanels.keys where !activeIds.contains(staleId) {
            orderOutIfVisible(stripPanels[staleId])
            stripPanels.removeValue(forKey: staleId)
        }
    }

    func orderOutIfVisible(_ panel: NSPanelHud?) {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
    }
}

extension WindowTabStripPanelController {
    func refresh() {
        guard TrayMenuModel.shared.isEnabled, (config.windowTabs.enabled && !config.usesBrowserTabs) else {
            hideAll()
            return
        }

        let strips = TrayMenuModel.shared.windowTabStrips
        let activeIds = Set(strips.map(\.id))
        if let mouseInteractionChromeMode {
            refreshSuppressedChrome(mode: mouseInteractionChromeMode, strips: strips, activeIds: activeIds)
            return
        }
        refreshInteractiveChrome(strips: strips, activeIds: activeIds)
    }

    func refreshInteractiveChrome(strips: [WindowTabStripViewModel], activeIds: Set<ObjectIdentifier>) {
        for strip in strips {
            guard !hiddenPassiveTabGroupChromeIds.contains(strip.id) else {
                orderOutPanels(id: strip.id)
                continue
            }
            visualPanel(for: strip.id).update(with: strip)
            stripPanel(for: strip.id).update(with: strip)
        }
        removeStalePanels(activeIds: activeIds)
    }

    func refreshSuppressedChrome(
        mode: MouseInteractionChromeMode,
        strips: [WindowTabStripViewModel],
        activeIds: Set<ObjectIdentifier>,
    ) {
        switch mode {
            case .frameOnly:
                refreshFrameOnlyChrome(strips: strips, activeIds: activeIds)
            case .hidden:
                refreshHiddenChrome(activeIds: activeIds)
        }
    }

    func refreshFrameOnlyChrome(strips: [WindowTabStripViewModel], activeIds: Set<ObjectIdentifier>) {
        for strip in strips {
            guard !hiddenPassiveTabGroupChromeIds.contains(strip.id) else {
                orderOutPanels(id: strip.id)
                continue
            }
            visualPanel(for: strip.id).update(with: strip)
            orderOutIfVisible(stripPanels[strip.id])
        }
        removeStalePanels(activeIds: activeIds)
    }
}

extension WindowTabStripPanelController {
    func hideChromeDuringMouseInteraction(showFrameOnly: Bool = true) {
        guard TrayMenuModel.shared.isEnabled, (config.windowTabs.enabled && !config.usesBrowserTabs) else { return }
        let nextMode: MouseInteractionChromeMode = showFrameOnly ? .frameOnly : .hidden
        guard mouseInteractionChromeMode != nextMode else { return }
        mouseInteractionChromeMode = nextMode
        refresh()
    }

    func showChromeDuringMouseInteraction() {
        guard mouseInteractionChromeMode != nil || !hiddenPassiveTabGroupChromeIds.isEmpty else { return }
        mouseInteractionChromeMode = nil
        hiddenPassiveTabGroupChromeIds.removeAll()
        refresh()
    }

    func refreshHiddenChrome(activeIds: Set<ObjectIdentifier>) {
        for id in Array(visualPanels.keys) {
            orderOutIfVisible(visualPanels[id])
            if !activeIds.contains(id) {
                visualPanels.removeValue(forKey: id)
            }
        }
        for id in Array(stripPanels.keys) {
            orderOutIfVisible(stripPanels[id])
            if !activeIds.contains(id) {
                stripPanels.removeValue(forKey: id)
            }
        }
    }

    @discardableResult
    func clearMouseInteractionChromeSuppressionIfInactive() -> Bool {
        guard currentlyManipulatedWithMouseWindowId == nil,
              mouseInteractionChromeMode != nil
        else { return false }
        mouseInteractionChromeMode = nil
        return true
    }
}

extension WindowTabStripPanelController {
    func setHiddenPassiveTabGroupChrome(_ ids: Set<ObjectIdentifier>) {
        guard hiddenPassiveTabGroupChromeIds != ids else { return }
        hiddenPassiveTabGroupChromeIds = ids
        refresh()
    }

    func clearHiddenPassiveTabGroupChrome() {
        guard !hiddenPassiveTabGroupChromeIds.isEmpty else { return }
        hiddenPassiveTabGroupChromeIds.removeAll()
        refresh()
    }

    func hideAll() {
        mouseInteractionChromeMode = nil
        hiddenPassiveTabGroupChromeIds.removeAll()
        for panel in visualPanels.values {
            panel.orderOut(nil)
        }
        for panel in stripPanels.values {
            panel.orderOut(nil)
        }
        visualPanels.removeAll()
        stripPanels.removeAll()
    }

    func setIgnoresMouseEvents(_ ignoresMouseEvents: Bool) {
        for panel in stripPanels.values {
            panel.setExternalIgnoresMouseEvents(ignoresMouseEvents)
        }
    }
}
