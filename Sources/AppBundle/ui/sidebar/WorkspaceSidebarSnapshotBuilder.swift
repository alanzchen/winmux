import Foundation

extension TrayMenuModel {
    @MainActor func refreshWorkspaceSidebarAppearance() {
        // Config is not observable. Publish appearance-only changes even when the
        // workspace data and panel width are unchanged, without resetting view state.
        setIfChanged(\.workspaceSidebarAppearance, workspaceSidebarConfiguration())
    }
}

@MainActor
func workspaceSidebarConfiguration() -> WorkspaceSidebarConfiguration {
    WorkspaceSidebarConfiguration(
        collapsedWidth: workspaceSidebarCollapsedContentWidth(config.workspaceSidebar),
        expandedWidth: CGFloat(config.workspaceSidebar.width),
        topPadding: TrayMenuModel.shared.workspaceSidebarTopPadding,
        showMonitorSelector: TrayMenuModel.shared.workspaceSidebarShowsMonitorSelector,
        showsClock: config.workspaceSidebar.showClock,
        showsSeconds: config.workspaceSidebar.showSeconds,
        showsDate: config.workspaceSidebar.showDate,
        showsWeekday: config.workspaceSidebar.showWeekday,
        showsStatusPills: config.workspaceSidebar.showStatusPills,
        chromeStyle: config.workspaceSidebar.dockChromeStyle,
        solidChromeColor: config.workspaceSidebar.dockSolidColor,
        solidChromeCustomColor: config.workspaceSidebar.dockCustomColor,
        showAppIcons: config.workspaceSidebar.showAppIcons,
        showWorkspaceTooltips: config.workspaceSidebar.showWorkspaceTooltips,
        showAppTooltips: config.workspaceSidebar.showAppTooltips,
        showHiddenWorkspaceAppReminders: config.workspaceSidebar.showHiddenWorkspaceAppReminders,
        dockMagnification: config.workspaceSidebar.usesDockMagnification,
        dockMagnificationAmount: config.workspaceSidebar.dockMagnificationAmount,
        dockIconSize: CGFloat(config.workspaceSidebar.dockIconSize),
        dockPosition: config.workspaceSidebar.effectiveDockPosition,
        compactLeftGap: CGFloat(config.workspaceSidebar.effectiveLeftGap),
        glassOpacity: config.workspaceSidebar.dockGlassOpacity,
        sidebarBackgroundOpacity: config.workspaceSidebar.sidebarAppearance.backgroundOpacity,
        sidebarBlur: config.workspaceSidebar.sidebarAppearance.blur,
        configuredCollapsedWidth: CGFloat(config.workspaceSidebar.effectiveCollapsedWidth),
        alwaysExpanded: config.workspaceSidebar.alwaysExpanded,
    )
}
