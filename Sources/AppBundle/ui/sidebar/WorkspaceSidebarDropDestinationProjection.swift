import AppKit

// The list temporary drop UI shows is a picture of another display's sidebar: that display's tabs
// or workspaces, as its own panel would list them, built from the shared model. It's read-only:
// it takes drops through the same targets, but selects, edits and watches nothing.

/// What the other display's list shows, as one value: it publishes only when this changes.
struct WorkspaceSidebarDropDestinationSnapshot: Equatable {
    let hint: WorkspaceSidebarDropDestinationHint
    /// The surface the list is, whose drop previews it shows.
    let surface: WorkspaceSidebarSurfaceRef
    /// The model as the display's own panel would see it: its scope, its project, its settings.
    /// Its drop preview is the one this list owns, or only what's dragged.
    let projection: WorkspaceSidebarSnapshot
    let width: CGFloat

    var monitorScopeId: String { hint.id }
    var projectId: WorkspaceProjectId { projection.activeProjectId }
    var project: WorkspaceSidebarProjectViewModel? { projection.projects.first { $0.id == projectId } }
    var usesTabsList: Bool { projection.configuration.usesTabsList }

    /// Tabs mode: the pinned tiles, then the other tabs, as the display's list shows them.
    var pins: [WorkspaceSidebarWorkspaceViewModel] { projection.tabsPinnedWorkspaces(for: projectId) }
    var tabSections: [WorkspaceSidebarTabSection] {
        workspaceSidebarTabSections(workspaces: projection.tabsListedWorkspaces(for: projectId).filter { !$0.appearance.isFavorite },
            collections: projection.configuration.tabCollections, projectId: projectId)
    }

    /// Sidebar and Dock: the display's workspaces in its project.
    var workspaces: [WorkspaceSidebarWorkspaceViewModel] {
        projection.workspaces.filter {
            $0.projectId == projectId && !$0.isLeftEmpty && workspaceSidebarWorkspaceMatchesScope($0,
                selectedScopeId: monitorScopeId, focusedMonitorScopeId: projection.focusedMonitorScopeId)
        }
    }
}

/// The list of `hint`'s display, from the shared model. Nil once that display is gone.
@MainActor
func workspaceSidebarDropDestinationSnapshot(for hint: WorkspaceSidebarDropDestinationHint,
                                             surface: WorkspaceSidebarSurfaceRef, width: CGFloat,
                                             model: TrayMenuModel = .shared) -> WorkspaceSidebarDropDestinationSnapshot? {
    guard let monitor = workspaceSidebarMonitor(forScopeId: hint.id) else { return nil }
    // The display it represents, not the one it's shown on: its scope, project and pins.
    let projection = WorkspaceSidebarSnapshot(
        workspaces: model.workspaceSidebarWorkspaces,
        projects: model.workspaceSidebarProjects,
        activeProjectId: activeWorkspaceProjectId(for: monitor),
        monitorScopes: model.workspaceSidebarMonitorScopes,
        selectedMonitorScopeId: hint.id,
        targetMonitorScopeId: hint.id,
        focusedMonitorScopeId: model.workspaceSidebarFocusedMonitorScopeId,
        visibleWidth: width,
        hoveredWorkspaceName: nil,
        dropPreview: workspaceSidebarDropDestinationPreview(model.workspaceSidebarDropPreview, surface: surface,
            ownerId: currentWorkspaceSidebarDropPreviewOwnerScopeId()),
        configuration: workspaceSidebarConfiguration(displayName: hint.name),
    )
    return .init(hint: hint, surface: surface, projection: projection, width: width)
}

/// The list shows the drop only when it's the list's own; any other drop keeps what's dragged, so
/// a tab listed here that's being dragged still dims.
func workspaceSidebarDropDestinationPreview(_ preview: WorkspaceSidebarDropPreviewViewModel?,
                                            surface: WorkspaceSidebarSurfaceRef,
                                            ownerId: String?) -> WorkspaceSidebarDropPreviewViewModel? {
    guard let preview else { return nil }
    return ownerId == surface.ownerId ? preview : preview.sourceOnly
}
