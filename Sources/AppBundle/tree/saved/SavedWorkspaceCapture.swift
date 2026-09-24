import AppKit
import Common

struct SavedWorkspaceCaptureFacts {
    let now: Date
    let runningApps: [String: [SavedRunningApp]]
    let titleByWindowId: [UInt32: String]
    /// Processes with at least one registered window.
    let registeredWindowPids: Set<Int32>
    let normalization: SavedLayoutNormalization
    /// WinMux started recently: everything saved keeps waiting for its windows.
    let startupRestoreActive: Bool
}

@MainActor
func currentSavedWorkspaceCaptureFacts(titleByWindowId: [UInt32: String]) -> SavedWorkspaceCaptureFacts {
    let runtime = savedWorkspaceRuntime
    return SavedWorkspaceCaptureFacts(
        now: runtime.now,
        runningApps: runtime.environment.runningApps(),
        titleByWindowId: titleByWindowId,
        registeredWindowPids: registeredSavedWorkspaceWindowPids(),
        normalization: .current,
        startupRestoreActive: runtime.isStartupRestoreActive,
    )
}

@MainActor
func registeredSavedWorkspaceWindowPids() -> Set<Int32> {
    guard isUnitTest else { return MacWindow.allWindowsMap.values.map(\.macApp.pid).toSet() }
    let windows = Workspace.all.flatMap(\.allLeafWindowsRecursive) +
        macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self) +
        macosPopupWindowsContainer.children.filterIsInstance(of: Window.self)
    return windows.map(\.app.pid).toSet()
}

// MARK: - Scheduling

/// Captures saved workspaces shortly after something changed. Called at the end of every
/// reconcile and whenever the closed-windows cache is synced, which together cover commands,
/// refreshes, mouse moves and resizes, drags, and sidebar actions.
@MainActor
func scheduleSavedWorkspaceCheckpoint(after delay: TimeInterval = SavedWorkspaceTiming.captureDelay) {
    guard !isUnitTest else { return }
    let runtime = savedWorkspaceRuntime
    guard runtime.runtimeReadyAt != nil, !savedWorkspaceStore.isReadOnly else { return }
    let adoptionPending = !runtime.didRunLabelAdoption && savedWorkspaceStore.fileWasAbsentAtLoad
    guard !savedWorkspaceStore.isEmpty || adoptionPending else { return }
    // Coalesce, but never let a later follow-up (a grace expiry) delay an earlier checkpoint.
    let deadline = Date().addingTimeInterval(max(delay, 0))
    if runtime.checkpointTask != nil, let pending = runtime.checkpointDeadline, pending <= deadline { return }
    runtime.checkpointTask?.cancel()
    runtime.checkpointDeadline = deadline
    runtime.checkpointTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
        guard !Task.isCancelled else { return }
        runtime.checkpointTask = nil
        runtime.checkpointDeadline = nil
        await runSavedWorkspaceCheckpoint()
    }
}

@MainActor
func runSavedWorkspaceCheckpoint() async {
    let runtime = savedWorkspaceRuntime
    guard !savedWorkspaceStore.isReadOnly,
          runtime.runtimeReadyAt != nil,
          TrayMenuModel.shared.isEnabled,
          !runtime.isCaptureSuspended,
          runtime.environment.frontmostAppBundleId() != lockScreenAppBundleId,
          !MonitorConfigurationObserver.shared.isSettling
    else { return }
    adoptLabeledWorkspacesIfNeeded()
    guard !savedWorkspaceStore.isEmpty else { return }
    var titles: [UInt32: String] = [:]
    for record in savedWorkspaceStore.records {
        guard let workspace = Workspace.existing(byName: record.workspaceName) else { continue }
        for window in workspace.rootTilingContainer.allLeafWindowsRecursive + workspace.floatingWindows {
            if let title = await getCachedWindowTitle(window, maxAge: SavedWorkspaceTiming.titleMaxAge) {
                titles[window.windowId] = title
            }
        }
    }
    // The awaits above may have let the world change, or suspended capture.
    guard !runtime.isCaptureSuspended, !savedWorkspaceStore.isReadOnly else { return }
    captureSavedWorkspaces(facts: currentSavedWorkspaceCaptureFacts(titleByWindowId: titles))
}

// MARK: - Capture

@MainActor
func captureSavedWorkspaces(facts: SavedWorkspaceCaptureFacts) {
    for record in savedWorkspaceStore.records {
        captureSavedWorkspace(named: record.workspaceName, facts: facts)
    }
    savedWorkspaceStore.reorder(workspaceNamesInOrder: orderedWorkspacesForPresentation().map(\.name))
    savedWorkspaceStore.scheduleWrite()
    // Slots of records deleted since they vanished would otherwise schedule follow-ups forever.
    let runtime = savedWorkspaceRuntime
    let runningPids = facts.runningApps.values.flatMap { $0.map(\.pid) }.toSet()
    runtime.firstWindowSeenByPid = runtime.firstWindowSeenByPid.filter { runningPids.contains($0.key) }
    let knownSlotIds = Set(savedWorkspaceStore.records.flatMap { $0.layout.allSlots.map(\.id) })
    runtime.vanishedSlots = runtime.vanishedSlots.filter { knownSlotIds.contains($0.key) }
    if let nextExpiry = runtime.vanishedSlots.values.map(\.expiresAt).min() {
        scheduleSavedWorkspaceCheckpoint(after: max(nextExpiry.timeIntervalSince(facts.now), 0) + 0.5)
    }
}

/// Updates one saved record from its live workspace.
/// - Parameters:
///   - excludingWindowId: a window being placed right now; it is neither live nor missing.
///   - forceKeepSlotIds: slots that must keep waiting whatever the rules say (a claimed slot).
@MainActor
func captureSavedWorkspace(
    named workspaceName: String,
    facts: SavedWorkspaceCaptureFacts,
    excludingWindowId: UInt32? = nil,
    forceKeepSlotIds: Set<String> = [],
) {
    guard let record = savedWorkspaceStore.record(named: workspaceName),
          let workspace = Workspace.existing(byName: workspaceName)
    else { return }
    let runtime = savedWorkspaceRuntime
    var updated = record

    // Metadata. A TOML label wins; the record keeps the last non-empty one as a fallback.
    if let label = config.workspaceSidebar.workspaceLabels[workspaceName]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !label.isEmpty
    {
        updated.displayName = label
    }
    if savedWorkspaceProjectSyncAllowed(workspace, record: record) {
        updated.projectId = workspace.projectId
    }
    updated.namingStyle = workspace.namingStyle

    // Visibility and display affinity.
    let currentMonitors = monitors
    let home = resolveSavedDisplay(record.display, in: currentMonitors)
    let visibleMonitor = workspace.visibleMonitor
    let isVisibleOnHome = visibleMonitor != nil && home.map { $0.rect.topLeftCorner == visibleMonitor?.rect.topLeftCorner } == true
    if isVisibleOnHome {
        if !runtime.visibleOnHomeAtLastCheckpoint.contains(workspaceName) {
            updated.lastVisibleSequence = savedWorkspaceStore.takeVisibilitySequence()
        }
        runtime.visibleOnHomeAtLastCheckpoint.insert(workspaceName)
    } else {
        runtime.visibleOnHomeAtLastCheckpoint.remove(workspaceName)
    }
    if updated.display == nil, let visibleMonitor, let affinity = SavedDisplayAffinity(monitor: visibleMonitor) {
        updated.display = affinity
        runtime.visibleOnHomeAtLastCheckpoint.insert(workspaceName)
        updated.lastVisibleSequence = savedWorkspaceStore.takeVisibilitySequence()
    } else if isVisibleOnHome, let home, var display = updated.display {
        // Only while the workspace is shown there: with one of two identical displays
        // unplugged, the home resolves to the other one, and its point must not replace the
        // tie-break.
        display.lastTopLeft = home.rect.topLeftCorner
        display.name = home.name
        updated.display = display
    }

    // Layout. Windows being routed, or waiting for a title to be routed, are neither live here
    // nor missing.
    let excludedWindowIds = runtime.routingInFlightWindowIds
        .union(runtime.windowsAwaitingTitle.keys)
        .union(excludingWindowId.map { [$0] } ?? [])
    let snapshot = snapshotLiveSavedLayout(
        workspace,
        previous: record.layout,
        titleByWindowId: facts.titleByWindowId,
        excludingWindowIds: excludedWindowIds,
    )
    let previousSlots = record.layout.allSlots
    let protectedSlotIds = forceKeepSlotIds.union(previousSlots.filter { slot in
        slot.lastWindowId.map(excludedWindowIds.contains) == true
    }.map(\.id))
    let missingSlots = previousSlots.filter {
        !snapshot.liveTiled.contains($0.id) && !snapshot.liveFloating.contains($0.id) && !protectedSlotIds.contains($0.id)
    }
    let workspaceHasNoLiveWindows = snapshot.liveTiled.isEmpty && snapshot.liveFloating.isEmpty
    let vanishedRunningCount = missingSlots.count { slot in
        !snapshot.detached.contains(slot.id) && facts.runningApps[slot.bundleId]?.isEmpty == false
    }
    let massVanish = vanishedRunningCount >= 2 && workspaceHasNoLiveWindows
    var decisions: [String: Bool] = [:]
    for slot in missingSlots {
        decisions[slot.id] = savedSlotKeepsWaiting(
            slot,
            in: workspace,
            detached: snapshot.detached,
            facts: facts,
            massVanish: massVanish,
        )
    }
    for slot in previousSlots where !missingSlots.contains(where: { $0.id == slot.id }) {
        runtime.vanishedSlots.removeValue(forKey: slot.id)
    }
    updated.layout = mergeSavedLayout(
        previous: record.layout,
        live: snapshot.layout,
        context: SavedLayoutMergeContext(
            liveTiled: snapshot.liveTiled,
            liveFloating: snapshot.liveFloating,
            keep: { protectedSlotIds.contains($0.id) || decisions[$0.id] ?? true },
            normalization: facts.normalization,
            protectedSlotIds: protectedSlotIds,
        ),
    )
    let remaining = Set(updated.layout.allSlots.map(\.id))
    for slot in previousSlots where !remaining.contains(slot.id) {
        runtime.vanishedSlots.removeValue(forKey: slot.id)
    }
    _ = savedWorkspaceStore.update(named: workspaceName) { $0 = updated }
}

@MainActor
private func slotOwnerIsRunning(_ slot: SavedWindowSlot, facts: SavedWorkspaceCaptureFacts) -> Bool {
    guard let pid = slot.lastPid else { return false }
    return facts.runningApps[slot.bundleId]?.contains { $0.pid == pid } == true
}

/// Whether a saved slot whose window isn't in the workspace keeps its place.
///
/// Cmd-Q (the app quit) keeps it: the app's windows come back when it relaunches. Cmd-W (the
/// app keeps running) drops it after a grace period. Moving the window to another workspace
/// drops it right away.
@MainActor
func savedSlotKeepsWaiting(
    _ slot: SavedWindowSlot,
    in workspace: Workspace,
    detached: Set<String>,
    facts: SavedWorkspaceCaptureFacts,
    massVanish: Bool,
) -> Bool {
    let runtime = savedWorkspaceRuntime
    // Minimized, hidden-app and native-fullscreen windows still belong here.
    if detached.contains(slot.id) { return true }
    if let windowId = slot.lastWindowId, let pid = slot.lastPid {
        if let window = Window.get(byId: windowId), window.app.pid == pid {
            // Still classified as a popup: it may be promoted to a window later.
            if window.parent is MacosPopupWindowsContainer { return true }
            // Minimized windows live outside every workspace. Only one attributed to another
            // existing workspace has moved.
            if window.parent is MacosMinimizedWindowsContainer {
                guard case .macos(_, let previousWorkspaceName?) = window.layoutReason,
                      previousWorkspaceName != workspace.name,
                      Workspace.existing(byName: previousWorkspaceName) != nil
                else { return true }
            }
            // The window is alive somewhere else: the user moved it.
            runtime.vanishedSlots.removeValue(forKey: slot.id)
            return false
        }
        // Alive but not registered yet (a refresh is still registering windows).
        if runtime.aliveWindowPidsDuringRefresh[windowId] == pid { return true }
    }
    // The app quit: wait for its next launch. If a newer instance runs instead, the slot waits
    // until that instance has shown windows and had its chance to bring this one back.
    if !slotOwnerIsRunning(slot, facts: facts) {
        let instances = facts.runningApps[slot.bundleId] ?? []
        let hasShownWindows = instances.contains { facts.registeredWindowPids.contains($0.pid) || runtime.firstWindowSeenByPid[$0.pid] != nil }
        if !hasShownWindows { return true }
    }
    if facts.startupRestoreActive || runtime.isAnyInstanceArmed(bundleId: slot.bundleId, runningApps: facts.runningApps, at: facts.now) {
        return true
    }
    // The grace is chosen when the window vanishes, so a window that returns later doesn't
    // shorten the others'.
    let vanished = runtime.vanishedSlots[slot.id] ?? SavedVanishedSlot(
        since: facts.now,
        grace: massVanish ? SavedWorkspaceTiming.massVanishGrace : SavedWorkspaceTiming.closedWindowGrace,
    )
    runtime.vanishedSlots[slot.id] = vanished
    if facts.now < vanished.expiresAt { return true }
    runtime.vanishedSlots.removeValue(forKey: slot.id)
    return false
}

// MARK: - Live snapshot

struct SavedLiveSnapshot {
    var layout: SavedWorkspaceLayout
    var liveTiled: Set<String>
    var liveFloating: Set<String>
    /// Slots of windows that are minimized, hidden with their app, or in native fullscreen.
    var detached: Set<String>
}

@MainActor
func snapshotLiveSavedLayout(
    _ workspace: Workspace,
    previous: SavedWorkspaceLayout,
    titleByWindowId: [UInt32: String],
    excludingWindowIds: Set<UInt32> = [],
) -> SavedLiveSnapshot {
    var previousByWindow: [SavedWindowIdentity: SavedWindowSlot] = [:]
    for slot in previous.allSlots {
        guard let windowId = slot.lastWindowId, let pid = slot.lastPid else { continue }
        previousByWindow[SavedWindowIdentity(windowId: windowId, pid: pid)] = slot
    }
    var liveTiled: Set<String> = []
    var liveFloating: Set<String> = []

    func slot(for window: Window, weight: CGFloat, isMostRecent: Bool) -> SavedWindowSlot? {
        guard !excludingWindowIds.contains(window.windowId), let bundleId = window.app.rawAppBundleId else { return nil }
        let previousSlot = previousByWindow[SavedWindowIdentity(windowId: window.windowId, pid: window.app.pid)]
        var slot = previousSlot ?? SavedWindowSlot(bundleId: bundleId)
        slot.bundleId = bundleId
        slot.appName = window.app.name ?? slot.appName
        slot.bundlePath = window.app.bundlePath ?? slot.bundlePath
        slot.title = normalizedSavedWindowTitle(titleByWindowId[window.windowId] ?? cachedWindowTitle(for: window)) ?? slot.title
        slot.weight = weight
        slot.isFullscreen = window.isFullscreen
        slot.isMostRecentInParent = isMostRecent
        slot.lastWindowId = window.windowId
        slot.lastPid = window.app.pid
        return slot
    }

    func snapshot(_ container: TilingContainer, weight: CGFloat) -> SavedLayoutContainer {
        let mostRecent = container.mostRecentChild
        var result = SavedLayoutContainer(layout: container.layout, orientation: container.orientation, weight: weight)
        for child in container.children {
            let childWeight = child.getWeight(container.orientation)
            switch child.nodeCases {
                case .window(let window):
                    if let slot = slot(for: window, weight: childWeight, isMostRecent: mostRecent === child) {
                        liveTiled.insert(slot.id)
                        result.children.append(.slot(slot))
                    }
                case .tilingContainer(let nested):
                    var nestedSnapshot = snapshot(nested, weight: childWeight)
                    guard !nestedSnapshot.children.isEmpty else { continue }
                    nestedSnapshot.isMostRecentInParent = mostRecent === child
                    result.children.append(.container(nestedSnapshot))
                case .workspace, .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer,
                     .macosFullscreenWindowsContainer, .macosPopupWindowsContainer:
                    break
            }
        }
        return result
    }

    let root = snapshot(workspace.rootTilingContainer, weight: 1)
    let floating = workspace.floatingWindows.compactMap { window -> SavedWindowSlot? in
        guard let slot = slot(for: window, weight: 1, isMostRecent: false) else { return nil }
        liveFloating.insert(slot.id)
        return slot
    }
    let detachedWindows = workspaceOwnedMinimizedWindows(workspace) +
        (workspace.existingMacOsNativeHiddenAppsWindowsContainer?.children.filterIsInstance(of: Window.self) ?? []) +
        (workspace.existingMacOsNativeFullscreenWindowsContainer?.children.filterIsInstance(of: Window.self) ?? [])
    let detached = detachedWindows.compactMap { window in
        previousByWindow[SavedWindowIdentity(windowId: window.windowId, pid: window.app.pid)]?.id
    }.toSet()
    return SavedLiveSnapshot(
        layout: SavedWorkspaceLayout(root: root, floating: floating),
        liveTiled: liveTiled,
        liveFloating: liveFloating,
        detached: detached,
    )
}

/// The live layout of a workspace being saved right now, with cached titles.
@MainActor
func snapshotSavedWorkspaceLayoutNow(_ workspace: Workspace) -> SavedWorkspaceLayout {
    snapshotLiveSavedLayout(
        workspace,
        previous: .init(),
        titleByWindowId: [:],
        excludingWindowIds: savedWorkspaceRuntime.routingInFlightWindowIds.union(savedWorkspaceRuntime.windowsAwaitingTitle.keys),
    ).layout
}

private struct SavedWindowIdentity: Hashable {
    let windowId: UInt32
    let pid: Int32
}
