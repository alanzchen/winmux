@testable import AppBundle
import Common
import Darwin
import Foundation
import XCTest

@MainActor
final class CarbonS2DeltaReproTest: XCTestCase {
    private func isSymbolicLink(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// S2-D1: `writeConfigFile` (`ConfigFileWrite.swift:57-63`) and `SettingsPersistence.write`
    /// (`SettingsEditor.swift:55-58`) call `String.write(to: url, atomically: true, encoding: .utf8)`
    /// directly on `url`, which renames a temp file over the symlink path, unlinking the user's
    /// `~/.config/winmux/winmux.toml -> dotfiles/winmux.toml` symlink and leaving the dotfiles target stale.
    func testConfigWritesPreserveDotfilesSymlinkAndUpdateTarget() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("carbon-s2-delta-symlink-\(UUID().uuidString)")
        let dotfilesDir = baseDir.appendingPathComponent("dotfiles")
        let configDir = baseDir.appendingPathComponent("winmux")
        try FileManager.default.createDirectory(at: dotfilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let dotfilesToml = dotfilesDir.appendingPathComponent("winmux.toml")
        let symlinkToml = configDir.appendingPathComponent("winmux.toml")
        let initial = "config-version = 2\n\n[workspace-sidebar]\n    width = 300\n"
        try initial.write(to: dotfilesToml, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkToml.path,
            withDestinationPath: "../dotfiles/winmux.toml",
        )
        XCTAssertTrue(isSymbolicLink(symlinkToml))

        // 1. Direct `writeConfigFile` path (sidebar / shortcut / tabs writers)
        try persistWorkspaceSidebarLabel(workspaceName: "1", label: "Work", targetUrl: symlinkToml)
        XCTAssertTrue(
            isSymbolicLink(symlinkToml),
            "writeConfigFile replaced symlinked winmux.toml with a regular file",
        )
        let afterSidebar = try String(contentsOf: dotfilesToml, encoding: .utf8)
        XCTAssertEqual(
            parseConfig(afterSidebar).config.workspaceSidebar.workspaceLabels["1"],
            "Work",
            "writeConfigFile left dotfiles target unchanged",
        )

        // 2. `SettingsPersistence` default disk writer path
        var persistence = SettingsPersistence()
        persistence.target = { symlinkToml }
        persistence.reload = { _ in true }
        _ = try await persistence.save([
            SettingsFileEdit(section: "workspace-sidebar", values: ["width": "340"]),
        ])
        XCTAssertTrue(
            isSymbolicLink(symlinkToml),
            "SettingsPersistence.write replaced symlinked winmux.toml with a regular file",
        )
        let afterSettings = try String(contentsOf: dotfilesToml, encoding: .utf8)
        XCTAssertEqual(
            parseConfig(afterSettings).config.workspaceSidebar.width,
            340,
            "SettingsPersistence.write left dotfiles target unchanged",
        )
    }

    /// S2-D2a: Pure `081780c1 -> f9b15b91` regression in `tomlStatementEnd` (`WinMuxToml.swift:156-171`)
    /// + `WinMuxToml.source` (`WinMuxToml.swift:134-138`). Splitting CRLF text with `.components(separatedBy: "\n")`
    /// leaves `\r` at the end of each line; `lines[index..<end].joined(separator: "\n")` therefore ends with a lone `\r`,
    /// which `normalizedLineEndings` rejects before `WinMuxToml.source` appends `\n`. `tomlStatementEnd` never ends the
    /// multiline `project-order` array, swallowing `width = 300` and causing `writeConfigFile` to false-refuse the edit.
    func testPersistProjectOrderOnCrlfConfigDoesNotSwallowSubsequentKeys() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("carbon-s2-delta-crlf-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetUrl = tempDir.appendingPathComponent("winmux.toml")
        let initialCrlf = [
            "config-version = 2",
            "",
            "[workspace-sidebar] # panel",
            "    project-order = [",
            "        \"default\",",
            "    ]",
            "    width = 300",
            "",
        ].joined(separator: "\r\n")
        XCTAssertEqual(parseConfig(initialCrlf).errors, [])
        try Data(initialCrlf.utf8).write(to: targetUrl)

        XCTAssertNoThrow(try persistWorkspaceSidebarProjectOrder(["default", "work"], targetUrl: targetUrl))
        let saved = try String(contentsOf: targetUrl, encoding: .utf8)
        let (parsed, errors) = parseConfig(saved)
        XCTAssertEqual(errors, [])
        XCTAssertEqual(parsed.workspaceSidebar.projectOrder, ["default", "work"])
        XCTAssertEqual(parsed.workspaceSidebar.width, 300)
    }

    /// S2-D2b: On a valid CRLF `winmux.toml`, sidebar and shortcut config writers split on `"\n"` without stripping
    /// `"\r"` (`WorkspaceSidebarConfigEdits.swift:11,37,173`, `ShortcutSettingsConfigEdits.swift:12`), so neither
    /// `tomlStatementEnd` nor `.trimmingCharacters(in: .whitespaces)` recognizes CRLF lines; existing sections are
    /// duplicated and `writeConfigFile` refuses every save with `Key already exists.`.
    func testSidebarAndShortcutWritersAcceptValidCrlfConfig() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("carbon-s2-delta-crlf-writers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetUrl = tempDir.appendingPathComponent("winmux.toml")
        let initialCrlf = [
            "config-version = 2",
            "",
            "[exec.env-vars]",
            "SCRIPT = '''",
            "printf first",
            "printf second",
            "'''",
            "",
            "[workspace-sidebar]",
            "    enabled = true",
            "    width = 300",
            "",
            "[workspace-sidebar.workspace-labels]",
            "\"1\" = \"One\"",
            "",
            "[mode.main.binding]",
            "alt-h = 'focus left'",
            "",
        ].joined(separator: "\r\n")
        XCTAssertEqual(parseConfig(initialCrlf).errors, [])
        try Data(initialCrlf.utf8).write(to: targetUrl)

        XCTAssertNoThrow(try persistWorkspaceSidebarLabel(workspaceName: "1", label: "Renamed", targetUrl: targetUrl))

        let currentAfterLabel = try String(contentsOf: targetUrl, encoding: .utf8)
        let updatedBindings = updateModeBindingConfig(
            in: currentAfterLabel,
            modeName: mainModeId,
            tableKey: "binding",
            managedCommands: ["focus left"],
            assignments: ["alt-h": "focus down"],
        )
        XCTAssertNoThrow(
            try writeConfigFile(
                updatedBindings,
                replacing: currentAfterLabel,
                at: targetUrl,
                changing: [["mode", mainModeId, "binding"]],
            ),
        )
    }
}
