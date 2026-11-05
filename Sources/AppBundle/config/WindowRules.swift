import Common
import Foundation
import TOMLKit

// Window rules (Tabs mode): which new windows of an app float over the window they were opened from, in
// its tab, listed under it, rather than taking a tab of their own. WinMux ships its rules in a file of its
// own; the user's file, ~/.config/winmux/window-rules.toml, replaces or turns off a shipped rule by its id
// and adds its own. A rule is declarative: an app, the exact titles of its window in each language, and
// optionally the window's subrole. Nothing in a rules file runs. A rule is only asked about a window
// WinMux sees for the first time, and only when that window was opened from a window of its app in use
// just after a press (`auxiliaryWindowOrigin`); a window placed already is never moved by one. A rule
// that can't be used is left out with its reason, and never matches; the rest still apply.

/// What a window rule matches on, read from a new window in one accessibility call.
struct WindowRuleFacts: Equatable, Sendable {
    var title: String?
    var subrole: String?
}

struct WindowRule: Equatable, Sendable {
    let id: String
    /// The app, by its bundle id, exactly.
    let appId: String
    /// The window's titles, exactly, one per language the rule covers.
    let windowTitles: [String]
    /// The window's accessibility subrole, exactly; any when nil.
    let subrole: String?

    func matches(appId: String?, facts: WindowRuleFacts) -> Bool {
        guard let appId, appId == self.appId,
              let title = facts.title?.trimmingCharacters(in: .whitespacesAndNewlines), windowTitles.contains(title)
        else { return false }
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
private let windowRuleKeys: Set<String> = ["id", "enabled", "app-id", "window-title", "subrole", "opened-from", "action"]
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
    let titles: [String]
    switch table["window-title"] {
        case nil:
            return fail("needs window-title, the window's exact title.")
        case let raw?:
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
    }
    let trimmed = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard !trimmed.isEmpty else { return fail("window-title needs at least one title.") }
    guard trimmed.count <= windowRuleTitlesLimit else { return fail("window-title may list at most \(windowRuleTitlesLimit) titles.") }
    guard trimmed.allSatisfy({ !$0.isEmpty }) else { return fail("window-title has an empty title.") }
    guard trimmed.allSatisfy({ $0.count <= windowRuleTitleLengthLimit }) else {
        return fail("window-title has a title longer than \(windowRuleTitleLengthLimit) characters.")
    }
    var subrole: String?
    if let raw = table["subrole"] {
        guard let value = raw.string, !value.isEmpty else { return fail("subrole must be an accessibility subrole, such as \"AXStandardWindow\".") }
        subrole = value
    }
    guard let openedFrom = table["opened-from"]?.string else { return fail("needs opened-from = \"\(windowRuleOpenedFrom)\".") }
    guard openedFrom == windowRuleOpenedFrom else { return fail("opened-from must be \"\(windowRuleOpenedFrom)\".") }
    guard let action = table["action"]?.string else { return fail("needs action = \"\(windowRuleAction)\".") }
    guard action == windowRuleAction else { return fail("action must be \"\(windowRuleAction)\".") }
    return .success((id, WindowRule(id: id, appId: appId, windowTitles: trimmed, subrole: subrole)))
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

/// The role of a regular window that just appeared, once its origin holds: its app's own, as Mail's windows
/// tell it; or, when a window rule names the window, a window floated under its opener. The window's title
/// and subrole are read only when a rule names its app.
@MainActor
func newWindowAuxiliaryRole(bundleId: String?, ownRole: () async throws -> AuxiliaryWindowRole?,
                            facts: () async throws -> WindowRuleFacts?) async rethrows -> AuxiliaryWindowRole? {
    if let role = try await ownRole() { return role }
    let rules = activeWindowRules.filter { $0.appId == bundleId }
    guard !rules.isEmpty, let facts = try await facts() else { return nil }
    return rules.contains { $0.matches(appId: bundleId, facts: facts) } ? .windowRule : nil
}
