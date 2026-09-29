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
    /// Tabs mode: its windows have all gone and it isn't saved. It closes off screen, and the
    /// sidebar doesn't list it while it can't, as the only tab on its display.
    var isLeftEmpty = false

    var id: String { name }
}

/// An app a saved tab opens in, for showing that tab while the app isn't open.
struct WorkspaceSidebarSavedApp: Hashable {
    let bundleId: String
    let bundlePath: String?
    let name: String
}

struct WorkspaceSidebarSavedState: Hashable {
    var isPinnedToDisplay: Bool
    /// The saved home display, nil until the workspace has been seen on a display with an identity.
    var homeDisplayName: String?
    var isHomeConnected: Bool
    var isForceAssignedByConfig: Bool
    var missingAppNames: [String]
    var keepWhenEmpty = true
    /// The apps of its saved windows, in layout order, one per window.
    var apps: [WorkspaceSidebarSavedApp] = []
}

struct WorkspaceSidebarMonitorScopeViewModel: Hashable, Identifiable {
    let id: String
    let displayName: String
    let subtitle: String?
    let systemImageName: String
    let isFocusedMonitor: Bool
}
