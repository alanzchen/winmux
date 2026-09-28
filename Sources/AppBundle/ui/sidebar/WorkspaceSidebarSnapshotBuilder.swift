import Foundation

extension TrayMenuModel {
    /// `displayName` is the panel's display, which may have its own width.
    @MainActor func refreshWorkspaceSidebarAppearance(displayName: String? = nil) {
        // Config is not observable. Publish appearance-only changes even when the
        // workspace data and panel width are unchanged, without resetting view state.
        setIfChanged(\.workspaceSidebarAppearance, workspaceSidebarConfiguration(displayName: displayName))
    }
}

@MainActor
func workspaceSidebarConfiguration(_ source: Config = config, displayName: String? = nil) -> WorkspaceSidebarConfiguration {
    WorkspaceSidebarConfiguration(
        collapsedWidth: workspaceSidebarCollapsedContentWidth(source.workspaceSidebar),
        expandedWidth: CGFloat(source.workspaceSidebar.width(onDisplayNamed: displayName)),
        topPadding: TrayMenuModel.shared.workspaceSidebarTopPadding,
        showMonitorSelector: TrayMenuModel.shared.workspaceSidebarShowsMonitorSelector,
        showsClock: source.workspaceSidebar.showClock,
        showsSeconds: source.workspaceSidebar.showSeconds,
        showsDate: source.workspaceSidebar.showDate,
        showsWeekday: source.workspaceSidebar.showWeekday,
        showsStatusPills: source.workspaceSidebar.showStatusPills,
        chromeStyle: source.workspaceSidebar.dockChromeStyle,
        solidChromeColor: source.workspaceSidebar.dockSolidColor,
        solidChromeCustomColor: source.workspaceSidebar.dockCustomColor,
        showAppIcons: source.workspaceSidebar.showAppIcons,
        usesTabsList: source.workspaceSidebar.usesTabsList,
        showWorkspaceTooltips: source.workspaceSidebar.showWorkspaceTooltips,
        showAppTooltips: source.workspaceSidebar.showAppTooltips,
        showHiddenWorkspaceAppReminders: source.workspaceSidebar.showHiddenWorkspaceAppReminders,
        dockMagnification: source.workspaceSidebar.usesDockMagnification,
        dockMagnificationAmount: source.workspaceSidebar.dockMagnificationAmount,
        dockIconSize: CGFloat(source.workspaceSidebar.dockIconSize),
        dockPosition: source.workspaceSidebar.effectiveDockPosition,
        compactLeftGap: CGFloat(source.workspaceSidebar.effectiveLeftGap),
        glassOpacity: source.workspaceSidebar.dockGlassOpacity,
        sidebarBackgroundOpacity: source.workspaceSidebar.sidebarAppearance.backgroundOpacity,
        sidebarBlur: source.workspaceSidebar.sidebarAppearance.blur,
        configuredCollapsedWidth: CGFloat(source.workspaceSidebar.effectiveCollapsedWidth),
        alwaysExpanded: source.workspaceSidebar.pinsSidebarOpen,
        tabCollections: workspaceSidebarOrganizationStore.state.collections,
        displayFilter: source.workspaceSidebar.displayFilter,
        panelsCoverEveryDisplay: workspaceSidebarPanelsCoverEveryDisplay(),
        musicPlayerAtBottom: source.workspaceSidebar.musicPlayerAtBottom,
    )
}
