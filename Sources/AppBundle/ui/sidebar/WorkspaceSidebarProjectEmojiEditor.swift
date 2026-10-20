import AppKit

@MainActor
func setWorkspaceSidebarProjectEmoji(_ projectId: WorkspaceProjectId, emoji: String?) {
    runWorkspaceSidebarSession {
        try setWorkspaceProjectEmoji(projectId, emoji: emoji)
        await updateWorkspaceSidebarModel()
    }
}
