import AppKit

@MainActor
func updateWorkspaceSidebarModel() async {
    WorkspaceSidebarTabUndo.shared.invalidateIfChanged()
    WorkspaceSidebarDockBadgeModel.shared.setEnabled(
        TrayMenuModel.shared.isEnabled && config.workspaceSidebar.enabled &&
            workspaceSidebarNeedsDockBadgePolling(config.workspaceSidebar),
        showsAppBadges: config.workspaceSidebar.showAppBadges
    )
    guard TrayMenuModel.shared.isEnabled, config.workspaceSidebar.enabled else {
        clearWorkspaceSidebarModelState()
        return
    }

    let previousTopPadding = TrayMenuModel.shared.workspaceSidebarTopPadding
    pruneCachedWindowTitles()
    let state = await buildWorkspaceSidebarModelState()
    applyWorkspaceSidebarModelState(state, previousTopPadding: previousTopPadding)
}

func workspaceSidebarNeedsDockBadgePolling(_ sidebar: WorkspaceSidebarConfig) -> Bool {
    sidebar.showAppBadges && (sidebar.mode == .dock || sidebar.mode == .tabs) ||
        sidebar.mode == .dock && sidebar.showHiddenWorkspaceAppReminders
}
