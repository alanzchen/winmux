@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class CarbonS2SettingsToml11ReproTest: XCTestCase {
    private func resetToastState() {
        MessageModel.shared.message = nil
        MessageModel.shared.detailMessage = nil
        WinMuxToastPanel.shared.dismiss()
    }

    func testSettingsEditOfToml11MultilineValueDoesNotTruncateSubsequentConfig() async {
        let previous = config
        defer {
            config = previous
            resetToastState()
        }

        var savedText = """
            config-version = 2

            [gaps]
                outer.left = [
                    {
                        monitor.main = 16,
                    },
                    8,
                ]
                outer.right = 10

            [workspace-sidebar]
                enabled = true
                width = 300

            [mode.main.binding]
                alt-h = 'focus left'
            """
        let initial = parseConfig(savedText)
        XCTAssertEqual(initial.errors, [])
        config = initial.config

        let persistence = SettingsPersistence(
            target: { URL(fileURLWithPath: "/test-only/winmux-s2-toml11.toml") },
            read: { _ in savedText },
            write: { _, next in savedText = next },
            reload: { _ in
                let parsed = parseConfig(savedText)
                guard parsed.errors.isEmpty else { return false }
                config = parsed.config
                return true
            },
        )
        let editor = SettingsEditor(configuration: config, persistence: persistence)
        let field = SettingsCatalog.field("gaps.outer.left")
        editor.setDraft(.integer(12), for: field)
        editor.commit(field)
        await editor.waitUntilIdle()

        XCTAssertNil(editor.error)
        XCTAssertEqual(config.gaps.outer.left, .constant(12))
        XCTAssertEqual(config.gaps.outer.right, .constant(10), "Editing gaps.outer.left truncated subsequent keys in [gaps]")
        XCTAssertEqual(config.workspaceSidebar.width, 300, "Editing gaps.outer.left wiped out [workspace-sidebar]")
        XCTAssertFalse(config.modes[mainModeId]?.bindings.isEmpty ?? true, "Editing gaps.outer.left wiped out [mode.main.binding]")
    }

    func testSettingsEditBelowToml11MultilineValueUpdatesExistingSection() async {
        let previous = config
        defer {
            config = previous
            resetToastState()
        }

        var savedText = """
            config-version = 2

            [gaps]
                outer.left = [
                    {
                        monitor.main = 16,
                    },
                    8,
                ]

            [workspace-sidebar]
                enabled = true
                width = 300
            """
        let initial = parseConfig(savedText)
        XCTAssertEqual(initial.errors, [])
        config = initial.config

        let persistence = SettingsPersistence(
            target: { URL(fileURLWithPath: "/test-only/winmux-s2-toml11-below.toml") },
            read: { _ in savedText },
            write: { _, next in savedText = next },
            reload: { _ in
                let parsed = parseConfig(savedText)
                guard parsed.errors.isEmpty else { return false }
                config = parsed.config
                return true
            },
        )
        let editor = SettingsEditor(configuration: config, persistence: persistence)
        let field = SettingsCatalog.field("workspace-sidebar.width")
        editor.setDraft(.integer(340), for: field)
        editor.commit(field)
        await editor.waitUntilIdle()

        XCTAssertNil(editor.error)
        XCTAssertEqual(config.workspaceSidebar.width, 340)
    }

    func testPersistWorkspaceSidebarLabelPreservesConfigWithToml11Syntax() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("carbon-s2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetUrl = tempDir.appendingPathComponent("winmux.toml")
        let initialText = """
            config-version = 2

            [workspace-sidebar.workspace-labels]
            "1" = \"\"\"
            hello \\e world
            \"\"\"
            "2" = "Keep Me"

            [mode.main.binding]
            alt-h = 'focus left'
            """
        XCTAssertEqual(parseConfig(initialText).errors, [])
        try initialText.write(to: targetUrl, atomically: true, encoding: .utf8)

        try persistWorkspaceSidebarLabel(workspaceName: "1", label: "Renamed", targetUrl: targetUrl)

        let savedText = try String(contentsOf: targetUrl, encoding: .utf8)
        let (parsed, errors) = parseConfig(savedText)
        XCTAssertEqual(errors, [])
        XCTAssertEqual(parsed.workspaceSidebar.workspaceLabels["1"], "Renamed")
        XCTAssertEqual(parsed.workspaceSidebar.workspaceLabels["2"], "Keep Me", "Sidebar label edit truncated subsequent labels")
        XCTAssertFalse(parsed.modes[mainModeId]?.bindings.isEmpty ?? true, "Sidebar label edit wiped out [mode.main.binding]")
    }
}
