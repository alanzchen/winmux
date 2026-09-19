import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceProjectEmojiTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testEmojiFollowsProjectIdentityThroughRenameAndDisappearsOnDelete() throws {
        let project = createWorkspaceProject()
        try setWorkspaceProjectEmoji(project.id, emoji: "💻")
        try renameWorkspaceProject(project.id, displayName: "Research")
        var snapshot = try XCTUnwrap(buildWorkspaceSidebarProjectViewModels().first { $0.id == project.id })
        XCTAssertEqual(snapshot.displayName, "Research")
        XCTAssertEqual(snapshot.emoji, "💻")
        try setWorkspaceProjectEmoji(project.id, emoji: "👩🏽‍💻")
        snapshot = try XCTUnwrap(buildWorkspaceSidebarProjectViewModels().first { $0.id == project.id })
        XCTAssertEqual(snapshot.emoji, "👩🏽‍💻", "The next snapshot must reflect the edit immediately")
        try setWorkspaceProjectEmoji(project.id, emoji: nil)
        XCTAssertNil(buildWorkspaceSidebarProjectViewModels().first { $0.id == project.id }?.emoji)
        try setWorkspaceProjectEmoji(project.id, emoji: "💻")
        try deleteWorkspaceProject(project.id)
        XCTAssertNil(config.workspaceSidebar.projectEmojis[project.id.rawValue])
    }

    func testDefaultProjectAllowsEmojiAndInvalidEditsPreserveExistingValue() throws {
        try setWorkspaceProjectEmoji(workspaceProjectDefaultId, emoji: "🏠")
        XCTAssertThrowsError(try setWorkspaceProjectEmoji(workspaceProjectDefaultId, emoji: "words"))
        XCTAssertEqual(config.workspaceSidebar.projectEmojis[workspaceProjectDefaultId.rawValue], "🏠")
        XCTAssertThrowsError(try setWorkspaceProjectEmoji("missing-project", emoji: "💻"))
        XCTAssertNil(config.workspaceSidebar.projectEmojis["missing-project"])
    }

    func testNativeEmojiEditorOnlyEnablesSaveForOneEmoji() {
        let editor = WorkspaceSidebarProjectEmojiEditor(project: .init(id: workspaceProjectDefaultId, displayName: "Home", colorHex: nil, emoji: "🏠"))
        XCTAssertEqual(editor.emoji, "🏠")
        XCTAssertTrue(editor.alert.buttons[0].isEnabled)
        for (value, valid) in [("", false), ("work", false), ("💻🏠", false), ("👩🏽‍💻", true), ("❤️", true)] {
            editor.field.stringValue = value
            editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.field))
            XCTAssertEqual(editor.alert.buttons[0].isEnabled, valid)
        }
        XCTAssertEqual(editor.alert.buttons[1].title, "Cancel")
        editor.alert.layout()
        XCTAssertTrue(editor.alert.window.initialFirstResponder === editor.field, "The emoji field must retain initial focus after native alert layout")
        XCTAssertFalse(editor.alert.window.isVisible)
    }

    func testNativeEmojiModalBlocksSidebarCommandAndEditing() {
        let editor = WorkspaceSidebarProjectEmojiEditor(project: .init(id: workspaceProjectDefaultId, displayName: "Home", colorHex: nil))
        let session = NSApp.beginModalSession(for: editor.alert.window)
        defer {
            NSApp.endModalSession(session)
            editor.alert.window.orderOut(nil)
        }
        XCTAssertTrue(NSApp.modalWindow === editor.alert.window)
        let panel = WorkspaceSidebarPanel.shared
        let wasExpanded = panel.viewModel.isWorkspaceSidebarExpanded
        openWorkspaceSidebarFromCommand()
        panel.beginInlineTextEditing()
        panel.prepareForInlineTextEditing()
        panel.expandSidebar(to: 240, reason: .hover)
        XCTAssertNil(WorkspaceSidebarPanel.inputSession.owner)
        XCTAssertFalse(panel.inlineTextEditingActive)
        XCTAssertFalse(panel.commandExpansionLocksCollapse)
        XCTAssertEqual(panel.viewModel.isWorkspaceSidebarExpanded, wasExpanded)
        XCTAssertTrue(NSApp.modalWindow === editor.alert.window)
    }
}
