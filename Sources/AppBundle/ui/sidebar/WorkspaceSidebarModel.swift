import AppKit

@MainActor
func updateWorkspaceSidebarModel() async {
    BrowserTabsModel.shared.setEnabled(TrayMenuModel.shared.isEnabled && config.workspaceSidebar.enabled &&
        config.workspaceSidebar.usesTabsList && config.workspaceSidebar.browserTabs)
    WorkspaceSidebarTabUndo.shared.invalidateIfChanged()
    // Once the panels show the new state: a preview whose project or display list changed closes.
    defer { syncWorkspaceTopicSuggestions() }
    let showsTabs = TrayMenuModel.shared.isEnabled && config.workspaceSidebar.enabled && config.workspaceSidebar.usesTabsList
    AudioActivityModel.shared.setEnabled(showsTabs)
    AppleMusicNowPlayingModel.shared.setEnabled(showsTabs)
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
