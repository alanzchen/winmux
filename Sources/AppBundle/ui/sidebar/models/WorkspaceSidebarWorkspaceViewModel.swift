struct WorkspaceSidebarWorkspaceViewModel: Hashable, Identifiable {
    let name: String
    let projectId: WorkspaceProjectId
    let displayName: String
    let sidebarLabel: String
    let isGeneratedName: Bool
    let monitorScopeId: String
    let monitorName: String?
    var isFocused: Bool
    var isVisible: Bool
    let items: [WorkspaceSidebarItemViewModel]
    var apps: [WorkspaceSidebarAppViewModel] = []
    /// nil when the workspace isn't saved.
    var savedState: WorkspaceSidebarSavedState? = nil
    var appearance: WorkspaceSidebarItemAppearance = .init()
    /// Filtering a legacy stack must not turn its remaining window into a new
    /// browser group that wasn't searchable in the source presentation.
    var preservesFolderPresentation = false

    var id: String { name }
}

struct WorkspaceSidebarSavedState: Hashable {
    var isPinnedToDisplay: Bool
    /// The saved home display, nil until the workspace has been seen on a display with an identity.
    var homeDisplayName: String?
    var isHomeConnected: Bool
    var isForceAssignedByConfig: Bool
    var missingAppNames: [String]
    var keepWhenEmpty = true
}

struct WorkspaceSidebarMonitorScopeViewModel: Hashable, Identifiable {
    let id: String
    let displayName: String
    let subtitle: String?
    let systemImageName: String
    let isFocusedMonitor: Bool
}
