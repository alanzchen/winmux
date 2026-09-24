import AppKit
import Common

/// Apps that saved workspaces are waiting for and that aren't running, by bundle id, in saved
/// order. Callers checking many workspaces pass `runningApps` so it is read once.
@MainActor
func missingSavedWorkspaceApps(
    workspaceNames: [String]?,
    runningApps: [String: [SavedRunningApp]]? = nil,
) -> [(bundleId: String, appName: String?, bundlePath: String?)] {
    let runningApps = runningApps ?? savedWorkspaceRuntime.environment.runningApps()
    let names = workspaceNames.map(Set.init)
    var seen: Set<String> = []
    var result: [(bundleId: String, appName: String?, bundlePath: String?)] = []
    for record in savedWorkspaceStore.records where names?.contains(record.workspaceName) ?? true {
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

/// Opens the missing apps of the given saved workspaces (all when nil). Their windows then have
/// a short while to return to their saved slots. Returns how many apps were asked to open.
@MainActor
@discardableResult
func openMissingSavedWorkspaceApps(workspaceNames: [String]?) async -> Int {
    guard !serverArgs.isReadOnly else { return 0 }
    let runtime = savedWorkspaceRuntime
    var opened = 0
    for app in missingSavedWorkspaceApps(workspaceNames: workspaceNames) {
        runtime.manualArmUntilByBundleId[app.bundleId] = runtime.now.addingTimeInterval(SavedWorkspaceTiming.restoreWindow)
        if await runtime.environment.openApplication(app.bundleId, app.bundlePath) {
            opened += 1
        }
    }
    return opened
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
