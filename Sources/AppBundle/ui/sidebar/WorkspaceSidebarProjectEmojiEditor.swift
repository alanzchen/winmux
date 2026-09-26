import AppKit

@MainActor
func editWorkspaceSidebarProjectEmoji(_ project: WorkspaceSidebarProjectViewModel) {
    WorkspaceSidebarIdentityMenu.show(.project(project.id), showsIcons: true)
}

@MainActor
func setWorkspaceSidebarProjectEmoji(_ projectId: WorkspaceProjectId, emoji: String?) {
    runWorkspaceSidebarSession {
        try setWorkspaceProjectEmoji(projectId, emoji: emoji)
        await updateWorkspaceSidebarModel()
    }
}
