/// The panel under the pointer when the shared drop preview last changed: the panel showing
/// the drop. Hiding another panel must not take it away.
@MainActor
private var workspaceSidebarDropPreviewOwnerScopeId: String?

@MainActor
func setWorkspaceSidebarDropPreviewIfChanged(_ preview: WorkspaceSidebarDropPreviewViewModel?) {
    // An equal preview can move between panels that list the same tab, so the owner follows the
    // pointer on every assignment. Only a changed preview reaches the panels' models.
    workspaceSidebarDropPreviewOwnerScopeId = preview == nil ? nil
        : WorkspaceSidebarPanel.panel(containing: MousePointerTracker.shared.currentSample.point)?.monitorScopeId
    if TrayMenuModel.shared.setIfChanged(\.workspaceSidebarDropPreview, preview) {
        WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
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
