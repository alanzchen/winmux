import Foundation
import AppKit

@MainActor
func openWorkspaceSidebarFromCommand() {
    guard TrayMenuModel.shared.isEnabled, config.workspaceSidebar.enabled else { return }
    WorkspaceSidebarPanel.refreshAll()
    guard let panel = workspaceSidebarPanelForCommand(
        focusedScopeId: TrayMenuModel.shared.workspaceSidebarFocusedMonitorScopeId
    ), panel.currentSidebarPanelLayout() != nil else { return }
    if panel.inlineTextEditingActive ||
        (panel.viewModel.isWorkspaceSidebarExpanded && !config.workspaceSidebar.alwaysExpanded)
    {
        closeWorkspaceSidebarFromCommand(panel, restorePreviousApplication: true)
        return
    }
    panel.commandExpansionLocksCollapse = true
    panel.shouldLockNextSidebarSearchExpansion = true
    panel.bufferedCommandSidebarSearchKeys = []
    installWorkspaceSidebarCommandMouseUnlockMonitor(panel)
    panel.expandSidebar(to: CGFloat(config.workspaceSidebar.width))
    panel.beginInlineTextEditing(
        locksExpansion: true,
        cancelsOnPointerExit: false,
        onCancel: {
            closeWorkspaceSidebarFromCommand(panel)
        },
        onKeyDown: { key in
            switch key {
                case .cancel:
                    closeWorkspaceSidebarFromCommand(panel, restorePreviousApplication: true)
                case .ignored:
                    break
                default:
                    panel.bufferedCommandSidebarSearchKeys.append(key)
                    NotificationCenter.default.post(
                        name: workspaceSidebarCommandSearchKeyNotification,
                        object: panel,
                        userInfo: [
                            workspaceSidebarCommandSearchPanelUserInfoKey: panel,
                            workspaceSidebarCommandSearchKeyUserInfoKey: key,
                        ]
                    )
            }
        },
    )
}

@MainActor
func workspaceSidebarPanelForCommand(focusedScopeId: String) -> WorkspaceSidebarPanel? {
    let activeScopeIds = workspaceSidebarResolvedPanelMonitors().map { workspaceSidebarMonitorScopeId(for: $0) }
    // A connected fullscreen display deliberately blocks search. A disconnected or
    // deselected display must instead fall back to one of the currently configured panels.
    if activeScopeIds.contains(focusedScopeId) {
        return WorkspaceSidebarPanel.panel(for: focusedScopeId)
    }
    return activeScopeIds.compactMap { WorkspaceSidebarPanel.panel(for: $0) }
        .first { $0.currentSidebarPanelLayout() != nil }
}

@MainActor
func closeWorkspaceSidebarFromCommand(_ panel: WorkspaceSidebarPanel, restorePreviousApplication: Bool = false) {
    let previousApp = panel.inlineTextEditingPreviousApplication
    panel.endInlineTextEditing()
    panel.pendingExpand?.cancel()
    panel.pendingExpand = nil
    panel.pendingCollapse?.cancel()
    panel.pendingCollapse = nil
    panel.pendingCollapseFinalize?.cancel()
    panel.pendingCollapseFinalize = nil
    if !config.workspaceSidebar.alwaysExpanded {
        NotificationCenter.default.post(name: workspaceSidebarWillCollapseNotification, object: panel)
    }
    clearWorkspaceSidebarCommandInputState(panel)
    panel.animateVisibleSidebarWidth(workspaceSidebarRestingWidth(config.workspaceSidebar), animation: .easeInOut(duration: panel.animationDuration))
    panel.viewModel.isWorkspaceSidebarExpanded = config.workspaceSidebar.alwaysExpanded
    panel.updateMousePassthrough()
    if restorePreviousApplication, NSApp.isActive {
        previousApp?.activate(options: .activateIgnoringOtherApps)
    }
}

@MainActor
func clearWorkspaceSidebarCommandInputState(_ panel: WorkspaceSidebarPanel) {
    panel.commandExpansionLocksCollapse = false
    panel.shouldLockNextSidebarSearchExpansion = false
    panel.bufferedCommandSidebarSearchKeys = []
    removeWorkspaceSidebarCommandMouseUnlockMonitor(panel)
}

@MainActor
private func installWorkspaceSidebarCommandMouseUnlockMonitor(_ panel: WorkspaceSidebarPanel) {
    removeWorkspaceSidebarCommandMouseUnlockMonitor(panel)
    panel.commandMouseUnlockPoint = mouseLocation
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak panel] in
        guard let panel, panel.commandExpansionLocksCollapse else { return }
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak panel] event in
            Task { @MainActor in
                panel?.unlockCommandSidebarExpansionIfMouseMoved()
            }
            return event
        }
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak panel] _ in
            Task { @MainActor in
                panel?.unlockCommandSidebarExpansionIfMouseMoved()
            }
        }
        panel.commandMouseUnlockMonitors = [localMonitor, globalMonitor].compactMap { $0 }
    }
}

@MainActor
private func removeWorkspaceSidebarCommandMouseUnlockMonitor(_ panel: WorkspaceSidebarPanel) {
    for monitor in panel.commandMouseUnlockMonitors {
        NSEvent.removeMonitor(monitor)
    }
    panel.commandMouseUnlockMonitors = []
    panel.commandMouseUnlockPoint = nil
}

private let workspaceSidebarCommandMouseUnlockDistance: CGFloat = 1

extension WorkspaceSidebarPanel {
    @MainActor
    func unlockCommandSidebarExpansionIfMouseMoved() {
        guard commandExpansionLocksCollapse,
              let origin = commandMouseUnlockPoint
        else { return }
        let current = mouseLocation
        guard hypot(current.x - origin.x, current.y - origin.y) > workspaceSidebarCommandMouseUnlockDistance else { return }
        commandExpansionLocksCollapse = false
        shouldLockNextSidebarSearchExpansion = false
        inlineTextEditingLocksExpansion = false
        removeWorkspaceSidebarCommandMouseUnlockMonitor(self)
        updateHoverStateFromMousePosition()
    }
}
