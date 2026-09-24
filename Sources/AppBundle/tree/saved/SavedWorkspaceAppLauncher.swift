import AppKit
import Common

/// Apps that saved workspaces are waiting for and that aren't running, by bundle id: in saved
/// order, or in the order of `workspaceNames`. Callers checking many workspaces pass
/// `runningApps` so it is read once.
@MainActor
func missingSavedWorkspaceApps(
    workspaceNames: [String]?,
    runningApps: [String: [SavedRunningApp]]? = nil,
) -> [(bundleId: String, appName: String?, bundlePath: String?)] {
    let runningApps = runningApps ?? savedWorkspaceRuntime.environment.runningApps()
    let records = workspaceNames.map { $0.compactMap(savedWorkspaceStore.record(named:)) } ?? savedWorkspaceStore.records
    var seen: Set<String> = []
    var result: [(bundleId: String, appName: String?, bundlePath: String?)] = []
    for record in records {
        for slot in record.layout.allSlots {
            guard runningApps[slot.bundleId] == nil,
                  slot.bundleId != winMuxAppId,
                  slot.bundleId != lockScreenAppBundleId,
                  seen.insert(slot.bundleId).inserted
            else { continue }
            result.append((slot.bundleId, slot.appName, slot.bundlePath))
        }
    }
    return result
}

func savedWorkspaceAppDisplayName(bundleId: String, appName: String?, bundlePath: String?) -> String {
    appName?.takeIf { !$0.isEmpty }
        ?? bundlePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        ?? bundleId
}

struct SavedWorkspaceAppLaunchResult: Equatable {
    var opened: [String] = []
    /// Apps that couldn't be opened, for example because they were uninstalled.
    var failed: [String] = []
}

/// Opens the missing apps of the given saved workspaces (all when nil). Their windows then have
/// a short while to return to their saved slots.
@MainActor
@discardableResult
func openMissingSavedWorkspaceApps(workspaceNames: [String]?) async -> SavedWorkspaceAppLaunchResult {
    guard !serverArgs.isReadOnly else { return SavedWorkspaceAppLaunchResult() }
    let runtime = savedWorkspaceRuntime
    let now = runtime.now
    runtime.manualArmUntilByBundleId = runtime.manualArmUntilByBundleId.filter { $0.value > now }
    let apps = missingSavedWorkspaceApps(workspaceNames: workspaceNames)
    for app in apps {
        runtime.manualArmUntilByBundleId[app.bundleId] = now.addingTimeInterval(SavedWorkspaceTiming.restoreWindow)
    }
    // A few at a time: one slow app shouldn't hold back the others, and at login they shouldn't
    // all compete with the apps macOS reopens.
    let openApplication = runtime.environment.openApplication
    var result = SavedWorkspaceAppLaunchResult()
    for batch in stride(from: 0, to: apps.count, by: 4).map({ Array(apps[$0 ..< min($0 + 4, apps.count)]) }) {
        let launches = batch.map { app in
            Task { @MainActor in await openApplication(app.bundleId, app.bundlePath) }
        }
        for (app, launch) in zip(batch, launches) {
            let name = savedWorkspaceAppDisplayName(bundleId: app.bundleId, appName: app.appName, bundlePath: app.bundlePath)
            if await launch.value {
                result.opened.append(name)
            } else {
                result.failed.append(name)
            }
        }
    }
    return result
}

@MainActor
func openApplicationForSavedWorkspace(bundleId: String, bundlePath: String?) async -> Bool {
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        ?? bundlePath.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    guard let url else { return false }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.promptsUserIfNeeded = false
    do {
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    } catch {
        return false
    }
}
