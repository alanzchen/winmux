import AppKit

@MainActor
final class WorkspaceSidebarProjectEmojiEditor: NSObject, NSTextFieldDelegate {
    let alert = NSAlert()
    let field = NSTextField(string: "")

    init(project: WorkspaceSidebarProjectViewModel) {
        super.init()
        alert.messageText = "Project Emoji"
        alert.informativeText = "Choose an emoji for “\(project.displayName)” in Dock mode. Press Control–Command–Space to open the macOS emoji picker."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        field.font = .systemFont(ofSize: 26)
        field.alignment = .center
        field.usesSingleLineMode = true
        field.placeholderString = "Choose one emoji"
        field.stringValue = project.emoji ?? ""
        field.setAccessibilityLabel("Project emoji")
        field.delegate = self
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        updateValidation()
    }

    var emoji: String? { normalizedWorkspaceProjectEmoji(field.stringValue) }

    func controlTextDidChange(_ notification: Notification) {
        updateValidation()
    }

    private func updateValidation() {
        alert.buttons.first?.isEnabled = emoji != nil
    }
}

@MainActor
func editWorkspaceSidebarProjectEmoji(_ project: WorkspaceSidebarProjectViewModel) {
    guard NSApp.modalWindow == nil else { return }
    // The modal field owns keyboard input; release any sidebar event tap first.
    WorkspaceSidebarPanel.inputSession.owner?.cancelInlineTextEditing()
    let editor = WorkspaceSidebarProjectEmojiEditor(project: project)
    defer {
        // Native modals suppress hover events. Reconcile even when Cancel was used
        // and the cursor stopped moving while the editor was open.
        WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
    }
    NSApp.activate(ignoringOtherApps: true)
    guard editor.alert.runModal() == .alertFirstButtonReturn, let emoji = editor.emoji else { return }
    setWorkspaceSidebarProjectEmoji(project.id, emoji: emoji)
}

@MainActor
func setWorkspaceSidebarProjectEmoji(_ projectId: WorkspaceProjectId, emoji: String?) {
    runWorkspaceSidebarSession {
        try setWorkspaceProjectEmoji(projectId, emoji: emoji)
        await updateWorkspaceSidebarModel()
    }
}
