@testable import AppBundle
import Foundation
import XCTest

extension ConfigTest {
    func testProjectEmojiConfigurationSupportsJoinedEmojiAndRejectsText() {
        for emoji in ["🏠", "👩🏽‍💻", "👨‍👩‍👧‍👦", "🇺🇸", "❤️", "1️⃣"] {
            let (parsed, errors) = parseConfig("""
                [workspace-sidebar.project-emojis]
                default = ' \(emoji) '
                "project-1" = '💻'
                """)
            XCTAssertEqual(errors.descriptions, [])
            XCTAssertEqual(parsed.workspaceSidebar.projectEmojis["default"], emoji)
            XCTAssertEqual(parsed.workspaceSidebar.projectEmojis["project-1"], "💻")
        }
        for invalid in ["", "Work", "1", "#", "1\u{FE0F}", "🏽", "🇺", "a\u{FE0F}", "🏠💻"] {
            let (_, errors) = parseConfig("""
                [workspace-sidebar.project-emojis]
                default = '\(invalid)'
                """)
            XCTAssertEqual(errors.descriptions, ["workspace-sidebar.project-emojis.default: Must be a single emoji"])
        }
        for invalidType in ["42", "false", "[]"] {
            let (_, errors) = parseConfig("[workspace-sidebar.project-emojis]\ndefault = \(invalidType)")
            XCTAssertFalse(errors.isEmpty)
            let (_, tableErrors) = parseConfig("[workspace-sidebar]\nproject-emojis = \(invalidType)")
            XCTAssertFalse(tableErrors.isEmpty)
        }
    }

    func testProjectEmojiPersistenceReplacesResetsAndPreservesOtherMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("winmux.toml")
        try persistWorkspaceSidebarProjectMetadata(projectId: "project-1", label: "Work", colorHex: "#60A5FA", emoji: nil, targetUrl: target)
        for emoji in ["🏠", "👩🏽‍💻"] {
            try persistWorkspaceSidebarProjectEmoji(projectId: "project-1", emoji: emoji, targetUrl: target)
            let (parsed, errors) = parseConfig(try String(contentsOf: target, encoding: .utf8))
            XCTAssertEqual(errors.descriptions, [])
            XCTAssertEqual(parsed.workspaceSidebar.projectEmojis, ["project-1": emoji])
            XCTAssertEqual(parsed.workspaceSidebar.projectLabels["project-1"], "Work")
            XCTAssertEqual(parsed.workspaceSidebar.projectColors["project-1"], "#60A5FA")
        }
        try persistWorkspaceSidebarProjectEmoji(projectId: "project-1", emoji: nil, targetUrl: target)
        XCTAssertFalse(try String(contentsOf: target, encoding: .utf8).contains("[workspace-sidebar.project-emojis]"))
        try persistWorkspaceSidebarProjectEmoji(projectId: "project-1", emoji: "💻", targetUrl: target)
        try persistWorkspaceSidebarProjectEmoji(projectId: "default", emoji: "🏠", targetUrl: target)
        try persistWorkspaceSidebarProjectMetadata(projectId: "project-1", label: nil, colorHex: nil, emoji: nil, targetUrl: target)
        let (deleted, errors) = parseConfig(try String(contentsOf: target, encoding: .utf8))
        XCTAssertEqual(errors.descriptions, [])
        XCTAssertEqual(deleted.workspaceSidebar.projectEmojis, ["default": "🏠"])
        XCTAssertNil(deleted.workspaceSidebar.projectLabels["project-1"])
        XCTAssertNil(deleted.workspaceSidebar.projectColors["project-1"])
    }

    func testProjectEmojiPersistenceDoesNotOverwriteUnreadableConfig() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        let invalidUtf8 = Data([0xC3, 0x28])
        try invalidUtf8.write(to: target)
        XCTAssertThrowsError(try persistWorkspaceSidebarProjectEmoji(projectId: "default", emoji: "🏠", targetUrl: target))
        XCTAssertEqual(try Data(contentsOf: target), invalidUtf8)
    }

    func testResettingLastProjectEmojiPreservesCommentedExamples() {
        let original = """
            [workspace-sidebar.project-emojis]
            # "default" = "🏠"
            # Keep this example.
            """
        let added = updateWorkspaceSidebarProjectEmojiConfig(in: original, projectId: "default", emoji: "🏠")
        let reset = updateWorkspaceSidebarProjectEmojiConfig(in: added, projectId: "default", emoji: nil)
        XCTAssertEqual(reset, original)
        let (parsed, errors) = parseConfig(reset)
        XCTAssertEqual(errors.descriptions, [])
        XCTAssertTrue(parsed.workspaceSidebar.projectEmojis.isEmpty)
    }

    func testProjectEmojiEditsRecognizeBareBasicAndLiteralTomlKeys() {
        for key in ["project-1", "\"project-1\"", "'project-1'"] {
            let original = "[workspace-sidebar.project-emojis]\n\(key) = '💻'"
            let updated = updateWorkspaceSidebarProjectEmojiConfig(in: original, projectId: "project-1", emoji: "🏠")
            let (parsed, errors) = parseConfig(updated)
            XCTAssertEqual(errors.descriptions, [], "Must replace rather than duplicate \(key)")
            XCTAssertEqual(parsed.workspaceSidebar.projectEmojis["project-1"], "🏠")
            let reset = updateWorkspaceSidebarProjectEmojiConfig(in: original, projectId: "project-1", emoji: nil)
            let (cleared, resetErrors) = parseConfig(reset)
            XCTAssertEqual(resetErrors.descriptions, [])
            XCTAssertNil(cleared.workspaceSidebar.projectEmojis["project-1"], "Must remove \(key)")
        }
    }
}
