import AppKit
import CryptoKit
import os

private let workspaceTopicLog = Logger(subsystem: "dev.winmux", category: "TopicGroups")

/// A group as the preview edits it.
struct WorkspaceTopicDraftGroup: Identifiable, Equatable {
    let id: Int
    var name: String
    var isIncluded = true
    var members: [WorkspaceTopicDraftMember]
    let sharedEvidence: [String]

    var includedMembers: [WorkspaceTopicToken] { members.filter(\.isIncluded).map(\.token) }
    /// Why this group can't be applied as edited, if it can't.
    var problem: String? {
        guard isIncluded else { return nil }
        if includedMembers.count < 2 { return "A group needs at least 2 tabs." }
        let cleaned = workspaceTopicSanitizedText(name)
        if cleaned.isEmpty { return "Name the group." }
        if cleaned.count > workspaceTopicMaximumEditedNameLength { return "Use \(workspaceTopicMaximumEditedNameLength) characters or fewer." }
        return nil
    }
}

struct WorkspaceTopicDraftMember: Identifiable, Equatable {
    let token: WorkspaceTopicToken
    var isIncluded = true
    var id: Int { token.rawValue }
}

let workspaceTopicMaximumEditedNameLength = 60

/// What the preview shows about the request it's for.
@MainActor
struct WorkspaceTopicRequestState {
    let generation: UInt64
    let prepared: WorkspaceTopicPreparedRequest
    /// Tabs whose titles were sent to the model, as sent.
    var analyzed: [WorkspaceTopicEvidence] = []
    /// Tabs left out after reading them: their titles say too little, or the model couldn't tag them.
    var thin: [WorkspaceTopicToken] = []
    var scope: WorkspaceTopicScope { prepared.scope }
}

/// The one suggestion in progress, its preview and its in-memory cache. Created on the first
/// Suggest Topic Groups…, never while the feature is off; turning it off resets everything.
@MainActor
final class WorkspaceTopicCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case analyzing(done: Int, total: Int)
        case ready
        case unavailable(WorkspaceTopicUnavailableReason)
        case failed(WorkspaceTopicFailure)
        /// Apply found the tabs changed, or couldn't save.
        case notApplied(String)
        case applying
    }

    private(set) static var existing: WorkspaceTopicCoordinator?
    static var shared: WorkspaceTopicCoordinator {
        if let existing { return existing }
        let coordinator = WorkspaceTopicCoordinator()
        existing = coordinator
        return coordinator
    }

    @Published private(set) var phase: Phase = .idle
    @Published var groups: [WorkspaceTopicDraftGroup] = []
    @Published private(set) var request: WorkspaceTopicRequestState?
    /// Request-scoped browser consent, by tab name. Never saved, and cleared with the preview.
    @Published private(set) var includedBrowserTabs: Set<String> = []

    var makeProvider: @MainActor () -> (any WorkspaceTopicProvider)? = { makeSystemWorkspaceTopicProvider() }
    var clock: any WorkspaceTopicClock = WorkspaceTopicSystemClock()
    var itemTimeout = 20.0
    var totalTimeout = 120.0
    /// Runs on the main actor's behalf off it: the policy, thin-evidence checks. Tests may wait on it.
    private(set) var runTask: Task<Void, Never>?
    private var provider: (any WorkspaceTopicProvider)?
    private var generation: UInt64 = 0
    /// The provider's latest call, until it really returns. Cancelling a suggestion doesn't stop
    /// the model, so the next call waits for this one: never two at once.
    private var occupancy: Task<Void, Never>?
    private var cache = WorkspaceTopicTagCache(capacity: 128)
    private var consents: [WorkspaceTopicBrowserConsent] = []
    private(set) var providerCallCount = 0
    private(set) var providerFactoryCallCount = 0

    init() {}

    var isActive: Bool { request != nil || phase != .idle }

    // MARK: Requests

    /// Starts a suggestion for `scope`, replacing any in progress.
    func suggest(_ scope: WorkspaceTopicScope, snapshot: WorkspaceSidebarSnapshot) {
        let started = clock.now
        generation &+= 1
        let current = generation
        runTask?.cancel()
        runTask = nil
        groups = []
        guard config.suggestsTopicGroups else {
            request = nil
            phase = .unavailable(.notTabsMode)
            return
        }
        var prepared = prepareWorkspaceTopicRequest(scope: scope, snapshot: snapshot, consents: consents)
        // Consent covers what the user saw; anything else is asked for again.
        for token in prepared.revokedConsents {
            if let name = prepared.bindings[token]?.name { includedBrowserTabs.remove(name); consents.removeAll { $0.name == name } }
        }
        prepared.skipped.sort { $0.token < $1.token }
        request = WorkspaceTopicRequestState(generation: current, prepared: prepared)
        phase = .checking
        workspaceTopicLog.debug("prepare candidates=\(prepared.candidates.count, privacy: .public) skipped=\(prepared.skipped.count, privacy: .public) ms=\(Int((self.clock.now - started) * 1000), privacy: .public)")
        let candidates = prepared.candidates
        let projectId = scope.projectId.rawValue
        let privacy = prepared.privacy
        runTask = Task { [weak self] in
            await self?.run(candidates, generation: current, projectId: projectId, privacy: privacy, started: started)
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool { generation == self.generation && !Task.isCancelled }

    private func run(_ candidates: [WorkspaceTopicEvidence], generation: UInt64, projectId: String,
                     privacy: WorkspaceIntelligenceConfig, started: Double) async {
        if provider == nil {
            providerFactoryCallCount += 1
            provider = makeProvider()
        }
        guard let provider else { phase = .unavailable(.requiresNewerMacOS); return }
        let availability = await provider.availability()
        guard isCurrent(generation) else { return }
        if case .unavailable(let reason) = availability { phase = .unavailable(reason); return }
        let (enough, thin) = await workspaceTopicSplitThinEvidence(candidates)
        guard isCurrent(generation) else { return }
        request?.thin = thin
        request?.analyzed = enough
        phase = .analyzing(done: 0, total: enough.count)
        let deadline = started + totalTimeout
        var items: [WorkspaceTopicPolicyItem] = []
        var calls = 0
        var hits = 0
        var abstained: [WorkspaceTopicToken] = []
        for (index, evidence) in enough.enumerated() {
            let key = WorkspaceTopicTagCache.key(evidence, version: provider.cacheVersion, projectId: projectId, privacy: privacy)
            var tags: [String]
            if let cached = cache.value(for: key) {
                hits += 1
                tags = cached
            } else {
                // Wait out a call this or an earlier suggestion started, until the deadline.
                if let previous = occupancy {
                    let waiting = Task<Void, any Error> { await previous.value }
                    do { try await workspaceTopicAwait(waiting, timeout: max(0, deadline - clock.now), clock: clock) }
                    catch is CancellationError { return }
                    catch { return fail(.timedOut, generation) }
                }
                // A newer suggestion, Cancel or Off may have come while waiting: check before asking.
                guard isCurrent(generation) else { return }
                let call = Task { try await provider.topics(for: evidence) }
                occupancy = Task { _ = try? await call.value }
                providerCallCount += 1
                calls += 1
                do {
                    tags = try await workspaceTopicAwait(call, timeout: min(itemTimeout, max(0, deadline - clock.now)), clock: clock)
                    cache.insert(tags, for: key)
                } catch is CancellationError {
                    // A newer suggestion, Cancel, or turning the feature off.
                    return
                } catch {
                    guard isCurrent(generation) else { return }
                    let failure = error as? WorkspaceTopicFailure ?? .generationFailed
                    if failure == .timedOut, clock.now >= deadline { return fail(.timedOut, generation) }
                    guard failure.affectsOnlyOneTab else { return fail(failure, generation) }
                    // A refused or failed tab stays out entirely, titles included.
                    workspaceTopicLog.debug("tab abstained category=\(failure.category, privacy: .public)")
                    abstained.append(evidence.token)
                    phase = .analyzing(done: index + 1, total: enough.count)
                    continue
                }
            }
            guard isCurrent(generation) else { return }
            items.append(.init(evidence: evidence, tags: tags))
            phase = .analyzing(done: index + 1, total: enough.count)
        }
        let suggested = await workspaceTopicRunPolicy(items)
        guard isCurrent(generation) else { return }
        request?.thin += abstained
        groups = suggested.map { group in
            WorkspaceTopicDraftGroup(id: group.id, name: group.name,
                members: group.members.map { WorkspaceTopicDraftMember(token: $0) }, sharedEvidence: group.sharedEvidence)
        }
        phase = .ready
        workspaceTopicLog.debug("suggested groups=\(suggested.count, privacy: .public) tabs=\(enough.count, privacy: .public) calls=\(calls, privacy: .public) cached=\(hits, privacy: .public) ms=\(Int((self.clock.now - started) * 1000), privacy: .public)")
    }

    private func fail(_ failure: WorkspaceTopicFailure, _ generation: UInt64) {
        guard generation == self.generation else { return }
        workspaceTopicLog.debug("failed category=\(failure.category, privacy: .public)")
        phase = .failed(failure)
    }

    /// Asks again for the same tabs, as they are now.
    func suggestAgain() {
        guard let request, let snapshot = workspaceTopicPanelSnapshot(for: request.scope) else { return reset() }
        suggest(request.scope, snapshot: snapshot)
    }

    /// Includes a browser tab's titles in this request only, bound to the text just shown.
    func setBrowserTab(_ token: WorkspaceTopicToken, included: Bool) {
        guard let request, let binding = request.prepared.bindings[token] else { return }
        if included {
            guard let skipped = request.prepared.skipped.first(where: { $0.token == token }), case .browser = skipped.reason,
                  let text = skipped.preview, let workspace = binding.liveWorkspace else { return }
            consents.removeAll { $0.name == binding.name }
            consents.append(.init(name: binding.name, workspace: workspace,
                windowIds: workspaceTopicLiveWindows(workspace).map(\.windowId).sorted(), text: text))
            includedBrowserTabs.insert(binding.name)
        } else {
            consents.removeAll { $0.name == binding.name }
            includedBrowserTabs.remove(binding.name)
        }
        suggestAgain()
    }

    /// Cancel, Esc, or the preview closing: the run stops, nothing is kept, nothing was saved.
    func cancel() {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        groups = []
        request = nil
        consents = []
        includedBrowserTabs = []
        phase = .idle
    }

    /// Turning the feature off, or leaving Tabs mode: everything goes, cached tags included. A
    /// model call already running finishes on its own, unseen; the next waits for it.
    func reset() {
        cancel()
        provider = nil
        cache.removeAll()
        WorkspaceTopicSuggestionPanel.shared.close()
    }

    var cachedTagCount: Int { cache.count }

    // MARK: Apply

    /// Applies the included groups as one edit. Returns nil when it can't start a session.
    @discardableResult
    func apply() -> Task<Void, Never>? {
        guard let request, phase == .ready else { return nil }
        let plan = groups.filter(\.isIncluded).map {
            WorkspaceTopicCommitGroup(name: workspaceTopicSanitizedText($0.name), members: $0.includedMembers)
        }
        guard !plan.isEmpty, groups.allSatisfy({ $0.problem == nil }) else { return nil }
        let generation = request.generation
        phase = .applying
        guard let task = applyWorkspaceTopicGroups(plan, request: request, isCurrent: { [weak self] in
            self?.generation == generation && self?.request?.generation == generation
        }) else {
            phase = .ready
            return nil
        }
        return Task { [weak self] in
            let outcome = await task.value
            guard let self, self.generation == generation else { return }
            switch outcome {
                case .applied:
                    self.cancel()
                    WorkspaceTopicSuggestionPanel.shared.close()
                case .notApplied(let message):
                    self.phase = .notApplied(message)
            }
        }
    }

    // MARK: Staying in scope

    /// After each sidebar update: a preview whose sidebar now shows another project or display
    /// list, or whose feature was turned off, is closed rather than applied somewhere else.
    func revalidate() {
        guard let request else { return }
        guard config.suggestsTopicGroups, TrayMenuModel.shared.isEnabled else { return reset() }
        guard workspaceTopicPanelStillShows(request.scope) else { return reset() }
    }
}

/// Stops or keeps suggestions in step with the settings. Doesn't create the coordinator.
@MainActor
func syncWorkspaceTopicSuggestions() {
    guard let coordinator = WorkspaceTopicCoordinator.existing else { return }
    if !(config.suggestsTopicGroups && TrayMenuModel.shared.isEnabled) {
        if coordinator.isActive || coordinator.cachedTagCount > 0 { coordinator.reset() }
    } else {
        coordinator.revalidate()
    }
}

/// The model of the sidebar panel on a display, by its scope. Tests stand in a model of their own.
@MainActor var workspaceTopicPanelModel: (String) -> TrayMenuModel? = { WorkspaceSidebarPanel.panel(for: $0)?.viewModel }

/// The sidebar panel's model for a scope, as its list shows it.
@MainActor
func workspaceTopicPanelSnapshot(for scope: WorkspaceTopicScope) -> WorkspaceSidebarSnapshot? {
    workspaceTopicPanelModel(scope.panelScopeId).map { workspaceSidebarSnapshot(from: $0) }
}

@MainActor
func workspaceTopicPanelStillShows(_ scope: WorkspaceTopicScope) -> Bool {
    guard let snapshot = workspaceTopicPanelSnapshot(for: scope) else { return false }
    return snapshot.activeProjectId == scope.projectId && snapshot.selectedMonitorScopeId == scope.listedScopeId
}

/// Splits off evidence too thin to send, away from the main actor.
@concurrent
nonisolated func workspaceTopicSplitThinEvidence(_ candidates: [WorkspaceTopicEvidence])
    async -> (enough: [WorkspaceTopicEvidence], thin: [WorkspaceTopicToken]) {
    var enough: [WorkspaceTopicEvidence] = []
    var thin: [WorkspaceTopicToken] = []
    for evidence in candidates {
        if workspaceTopicHasEnoughEvidence(evidence) { enough.append(evidence) } else { thin.append(evidence.token) }
    }
    return (enough, thin)
}

@concurrent
nonisolated func workspaceTopicRunPolicy(_ items: [WorkspaceTopicPolicyItem]) async -> [WorkspaceTopicSuggestedGroup] {
    WorkspaceTopicPolicy.groups(for: items)
}

/// Waits for `task` up to `timeout` seconds, or until the caller is cancelled, without waiting
/// for a task that ignores cancellation. The task keeps running; only this wait ends.
nonisolated func workspaceTopicAwait<T: Sendable>(_ task: Task<T, any Error>, timeout: Double,
                                                  clock: any WorkspaceTopicClock) async throws -> T {
    let gate = WorkspaceTopicResumeGate<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            let waiter = Task {
                do { gate.resume(.success(try await task.value)) } catch { gate.resume(.failure(error)) }
            }
            let timer = Task {
                try? await clock.sleep(seconds: timeout)
                gate.resume(.failure(WorkspaceTopicFailure.timedOut))
            }
            gate.onResume { waiter.cancel(); timer.cancel() }
        }
    } onCancel: {
        gate.resume(.failure(CancellationError()))
    }
}

/// Resumes a continuation once, whichever of the result, the timer or cancellation comes first.
private final class WorkspaceTopicResumeGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var early: Result<T, any Error>?
    private var cleanup: (@Sendable () -> Void)?
    private var resumed = false

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        if let early {
            resumed = true
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func onResume(_ body: @escaping @Sendable () -> Void) {
        lock.lock()
        if resumed { lock.unlock(); body(); return }
        cleanup = body
        lock.unlock()
    }

    func resume(_ result: Result<T, any Error>) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        guard let continuation else {
            if early == nil { early = result }
            lock.unlock()
            return
        }
        resumed = true
        self.continuation = nil
        let cleanup = self.cleanup
        self.cleanup = nil
        lock.unlock()
        continuation.resume(with: result)
        cleanup?()
    }
}

/// Tags by evidence, in memory only, least recently used out first. Keys are digests: the cache
/// holds tags, never titles.
struct WorkspaceTopicTagCache {
    let capacity: Int
    private var entries: [String: (tags: [String], used: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) { self.capacity = capacity }

    var count: Int { entries.count }

    static func key(_ evidence: WorkspaceTopicEvidence, version: String, projectId: String,
                    privacy: WorkspaceIntelligenceConfig) -> String {
        let parts = [evidence.promptText, version, Locale.current.identifier, projectId,
                     privacy.mode.rawValue, privacy.excludedApps.joined(separator: ","),
                     evidence.bundleIds.contains(where: workspaceTopicIsBrowser) ? "consented" : "",
                     String(WorkspaceTopicPolicy.version)]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    mutating func value(for key: String) -> [String]? {
        guard let entry = entries[key] else { return nil }
        clock &+= 1
        entries[key] = (entry.tags, clock)
        return entry.tags
    }

    mutating func insert(_ tags: [String], for key: String) {
        clock &+= 1
        entries[key] = (tags, clock)
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    mutating func removeAll() { entries = [:] }
}
