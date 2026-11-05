@testable import AppBundle
import Common
import XCTest

/// Window rules files: WinMux's shipped rules, and the user's, which replace or turn off shipped rules by id
/// and add their own. Declarative only: nothing in them runs. A rule that can't be used is left out, with
/// the reason, and never matches; the rest still apply.
@MainActor
final class WindowRulesTest: XCTestCase {
    private let viewer = """
        version = 1

        [[rule]]
        id = "viewer"
        app-id = "com.example.messenger"
        window-title = ["Photo Viewer", "照片查看器"]
        subrole = "AXStandardWindow"
        opened-from = "focused-window"
        action = "float-under-opener"
        """

    private func parse(_ text: String) -> WindowRulesFile { parseWindowRulesFile(text, source: "test.toml") }

    // MARK: - Reading

    func testARuleIsReadAsWritten() {
        let file = parse(viewer)
        XCTAssertEqual(file.problems, [])
        XCTAssertEqual(file.rules, [WindowRule(id: "viewer", appId: "com.example.messenger",
            windowTitles: ["Photo Viewer", "照片查看器"], subrole: "AXStandardWindow")])
        let one = parse("""
            version = 1
            [[rule]]
            id = "one"
            app-id = "com.example.app"
            window-title = "Viewer"
            opened-from = "focused-window"
            action = "float-under-opener"
            """)
        XCTAssertEqual(one.rules.first?.windowTitles, ["Viewer"], "One title may be written as a string")
        XCTAssertNil(one.rules.first?.subrole, "Any subrole when none is named")
    }

    func testARuleThatCantBeUsedIsLeftOutWithItsReasonAndTheRestStillApply() {
        let base = """
            app-id = "com.example.app"
            window-title = "Viewer"
            opened-from = "focused-window"
            action = "float-under-opener"
            """
        let cases: [(String, String)] = [
            ("app-id = \"com.example.app\"\nwindow-title = \"Viewer\"\nopened-from = \"focused-window\"\naction = \"float-under-opener\"", "id"),
            ("id = \"Bad Id!\"\n" + base, "id"),
            ("id = \"r\"\n" + base + "\nrun = \"exec-and-forget rm -rf ~\"", "run"),
            ("id = \"r\"\n" + base.replacingOccurrences(of: "float-under-opener", with: "exec"), "action"),
            ("id = \"r\"\n" + base.replacingOccurrences(of: "focused-window", with: "any"), "opened-from"),
            ("id = \"r\"\n" + base.replacingOccurrences(of: "window-title = \"Viewer\"", with: "window-title = []"), "window-title"),
            ("id = \"r\"\n" + base.replacingOccurrences(of: "window-title = \"Viewer\"", with: "window-title = [\"\"]"), "window-title"),
            ("id = \"r\"\n" + base.replacingOccurrences(of: "window-title = \"Viewer\"", with: "window-title = [1]"), "window-title"),
            ("id = \"r\"\n" + base.replacingOccurrences(of: "app-id = \"com.example.app\"", with: ""), "app-id"),
            ("id = \"r\"\n" + base.replacingOccurrences(of: "action = \"float-under-opener\"", with: ""), "action"),
            ("id = \"r\"\nenabled = \"yes\"\n" + base, "enabled"),
        ]
        for (rule, reason) in cases {
            let file = parse("version = 1\n[[rule]]\n\(rule)\n\n" + viewer.replacingOccurrences(of: "version = 1\n", with: ""))
            XCTAssertEqual(file.rules.map(\.id), ["viewer"], "Only the good rule: \(rule)")
            XCTAssertEqual(file.problems.count, 1, "\(rule)")
            XCTAssertTrue(file.problems.first?.contains(reason) == true, "\(file.problems) should name \(reason)")
            XCTAssertTrue(file.problems.first?.contains("test.toml") == true, "Names the file")
        }
    }

    func testAFileThatIsntRulesIsLeftOutWhole() {
        for text in ["this is not toml [", "[[rule]]\nid = \"viewer\"", "version = 2\n[[rule]]\nid = \"x\"", "version = \"1\"",
                     "version = 1\nrule = \"x\"", "version = 1\nextra = true"] {
            let file = parse(text)
            XCTAssertEqual(file.rules, [], text)
            XCTAssertEqual(file.disabledIds, [], text)
            XCTAssertFalse(file.problems.isEmpty, text)
        }
        XCTAssertEqual(parse("version = 1").problems, [], "No rules at all is fine")
    }

    func testAnIdIsUsedOncePerFile() {
        let file = parse(viewer + "\n\n" + viewer.replacingOccurrences(of: "version = 1\n", with: ""))
        XCTAssertEqual(file.rules.count, 1)
        XCTAssertEqual(file.problems.count, 1)
        XCTAssertTrue(file.problems.first?.contains("viewer") == true)
    }

    func testRulesAreBounded() {
        var text = "version = 1\n"
        for index in 0 ..< windowRulesLimit + 1 {
            text += "[[rule]]\nid = \"r\(index)\"\napp-id = \"a\"\nwindow-title = \"t\"\nopened-from = \"focused-window\"\naction = \"float-under-opener\"\n"
        }
        let file = parse(text)
        XCTAssertEqual(file.rules.count, windowRulesLimit)
        XCTAssertEqual(file.problems.count, 1)
        let titles = (0 ... windowRuleTitlesLimit).map { "\"t\($0)\"" }.joined(separator: ", ")
        let many = parse("version = 1\n[[rule]]\nid = \"r\"\napp-id = \"a\"\nwindow-title = [\(titles)]\nopened-from = \"focused-window\"\naction = \"float-under-opener\"\n")
        XCTAssertEqual(many.rules, [])
        XCTAssertEqual(many.problems.count, 1)
    }

    // MARK: - Shipped and the user's

    func testTheUsersRulesReplaceOrTurnOffShippedOnesByIdAndAddTheirOwn() {
        let shipped = parse(viewer + """

            [[rule]]
            id = "palette"
            app-id = "com.example.paint"
            window-title = "Colors"
            opened-from = "focused-window"
            action = "float-under-opener"
            """)
        XCTAssertEqual(shipped.problems, [])
        let user = parse("""
            version = 1

            [[rule]]
            id = "viewer"
            enabled = false

            [[rule]]
            id = "palette"
            app-id = "com.example.paint"
            window-title = ["Colors", "Farben"]
            opened-from = "focused-window"
            action = "float-under-opener"

            [[rule]]
            id = "mine"
            app-id = "com.example.notes"
            window-title = "Preview"
            opened-from = "focused-window"
            action = "float-under-opener"
            """)
        XCTAssertEqual(user.problems, [])
        XCTAssertEqual(user.disabledIds, ["viewer"])
        let merged = mergeWindowRules(shipped: shipped, user: user)
        XCTAssertEqual(merged.map(\.id), ["palette", "mine"], "Shipped order, the user's own after")
        XCTAssertEqual(merged.first?.windowTitles, ["Colors", "Farben"], "Replaced whole by the user's")
        XCTAssertEqual(mergeWindowRules(shipped: shipped, user: nil).map(\.id), ["viewer", "palette"])
        let broken = parse("not toml [")
        XCTAssertEqual(mergeWindowRules(shipped: shipped, user: broken).map(\.id), ["viewer", "palette"],
            "A user file that can't be read changes nothing shipped")
    }

    func testTheUsersFileIsReadBesideWinMuxsAndAFileThatCantBeUsedChangesNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-window-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("window-rules.toml")
        let saved = windowRulesUserFileUrl
        defer { windowRulesUserFileUrl = saved }
        windowRulesUserFileUrl = { url }

        XCTAssertEqual(loadWindowRules().rules, [], "No user file: WinMux's rules alone")
        XCTAssertEqual(loadWindowRules().problems, [])
        try viewer.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(loadWindowRules().rules.map(\.id), ["viewer"])
        try "version = 1\n[[rule]]\nid = \"x\"\nrun = \"open -a Calculator\"".write(to: url, atomically: true, encoding: .utf8)
        let broken = loadWindowRules()
        XCTAssertEqual(broken.rules, [])
        XCTAssertEqual(broken.problems.count, 1)
        XCTAssertTrue(broken.problems[0].contains(url.path), "Says which file")
    }

    func testWinMuxShipsNoActiveRule() throws {
        let text = try String(contentsOf: bundledWindowRulesUrl, encoding: .utf8)
        let shipped = parse(text)
        XCTAssertEqual(shipped.problems, [], "The shipped file is valid")
        XCTAssertEqual(shipped.rules, [], "No rule is on by default: none is proven yet")
    }

    // MARK: - Matching

    func testARuleMatchesItsAppAndAnExactTitleItListsAndItsSubrole() throws {
        let rule = try XCTUnwrap(parse(viewer).rules.first)
        XCTAssertTrue(rule.matches(appId: "com.example.messenger", facts: .init(title: "Photo Viewer", subrole: "AXStandardWindow")))
        XCTAssertTrue(rule.matches(appId: "com.example.messenger", facts: .init(title: "  照片查看器 ", subrole: "AXStandardWindow")),
            "Around a title, spaces don't count")
        XCTAssertFalse(rule.matches(appId: "com.example.messenger", facts: .init(title: "Photo Viewer 2", subrole: "AXStandardWindow")))
        XCTAssertFalse(rule.matches(appId: "com.example.messenger", facts: .init(title: "photo viewer", subrole: "AXStandardWindow")))
        XCTAssertFalse(rule.matches(appId: "com.example.messenger", facts: .init(title: nil, subrole: "AXStandardWindow")))
        XCTAssertFalse(rule.matches(appId: "com.example.messenger", facts: .init(title: "Photo Viewer", subrole: "AXDialog")))
        XCTAssertFalse(rule.matches(appId: "com.example.messenger", facts: .init(title: "Photo Viewer", subrole: nil)))
        XCTAssertFalse(rule.matches(appId: "com.example.other", facts: .init(title: "Photo Viewer", subrole: "AXStandardWindow")))
        XCTAssertFalse(rule.matches(appId: nil, facts: .init(title: "Photo Viewer", subrole: "AXStandardWindow")))
    }

    func testTheRoleComesFromTheAppsOwnFieldsFirstAndIsAskedOnlyOfAnAppARuleNames() async {
        activeWindowRules = parse(viewer).rules
        defer { activeWindowRules = [] }
        var asked = 0
        let facts: () -> WindowRuleFacts? = { asked += 1; return .init(title: "Photo Viewer", subrole: "AXStandardWindow") }
        let ruled = await newWindowAuxiliaryRole(bundleId: "com.example.messenger", ownRole: { nil }, facts: facts)
        XCTAssertEqual(ruled, .windowRule)
        let own = await newWindowAuxiliaryRole(bundleId: "com.example.messenger", ownRole: { .mailCompose }, facts: facts)
        XCTAssertEqual(own, .mailCompose, "An app's own fields come first")
        asked = 0
        let unnamed = await newWindowAuxiliaryRole(bundleId: "com.example.other", ownRole: { nil }, facts: facts)
        XCTAssertNil(unnamed)
        XCTAssertEqual(asked, 0, "An app no rule names isn't asked for its window's title")
    }

    func testTheRuleRoleIsKeptAcrossARestartAsAnyOther() throws {
        let data = try JSONEncoder().encode(AuxiliaryWindowRole.windowRule)
        XCTAssertEqual(try JSONDecoder().decode(AuxiliaryWindowRole.self, from: data), .windowRule)
        XCTAssertTrue(AuxiliaryWindowRole.windowRule.isEphemeral, "Never saved into a tab's or pin's layout")
    }
}
