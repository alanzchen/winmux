import Foundation
@testable import AppBundle
import Common
import XCTest

/// S2 delta review fixes (Astra S2-D-A1/A2 and the guard contracts, Carbon S2-D1/D2): the vendored TOMLDecoder patch,
/// `EditableConfigText`, the symlink-following disk writer and empty tables in the kept-keys check. Astra's external
/// probes are ported here.
@MainActor
final class S2DeltaTest: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "s2-delta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Astra S2-D-A2 and the vendored lexer patch

    func testExistingMultilineShellBindingWithEscapedBackslashLoads() {
        let source = "config-version = 2\n[mode.main.binding]\nalt-a = \"\"\"exec-and-forget printf %s \"\"\\\\\\\\\"\"\"\"\"\n"
        let result = parseConfig(source)
        assertEquals(result.errors, [])
        XCTAssertNotNil(result.config.modes["main"]?.bindings["alt-a"])
    }

    func testMultilineBasicStringsReadAsTheSpecSays() throws {
        let table = try WinMuxToml.table(#"""
            a = """C:\\Users\\"""
            b = """x""\u005C"y"""
            c = """x""\
              "y"""
            d = """a\\\""""
            e = """\u0022\u0022\u0022"""
            """#)
        assertEquals(table["a"] as? String, #"C:\Users\"#)
        assertEquals(table["b"] as? String, #"x""\"y"#)
        assertEquals(table["c"] as? String, #"x"""y"#)
        assertEquals(table["d"] as? String, #"a\""#)
        assertEquals(table["e"] as? String, "\"\"\"")
        XCTAssertThrowsError(try WinMuxToml.table("x = \"\"\"a\"\"\"\"\"\"\n"), "a run of six quotes can't close the string")
        XCTAssertThrowsError(try WinMuxToml.table("x = \"\"\"a\\\"\"\"\n"), "an escaped quote doesn't close the string")
    }

    // MARK: Carbon S2-D2 — one line model for every editor

    func testEditableConfigTextKeepsLineEndingAndByteOrderMark() {
        let text = "\u{FEFF}[workspace-sidebar]\r\n    width = 300\r\n"
        let config = EditableConfigText(text)
        assertEquals(config.lines, ["[workspace-sidebar]", "    width = 300", ""])
        assertEquals(config.text, text)
        assertEquals(EditableConfigText("a\nb").text, "a\nb")
    }

    func testEveryEditorEditsACrlfFileLikeItsLfTwin() {
        let samples = [
            starterConfigText(),
            "config-version = 2\n\n[workspace-sidebar] # panel\n    project-order = [\n        \"default\",\n    ]\n    width = 300\n\n[workspace-sidebar.workspace-labels]\n\"1\" = \"\"\"\nOne\n\"\"\"\n\"2\" = \"Two\"\n\n[mode.main.binding]\n    alt-h = 'focus left'\n",
            "[gaps]\n    outer.left = [\n        { monitor.main = 16, },\n        8,\n    ]\n\n[workspace-sidebar.project-colors]\np = '#000000'\n",
        ]
        let editors: [(String) -> String?] = [
            { updateWorkspaceSidebarScalarConfig(in: $0, key: "width", renderedValue: "320") },
            { updateWorkspaceSidebarLabelConfig(in: $0, workspaceName: "1", label: "Renamed") },
            { updateWorkspaceSidebarProjectColorConfig(in: $0, projectId: "p", colorHex: "#112233") },
            { updateWorkspaceSidebarProjectEmojiConfig(in: $0, projectId: "p", emoji: "🚀") },
            { updateWorkspaceSidebarProjectOrderConfig(in: $0, order: ["default", "p"]) },
            { updateWorkspaceSidebarDisplayWidthConfig(in: $0, display: "Built-in", width: 280) },
            { updateModeBindingConfig(in: $0, managedCommands: ["focus left"], assignments: ["alt-h": "focus left"]) },
            { updateSettingsScalarConfig(in: $0, section: "gaps", key: "outer.left", renderedValue: "12") },
        ]
        for sample in samples {
            let crlf = sample.replacingOccurrences(of: "\n", with: "\r\n")
            for (index, edit) in editors.enumerated() {
                let lfAfter = edit(sample)
                assertEquals(edit(crlf), lfAfter?.replacingOccurrences(of: "\n", with: "\r\n"), additionalMsg: "editor \(index)")
                if let lfAfter { assertEquals(parseConfig(lfAfter).errors, [], additionalMsg: "editor \(index)") }
            }
        }
    }

    // MARK: Astra S2-D-A1 / Carbon S2-D1 — symlinks

    func testConfigWritesUpdateTheSymlinkTargetAndKeepTheLink() async throws {
        let fileManager = FileManager.default
        let before = "[workspace-sidebar]\nwidth = 300\n", after = "[workspace-sidebar]\nwidth = 320\n"
        func target(_ name: String) throws -> URL {
            let url = root.appending(path: name)
            try before.write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        }
        func assertUpdated(_ link: URL, _ target: URL, _ name: String) throws {
            XCTAssertNotNil(try? fileManager.destinationOfSymbolicLink(atPath: link.path), "\(name): link kept")
            assertEquals(try String(contentsOf: target, encoding: .utf8), after, additionalMsg: name)
            assertEquals((try fileManager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600, additionalMsg: name)
        }
        for relative in [true, false] {
            let real = try target(relative ? "dotfiles-relative.toml" : "dotfiles-absolute.toml")
            let link = root.appending(path: relative ? "relative.toml" : "absolute.toml")
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: relative ? real.lastPathComponent : real.path)
            try writeConfigFile(after, replacing: before, at: link, changing: [["workspace-sidebar", "width"]])
            try assertUpdated(link, real, relative ? "relative" : "absolute")
        }
        // Two hops, the first relative through a parent directory.
        try fileManager.createDirectory(at: root.appending(path: "dotfiles"), withIntermediateDirectories: true)
        let chained = try target("dotfiles/winmux.toml")
        try fileManager.createSymbolicLink(atPath: root.appending(path: "hop.toml").path, withDestinationPath: chained.path)
        try fileManager.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true)
        let chainLink = root.appending(path: "config/winmux.toml")
        try fileManager.createSymbolicLink(atPath: chainLink.path, withDestinationPath: "../hop.toml")
        try writeConfigFile(after, replacing: before, at: chainLink, changing: [["workspace-sidebar", "width"]])
        try assertUpdated(chainLink, chained, "chain")
        XCTAssertNotNil(try? fileManager.destinationOfSymbolicLink(atPath: root.appending(path: "hop.toml").path))
        // The Settings route, with its real disk writer.
        let settingsReal = try target("settings-dotfiles.toml")
        let settingsLink = root.appending(path: "settings-link.toml")
        try fileManager.createSymbolicLink(atPath: settingsLink.path, withDestinationPath: settingsReal.lastPathComponent)
        let persistence = SettingsPersistence(target: { settingsLink }, reload: { _ in true })
        _ = try await persistence.save([SettingsFileEdit(section: "workspace-sidebar", values: ["width": "320"])])
        try assertUpdated(settingsLink, settingsReal, "Settings")
        // A regular file stays a regular file with its mode.
        let regular = try target("regular.toml")
        try writeConfigFile(after, replacing: before, at: regular, changing: [["workspace-sidebar", "width"]])
        assertEquals(try String(contentsOf: regular, encoding: .utf8), after)
        assertEquals((try fileManager.attributesOfItem(atPath: regular.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFirstLaunchFileThroughADanglingSymlinkCreatesTheTarget() throws {
        let link = root.appending(path: "winmux.toml")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles-new.toml")
        try replaceConfigFileOnDisk("config-version = 2\n", at: link)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        assertEquals(try String(contentsOf: root.appending(path: "dotfiles-new.toml"), encoding: .utf8), "config-version = 2\n")
    }

    // MARK: Astra's guard contracts — empty tables

    func testKeptKeysCheckCountsEmptyTables() {
        func allowed(_ before: String, _ after: String, _ paths: [ConfigKeyPath]) -> Bool {
            (try? validateConfigEdit(before: before, after: after, changing: paths)) != nil
        }
        let width = [["workspace-sidebar", "width"]]
        XCTAssertFalse(allowed("[exec]\n[workspace-sidebar]\nwidth=300", "[workspace-sidebar]\nwidth=320", width),
                       "an empty [exec] changes PATH")
        XCTAssertFalse(allowed("[mode.main.binding]\nalt-a='focus left'\n[mode.service.binding]\n[workspace-sidebar]\nwidth=300",
                               "[mode.main.binding]\nalt-a='focus left'\n[workspace-sidebar]\nwidth=320", width),
                       "an empty mode is still a mode")
        let label = [["workspace-sidebar", "workspace-labels", "1"]]
        XCTAssertTrue(allowed("[workspace-sidebar.workspace-labels]\n\"1\"=\"One\"", "", label), "the last label takes its table")
        XCTAssertTrue(allowed("[workspace-sidebar.workspace-labels]\n\"1\"=\"One\"", "[workspace-sidebar.workspace-labels]\n", label),
                      "or leaves it empty")
        XCTAssertTrue(allowed("[gaps]\nouter.left = [{monitor.main=16},8]\nouter.right=10", "[gaps]\nouter.left=12\nouter.right=10",
                              [["gaps", "outer", "left"]]))
    }
}
