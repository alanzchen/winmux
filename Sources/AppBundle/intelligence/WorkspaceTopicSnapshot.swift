import AppKit
import Common

/// Where a suggestion was asked for, as it was at the click.
struct WorkspaceTopicScope: Hashable, Sendable {
    let projectId: WorkspaceProjectId
    /// The sidebar panel that asked: its own display.
    let panelScopeId: String
    /// What its list showed: that panel's display-menu choice.
    let listedScopeId: String
    /// Tabs chosen with Shift or Command; nil for the whole list.
    let selection: [String]?
}

/// One live window a request saw, held weakly so a closed window can't be mistaken for a new one.
@MainActor
struct WorkspaceTopicWindowRef {
    let windowId: UInt32
    weak var window: Window?

    var isLive: Bool { window.map { Window.get(byId: windowId) === $0 } ?? false }
}

/// A request's token, mapped to the live tab it stood for. Only the main actor holds these.
@MainActor
struct WorkspaceTopicBinding {
    let token: WorkspaceTopicToken
    let name: String
    let projectId: WorkspaceProjectId
    weak var workspace: Workspace?
    let windows: [WorkspaceTopicWindowRef]
    /// The tab's label and sanitized titles as the request read them, to tell whether it changed since.
    let evidenceText: String

    /// The same Workspace object, still registered under its name: never a new tab that reused it.
    var liveWorkspace: Workspace? {
        guard let workspace, Workspace.existing(byName: name) === workspace,
              winMuxWorkspaceState.workspaceById[workspace.id] === workspace else { return nil }
        return workspace
    }
}

/// A browser tab the user chose to include, for this request only, bound to exactly what they saw.
@MainActor
struct WorkspaceTopicBrowserConsent {
    let name: String
    weak var workspace: Workspace?
    let windowIds: [UInt32]
    let text: String
}

struct WorkspaceTopicTabDisplay: Hashable, Sendable {
    let title: String
    let appName: String
    let bundleId: String?
    let bundlePath: String?
    let windowCount: Int
}

/// What the main actor hands to a suggestion run: plain values, plus its own token map.
@MainActor
struct WorkspaceTopicPreparedRequest {
    let scope: WorkspaceTopicScope
    let candidates: [WorkspaceTopicEvidence]
    var skipped: [WorkspaceTopicSkippedTab]
    /// Browser tabs whose consent no longer matches what they show.
    let revokedConsents: Set<WorkspaceTopicToken>
    let bindings: [WorkspaceTopicToken: WorkspaceTopicBinding]
    let displays: [WorkspaceTopicToken: WorkspaceTopicTabDisplay]
    /// Listed tabs left alone: pinned, or already in a group.
    let unchangedCount: Int
    let privacy: WorkspaceIntelligenceConfig
}

/// Bundle ID prefixes of browsers whose window titles stay out by default. Matching is by prefix
/// so channels (Beta, Dev, Canary, Nightly) are covered.
let workspaceTopicBrowserBundleIdPrefixes = [
    "com.apple.Safari", "com.google.Chrome", "org.chromium.", "com.brave.Browser", "com.microsoft.edgemac",
    "company.thebrowser.", "org.mozilla.", "com.vivaldi.", "com.operasoftware.", "com.kagi.kagimacOS",
    "app.zen-browser.", "com.duckduckgo.", "com.sidekick.", "com.sigmaos.", "org.torproject.", "ai.perplexity.comet",
    "com.openai.atlas", "net.waterfox.", "org.librewolf.", "com.naver.Whale", "ru.yandex.desktop.yandex-browser",
]

func workspaceTopicIsBrowser(_ bundleId: String?) -> Bool {
    guard let bundleId else { return false }
    return workspaceTopicBrowserBundleIdPrefixes.contains { bundleId.hasPrefix($0) }
}

/// Every window the tab owns, wherever WinMux keeps it: its layout, floating, minimized, and the
/// native hidden-app and full-screen containers. A split is judged by all of them.
@MainActor
func workspaceTopicLiveWindows(_ workspace: Workspace) -> [Window] {
    let all = workspace.allLeafWindowsRecursive + workspace.floatingWindows + workspaceOwnedMinimizedWindows(workspace) +
        (workspace.existingMacOsNativeHiddenAppsWindowsContainer?.allLeafWindowsRecursive ?? []) +
        (workspace.existingMacOsNativeFullscreenWindowsContainer?.allLeafWindowsRecursive ?? [])
    var seen: Set<ObjectIdentifier> = []
    return all.filter { seen.insert(ObjectIdentifier($0)).inserted }
}

/// The windows of the tab the sidebar lists, and so can be read: its layout and floating ones.
/// Minimized ones and those in a native container aren't.
@MainActor
func workspaceTopicReadableWindows(_ workspace: Workspace) -> [Window] {
    workspace.rootTilingContainer.allLeafWindowsRecursive + workspace.floatingWindows.filter(\.isBound)
}

/// Whether the tab, as it is now, belongs to a list of `listedScopeId`'s tabs: every display's,
/// the focused tab only, or one display's. From live placement, not the last published list.
@MainActor
func workspaceTopicLiveScopeMatches(_ workspace: Workspace, listedScopeId: String) -> Bool {
    switch listedScopeId {
        case workspaceSidebarDefaultScopeId: true
        case workspaceSidebarFocusedScopeId: focus.workspace === workspace
        default: workspaceSidebarMonitorScopeId(for: workspace.workspaceMonitor) == listedScopeId
    }
}

/// A window title fit to analyze: no control characters, the home folder as ~, at most 120
/// characters. Nil when nothing's left or it only repeats the app's name.
nonisolated func workspaceTopicSanitizedTitle(_ title: String?, appName: String,
                                              home: String = NSHomeDirectory()) -> (title: String, wasCut: Bool)? {
    guard var text = title.map(workspaceTopicSanitizedText), !text.isEmpty else { return nil }
    if !home.isEmpty, home != "/" { text = text.replacingOccurrences(of: home, with: "~") }
    text = text.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "~", options: .regularExpression)
    guard text.caseInsensitiveCompare(appName) != .orderedSame else { return nil }
    let limit = 120
    return text.count > limit ? (String(text.prefix(limit)), true) : (text, false)
}

/// A tab's evidence from what the sidebar shows: at most 6 titles and 600 characters.
@MainActor
func workspaceTopicEvidence(for tab: WorkspaceSidebarWorkspaceViewModel, token: WorkspaceTopicToken,
                            liveWindowCount: Int) -> WorkspaceTopicEvidence {
    let label = tab.sidebarLabel.takeIf { !$0.isEmpty } ?? (tab.isGeneratedName ? nil : tab.displayName.takeIf { !$0.isEmpty })
    var windows: [WorkspaceTopicWindowEvidence] = []
    var characters = 0
    var isComplete = true
    let listed = workspaceSidebarPinnedTabWindows(tab)
    // WinMux's own windows, such as Settings, say nothing about the tab.
    let shown = listed.filter { $0.appBundleId != winMuxAppId }
    for window in shown {
        guard windows.count < 6 else { isComplete = false; break }
        let title = workspaceTopicSanitizedTitle(window.title, appName: window.appName)?.title ?? ""
        guard characters + title.count <= 600 else { isComplete = false; break }
        characters += title.count
        windows.append(.init(appName: window.appName, bundleId: window.appBundleId, title: title))
    }
    if liveWindowCount > listed.count { isComplete = false }
    return WorkspaceTopicEvidence(token: token, label: label.map(workspaceTopicSanitizedText), windows: windows, isComplete: isComplete)
}

/// The tabs a suggestion may look at: the panel's listed tabs of the project, or the chosen ones,
/// minus pins and grouped tabs. Reads only what the sidebar already published, and live window
/// identities; never AX, titles from apps, or browser tabs.
@MainActor
func prepareWorkspaceTopicRequest(scope: WorkspaceTopicScope, snapshot: WorkspaceSidebarSnapshot,
                                  privacy: WorkspaceIntelligenceConfig = config.workspaceSidebar.intelligence,
                                  consents: [WorkspaceTopicBrowserConsent] = []) -> WorkspaceTopicPreparedRequest {
    let listed = snapshot.tabsListedWorkspaces(for: scope.projectId)
    let chosen = scope.selection.map { names in listed.filter { names.contains($0.name) } } ?? listed
    let store = workspaceSidebarOrganizationStore
    let excluded = Set(privacy.excludedApps)
    var candidates: [WorkspaceTopicEvidence] = []
    var skipped: [WorkspaceTopicSkippedTab] = []
    var revoked: Set<WorkspaceTopicToken> = []
    var bindings: [WorkspaceTopicToken: WorkspaceTopicBinding] = [:]
    var displays: [WorkspaceTopicToken: WorkspaceTopicTabDisplay] = [:]
    var unchanged = 0
    for tab in chosen {
        guard !tab.appearance.isFavorite, store.collection(containing: tab.name) == nil else {
            unchanged += 1
            continue
        }
        let token = WorkspaceTopicToken(rawValue: bindings.count)
        guard let workspace = Workspace.existing(byName: tab.name), workspace.projectId == scope.projectId else { continue }
        let shown = workspaceSidebarPinnedTabWindows(tab)
        let live = workspaceTopicLiveWindows(workspace)
        let liveIds = Set(live.map(\.windowId))
        let evidence = workspaceTopicEvidence(for: tab, token: token, liveWindowCount: live.count)
        bindings[token] = WorkspaceTopicBinding(token: token, name: tab.name, projectId: tab.projectId, workspace: workspace,
            windows: live.map { WorkspaceTopicWindowRef(windowId: $0.windowId, window: $0) }.sorted { $0.windowId < $1.windowId },
            evidenceText: evidence.promptText)
        let first = shown.first
        displays[token] = WorkspaceTopicTabDisplay(title: workspaceSidebarTabListTitle(tab), appName: first?.appName ?? "",
            bundleId: first?.appBundleId, bundlePath: first?.appBundlePath, windowCount: max(shown.count, live.count))
        func skip(_ reason: WorkspaceTopicSkipReason, preview: String? = nil) {
            skipped.append(.init(token: token, reason: reason, preview: preview))
        }
        // A window the list showed that's gone or elsewhere: the published list is behind.
        guard shown.allSatisfy({ liveIds.contains($0.windowId) }) else { skip(.changed); continue }
        // An empty tab has nothing of its own to group by.
        guard !live.isEmpty else { skip(.empty); continue }
        let appName = { (window: Window) in window.app.name ?? window.app.rawAppBundleId ?? "Unknown App" }
        if let window = live.first(where: { $0.app.rawAppBundleId.map(excluded.contains) == true }) {
            skip(.excludedApp(appName: appName(window)))
            continue
        }
        // A window it can't read could be about something else entirely: judge the tab whole or
        // not at all. Its text can't all be shown, so it can't be offered for consent either.
        let readable = Set(workspaceTopicReadableWindows(workspace).map(ObjectIdentifier.init))
        guard evidence.isComplete, live.allSatisfy({ readable.contains(ObjectIdentifier($0)) }) else {
            skip(.partlyHidden)
            continue
        }
        if let browser = live.first(where: { workspaceTopicIsBrowser($0.app.rawAppBundleId) }) {
            let windowIds = live.map(\.windowId).sorted()
            let text = evidence.promptText
            let consent = consents.first { $0.name == tab.name }
            guard let consent else { skip(.browser(appName: appName(browser)), preview: text); continue }
            guard consent.workspace === workspace, consent.windowIds == windowIds, consent.text == text else {
                revoked.insert(token)
                skip(.browser(appName: appName(browser)), preview: text)
                continue
            }
        }
        guard candidates.count < workspaceTopicMaximumCandidates else { skip(.limit); continue }
        candidates.append(evidence)
    }
    return WorkspaceTopicPreparedRequest(scope: scope, candidates: candidates, skipped: skipped, revokedConsents: revoked,
        bindings: bindings, displays: displays, unchangedCount: unchanged, privacy: privacy)
}

/// Evidence too thin to send: no title has a word that could name a topic. Checked off the main
/// actor, before the model; the model guesses wildly at "Music" or "Untitled".
nonisolated func workspaceTopicHasEnoughEvidence(_ evidence: WorkspaceTopicEvidence) -> Bool {
    var appWords: Set<String> = []
    for window in evidence.windows {
        let name = workspaceTopicNormalize(window.appName)
        appWords.insert(name)
        for word in name.split(separator: " ") { appWords.insert(String(word)) }
    }
    let texts = evidence.windows.map(\.title) + [evidence.label].compactMap(\.self)
    return texts.contains { text in
        workspaceTopicWords(in: text).contains { workspaceTopicIsUsefulWord($0.normalized, appWords: appWords) }
    }
}
