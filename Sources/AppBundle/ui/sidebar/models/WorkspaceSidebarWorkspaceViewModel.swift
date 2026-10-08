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
    /// A pinned tab's display, where that's known, while pins are shared across displays.
    var knownDisplay: WorkspaceSidebarTabDisplay? = nil
    /// With more than one display, the one a pinned tab is held to, the only one it may be shown
    /// on: by `workspace-to-monitor-force-assignment`, else a saved Keep on display.
    var heldMonitorScopeId: String? = nil
    /// Tabs mode, a pin with one window: that window, while it's in another tab's split. The pin
    /// shows it grey, and a click brings it back.
    var lentWindow: WorkspaceSidebarWindowViewModel? = nil
    /// Tabs mode: a click on this pin brings a window back, the one it lent, or, for a pinned split,
    /// one of its own back in its pin, instead of only showing it.
    var recallsWindows = false

    var id: String { name }
}

/// The display a tab is on: on screen there, or held, saved or last placed there. Unlike the
/// display a hidden tab is listed on, never a guess: not the focused or main display.
struct WorkspaceSidebarTabDisplay: Hashable {
    let monitorScopeId: String
    /// As the display menu names it, identical displays numbered.
    let displayName: String
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
