import AppKit
@testable import AppBundle
import Common
import XCTest

/// S2 review fixes (Astra A1–A3, Carbon S2-C1/C2): the loader's TOML front end (`WinMuxToml`) and the one validated
/// write path (`writeConfigFile`). Astra's external reproducers are ported here as XCTest contracts.
@MainActor
final class S2TomlFrontEndTest: XCTestCase {
    // MARK: A1 — text bridged from NSTextStorage

    func testTomlEditorTextFromNSTextStorageSavesWithoutTrapping() async throws {
        let before = "[workspace-sidebar]\nglass-opacity = 0.5\n"
        let storage = NSTextStorage(string: before)
        storage.mutableString.append("# 配置编辑器 — edited comment\n")
        let editorText = storage.string
        var writes = 0
        let persistence = SettingsPersistence(
            target: { URL(fileURLWithPath: "/test-only/s2-a1.toml") },
            read: { _ in before },
            write: { _, text in XCTAssertEqual(text, editorText); writes += 1 },
            reload: { _ in true },
        )
        _ = try await persistence.saveDocument(editorText, expected: before)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(parseConfigForTests(editorText).config.workspaceSidebar.glassOpacity, 0.5)
    }

    // MARK: A2 — CRLF

    func testCrlfMultilineStringsReadAsLf() {
        let literal = "[exec.env-vars]\r\nSCRIPT = '''\r\nprintf first\r\nprintf second\r\n'''\r\n"
        assertParses(literal, \.execConfig.envVariables["SCRIPT"], "printf first\nprintf second\n")
        let edited = updateSettingsScalarConfig(in: literal, section: "workspace-sidebar", key: "glass-opacity", renderedValue: "0.25")
        assertParses(edited, \.execConfig.envVariables["SCRIPT"], "printf first\nprintf second\n")
        let basic = "exec-on-workspace-change = [\"/bin/sh\", \"-c\", \"\"\"\r\nprintf first\r\nprintf second\r\n\"\"\"]\r\n"
        assertParses(basic, \.execOnWorkspaceChange.last, "printf first\nprintf second\n")
        // An escaped CR is the string's own character, not a line ending.
        assertParses("[exec.env-vars]\r\nA = \"x\\r\\ny\"\r\n", \.execConfig.envVariables["A"], "x\r\ny")
    }

    func testLoneCarriageReturnIsRejectedWithItsLine() {
        assertEquals(parseConfigForTests("config-version = 2\n\r\n# a\rb\n").errors,
                     ["(Line 3) Syntax error: carriage return without line feed."])
        assertEquals(parseConfigForTests("a = 1\r\r\nb = 2\n").errors, ["(Line 1) Syntax error: carriage return without line feed."])
        assertEquals(parseConfigForTests("x = '''\rq'''\n").errors, ["(Line 1) Syntax error: carriage return without line feed."])
    }

    // MARK: A3 — escaped backslashes

    func testEscapedBackslashesKeepTheirValue() {
        let source = #"""
            config-version = 2
            [mode.main.binding]
            alt-a = 'focus left'
            [exec.env-vars]
            WINDOWS_ROOT = """C:\\Users\\alan\\"""
            ONE_LINE = "C:\\Users\\"
            QUOTE = """a\\\"""\\"""
            TWO_EXTRA = """x\\"""""
            LITERAL = '''C:\\'''
            KEPT = "tab\tand \u00E9 \\n"
            # comment with \\ and """ stays a comment
            """#
        let (parsed, errors) = parseConfigForTests(source)
        assertEquals(errors, [])
        let env = parsed.execConfig.envVariables
        assertEquals(env["WINDOWS_ROOT"], #"C:\Users\alan\"#)
        assertEquals(env["ONE_LINE"], #"C:\Users\"#)
        assertEquals(env["QUOTE"], #"a\"""\"#)
        assertEquals(env["TWO_EXTRA"], #"x\"""#)
        assertEquals(env["LITERAL"], #"C:\\"#)
        assertEquals(env["KEPT"], "tab\tand é \\n")
        XCTAssertNotNil(parsed.modes[mainModeId]?.bindings["alt-a"])
    }

    func testFrontEndKeepsLineNumbersAndInvalidText() {
        let crlfErrors = parseConfigForTests("a = 1\r\nb = \r\nc = 2\r\n").errors
        assertEquals(crlfErrors, parseConfigForTests("a = 1\nb = \nc = 2\n").errors)
        XCTAssertTrue(crlfErrors.singleOrNil()?.hasPrefix("(Line 2)") == true, "\(crlfErrors)")
        XCTAssertFalse(parseConfigForTests("x = \"\\q\"").errors.isEmpty, "an invalid escape stays invalid")
        XCTAssertFalse(parseConfigForTests("x = \"\"\"\\\\").errors.isEmpty, "an unterminated string stays unterminated")
    }

    // MARK: Carbon nit 2 — byte order mark

    func testLeadingByteOrderMarkIsIgnoredAsTomlKitDid() {
        assertEquals(parseConfigForTests("\u{FEFF}config-version = 2\n").errors, [])
    }

    // MARK: S2-C2 — EOF and truncated input

    func testTruncatedPrefixesNeverTrap() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var corpus = [starterConfigText()]
        for file in ["resources/default-config.toml", "resources/default-window-rules.toml"] {
            corpus.append(try String(contentsOf: root.appending(path: file), encoding: .utf8))
        }
        corpus += ["width = -", "enabled = true", "mode = inf", "x = nan", "x = +inf", "x = -0.5e+10", "x = 0x1F",
                   "x = 0o17", "x = 0b101", "x = 1979-05-27T07:32:00Z", "x = 07:32:00", "x = { a = [1, 2], b = 'c' }",
                   "x = \"\"\"\\\\\"\"\"", "x = '''a'''", "[[a.b]]\nc = 1"]
        // A token cut off at EOF is what read out of bounds; every character prefix of each line, alone, covers that
        // cheaply. Whole-file prefixes end at each line. The every-character run over whole files is external
        // (docs/upstream-sync.md, S2 review fixes).
        var parses = 0
        for text in corpus {
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                var prefix = ""
                for character in line {
                    prefix.append(character)
                    _ = WinMuxToml.parses(prefix)
                    _ = WinMuxToml.parses(prefix + "\r")
                    parses += 2
                }
                _ = WinMuxToml.parses(lines[...index].joined(separator: "\n"))
                parses += 1
            }
        }
        XCTAssertGreaterThan(parses, 15_000)
    }

    // MARK: Astra — jsonDouble without initializing defaultConfig

    func testFloatsConvertToJsonDoubles() {
        var errors: [ConfigParseDiagnostic] = []
        assertEquals(tomlAnyToOrderedJsonRecursive(any: 0.5, .emptyRoot, &errors), .double(0.5))
        assertEquals(errors, [])
        XCTAssertEqual((try? WinMuxToml.table("x = 0.25"))?["x"] as? Double, 0.25)
    }

    // MARK: S2-C1 — one validated write path

    func testConfigWriteRefusesAChangeOutsideTheEditedKeys() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "s2-write-\(UUID().uuidString)/winmux.toml")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = "[workspace-sidebar.workspace-labels]\n\"1\" = \"One\"\n\"2\" = \"Two\"\n\n[mode.main.binding]\nalt-h = 'focus left'\n"
        // A line edit that lost the rest of the file passes the loader, but not the kept-keys check.
        let truncated = "[workspace-sidebar.workspace-labels]\n\"1\" = \"Renamed\"\n"
        XCTAssertThrowsError(try writeConfigFile(truncated, replacing: before, at: url,
                                                 changing: [["workspace-sidebar", "workspace-labels", "1"]]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a refused edit writes nothing")

        let renamed = before.replacingOccurrences(of: "\"One\"", with: "\"Renamed\"")
        try writeConfigFile(renamed, replacing: before, at: url, changing: [["workspace-sidebar", "workspace-labels", "1"]])
        assertEquals(try String(contentsOf: url, encoding: .utf8), renamed)
    }

    func testConfigWriteRefusesATextTheLoaderRejects() {
        let url = FileManager.default.temporaryDirectory.appending(path: "s2-reject-\(UUID().uuidString)/winmux.toml")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertThrowsError(try writeConfigFile("[workspace-sidebar]\nwidth = 'wide'\n", replacing: "", at: url,
                                                 changing: [["workspace-sidebar", "width"]]))
        XCTAssertThrowsError(try writeConfigFile("a = \"\"\"\\\\", replacing: "", at: url, changing: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a refused edit writes nothing")
    }

    func testSettingsSaveRefusesAnEditThatTouchesOtherKeys() async {
        var saved = "[workspace-sidebar]\nwidth = 300\nenabled = true\n"
        let persistence = SettingsPersistence(
            target: { URL(fileURLWithPath: "/test-only/s2-settings.toml") },
            read: { _ in saved },
            write: { _, next in saved = next },
            reload: { _ in true },
        )
        do {
            _ = try await persistence.save(changing: [["workspace-sidebar", "width"]]) { _ in "[workspace-sidebar]\nwidth = 320\n" }
            XCTFail("an edit that drops 'enabled' must be refused")
        } catch {}
        assertEquals(saved, "[workspace-sidebar]\nwidth = 300\nenabled = true\n")
    }

    private func assertParses(_ source: String, _ get: (Config) -> String?, _ expected: String,
                              file: StaticString = #filePath, line: UInt = #line)
    {
        let (config, errors) = parseConfigForTests(source)
        XCTAssertEqual(errors, [], file: file, line: line)
        XCTAssertEqual(get(config), expected, file: file, line: line)
    }
}
