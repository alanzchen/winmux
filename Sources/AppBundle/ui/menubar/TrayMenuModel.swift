import AppKit
import Common

public final class TrayMenuModel: ObservableObject {
    @MainActor public static let shared = TrayMenuModel()

    init() {}

    /// Is "layouting" enabled
    @Published var isEnabled: Bool = true
    @Published var workspaces: [WorkspaceViewModel] = []
    @Published var workspaceSidebarWorkspaces: [WorkspaceSidebarWorkspaceViewModel] = []
    @Published var workspaceSidebarProjects: [WorkspaceSidebarProjectViewModel] = []
    @Published var workspaceSidebarActiveProjectId: WorkspaceProjectId = workspaceProjectDefaultId
    @Published var workspaceSidebarMonitorScopes: [WorkspaceSidebarMonitorScopeViewModel] = []
    /// Panel-local UI state. The shared model keeps this only as a compatibility default for legacy callers.
    @Published var workspaceSidebarSelectedMonitorScopeId: String = workspaceSidebarDefaultScopeId
    /// The Show workspaces from setting a menu choice (including All Displays) was made under;
    /// nil until the menu is used. The choice survives refreshes until that setting changes.
    var workspaceSidebarMonitorScopeChoiceFilter: WorkspaceSidebarDisplayFilter? = nil
    @Published var workspaceSidebarTargetMonitorScopeId: String = workspaceSidebarDefaultScopeId
    @Published var workspaceSidebarFocusedMonitorScopeId: String = ""
    @Published var workspaceSidebarShowsMonitorSelector: Bool = false
    @Published var workspaceSidebarDropPreview: WorkspaceSidebarDropPreviewViewModel? = nil
    @Published var workspaceSidebarDockDrag: WorkspaceSidebarDockDragPresentation? = nil
    @Published var windowTabStrips: [WindowTabStripViewModel] = []
    @Published var isWorkspaceSidebarExpanded: Bool = false
    @Published var workspaceSidebarVisibleWidth: CGFloat = 0
    @Published var workspaceSidebarTopPadding: CGFloat = 12
    @Published var workspaceSidebarAppearance: WorkspaceSidebarConfiguration = .empty
    @Published var workspaceSidebarHoveredWorkspaceName: String? = nil
    @Published var experimentalUISettings: ExperimentalUISettings = ExperimentalUISettings()

    var visibleWorkspaceSidebarWorkspaces: [WorkspaceSidebarWorkspaceViewModel] {
        workspaceSidebarWorkspaces.filter {
            $0.projectId == workspaceSidebarActiveProjectId &&
            workspaceSidebarWorkspaceMatchesScope(
                $0,
                selectedScopeId: workspaceSidebarSelectedMonitorScopeId,
                focusedMonitorScopeId: workspaceSidebarFocusedMonitorScopeId,
            )
        }
    }

}

extension ObservableObject {
    /// Assigning a @Published property fires objectWillChange even when the value is unchanged,
    /// re-rendering every observing view (menu bar icon, sidebar panels, tab strips). Models
    /// republished wholesale on every refresh session must equality-guard their writes.
    /// Returns whether the value actually changed, for callers that need to chain side effects.
    @discardableResult
    func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Self, T>, _ value: T) -> Bool {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
            return true
        }
        return false
    }
}

@MainActor func updateTrayWorkspaces() {
    let workspaces = userFacingWorkspaces(Workspace.all).filter {
        workspaceContextProjectId(of: $0) == activeWorkspaceProjectId(for: $0.workspaceMonitor)
    }.map { WorkspaceViewModel(name: $0.name) }
    TrayMenuModel.shared.setIfChanged(\.workspaces, workspaces)
}
