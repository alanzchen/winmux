import Foundation

// Value types for topic suggestions. Nothing here refers to a Workspace, Window, AX element or
// view model: requests cross to the provider and the policy as plain Sendable data, and the
// model only ever sees text. Mapping results back to live objects stays on the MainActor.

/// A tab's handle within one request. It's never shown to the model, and means nothing outside
/// the request that issued it.
struct WorkspaceTopicToken: Hashable, Comparable, Sendable {
    let rawValue: Int
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct WorkspaceTopicWindowEvidence: Hashable, Sendable {
    let appName: String
    let bundleId: String?
    /// Sanitized: no control characters, the home folder shortened to ~, length capped.
    let title: String
}

/// What one tab contributes to a request: the titles the sidebar already shows, never more.
struct WorkspaceTopicEvidence: Hashable, Sendable {
    let token: WorkspaceTopicToken
    /// A name the user gave the tab. Generated names, which may come from titles, aren't used.
    let label: String?
    let windows: [WorkspaceTopicWindowEvidence]
    /// False when some of its windows can't be read: minimized or hidden ones the sidebar doesn't
    /// list, or more than one request takes. A long title cut short still counts as read.
    let isComplete: Bool

    var appNames: [String] { windows.map(\.appName) }
    var bundleIds: Set<String> { Set(windows.compactMap(\.bundleId)) }

    /// Exactly what the model receives, as the preview shows it.
    var promptText: String {
        let lines = (label.map { ["Tab: \($0)"] } ?? []) + windows.filter { !$0.title.isEmpty }.map { "\($0.appName): \($0.title)" }
        return lines.joined(separator: "\n")
    }
}

enum WorkspaceTopicSkipReason: Hashable, Sendable {
    /// Browser titles stay out unless this request includes them.
    case browser(appName: String)
    case excludedApp(appName: String)
    /// Its titles are empty or generic, such as "Downloads" or "Untitled".
    case notEnoughToGoOn
    /// It has no windows of its own.
    case empty
    /// Some of its windows can't be read, such as minimized ones, so it can't be judged whole.
    case partlyHidden
    /// Apple Intelligence couldn't tag it, for example because it declined.
    case untagged
    /// Its windows changed while the sidebar was being read.
    case changed
    /// More tabs than one suggestion analyzes.
    case limit

    var description: String {
        switch self {
            case .browser(let app): "Has a \(app) window. Browser titles aren't analyzed unless you include them."
            case .excludedApp(let app): "Has a \(app) window, which you excluded."
            case .notEnoughToGoOn: "Its titles don't say what it's about."
            case .empty: "It has no windows."
            case .partlyHidden: "Some of its windows, such as minimized ones, can't be read, so it's left as it is."
            case .untagged: "Apple Intelligence couldn't tag it."
            case .changed: "It changed while WinMux was reading it."
            case .limit: "Over the \(workspaceTopicMaximumCandidates)-tab limit for one suggestion."
        }
    }
}

/// The most tabs one suggestion sends to the model, in list order.
let workspaceTopicMaximumCandidates = 60

struct WorkspaceTopicSkippedTab: Hashable, Sendable, Identifiable {
    let token: WorkspaceTopicToken
    let reason: WorkspaceTopicSkipReason
    /// For a browser tab: the text that would be analyzed if it were included.
    let preview: String?
    var id: Int { token.rawValue }
}

struct WorkspaceTopicSuggestedGroup: Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let members: [WorkspaceTopicToken]
    /// Words every member shares, shown as the reason for the suggestion.
    let sharedEvidence: [String]
}

enum WorkspaceTopicUnavailableReason: Hashable, Sendable {
    /// Before macOS 26, or a build without Foundation Models.
    case requiresNewerMacOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case languageNotSupported
    case notTabsMode
    case readOnly(String)

    var message: String {
        switch self {
            case .requiresNewerMacOS: "Topic suggestions need macOS 26 or later with Apple Intelligence."
            case .deviceNotEligible: "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings to use topic suggestions."
            case .modelNotReady: "Apple Intelligence is still getting ready. Try again later."
            case .languageNotSupported: "Apple Intelligence doesn't support this Mac's language yet."
            case .notTabsMode: "Topic suggestions are for Tabs mode."
            case .readOnly(let reason): reason
        }
    }
}

enum WorkspaceTopicAvailability: Hashable, Sendable {
    case available
    case unavailable(WorkspaceTopicUnavailableReason)
}

/// Categories only: never a title, tag or prompt.
enum WorkspaceTopicFailure: Error, Hashable, Sendable {
    case unavailable(WorkspaceTopicUnavailableReason)
    case timedOut
    case contextTooLarge
    case refused
    case unsupportedLanguage
    case busy
    case generationFailed

    /// Whether only this tab is affected, so the others can still be grouped.
    var affectsOnlyOneTab: Bool {
        switch self {
            case .contextTooLarge, .refused, .unsupportedLanguage, .generationFailed, .timedOut: true
            case .unavailable, .busy: false
        }
    }

    var category: String {
        switch self {
            case .unavailable: "unavailable"
            case .timedOut: "timeout"
            case .contextTooLarge: "context"
            case .refused: "refused"
            case .unsupportedLanguage: "language"
            case .busy: "busy"
            case .generationFailed: "generation"
        }
    }

    var message: String {
        switch self {
            case .unavailable(let reason): reason.message
            case .timedOut: "Apple Intelligence took too long. Try again."
            case .busy: "Apple Intelligence is busy. Try again in a moment."
            case .contextTooLarge, .refused, .unsupportedLanguage, .generationFailed:
                "Apple Intelligence couldn't suggest groups for these tabs."
        }
    }
}

/// The model's whole job: a few short topic words for one tab. It's given no tools and can't act.
protocol WorkspaceTopicProvider: Sendable {
    /// Changes whenever the same evidence could be tagged differently: provider, prompt or OS.
    var cacheVersion: String { get }
    func availability() async -> WorkspaceTopicAvailability
    /// Throws a ``WorkspaceTopicFailure``.
    func topics(for evidence: WorkspaceTopicEvidence) async throws -> [String]
}

/// Seconds, so tests can drive timeouts by hand.
protocol WorkspaceTopicClock: Sendable {
    var now: Double { get }
    func sleep(seconds: Double) async throws
}

struct WorkspaceTopicSystemClock: WorkspaceTopicClock {
    private let start = ContinuousClock.now
    var now: Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
    }
}
