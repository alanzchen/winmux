import ApplicationServices
import Common
import Foundation
import TOMLKit

// Window rules (Tabs mode): which new windows of an app float over the window they were opened from, in
// its tab, listed under it, rather than taking a tab of their own. WinMux ships its rules in a file of its
// own; the user's file, ~/.config/winmux/window-rules.toml, replaces or turns off a shipped rule by its id
// and adds its own. A rule is declarative: an app, the exact titles of its window in each language (or
// that the window has none), optionally the window's subrole, and optionally that the window it was opened
// from has a title. Nothing in a rules file runs. A rule is only asked about a window
// WinMux sees for the first time, and only when that window was opened from a window of its app in use
// just after a press (`auxiliaryWindowOrigin`); a window placed already is never moved by one. A rule
// that can't be used is left out with its reason, and never matches; the rest still apply.

/// What a window rule matches on, read from a new window in one accessibility call.
struct WindowRuleFacts: Equatable, Sendable {
    var title: String?
    var subrole: String?
    /// The title couldn't be read (a busy app's timeout, say): that's neither a title nor the lack of one.
    var titleUnreadable = false
}

extension WindowRuleFacts {
    /// From a window's answers: reading its title attribute (`error`, `value`), and its subrole. No title attribute,
    /// or no value, is no title; any other failure, or a value that isn't text, leaves the title unread.
    init(titleRead error: AXError, _ value: AnyObject?, subrole: String?) {
        self.subrole = subrole
        if error == .noValue || error == .attributeUnsupported { return }
        guard error == .success, let title = value as? String else {
            titleUnreadable = true
            return
        }
        self.title = title
    }
}

/// How a rule names its window by title.
enum WindowRuleTitle: Equatable, Sendable {
    /// Exactly one of these, trimmed: one per language the rule covers (`window-title`).
    case exact([String])
    /// None: no title, or an empty one, once spaces around it are trimmed; not one that couldn't be read
    /// (`untitled = true`).
    case untitled

    func matches(_ facts: WindowRuleFacts) -> Bool {
        let title = facts.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
            case .exact(let titles): return title.map { titles.contains($0) } ?? false
            case .untitled: return !facts.titleUnreadable && (title ?? "").isEmpty
        }
    }
}

struct WindowRule: Equatable, Sendable {
    let id: String
    /// The app, by its bundle id, exactly.
    let appId: String
    /// The window's title: exactly one it lists, or none.
    let title: WindowRuleTitle
    /// The window's accessibility subrole, exactly; any when nil.
    let subrole: String?
    /// The window it was opened from must have a title, read when the new window is first seen (`opener-titled`).
    let openerTitled: Bool

    init(id: String, appId: String, title: WindowRuleTitle, subrole: String?, openerTitled: Bool = false) {
        (self.id, self.appId, self.title, self.subrole, self.openerTitled) = (id, appId, title, subrole, openerTitled)
    }

    /// A rule naming its window by its exact titles, one per language it covers.
    init(id: String, appId: String, windowTitles: [String], subrole: String?, openerTitled: Bool = false) {
        self.init(id: id, appId: appId, title: .exact(windowTitles), subrole: subrole, openerTitled: openerTitled)
    }

    /// The exact titles it names its window by; none for a rule naming an untitled window.
    var windowTitles: [String] {
        if case .exact(let titles) = title { titles } else { [] }
    }

    func matches(appId: String?, facts: WindowRuleFacts) -> Bool {
        guard let appId, appId == self.appId, title.matches(facts) else { return false }
        return subrole.map { $0 == facts.subrole } ?? true
    }
}

/// One file's rules, the shipped rules it turns off, and what in it couldn't be used.
struct WindowRulesFile: Equatable {
    var rules: [WindowRule] = []
    var disabledIds: Set<String> = []
    var problems: [String] = []
}

/// At most this many rules are read from a file, and this many titles from a rule.
let windowRulesLimit = 64
let windowRuleTitlesLimit = 32
private let windowRuleTitleLengthLimit = 200
private let windowRuleKeys: Set<String> = ["id", "enabled", "app-id", "window-title", "untitled", "subrole", "opener-titled", "opened-from",
                                             "action"]
private let windowRuleOpenedFrom = "focused-window"
private let windowRuleAction = "float-under-opener"

/// Reads a rules file. A file that isn't one (not TOML, another version, or keys rules files don't have) is
/// left out whole; a rule that can't be used is left out with its reason.
func parseWindowRulesFile(_ text: String, source: String) -> WindowRulesFile {
    let table: TOMLTable
    do {
        table = try TOMLTable(string: text)
    } catch {
        return WindowRulesFile(problems: ["\(source): isn't a valid TOML file, so none of its rules is used."])
    }
    if let unknown = table.keys.sorted().first(where: { $0 != "version" && $0 != "rule" }) {
        return WindowRulesFile(problems: ["\(source): has '\(unknown)', which rules files don't have, so none of its rules is used."])
    }
    guard table["version"]?.int == 1 else {
        return WindowRulesFile(problems: ["\(source): needs 'version = 1', so none of its rules is used."])
    }
    guard let raw = table["rule"] else { return WindowRulesFile() }
    guard let entries = raw.array else {
        return WindowRulesFile(problems: ["\(source): 'rule' must be a list of [[rule]] tables, so none of its rules is used."])
    }
    var file = WindowRulesFile()
    var seen: Set<String> = []
    for (index, entry) in entries.enumerated() {
        guard index < windowRulesLimit else {
            file.problems.append("\(source): only the first \(windowRulesLimit) rules are used.")
            break
        }
        guard let ruleTable = entry.table else {
            file.problems.append("\(source): rule #\(index + 1) isn't a [[rule]] table.")
            continue
        }
        switch parseWindowRule(ruleTable, number: index + 1) {
            case .failure(let problem):
                file.problems.append("\(source): \(problem.reason)")
            case .success(let parsed):
                guard seen.insert(parsed.id).inserted else {
                    file.problems.append("\(source): rule \(parsed.id) is there twice; only the first is used.")
                    continue
                }
                if let rule = parsed.rule { file.rules.append(rule) } else { file.disabledIds.insert(parsed.id) }
        }
    }
    return file
}

private struct WindowRuleProblem: Error { let reason: String }

private extension Result where Failure == WindowRuleProblem {
    static func failure(_ reason: String) -> Self { .failure(WindowRuleProblem(reason: reason)) }
}

/// One rule, or the id of a shipped rule it turns off (`enabled = false`).
private func parseWindowRule(_ table: TOMLTable, number: Int) -> Result<(id: String, rule: WindowRule?), WindowRuleProblem> {
    let rawId = table["id"]?.string
    let label = rawId.map { "rule \($0)" } ?? "rule #\(number)"
    func fail(_ reason: String) -> Result<(id: String, rule: WindowRule?), WindowRuleProblem> { .failure("\(label): \(reason)") }
    if let unknown = table.keys.sorted().first(where: { !windowRuleKeys.contains($0) }) {
        return fail("has '\(unknown)', which a rule doesn't have: a rule only describes windows, and nothing in it runs.")
    }
    guard let id = rawId, !id.isEmpty else { return fail("needs an id.") }
    guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
        return fail("its id may have only letters, digits, '-', '_' and '.'.")
    }
    var enabled = true
    if let raw = table["enabled"] {
        guard let value = raw.bool else { return fail("'enabled' must be true or false.") }
        enabled = value
    }
    if !enabled { return .success((id, nil)) }
    guard let appId = table["app-id"]?.string, !appId.isEmpty else { return fail("needs app-id, the app's bundle id.") }
    // A window is named by its titles or as one without a title: exactly one of the two.
    let title: WindowRuleTitle
    switch (table["window-title"], table["untitled"]) {
        case (nil, nil):
            return fail("needs window-title, the window's exact title, or untitled = true for a window without one.")
        case (_?, _?):
            return fail("has both window-title and untitled: name the window by its titles, or as untitled, not both.")
        case (nil, let raw?):
            guard let untitled = raw.bool else { return fail("untitled must be true, for a window without a title.") }
            guard untitled else {
                return fail("untitled = false names no window: name it by window-title instead, or leave untitled out; " +
                    "to turn a rule off, use enabled = false.")
            }
            title = .untitled
        case (let raw?, nil):
            let titles: [String]
            if let one = raw.string {
                titles = [one]
            } else if let many = raw.array {
                var read: [String] = []
                for value in many {
                    guard let title = value.string else { return fail("window-title must be a title, or a list of titles.") }
                    read.append(title)
                }
                titles = read
            } else {
                return fail("window-title must be a title, or a list of titles.")
            }
            let trimmed = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !trimmed.isEmpty else { return fail("window-title needs at least one title.") }
            guard trimmed.count <= windowRuleTitlesLimit else { return fail("window-title may list at most \(windowRuleTitlesLimit) titles.") }
            guard trimmed.allSatisfy({ !$0.isEmpty }) else {
                return fail("window-title has an empty title; for a window without one, use untitled = true instead.")
            }
            guard trimmed.allSatisfy({ $0.count <= windowRuleTitleLengthLimit }) else {
                return fail("window-title has a title longer than \(windowRuleTitleLengthLimit) characters.")
            }
            title = .exact(trimmed)
    }
    var subrole: String?
    if let raw = table["subrole"] {
        guard let value = raw.string, !value.isEmpty else { return fail("subrole must be an accessibility subrole, such as \"AXStandardWindow\".") }
        subrole = value
    }
    var openerTitled = false
    if let raw = table["opener-titled"] {
        guard let value = raw.bool else { return fail("opener-titled must be true, for an opener with a title.") }
        guard value else { return fail("opener-titled = false asks nothing of the opener: leave it out.") }
        openerTitled = true
    }
    guard let openedFrom = table["opened-from"]?.string else { return fail("needs opened-from = \"\(windowRuleOpenedFrom)\".") }
    guard openedFrom == windowRuleOpenedFrom else { return fail("opened-from must be \"\(windowRuleOpenedFrom)\".") }
    guard let action = table["action"]?.string else { return fail("needs action = \"\(windowRuleAction)\".") }
    guard action == windowRuleAction else { return fail("action must be \"\(windowRuleAction)\".") }
    return .success((id, WindowRule(id: id, appId: appId, title: title, subrole: subrole, openerTitled: openerTitled)))
}

/// The rules in effect: the shipped rules in their order, each replaced by the user's rule of the same id or
/// left out when the user turns it off, then the user's own.
func mergeWindowRules(shipped: WindowRulesFile, user: WindowRulesFile?) -> [WindowRule] {
    guard let user else { return shipped.rules }
    let users = Dictionary(user.rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let shippedIds = Set(shipped.rules.map(\.id))
    return shipped.rules.compactMap { user.disabledIds.contains($0.id) ? nil : users[$0.id] ?? $0 }
        + user.rules.filter { !shippedIds.contains($0.id) }
}

@MainActor var activeWindowRules: [WindowRule] = []

/// The rules WinMux ships, in its bundle; the project's copy in tests and debug builds.
var bundledWindowRulesUrl: URL {
    if !isUnitTest, let url = Bundle.main.url(forResource: "default-window-rules", withExtension: "toml") { return url }
    return defaultConfigUrl.deletingLastPathComponent().appending(component: "default-window-rules.toml")
}

/// The user's rules file. Nil in unit tests unless a test sets it.
@MainActor var windowRulesUserFileUrl: @MainActor () -> URL? = {
    isUnitTest ? nil : xdgConfigHomeUrl().appending(path: generatedConfigDirectoryName).appending(path: "window-rules.toml")
}

/// Reads the shipped rules and the user's: the rules in effect, and what couldn't be used. A user file that
/// can't be read changes nothing shipped.
@MainActor
func loadWindowRules() -> (rules: [WindowRule], problems: [String]) {
    let shipped = (try? String(contentsOf: bundledWindowRulesUrl, encoding: .utf8))
        .map { parseWindowRulesFile($0, source: "WinMux's window rules") }
        ?? WindowRulesFile(problems: ["WinMux's window rules couldn't be read."])
    var user: WindowRulesFile?
    if let url = windowRulesUserFileUrl(), FileManager.default.fileExists(atPath: url.path) {
        user = (try? String(contentsOf: url, encoding: .utf8)).map { parseWindowRulesFile($0, source: url.path) }
            ?? WindowRulesFile(problems: ["\(url.path) couldn't be read, so none of its rules is used."])
    }
    return (mergeWindowRules(shipped: shipped, user: user), shipped.problems + (user?.problems ?? []))
}

/// The window a new one is being placed under, while its role is read (`auxiliaryWindowPlacement`).
@TaskLocal
var windowRuleOpenerId: UInt32? = nil

/// The role of a regular window that just appeared, once its origin holds: its app's own, as Mail's windows
/// tell it; or, when a window rule names the window, a window floated under its opener. The window's title
/// and subrole are read only when a rule names its app; its opener's title (`opener`, by default the one it's
/// being placed under) only when every rule that names it asks for one with a title. An opener whose title is
/// empty, or can't be read, has none.
@MainActor
func newWindowAuxiliaryRole(bundleId: String?, ownRole: () async throws -> AuxiliaryWindowRole?,
                            facts: () async throws -> WindowRuleFacts?, opener: Window? = nil) async rethrows -> AuxiliaryWindowRole? {
    if let role = try await ownRole() { return role }
    let rules = activeWindowRules.filter { $0.appId == bundleId }
    guard !rules.isEmpty, let facts = try await facts() else { return nil }
    let naming = rules.filter { $0.matches(appId: bundleId, facts: facts) }
    guard !naming.isEmpty else { return nil }
    if naming.contains(where: { !$0.openerTitled }) { return .windowRule }
    guard let opener = opener ?? windowRuleOpenerId.flatMap({ Window.get(byId: $0) }),
          let title = try? await opener.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return .windowRule
}
