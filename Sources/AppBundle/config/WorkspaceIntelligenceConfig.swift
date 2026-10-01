import Common
import Foundation
import TOMLKit

/// Tabs mode: whether WinMux may suggest topic groups for a project's tabs with the on-device
/// model. `manual` only ever runs when Suggest Topic Groups… is chosen; `off` never touches the
/// model.
enum WorkspaceIntelligenceMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case manual

    var id: String { rawValue }
}

struct WorkspaceIntelligenceConfig: ConvenienceCopyable, Equatable, Sendable {
    var mode: WorkspaceIntelligenceMode = .off
    /// Bundle IDs whose windows are never analyzed. A tab with one of their windows is skipped
    /// whole, so the rest of its split can't hint at what that window shows.
    var excludedApps: [String] = []
}

extension Config {
    /// Topic suggestions are offered only in Tabs mode, where groups exist.
    var suggestsTopicGroups: Bool { usesBrowserTabs && workspaceSidebar.intelligence.mode == .manual }
}

func parseWorkspaceIntelligence(
    _ raw: TOMLValueConvertible,
    _ backtrace: TomlBacktrace,
    _ errors: inout [TomlParseError],
) -> WorkspaceIntelligenceConfig {
    parseTable(raw, WorkspaceIntelligenceConfig(), [
        "mode": Parser(\.mode) { raw, backtrace in
            parseString(raw, backtrace).flatMap { value in
                WorkspaceIntelligenceMode(rawValue: value).orFailure(.semantic(backtrace, "Possible values: off, manual"))
            }
        },
        "excluded-apps": Parser(\.excludedApps) { raw, backtrace in
            parseArrayOfStrings(raw, backtrace).flatMap { apps in
                let trimmed = apps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if trimmed.contains(where: \.isEmpty) { return .failure(.semantic(backtrace, "App bundle IDs can't be empty")) }
                var seen: Set<String> = []
                return .success(trimmed.filter { seen.insert($0).inserted })
            }
        },
    ], backtrace, &errors)
}
