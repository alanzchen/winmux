import AppKit

@MainActor
func updateWorkspaceSidebarModel() async {
    WorkspaceSidebarDockBadgeModel.shared.setEnabled(
        TrayMenuModel.shared.isEnabled && config.workspaceSidebar.enabled &&
            config.workspaceSidebar.mode == .dock &&
            (config.workspaceSidebar.showAppBadges || config.workspaceSidebar.showHiddenWorkspaceAppReminders),
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
