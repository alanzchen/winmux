@testable import AppBundle
import AppKit
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

    func testARuleCanNameAWindowWithoutATitle() {
        let file = parse("""
            version = 1
            [[rule]]
            id = "web-view"
            app-id = "com.example.messenger"
            untitled = true
            subrole = "AXStandardWindow"
            opened-from = "focused-window"
            action = "float-under-opener"
            """)
        XCTAssertEqual(file.problems, [])
        XCTAssertEqual(file.rules, [WindowRule(id: "web-view", appId: "com.example.messenger", title: .untitled, subrole: "AXStandardWindow")])
        XCTAssertEqual(file.rules.first?.windowTitles, [], "Named by no title")
    }

    func testARuleNamesItsWindowByTitlesOrAsUntitledExactlyOneOfTheTwo() {
        let base = "app-id = \"com.example.app\"\nopened-from = \"focused-window\"\naction = \"float-under-opener\""
        let cases: [(keys: String, reason: String)] = [
            ("window-title = \"Viewer\"\nuntitled = true", "has both window-title and untitled"),
            ("window-title = \"Viewer\"\nuntitled = false", "has both window-title and untitled"),
            ("", "needs window-title, the window's exact title, or untitled = true"),
            ("untitled = false", "untitled = false names no window: name it by window-title instead, or leave untitled out; " +
                "to turn a rule off, use enabled = false."),
            ("untitled = \"yes\"", "untitled must be true"),
            ("window-title = \"  \"", "window-title has an empty title; for a window without one, use untitled = true"),
        ]
        var reasons: Set<String> = []
        for (keys, reason) in cases {
            let file = parse("version = 1\n[[rule]]\nid = \"r\"\n\(base)\n\(keys)\n\n" + viewer.replacingOccurrences(of: "version = 1\n", with: ""))
            XCTAssertEqual(file.rules.map(\.id), ["viewer"], "Left out, and the rest still apply: \(keys)")
            XCTAssertEqual(file.problems.count, 1, keys)
            XCTAssertTrue(file.problems.first?.contains("test.toml: rule r: \(reason)") == true, "\(file.problems) should say: \(reason)")
            reasons.insert(file.problems.first ?? "")
        }
        XCTAssertEqual(reasons.count, cases.count - 1, "Each mistake says what it is (both keys, either value, say the same)")
    }

    func testARuleCanAskForAnOpenerWithATitle() {
        let rule = """
            app-id = "com.example.app"
            untitled = true
            opened-from = "focused-window"
            action = "float-under-opener"
            """
        let asked = parse("version = 1\n[[rule]]\nid = \"r\"\n\(rule)\nopener-titled = true")
        XCTAssertEqual(asked.problems, [])
        XCTAssertEqual(asked.rules, [WindowRule(id: "r", appId: "com.example.app", title: .untitled, subrole: nil, openerTitled: true)])
        XCTAssertEqual(parse("version = 1\n[[rule]]\nid = \"r\"\n\(rule)").rules.first?.openerTitled, false, "Not asked when left out")
        for (value, reason) in [("false", "opener-titled = false asks nothing of the opener: leave it out."),
                                ("\"yes\"", "opener-titled must be true, for an opener with a title.")] {
            let file = parse("version = 1\n[[rule]]\nid = \"r\"\n\(rule)\nopener-titled = \(value)\n\n" +
                viewer.replacingOccurrences(of: "version = 1\n", with: ""))
            XCTAssertEqual(file.rules.map(\.id), ["viewer"], "Left out, and the rest still apply: \(value)")
            XCTAssertEqual(file.problems, ["test.toml: rule r: \(reason)"])
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

        let shippedIds = loadWindowRules().rules.map(\.id)
        XCTAssertEqual(loadWindowRules().problems, [], "No user file: WinMux's rules alone")
        try viewer.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(loadWindowRules().rules.map(\.id), shippedIds + ["viewer"], "The user's own rules after WinMux's")
        try "version = 1\n[[rule]]\nid = \"x\"\nrun = \"open -a Calculator\"".write(to: url, atomically: true, encoding: .utf8)
        let broken = loadWindowRules()
        XCTAssertEqual(broken.rules.map(\.id), shippedIds, "A user file that can't be used changes nothing shipped")
        XCTAssertEqual(broken.problems.count, 1)
        XCTAssertTrue(broken.problems[0].contains(url.path), "Says which file")
    }

    func testWinMuxShipsTheWeChatAndTelegramRulesAndAUserFileCanTurnThemOffOrReplaceThem() throws {
        let shipped = parse(try String(contentsOf: bundledWindowRulesUrl, encoding: .utf8))
        XCTAssertEqual(shipped.problems, [], "The shipped file is valid")
        let telegram = WindowRule(id: "telegram-web-view", appId: "ru.keepcoder.Telegram", title: .untitled, subrole: "AXStandardWindow",
            openerTitled: true)
        XCTAssertEqual(shipped.rules, [WindowRule(id: "wechat-image-viewer", appId: "com.tencent.xinWeChat",
            windowTitles: ["Photos and Videos"], subrole: "AXStandardWindow"), telegram],
            "On by default: WeChat's image viewer, by its English title, and Telegram's untitled windows, as observed")
        let off = parse("version = 1\n[[rule]]\nid = \"wechat-image-viewer\"\nenabled = false")
        XCTAssertEqual(off.problems, [])
        XCTAssertEqual(mergeWindowRules(shipped: shipped, user: off), [telegram], "Turned off by its id")
        let bothOff = parse("version = 1\n[[rule]]\nid = \"wechat-image-viewer\"\nenabled = false\n[[rule]]\nid = \"telegram-web-view\"\nenabled = false")
        XCTAssertEqual(mergeWindowRules(shipped: shipped, user: bothOff), [])
        let replaced = parse("""
            version = 1
            [[rule]]
            id = "wechat-image-viewer"
            app-id = "com.tencent.xinWeChat"
            window-title = ["Photos and Videos", "图片和视频"]
            subrole = "AXStandardWindow"
            opened-from = "focused-window"
            action = "float-under-opener"
            """)
        XCTAssertEqual(mergeWindowRules(shipped: shipped, user: replaced).map(\.windowTitles), [["Photos and Videos", "图片和视频"], []],
            "Replaced whole by the user's rule of the same id")
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

    func testAnUntitledRuleMatchesAMissingOrEmptyTitleOnlyNotOneThatCouldntBeRead() {
        let rule = WindowRule(id: "web-view", appId: "com.example.messenger", title: .untitled, subrole: "AXStandardWindow")
        for title: String? in [nil, "", "  ", "\n\t"] {
            XCTAssertTrue(rule.matches(appId: "com.example.messenger", facts: .init(title: title, subrole: "AXStandardWindow")),
                "No title: \(String(describing: title))")
        }
        XCTAssertFalse(rule.matches(appId: "com.example.messenger", facts: .init(title: "Mini App", subrole: "AXStandardWindow")))
        XCTAssertFalse(rule.matches(appId: "com.example.messenger", facts: .init(title: " . ", subrole: "AXStandardWindow")))
        XCTAssertFalse(rule.matches(appId: "com.example.messenger", facts: .init(title: nil, subrole: "AXStandardWindow", titleUnreadable: true)),
            "A title that couldn't be read isn't the lack of one")
        XCTAssertFalse(rule.matches(appId: "com.example.messenger", facts: .init(title: "", subrole: "AXDialog")))
        XCTAssertFalse(rule.matches(appId: "com.example.messenger", facts: .init(title: "", subrole: nil)))
        XCTAssertFalse(rule.matches(appId: "com.example.other", facts: .init(title: "", subrole: "AXStandardWindow")))
        XCTAssertFalse(rule.matches(appId: nil, facts: .init(title: "", subrole: "AXStandardWindow")))
        let titled = WindowRule(id: "viewer", appId: "com.example.messenger", windowTitles: ["Viewer"], subrole: nil)
        XCTAssertFalse(titled.matches(appId: "com.example.messenger", facts: .init(title: "", subrole: nil)),
            "A rule naming titles doesn't name an untitled window")
    }

    func testAWindowsTitleReadIsToldApartFromNoTitleAndFromOneThatCouldntBeRead() {
        let titled = WindowRuleFacts(titleRead: .success, "Mini App" as NSString, subrole: "AXStandardWindow")
        XCTAssertEqual(titled, WindowRuleFacts(title: "Mini App", subrole: "AXStandardWindow"))
        XCTAssertEqual(WindowRuleFacts(titleRead: .success, "" as NSString, subrole: nil), WindowRuleFacts(title: "", subrole: nil))
        for none: AXError in [.noValue, .attributeUnsupported] {
            XCTAssertEqual(WindowRuleFacts(titleRead: none, nil, subrole: nil), WindowRuleFacts(title: nil, subrole: nil), "No title: \(none)")
        }
        for failed: AXError in [.cannotComplete, .invalidUIElement, .failure, .apiDisabled] {
            XCTAssertEqual(WindowRuleFacts(titleRead: failed, nil, subrole: nil),
                WindowRuleFacts(title: nil, subrole: nil, titleUnreadable: true), "Unread: \(failed)")
        }
        XCTAssertEqual(WindowRuleFacts(titleRead: .success, NSNumber(value: 1), subrole: nil),
            WindowRuleFacts(title: nil, subrole: nil, titleUnreadable: true), "A title that isn't text is unread")
    }

    func testARuleAskingForAnOpenerWithATitleNamesTheWindowOnlyThen() async {
        setUpWorkspacesForTests()
        let titledOpener = TestWindow.new(id: 10, parent: focus.workspace.rootTilingContainer, title: "Messenger @ Alan")
        let untitledOpener = TestWindow.new(id: 12, parent: focus.workspace.rootTilingContainer, title: "  ")
        activeWindowRules = [WindowRule(id: "web-view", appId: "com.example.messenger", title: .untitled, subrole: nil, openerTitled: true)]
        defer { activeWindowRules = [] }
        let untitled: () -> WindowRuleFacts? = { .init(title: "", subrole: nil) }
        let underTitled = await newWindowAuxiliaryRole(bundleId: "com.example.messenger", ownRole: { nil }, facts: untitled, opener: titledOpener)
        XCTAssertEqual(underTitled, .windowRule)
        let underUntitled = await newWindowAuxiliaryRole(bundleId: "com.example.messenger", ownRole: { nil }, facts: untitled,
            opener: untitledOpener)
        XCTAssertNil(underUntitled, "Its opener has no title yet: not named")
        let noOpener = await newWindowAuxiliaryRole(bundleId: "com.example.messenger", ownRole: { nil }, facts: untitled)
        XCTAssertNil(noOpener, "No opener known: not named")
        let fromPlacement = await $windowRuleOpenerId.withValue(titledOpener.windowId) {
            await newWindowAuxiliaryRole(bundleId: "com.example.messenger", ownRole: { nil }, facts: untitled)
        }
        XCTAssertEqual(fromPlacement, .windowRule, "The opener being placed under, by default")
        activeWindowRules.append(WindowRule(id: "any", appId: "com.example.messenger", title: .untitled, subrole: nil))
        let anyOpener = await newWindowAuxiliaryRole(bundleId: "com.example.messenger", ownRole: { nil }, facts: untitled,
            opener: untitledOpener)
        XCTAssertEqual(anyOpener, .windowRule, "Another rule names it whatever its opener")
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
