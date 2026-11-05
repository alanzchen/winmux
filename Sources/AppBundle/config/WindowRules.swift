import Common
import Foundation
import TOMLKit

// RED skeleton: the window rules' types and entry points, doing nothing yet.

/// What a window rule matches on, read from a new window in one accessibility call.
struct WindowRuleFacts: Equatable, Sendable {
    var title: String?
    var subrole: String?
}

struct WindowRule: Equatable, Sendable {
    let id: String
    let appId: String
    let windowTitles: [String]
    let subrole: String?

    func matches(appId: String?, facts: WindowRuleFacts) -> Bool { false }
}

/// One file's rules, the shipped rules it turns off, and what in it couldn't be used.
struct WindowRulesFile: Equatable {
    var rules: [WindowRule] = []
    var disabledIds: Set<String> = []
    var problems: [String] = []
}

func parseWindowRulesFile(_ text: String, source: String) -> WindowRulesFile { WindowRulesFile() }

func mergeWindowRules(shipped: WindowRulesFile, user: WindowRulesFile?) -> [WindowRule] { [] }

@MainActor var activeWindowRules: [WindowRule] = []

/// The role of a regular window that just appeared, once its origin holds.
@MainActor
func newWindowAuxiliaryRole(bundleId: String?, ownRole: () async throws -> AuxiliaryWindowRole?,
                            facts: () async throws -> WindowRuleFacts?) async rethrows -> AuxiliaryWindowRole? {
    try await ownRole()
}

/// At most this many rules are read from a file, and this many titles from a rule.
let windowRulesLimit = 64
let windowRuleTitlesLimit = 32

/// The rules WinMux ships, in its bundle; the project's copy in tests and debug builds.
var bundledWindowRulesUrl: URL {
    if !isUnitTest, let url = Bundle.main.url(forResource: "default-window-rules", withExtension: "toml") { return url }
    return defaultConfigUrl.deletingLastPathComponent().appending(component: "default-window-rules.toml")
}
