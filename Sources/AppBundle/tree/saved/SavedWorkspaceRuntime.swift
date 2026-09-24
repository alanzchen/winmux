import AppKit
import Common

struct SavedRunningApp: Sendable {
    let pid: Int32
    let launchDate: Date?
}

/// Everything saved-workspace logic reads from the system. Tests replace it.
struct SavedWorkspaceEnvironment {
    var now: @MainActor () -> Date
    /// Running apps by bundle id.
    var runningApps: @MainActor () -> [String: [SavedRunningApp]]
    var openApplication: @MainActor (_ bundleId: String, _ bundlePath: String?) async -> Bool
    var frontmostAppBundleId: @MainActor () -> String?

    static var live: SavedWorkspaceEnvironment {
        SavedWorkspaceEnvironment(
            now: { Date() },
            runningApps: {
                var result: [String: [SavedRunningApp]] = [:]
                for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
                    guard let bundleId = app.bundleIdentifier else { continue }
                    result[bundleId, default: []].append(SavedRunningApp(pid: app.processIdentifier, launchDate: app.launchDate))
                }
                return result
            },
            openApplication: { bundleId, bundlePath in
                await openApplicationForSavedWorkspace(bundleId: bundleId, bundlePath: bundlePath)
            },
            frontmostAppBundleId: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        )
    }
}

enum SavedWorkspaceConfigLoadState: Equatable, Sendable {
    case notLoaded
    case userConfig
    case defaultConfigFallback
}

enum SavedWorkspaceSuspension: Hashable, Sendable {
    case screenLocked
    case sessionInactive
    case asleep
}

enum SavedWorkspaceTiming {
    /// Delay between a change and the checkpoint that captures it.
    static let captureDelay: TimeInterval = 1.5
    /// How long after an app launches (or WinMux starts, or Open Missing Apps runs) its new
    /// windows may fill waiting slots. Later windows get normal new-window behavior.
    static let restoreWindow: TimeInterval = 45
    /// A window closed while its app keeps running loses its slot after this long.
    static let closedWindowGrace: TimeInterval = 15
    /// Used instead when every window of a workspace vanished at once.
    static let massVanishGrace: TimeInterval = 60
    /// Capture stays frozen this long after a logout, restart, or shutdown starts.
    static let shutdownFreeze: TimeInterval = 120
    static let titleMaxAge: TimeInterval = 60
}

@MainActor
final class SavedWorkspaceRuntime {
    var environment: SavedWorkspaceEnvironment = .live
    var runtimeReadyAt: Date?
    var configLoadState: SavedWorkspaceConfigLoadState = .notLoaded
    var projectAssignmentPending = true
    var suspensions: Set<SavedWorkspaceSuspension> = []
    var frozenForShutdownUntil: Date?
    /// Slot id → first checkpoint that saw its window missing while its app kept running.
    var vanishedSince: [String: Date] = [:]
    var manualArmUntilByBundleId: [String: Date] = [:]
    var visibleOnHomeAtLastCheckpoint: Set<String> = []
    var didRunLabelAdoption = false
    var checkpointTask: Task<Void, Never>?
    /// Window ids (with owner pid) that are alive but may not be registered yet. Filled only
    /// while a refresh registers windows, so routing can't hand a still-arriving saved window's
    /// slot to another window of the same app.
    var aliveWindowPidsDuringRefresh: [UInt32: Int32] = [:]
    var didInstallObservers = false
    fileprivate var observerTokens: [NSObjectProtocol] = []
    fileprivate var distributedObserverTokens: [NSObjectProtocol] = []

    var now: Date { environment.now() }

    var isStartupRestoreActive: Bool {
        guard let runtimeReadyAt else { return true }
        return now.timeIntervalSince(runtimeReadyAt) < SavedWorkspaceTiming.restoreWindow
    }

    var isCaptureSuspended: Bool {
        if !suspensions.isEmpty { return true }
        if let frozenForShutdownUntil, now < frozenForShutdownUntil { return true }
        return false
    }

    func isArmed(bundleId: String, launchDate: Date?, at date: Date? = nil) -> Bool {
        let now = date ?? self.now
        if let launchDate, now.timeIntervalSince(launchDate) < SavedWorkspaceTiming.restoreWindow {
            return true
        }
        if let until = manualArmUntilByBundleId[bundleId], now < until {
            return true
        }
        return false
    }

    func isAnyInstanceArmed(bundleId: String, runningApps: [String: [SavedRunningApp]], at date: Date) -> Bool {
        if let until = manualArmUntilByBundleId[bundleId], date < until { return true }
        return runningApps[bundleId]?.contains { isArmed(bundleId: bundleId, launchDate: $0.launchDate, at: date) } == true
    }
}

@MainActor var savedWorkspaceRuntime = SavedWorkspaceRuntime()

@MainActor
func resetSavedWorkspacesForTests(environment: SavedWorkspaceEnvironment? = nil) {
    savedWorkspaceRuntime.checkpointTask?.cancel()
    savedWorkspaceStore = SavedWorkspaceStore(url: nil)
    let runtime = SavedWorkspaceRuntime()
    runtime.environment = environment ?? .forTests()
    runtime.configLoadState = .userConfig
    savedWorkspaceRuntime = runtime
}

extension SavedWorkspaceEnvironment {
    static func forTests(
        now: Date = Date(timeIntervalSinceReferenceDate: 800_000_000),
        runningApps: [String: [SavedRunningApp]] = [:],
    ) -> SavedWorkspaceEnvironment {
        SavedWorkspaceEnvironment(
            now: { now },
            runningApps: { runningApps },
            openApplication: { _, _ in false },
            frontmostAppBundleId: { nil },
        )
    }
}

/// Flush points and capture suspensions: logout/restart/shutdown, sleep, fast user switching,
/// screen lock, and termination paths that bypass the menu-bar Quit.
@MainActor
func installSavedWorkspaceObservers() {
    let runtime = savedWorkspaceRuntime
    guard !runtime.didInstallObservers else { return }
    runtime.didInstallObservers = true

    let workspaceCenter = NSWorkspace.shared.notificationCenter
    func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
    }
    runtime.observerTokens += [
        observe(workspaceCenter, NSWorkspace.willPowerOffNotification) {
            savedWorkspaceStore.flushNow()
            savedWorkspaceRuntime.frozenForShutdownUntil = savedWorkspaceRuntime.now.addingTimeInterval(SavedWorkspaceTiming.shutdownFreeze)
        },
        observe(workspaceCenter, NSWorkspace.willSleepNotification) {
            savedWorkspaceStore.flushNow()
            savedWorkspaceRuntime.suspensions.insert(.asleep)
        },
        observe(workspaceCenter, NSWorkspace.didWakeNotification) {
            resumeSavedWorkspaceCapture(after: .asleep)
        },
        observe(workspaceCenter, NSWorkspace.sessionDidResignActiveNotification) {
            savedWorkspaceStore.flushNow()
            savedWorkspaceRuntime.suspensions.insert(.sessionInactive)
        },
        observe(workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification) {
            resumeSavedWorkspaceCapture(after: .sessionInactive)
        },
        observe(NotificationCenter.default, NSApplication.willTerminateNotification) {
            savedWorkspaceStore.flushNow()
        },
    ]
    let distributedCenter = DistributedNotificationCenter.default()
    runtime.distributedObserverTokens += [
        observe(distributedCenter, Notification.Name("com.apple.screenIsLocked")) {
            savedWorkspaceStore.flushNow()
            savedWorkspaceRuntime.suspensions.insert(.screenLocked)
        },
        observe(distributedCenter, Notification.Name("com.apple.screenIsUnlocked")) {
            resumeSavedWorkspaceCapture(after: .screenLocked)
        },
    ]
}

@MainActor
private func resumeSavedWorkspaceCapture(after suspension: SavedWorkspaceSuspension) {
    guard savedWorkspaceRuntime.suspensions.remove(suspension) != nil else { return }
    // Windows that vanished during the suspension were never really closed.
    savedWorkspaceRuntime.vanishedSince = [:]
    scheduleSavedWorkspaceCheckpoint()
}
