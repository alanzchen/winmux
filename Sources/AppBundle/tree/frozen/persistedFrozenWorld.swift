import Common
import Foundation

private let persistedFrozenWorldVersion = 1
private let persistedFrozenWorldFilename = "window-state.json"
@MainActor private var pendingPersistedFrozenWorld: FrozenWorld? = nil
@MainActor private var pendingPersistedWindows: PersistedWindowIdentity? = nil
@MainActor private var didRestorePersistedFrozenWorldDuringCurrentSession = false

private struct PersistedFrozenWorldEnvelope: Codable {
    let version: Int
    let world: FrozenWorld
    /// Which window each of the world's ids was. Missing from snapshots written before WinMux saved it;
    /// an older WinMux reading a newer snapshot ignores it.
    var windows: [LiveWindowRef]? = nil
}

/// How to tell the windows a restart snapshot saved from other windows given the same ids: a window
/// number is unique only within the user session that gave it.
enum PersistedWindowIdentity {
    /// Each saved window by its lifetime.
    case refs([UInt32: LiveWindowRef])
    /// A snapshot from before WinMux saved that, written at `savedAt` in this boot. Nothing it says
    /// can be checked but this: a window whose process was already running when the snapshot was
    /// written is in that same process, of the same app, in the same session, where a number
    /// isn't given twice. Windows of a process launched since are never its windows.
    case unrecorded(savedAt: Date)

    @MainActor
    func isSavedWindow(_ window: Window) -> Bool { standing(of: window) == .mayBeOpen }

    /// Whether `window` is the one saved under its id (mayBeOpen), shown not to be (gone), or can't be told yet.
    @MainActor
    func standing(of window: Window) -> LiveWindowRefStanding {
        switch self {
            case .refs(let refs): refs[window.windowId]?.standing(of: window) ?? .gone
            case .unrecorded(let savedAt): window.app.launchDate.map { $0 <= savedAt ? .mayBeOpen : .gone } ?? .unknown
        }
    }
}

/// Where the restart snapshot is kept. Replaceable for tests.
@MainActor var persistedFrozenWorldFileUrl: () throws -> URL = { try persistedFrozenWorldUrl() }

@MainActor
private func persistedFrozenWorldUrl() throws -> URL {
    let appSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true,
    )
    let directory = appSupport.appendingPathComponent(aeroSpaceAppName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(persistedFrozenWorldFilename, isDirectory: false)
}

@MainActor
func persistFrozenWorldForRestartIfPossible() {
    // With --read-only WinMux keeps the files it found as they are (Carbon ASD-N2).
    guard !serverArgs.isReadOnly else { return }
    do {
        let url = try persistedFrozenWorldFileUrl()
        let world = snapshotCurrentFrozenWorld()
        guard !world.windowIds.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            PersistenceHealth.shared.recordSuccess(.restartWindowState)
            return
        }
        let windows = world.windowIds.sorted().compactMap { Window.get(byId: $0).map(LiveWindowRef.init) }
        let data = try JSONEncoder.aeroSpaceDefault.encode(
            PersistedFrozenWorldEnvelope(version: persistedFrozenWorldVersion, world: world, windows: windows),
        )
        try data.write(to: url, options: .atomic)
        PersistenceHealth.shared.recordSuccess(.restartWindowState)
    } catch {
        // Written as WinMux quits: logged, and never in the way of quitting.
        PersistenceHealth.shared.recordFailure(.restartWindowState, error, .notSaved)
    }
}

@discardableResult
@MainActor
func loadPersistedFrozenWorldForStartupIfPresent() -> Bool {
    do {
        let url = try persistedFrozenWorldFileUrl()
        // A persisted tiling tree would otherwise resize every existing window before the
        // new-window policy gets a chance to keep it floating.
        guard config.automaticallyTileNewWindows else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(PersistedFrozenWorldEnvelope.self, from: data)
        guard envelope.version == persistedFrozenWorldVersion else { return false }
        var world = envelope.world
        let identity: PersistedWindowIdentity
        if let windows = envelope.windows {
            let refs = Dictionary(windows.map { ($0.windowId, $0) }, uniquingKeysWith: { first, _ in first })
            // Shown to be of another boot, or of a process that has ended or been replaced: not open any more. Windows
            // whose standing can't be told stay, and are put back only once shown to be the windows saved.
            world = world.removing(windowIds: world.windowIds.filter { id in refs[id].map { $0.standing == .gone } ?? true })
            identity = .refs(refs)
        } else {
            let savedAt = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            // When it was written, or this boot's time, can't be told: nothing to go on, and nothing to delete it for.
            guard let savedAt, let boot = liveWindowBootTime() else { return false }
            // Written before this boot began: none of its numbers are these windows'.
            guard savedAt > boot else {
                try FileManager.default.removeItem(at: url)
                return false
            }
            identity = .unrecorded(savedAt: savedAt)
        }
        guard !world.windowIds.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        pendingPersistedFrozenWorld = world
        pendingPersistedWindows = identity
        didRestorePersistedFrozenWorldDuringCurrentSession = false
        return true
    } catch {
        return false
    }
}

/// The saved ids now held by open windows, by what they're known to be.
@MainActor
private func openPersistedWindows(_ world: FrozenWorld, _ identity: PersistedWindowIdentity) -> (others: Set<UInt32>, undecided: Set<UInt32>) {
    var others: Set<UInt32> = []
    var undecided: Set<UInt32> = []
    for id in world.windowIds {
        guard let window = Window.get(byId: id) else { continue }
        switch identity.standing(of: window) {
            case .mayBeOpen: break
            case .gone: others.insert(id)
            case .unknown: undecided.insert(id)
        }
    }
    return (others, undecided)
}

/// The world a restore may put back now. Ids held by windows shown not to be the ones saved leave the saved world
/// for good. Those whose windows can't be told yet stay in it, so the snapshot isn't lost and evidence that comes
/// later can still put them back, but they're left out of this restore (Astra R2-A1).
@MainActor
private func pendingPersistedFrozenWorldOfSavedWindows() -> FrozenWorld? {
    guard var world = pendingPersistedFrozenWorld else { return nil }
    guard let identity = pendingPersistedWindows else { return world }
    let open = openPersistedWindows(world, identity)
    if !open.others.isEmpty {
        world = world.removing(windowIds: open.others)
        pendingPersistedFrozenWorld = world
    }
    return world.removing(windowIds: open.undecided)
}

@MainActor
func restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: Window) async throws -> Bool {
    guard let pendingPersistedFrozenWorld = pendingPersistedFrozenWorldOfSavedWindows() else { return false }
    let didRestore = try await restoreFrozenWorldIfNeeded(pendingPersistedFrozenWorld, newlyDetectedWindow: newlyDetectedWindow)
    if didRestore {
        didRestorePersistedFrozenWorldDuringCurrentSession = true
    }
    return didRestore
}

/// `knownWindowIds`: the windows WinMux has registered.
@MainActor
func finalizePersistedFrozenWorldAfterRefresh(aliveWindowIds: Set<UInt32>,
                                              knownWindowIds: Set<UInt32> = Set(MacWindow.allWindowsMap.keys)) {
    guard let world = pendingPersistedFrozenWorld else { return }
    // A window that can't be told yet keeps the snapshot until it's shown to be the window saved or not.
    if let identity = pendingPersistedWindows, !openPersistedWindows(world, identity).undecided.isEmpty { return }
    if world.windowIds.isSubset(of: knownWindowIds) ||
        (didRestorePersistedFrozenWorldDuringCurrentSession &&
            !world.windowIds.isSubset(of: aliveWindowIds))
    {
        pendingPersistedFrozenWorld = nil
        pendingPersistedWindows = nil
        didRestorePersistedFrozenWorldDuringCurrentSession = false
        try? FileManager.default.removeItem(at: persistedFrozenWorldFileUrl())
    }
}

/// Whether a detected window will be put back from the world saved before WinMux restarted: its id
/// is saved there and, once WinMux knows the window, it's the window saved.
@MainActor
func persistedFrozenWorldContains(windowId: UInt32) -> Bool {
    guard pendingPersistedFrozenWorld?.windowIds.contains(windowId) == true else { return false }
    guard let identity = pendingPersistedWindows, let window = Window.get(byId: windowId) else { return true }
    return identity.isSavedWindow(window)
}

/// The world saved before WinMux restarted, once the user put `window` in `workspace` on purpose.
@MainActor
func supersedePendingPersistedFrozenWorld(placementOf window: Window, in workspace: Workspace) {
    pendingPersistedFrozenWorld = pendingPersistedFrozenWorld?.superseding(placementOf: window, in: workspace)
}

@MainActor
func setPendingPersistedFrozenWorldForTests(_ world: FrozenWorld?) {
    pendingPersistedFrozenWorld = world
    pendingPersistedWindows = nil
    didRestorePersistedFrozenWorldDuringCurrentSession = false
}

extension FrozenWorld {
    /// This world without those windows; the rest keep their places.
    func removing(windowIds removed: Set<UInt32>) -> FrozenWorld {
        guard !removed.isEmpty else { return self }
        return FrozenWorld(
            workspaces: workspaces.map { workspace in removed.reduce(workspace) { $0.removing(windowId: $1) } },
            monitors: monitors,
            windowIds: windowIds.subtracting(removed),
        )
    }
}
