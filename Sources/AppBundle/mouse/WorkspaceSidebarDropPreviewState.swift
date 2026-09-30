/// The surface showing the shared drop preview: a display's panel, or the temporary drop UI
/// (`WorkspaceSidebarSurfaceRef.ownerId`). Hiding another panel must not take it away.
@MainActor
private var workspaceSidebarDropPreviewOwnerScopeId: String?

/// `owner` is the surface of the hit the preview was made from. Without one, it's the surface
/// under the pointer.
@MainActor
func setWorkspaceSidebarDropPreviewIfChanged(_ preview: WorkspaceSidebarDropPreviewViewModel?,
                                             owner: WorkspaceSidebarSurfaceRef?? = .none) {
    // An equal preview can move between surfaces that list the same tab, so the owner follows on
    // every assignment. Only a changed preview, or owner, reaches the panels' models.
    let ownerId = preview == nil ? nil
        : (owner ?? workspaceSidebarSurface(at: MousePointerTracker.shared.currentSample.point)?.surface)?.ownerId
    let ownerChanged = ownerId != workspaceSidebarDropPreviewOwnerScopeId
    workspaceSidebarDropPreviewOwnerScopeId = ownerId
    if TrayMenuModel.shared.setIfChanged(\.workspaceSidebarDropPreview, preview) || ownerChanged && preview != nil {
        WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
    }
}

/// The drop preview the panel for `panelScopeId` shows. Panels that don't show the drop keep only
/// what's dragged, so its row still dims:
/// - a drop aimed at temporary drop UI lights up no panel;
/// - with shared pins, one pin is drawn on several panels, so only the owner lights it. Without a
///   known owner, only the panel whose list the preview names does; one naming no list lights none.
func workspaceSidebarPanelDropPreview(_ preview: WorkspaceSidebarDropPreviewViewModel?, panelScopeId: String,
                                      ownerId: String?, sharesPinnedTabs: Bool) -> WorkspaceSidebarDropPreviewViewModel? {
    guard let preview else { return nil }
    if workspaceSidebarDropPreviewOwnerIsTemporary(ownerId) { return preview.sourceOnly }
    guard sharesPinnedTabs else { return preview }
    let shows = ownerId.map { $0 == panelScopeId } ?? (preview.targetMonitorScopeId == panelScopeId)
    return shows ? preview : preview.sourceOnly
}

extension WorkspaceSidebarDropPreviewViewModel {
    /// What's dragged, without where it goes.
    var sourceOnly: WorkspaceSidebarDropPreviewViewModel {
        .init(sourceWindowId: sourceWindowId, label: label, appName: appName, appBundleIdentifier: appBundleIdentifier,
            appBundlePath: appBundlePath, targetWorkspaceName: nil, targetsNewWorkspace: false, isTabGroup: isTabGroup,
            windowCount: windowCount, tabItems: tabItems)
    }
}

@MainActor
func currentWorkspaceSidebarDropPreviewOwnerScopeId() -> String? {
    workspaceSidebarDropPreviewOwnerScopeId
}

@MainActor
func setWorkspaceSidebarDropPreviewOwnerScopeIdForTests(_ scopeId: String?) {
    workspaceSidebarDropPreviewOwnerScopeId = scopeId
}

/// Whether hiding or retiring the panel for `scopeId` takes the shared drop preview with it:
/// only when the drop is that panel's. A preview another display's panel is showing stays.
/// Without a known owner, a preview aimed at no display, or at this one, goes with the panel.
func workspaceSidebarDropPreviewBelongs(toPanel scopeId: String, preview: WorkspaceSidebarDropPreviewViewModel,
                                        ownerScopeId: String?) -> Bool {
    if let ownerScopeId { return ownerScopeId == scopeId }
    return preview.targetMonitorScopeId == nil || preview.targetMonitorScopeId == scopeId
}
