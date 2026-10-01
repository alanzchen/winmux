@testable import AppBundle
import Foundation
import XCTest

/// A stand-in for the on-device model: tags from a script, with controllable latency, failures,
/// and a mode that ignores cancellation the way a real model request can. Never a real model.
actor FakeWorkspaceTopicProvider: WorkspaceTopicProvider {
    nonisolated let cacheVersion: String
    private var availabilityResult: WorkspaceTopicAvailability
    /// Tags for prompts containing a key; others get none.
    private var script: [String: [String]]
    private var failures: [String: WorkspaceTopicFailure] = [:]
    private var holds = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var prompts: [String] = []
    private(set) var running = 0
    private(set) var maximumRunning = 0
    private(set) var availabilityChecks = 0

    init(script: [String: [String]] = [:], availability: WorkspaceTopicAvailability = .available, version: String = "fake-1") {
        self.script = script
        availabilityResult = availability
        cacheVersion = version
    }

    func setScript(_ script: [String: [String]]) { self.script = script }
    func fail(_ key: String, with failure: WorkspaceTopicFailure) { failures[key] = failure }
    /// While held, every call waits for `release()`, cancelled or not.
    func hold() { holds = true }
    func release() {
        holds = false
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }
    var heldCount: Int { held.count }

    func availability() async -> WorkspaceTopicAvailability {
        availabilityChecks += 1
        return availabilityResult
    }

    func topics(for evidence: WorkspaceTopicEvidence) async throws -> [String] {
        let prompt = evidence.promptText
        prompts.append(prompt)
        running += 1
        maximumRunning = max(maximumRunning, running)
        defer { running -= 1 }
        if holds { await withCheckedContinuation { held.append($0) } }
        if let failure = failures.first(where: { prompt.contains($0.key) })?.value { throw failure }
        return script.first { prompt.contains($0.key) }?.value ?? []
    }
}

/// Time that moves only when a test says so.
final class ManualWorkspaceTopicClock: WorkspaceTopicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0.0
    private var sleepers: [UUID: (deadline: Double, continuation: CheckedContinuation<Void, any Error>)] = [:]
    private var cancelled: Set<UUID> = []

    var now: Double { lock.withLock { current } }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(seconds: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelled.remove(id) != nil { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                if seconds <= 0 { lock.unlock(); continuation.resume(); return }
                sleepers[id] = (current + seconds, continuation)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            if sleeper == nil { cancelled.insert(id) }
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: Double) {
        lock.lock()
        current += seconds
        let due = sleepers.filter { $0.value.deadline <= current }
        for id in due.keys { sleepers.removeValue(forKey: id) }
        lock.unlock()
        for sleeper in due.values { sleeper.continuation.resume() }
    }
}

@MainActor
enum WorkspaceTopicTestEnvironment {
    /// Tabs mode with suggestions on, the shared model standing in for the sidebar panel, and
    /// the coordinator fresh with `provider`.
    static func setUp(provider: (any WorkspaceTopicProvider)?, clock: (any WorkspaceTopicClock)? = nil) -> WorkspaceTopicCoordinator {
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        config.workspaceSidebar.intelligence.mode = .manual
        workspaceSidebarOrganizationStore = .init()
        workspaceTopicPanelModel = { _ in TrayMenuModel.shared }
        let coordinator = WorkspaceTopicCoordinator.shared
        coordinator.reset()
        coordinator.makeProvider = { provider }
        if let clock { coordinator.clock = clock } else { coordinator.clock = WorkspaceTopicSystemClock() }
        coordinator.itemTimeout = 20
        coordinator.totalTimeout = 120
        return coordinator
    }

    static func tearDown() {
        WorkspaceTopicCoordinator.existing?.reset()
        WorkspaceTopicCoordinator.existing?.makeProvider = { makeSystemWorkspaceTopicProvider() }
        workspaceTopicPanelModel = { WorkspaceSidebarPanel.panel(for: $0)?.viewModel }
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    static var scopeId: String { TrayMenuModel.shared.workspaceSidebarTargetMonitorScopeId }

    /// A request for the shared model's project, as its list shows it.
    static func scope(selection: [String]? = nil) -> WorkspaceTopicScope {
        let model = TrayMenuModel.shared
        return WorkspaceTopicScope(projectId: model.workspaceSidebarActiveProjectId, panelScopeId: scopeId,
            listedScopeId: model.workspaceSidebarSelectedMonitorScopeId, selection: selection)
    }

    static var snapshot: WorkspaceSidebarSnapshot { workspaceSidebarSnapshot(from: TrayMenuModel.shared) }

    /// Waits for the coordinator to leave its working states.
    static func settle(_ coordinator: WorkspaceTopicCoordinator, timeout: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch coordinator.phase {
                case .checking, .analyzing, .applying:
                    guard Date() < deadline else { return XCTFail("Still \(coordinator.phase)") }
                    try await Task.sleep(nanoseconds: 5_000_000)
                default: return
            }
        }
    }

    static func waitUntil(timeout: Double = 5, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Test apps for these suites, made once: windows keep a reference to their app.
@MainActor
enum TopicTestApps {
    private static var apps: [Int32: TestApp] = [:]

    private static func app(_ pid: Int32, _ bundleId: String, _ name: String) -> TestApp {
        if let app = apps[pid] { return app }
        let app = TestApp(pid: pid, bundleId: bundleId, name: name)
        apps[pid] = app
        return app
    }

    static var safari: TestApp { app(9101, "com.apple.Safari", "Safari") }
    static var xcode: TestApp { app(9102, "com.apple.dt.Xcode", "Xcode") }
    static var terminal: TestApp { app(9103, "com.apple.Terminal", "Terminal") }
    static var keynote: TestApp { app(9104, "com.apple.iWork.Keynote", "Keynote") }
    static var numbers: TestApp { app(9105, "com.apple.iWork.Numbers", "Numbers") }
    static var secret: TestApp { app(9106, "com.example.Secret", "Secret") }
    static var mail: TestApp { app(9107, "com.apple.mail", "Mail") }

    static func reset() {
        for app in apps.values {
            app.focusedWindow = nil
            app.windows = []
        }
    }
}
