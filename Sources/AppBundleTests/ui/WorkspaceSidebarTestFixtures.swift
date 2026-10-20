@testable import AppBundle

extension WorkspaceSidebarSnapshot {
    /// A sidebar with nothing in it, which tests fill in. Computed, so each use gets a fresh value.
    static var empty: WorkspaceSidebarSnapshot {
        WorkspaceSidebarSnapshot(
            workspaces: [],
            projects: [],
            activeProjectId: workspaceProjectDefaultId,
            monitorScopes: [],
            selectedMonitorScopeId: workspaceSidebarDefaultScopeId,
            targetMonitorScopeId: workspaceSidebarDefaultScopeId,
            focusedMonitorScopeId: "",
            visibleWidth: 0,
            hoveredWorkspaceName: nil,
            dropPreview: nil,
            configuration: .empty,
        )
    }
}
