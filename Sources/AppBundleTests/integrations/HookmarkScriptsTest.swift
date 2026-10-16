@testable import AppBundle
import Foundation
import XCTest

/// Hookmark-compatible scripts: what they need, what WinMux makes of them, and how they run. An address is
/// only ever data: real `osascript` runs show one that looks like code isn't run, and Unicode arrives whole.
/// The scripts here are written for these tests.
@MainActor
final class HookmarkScriptsTest: XCTestCase {
    private func integration(_ getAddress: String, getName: String? = nil, openItem: String? = nil, newItem: String? = nil,
                             scheme: String? = nil, scriptingMethod: String? = nil, urlConverter: String? = nil) -> LinkIntegration {
        LinkIntegration(bundleId: "com.example.Notebook", appName: "Notebook", getAddress: getAddress, getName: getName,
            openItem: openItem, newItem: newItem, scheme: scheme, scriptingMethod: scriptingMethod, urlConverter: urlConverter,
            source: .init(kind: .pasted))
    }

    // MARK: - Language and needs

    func testAScriptIsJavaScriptOnlyWhenItSaysSo() {
        XCTAssertEqual(hookmarkScriptLanguage("//JavaScript\nApplication('Notebook').name()"), .javaScript)
        XCTAssertEqual(hookmarkScriptLanguage("\n  // JavaScript\n1"), .javaScript)
        XCTAssertEqual(hookmarkScriptLanguage("tell application \"Notebook\" to get name"), .appleScript)
        XCTAssertEqual(hookmarkScriptLanguage("// a comment\nvar x = 1"), .appleScript, "Hookmark's rule, not a guess")
    }

    func testWhatAScriptNeedsIsReadFromItsText() {
        let ui = hookmarkScriptTraits("""
            tell application "System Events" to keystroke "c" using command down
            set copied to the clipboard
            do shell script "echo"
            """)
        XCTAssertTrue(ui.usesUIScripting)
        XCTAssertTrue(ui.usesClipboard)
        XCTAssertTrue(ui.usesShell)
        XCTAssertFalse(ui.needsHookmark)
        XCTAssertEqual(ui.apps, ["System Events"])
        XCTAssertTrue(hookmarkScriptTraits("tell application \"Hookmark\" to get name").needsHookmark)
        XCTAssertTrue(hookmarkScriptTraits("return \"hook://file/ABC\"").needsHookmark)
        XCTAssertTrue(hookmarkScriptTraits("//JavaScript\nApplication('Hookmark').name()").needsHookmark)
        XCTAssertTrue(hookmarkScriptTraits("open location \"x-notebook://x-callback-url/get?x-success=hook://x-callback-url/setCurrentNode\"")
            .usesCallback)
        let open = hookmarkScriptTraits("tell application \"Notebook\" to open location \"$0\" -- not $0 here")
        XCTAssertTrue(open.usesAddress)
        XCTAssertTrue(hookmarkScriptTraits("//JavaScript\nlet a = `see ${x} $0`").placeholderInTemplate)
    }

    // MARK: - The compatibility verdict

    func testTheVerdictSaysWhatRunsUnchangedNeedsAdaptationOrCant() {
        let plain = integration("tell application \"Notebook\" to return URL of front document")
        XCTAssertEqual(plain.analysis.verdict, .runsUnchanged)
        XCTAssertTrue(plain.analysis.canCapture)
        XCTAssertTrue(plain.analysis.notes.first?.contains("Apple events") == true, "Automation is said first")

        let clipboard = integration("set the clipboard to \"\"\nreturn the clipboard")
        XCTAssertEqual(clipboard.analysis.verdict, .runsWithNotes)

        let converter = integration("return \"https://example.com/\"", urlConverter: "tell application \"Hookmark\" to …")
        XCTAssertEqual(converter.analysis.verdict, .needsAdaptation)

        let nameNeedsHookmark = integration("return \"https://example.com/\"", getName: "tell application \"Hookmark\" to get name")
        XCTAssertEqual(nameNeedsHookmark.analysis.verdict, .needsAdaptation, "Get Name is optional: skipped, not fatal")
        XCTAssertTrue(nameNeedsHookmark.analysis.canCapture)
        XCTAssertFalse(nameNeedsHookmark.analysis.canName)

        let openInTemplate = integration("return \"x-notebook://1\"", openItem: "//JavaScript\nApp.openLocation(`$0`)", scheme: "x-notebook")
        XCTAssertEqual(openInTemplate.analysis.verdict, .needsAdaptation)
        XCTAssertFalse(openInTemplate.analysis.canOpen)
        XCTAssertTrue(openInTemplate.analysis.problems.contains { $0.contains("open as macOS opens them") })

        let hookmarkAddress = integration("tell application \"Hookmark\" to return address of current node")
        XCTAssertEqual(hookmarkAddress.analysis.verdict, .unsupported)
        XCTAssertFalse(hookmarkAddress.analysis.canCapture)

        let callback = integration("open location \"x-notebook://x-callback-url/get\"", scriptingMethod: "x-callback-url")
        XCTAssertEqual(callback.analysis.verdict, .unsupported)
        let setCurrentNode = integration("open location \"x-notebook://get?x-success=hook://x-callback-url/setCurrentNode\"")
        XCTAssertEqual(setCurrentNode.analysis.verdict, .unsupported)
        XCTAssertTrue(setCurrentNode.analysis.problems.first?.contains("call Hookmark back") == true, "Said as what it is")

        let newItem = integration("return \"x-notebook://1\"", newItem: "tell application \"Notebook\" to make new note named \"$title\"")
        XCTAssertTrue(newItem.analysis.notes.contains { $0.contains("New Item is kept") })
        XCTAssertEqual(newItem.analysis.verdict, .runsUnchanged, "Kept, labelled, never run")

        let noScheme = integration("return \"x-notebook://1\"", openItem: "open location \"$0\"")
        XCTAssertTrue(noScheme.analysis.notes.contains { $0.contains("Without a scheme") })
    }

    // MARK: - Placeholders are bound as data

    func testAppleScriptPlaceholdersBecomeReadsNeverTheAddressItself() throws {
        let source = """
            -- opens $0
            tell application "Notebook" to open location "$0"
            set |$0| to $0
            (* $0 (* nested $0 *) *)
            return "$$"
            """
        let values = HookmarkPlaceholderValues(address: "x\" & (do shell script \"echo pwned\") & \"", appName: "Note\"book")
        let executable = try hookmarkExecutableSource(source, values: values)
        XCTAssertFalse(executable.contains("pwned"), "The address is never in the script's text")
        XCTAssertTrue(executable.contains("-- opens $0"), "Comments are left as written")
        XCTAssertTrue(executable.contains("(* $0 (* nested $0 *) *)"))
        XCTAssertTrue(executable.contains("set |$0| to (winmuxHookmarkAddress)"))
        XCTAssertTrue(executable.contains("open location (\"\" & winmuxHookmarkAddress & \"\")"), "One value, in parentheses")
        XCTAssertTrue(executable.contains("return \"Note\\\"book\""), "$$ is the app name, escaped")
        XCTAssertTrue(executable.hasPrefix("-- opens $0\nglobal winmuxHookmarkAddress\n"), "After leading comments and use lines")
        XCTAssertEqual(hookmarkEnvironment(values)[hookmarkAddressEnvironment], hookmarkHex(values.address!))
        XCTAssertEqual(try hookmarkExecutableSource("return 1", values: values), "return 1", "Nothing to bind: unchanged")
    }

    func testJavaScriptPlaceholdersBecomeReadsAndTemplateStringsRefuse() throws {
        let values = HookmarkPlaceholderValues(address: "'+(function(){throw 1})()+'", appName: "Note'book")
        let executable = try hookmarkExecutableSource("""
            //JavaScript
            // opens $0
            var a = '$0'; var b = "$0"; var c = $0; /* $0 */ var d = '$$'
            """, values: values)
        XCTAssertFalse(executable.contains("throw 1"))
        XCTAssertTrue(executable.contains("// opens $0"))
        XCTAssertTrue(executable.contains("/* $0 */"))
        XCTAssertTrue(executable.contains("var d = 'Note\\'book'"))
        XCTAssertThrowsError(try hookmarkExecutableSource("//JavaScript\nvar a = `$0`", values: values)) { error in
            XCTAssertEqual(error as? HookmarkPlaceholderError, .templateString)
        }
        XCTAssertThrowsError(try hookmarkExecutableSource("return \"$0", values: values)) { error in
            XCTAssertEqual(error as? HookmarkPlaceholderError, .unterminated)
        }
    }

    // MARK: - Real runs

    private var canRunOsascript: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript") }

    func testAnAddressThatLooksLikeCodeIsOnlyDataWhenAppleScriptRuns() async throws {
        try XCTSkipUnless(canRunOsascript)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-hm-\(UUID().uuidString)")
        let address = "x-notebook://note/1?q=\" & (do shell script \"touch \(marker.path)\") & \""
        let result = await runHookmarkScript("return \"$0\"", .init(address: address, appName: "Notebook"))
        XCTAssertEqual(result, .success(address))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Nothing in the address ran")
        let inCode = await runHookmarkScript("return $0", .init(address: address))
        XCTAssertEqual(inCode, .success(address))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAnAddressThatLooksLikeCodeIsOnlyDataWhenJavaScriptRuns() async throws {
        try XCTSkipUnless(canRunOsascript)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-hm-\(UUID().uuidString)")
        let address = "x-notebook://note/1?q='+(function(){var a=Application.currentApplication();a.includeStandardAdditions=true;"
            + "a.doShellScript('touch \(marker.path)')})()+'"
        let result = await runHookmarkScript("//JavaScript\n'' + '$0'", .init(address: address))
        XCTAssertEqual(result, .success(address))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAStringHoldingTheAddressStaysOneValueToWhatFollowsIt() async throws {
        try XCTSkipUnless(canRunOsascript)
        let address = "x-notebook://note/12345"
        let javaScript = await runHookmarkScript("//JavaScript\n\"$0\".split(\"/\").pop()", .init(address: address))
        XCTAssertEqual(javaScript, .success("12345"))
        let indexed = await runHookmarkScript("//JavaScript\n'id=$0'.length", .init(address: address))
        XCTAssertEqual(indexed, .success(String("id=\(address)".count)))
        let appleScript = await runHookmarkScript("return text 1 thru 10 of \"$0\"", .init(address: address))
        XCTAssertEqual(appleScript, .success("x-notebook"))
    }

    func testATemplatesTextTakesNoPlaceholderButItsExpressionsAreCode() async throws {
        try XCTSkipUnless(canRunOsascript)
        let refused = await runHookmarkScript("//JavaScript\n`$$`", .init(appName: "Note${1+1}book"))
        guard case .failed = refused else { return XCTFail("$$ in a template's text refuses before anything runs") }
        let name = "Bob's \"Notes\" ${1+1}`"
        let inExpression = await runHookmarkScript("//JavaScript\n`<${ '$$' }>`", .init(appName: name))
        XCTAssertEqual(inExpression, .success("<\(name)>"), "A string inside ${…} is an ordinary string")
        let address = "x-notebook://note/1?q=' + 1 + '"
        let addressInExpression = await runHookmarkScript("//JavaScript\n`[${ \"$0\".length }|${ $0 }]`", .init(address: address))
        XCTAssertEqual(addressInExpression, .success("[\(address.count)|\(address)]"))
        let nested = await runHookmarkScript("//JavaScript\n`a${ `b${ '$$' }` }c`", .init(appName: "N'"))
        XCTAssertEqual(nested, .success("abN'c"))
        XCTAssertTrue(hookmarkScriptTraits("//JavaScript\n`see $$`").placeholderInTemplate)
        XCTAssertFalse(hookmarkScriptTraits("//JavaScript\n`see ${ '$0' }`").placeholderInTemplate)
    }

    func testUnicodeArrivesWholeInBothLanguagesAndInHandlers() async throws {
        try XCTSkipUnless(canRunOsascript)
        let address = "https://例え.jp/ü?q=é&name=\"Grüße\" 🙂"
        let apple = await runHookmarkScript("return \"$0\"", .init(address: address))
        XCTAssertEqual(apple, .success(address))
        let javaScript = await runHookmarkScript("//JavaScript\n$0", .init(address: address))
        XCTAssertEqual(javaScript, .success(address))
        let runHandler = await runHookmarkScript("on run\n\treturn \"<\" & \"$0\" & \">\"\nend run", .init(address: address))
        XCTAssertEqual(runHandler, .success("<\(address)>"))
        let handler = await runHookmarkScript("on shown()\n\treturn $0\nend shown\nreturn shown()", .init(address: address))
        XCTAssertEqual(handler, .success(address), "Handlers read it too")
        let insideTell = await runHookmarkScript("tell application \"System Events\"\n\treturn \"$0\"\nend tell", .init(address: address))
        XCTAssertEqual(insideTell, .success(address), "Read at the top level, not by the tell target")
        let name = await runHookmarkScript("return \"$$\"", .init(appName: "Note\"bøøk"))
        XCTAssertEqual(name, .success("Note\"bøøk"))
    }

    func testFailuresAndTimeoutsAreReportedPlainly() async throws {
        try XCTSkipUnless(canRunOsascript)
        let failed = await runHookmarkScript("error \"No note is open.\"", .init())
        XCTAssertEqual(failed, .failed("No note is open. (-2700)"))
        let timedOut = await runOsaScript("delay 5", language: .appleScript, environment: [:], timeout: 0.5)
        XCTAssertEqual(timedOut, .timedOut)
        let long = await runOsaScript("'x'.repeat(200000)", language: .javaScript, environment: [:], timeout: 10)
        XCTAssertEqual(long, .success(String(repeating: "x", count: 200_000)), "A long answer can't stall the script")
        let template = await runHookmarkScript("//JavaScript\n`$0`", .init(address: "x"))
        guard case .failed = template else { return XCTFail("A template string refuses before anything runs") }
    }

    // MARK: - What Get Address answered

    func testGetAddressAnswersAreKeptOnlyWhenWellFormed() throws {
        XCTAssertEqual(parseHookmarkAddress("https://example.com/a?b=c#d\n"), .link(url: "https://example.com/a?b=c#d", name: nil))
        XCTAssertEqual(parseHookmarkAddress("[Plan (v2)](x-notebook://note/1)"), .link(url: "x-notebook://note/1", name: "Plan (v2)"))
        let json = #"{"address":"\#(Data("x-notebook://note/2".utf8).base64EncodedString())","name":"\#(Data("Zwei\nZeilen".utf8).base64EncodedString())"}"#
        XCTAssertEqual(parseHookmarkAddress(json), .link(url: "x-notebook://note/2", name: "Zwei Zeilen"))
        XCTAssertEqual(parseHookmarkAddress("  "), .empty)
        XCTAssertEqual(parseHookmarkAddress("hook://x-callback-url/setCurrentNode?x=1"), .callback)
        XCTAssertEqual(parseHookmarkAddress("hook://file/ABC"), .hookmarkLink)
        XCTAssertEqual(parseHookmarkAddress("[n](hookmark://x)"), .hookmarkLink)
        for refused in ["javascript:alert(1)", "data:text/html,x", "https:///nohost", "not an address", "two\nlines://x"] {
            guard case .invalid = parseHookmarkAddress(refused) else { return XCTFail(refused) }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("winmux hm \(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(parseHookmarkAddress(file.path), .file(file.standardizedFileURL, name: nil), "A path may hold spaces")
        XCTAssertEqual(parseHookmarkAddress(file.absoluteString), .file(file.standardizedFileURL, name: nil))
        guard case .invalid = parseHookmarkAddress("/nonexistent/winmux-\(UUID().uuidString)") else { return XCTFail() }
        XCTAssertEqual(hookmarkCleanName(String(repeating: "a", count: 300) + "\u{7}"), String(repeating: "a", count: 200))
    }
}
