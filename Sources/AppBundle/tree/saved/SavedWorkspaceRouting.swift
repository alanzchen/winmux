import AppKit
import Common

/// Runs the restore paths for a newly detected window, then the `on-window-detected` callbacks
/// when nothing restored it. Returns whether the window was restored.
@MainActor
func restoreOrDetectNewWindow(_ window: Window, isRegularWindow: Bool) async throws -> Bool {
    let didRestorePersisted = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: window)
    let didRestoreClosed = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window)
    if didRestorePersisted || didRestoreClosed { return true }
    if try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: isRegularWindow) { return true }
    try await tryOnWindowDetected(window)
    return false
}

struct SavedSlotLocation: Equatable {
    let workspaceName: String
    let slot: SavedWindowSlot
    let isFloating: Bool
}

/// Puts a newly detected window back into the saved workspace slot waiting for it.
///
/// The same window (after a WinMux relaunch) always returns. A different window of the same app
/// returns only while its app is armed: during WinMux startup, shortly after the app launched,
/// or shortly after Open Missing Apps. A window opened later with Cmd-N behaves normally.
@MainActor
func routeNewWindowToSavedWorkspaceIfNeeded(_ window: Window, isRegularWindow: Bool) async throws -> Bool {
    guard !serverArgs.isReadOnly,
          !savedWorkspaceStore.isEmpty,
          isRegularWindow,
          window.parent !== macosPopupWindowsContainer,
          let bundleId = window.app.rawAppBundleId,
          savedWorkspaceStore.hasSlots(bundleId: bundleId)
    else { return false }

    if let location = waitingSavedSlots(bundleId: bundleId, routingWindow: window).first(where: {
        $0.slot.lastWindowId == window.windowId && $0.slot.lastPid == window.app.pid
    }) {
        return try await placeWindowInSavedSlot(window, location)
    }

    let runtime = savedWorkspaceRuntime
    guard isStartup || runtime.isStartupRestoreActive || runtime.isArmed(bundleId: bundleId, launchDate: window.app.launchDate) else {
        return false
    }
    let title = normalizedSavedWindowTitle(try? await window.title)
    // The title fetch awaited, so the saved state may have changed.
    guard window.isBound, window.parent !== macosPopupWindowsContainer else { return false }
    guard let location = bestSavedSlot(for: title, among: waitingSavedSlots(bundleId: bundleId, routingWindow: window)) else {
        return false
    }
    return try await placeWindowInSavedSlot(window, location)
}

/// Slots of the app that no registered window fills, in saved order: records, then tiling slots
/// depth-first, then floating slots. Slots whose saved window is alive but still registering are
/// left for that window.
@MainActor
func waitingSavedSlots(bundleId: String, routingWindow: Window) -> [SavedSlotLocation] {
    let runtime = savedWorkspaceRuntime
    var result: [SavedSlotLocation] = []
    for record in savedWorkspaceStore.records {
        guard let workspace = Workspace.existing(byName: record.workspaceName), !workspace.isArchived else { continue }
        let slots = record.layout.root.allSlots.map { ($0, false) } + record.layout.floating.map { ($0, true) }
        for (slot, isFloating) in slots where slot.bundleId == bundleId {
            if let windowId = slot.lastWindowId, let pid = slot.lastPid {
                if windowId != routingWindow.windowId, let window = Window.get(byId: windowId), window.app.pid == pid {
                    continue
                }
                if windowId != routingWindow.windowId, runtime.aliveWindowPidsDuringRefresh[windowId] == pid {
                    continue
                }
            }
            result.append(SavedSlotLocation(workspaceName: record.workspaceName, slot: slot, isFloating: isFloating))
        }
    }
    return result
}

/// Picks the slot whose saved title best matches. Ties, including windows without a title,
/// go to the first slot in saved order.
func bestSavedSlot(for title: String?, among candidates: [SavedSlotLocation]) -> SavedSlotLocation? {
    var best: (location: SavedSlotLocation, score: Int)?
    for candidate in candidates {
        let score = savedTitleMatchScore(title, candidate.slot.title)
        if best == nil || score > best!.score {
            best = (candidate, score)
        }
    }
    return best?.location
}

/// 3: same title. 2: same document part before " — " or " - ". 1: one title contains the other.
func savedTitleMatchScore(_ lhs: String?, _ rhs: String?) -> Int {
    guard let lhs = lhs?.lowercased(), let rhs = rhs?.lowercased(), !lhs.isEmpty, !rhs.isEmpty else { return 0 }
    if lhs == rhs { return 3 }
    func documentPart(_ title: String) -> String? {
        for separator in [" — ", " – ", " - "] {
            if let range = title.range(of: separator) {
                let prefix = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                return prefix.count >= 4 ? prefix : nil
            }
        }
        return nil
    }
    if let lhsDocument = documentPart(lhs), lhsDocument == documentPart(rhs) { return 2 }
    if lhs.count >= 4, rhs.count >= 4, lhs.contains(rhs) || rhs.contains(lhs) { return 1 }
    return 0
}

@MainActor
private func placeWindowInSavedSlot(_ window: Window, _ location: SavedSlotLocation) async throws -> Bool {
    guard let workspace = Workspace.existing(byName: location.workspaceName) else { return false }
    let slotId = location.slot.id
    // Claim the slot before anything else can await.
    let claimed = savedWorkspaceStore.update(named: location.workspaceName) { record in
        record.layout = claimSavedSlot(record.layout, slotId: slotId, window: window)
    }
    guard claimed || location.slot.lastWindowId == window.windowId else { return false }
    savedWorkspaceRuntime.vanishedSince.removeValue(forKey: slotId)
    savedWorkspaceStore.scheduleWrite()

    // Fold edits made since the last checkpoint into the saved layout before rebuilding from it.
    captureSavedWorkspace(
        named: workspace.name,
        facts: currentSavedWorkspaceCaptureFacts(titleByWindowId: [:]),
        excludingWindowId: window.windowId,
        forceKeepSlotIds: [slotId],
    )
    guard let record = savedWorkspaceStore.record(named: workspace.name) else { return false }

    let slot = record.layout.allSlots.first { $0.id == slotId } ?? location.slot
    window.isFullscreen = slot.isFullscreen
    let isFloating = record.layout.floating.contains { $0.id == slotId } || !config.automaticallyTileNewWindows
    if isFloating {
        window.bindAsFloatingWindow(to: workspace)
    } else {
        try await rebuildSavedWorkspaceTiling(workspace, root: record.layout.root, placing: window, slotId: slotId)
    }
    return true
}

private func claimSavedSlot(_ layout: SavedWorkspaceLayout, slotId: String, window: Window) -> SavedWorkspaceLayout {
    func claim(_ slot: SavedWindowSlot) -> SavedWindowSlot {
        guard slot.id == slotId else { return slot }
        var claimed = slot
        claimed.lastWindowId = window.windowId
        claimed.lastPid = window.app.pid
        return claimed
    }
    func claim(_ container: SavedLayoutContainer) -> SavedLayoutContainer {
        var result = container
        result.children = container.children.map { child in
            switch child {
                case .slot(let slot): .slot(claim(slot))
                case .container(let nested): .container(claim(nested))
            }
        }
        return result
    }
    return SavedWorkspaceLayout(root: claim(layout.root), floating: layout.floating.map(claim))
}

/// Rebuilds the workspace's tiling tree from its saved layout, with every window that is
/// present, including the one being placed. Slots still waiting are skipped, and containers
/// with nothing present are left out, so windows arriving in any order converge on the saved
/// structure.
@MainActor
func rebuildSavedWorkspaceTiling(_ workspace: Workspace, root: SavedLayoutContainer, placing window: Window, slotId: String) async throws {
    var windowBySlotId: [String: Window] = [slotId: window]
    let treeWindows = workspace.rootTilingContainer.allLeafWindowsRecursive
    for slot in root.allSlots where slot.id != slotId {
        guard let windowId = slot.lastWindowId,
              let candidate = treeWindows.first(where: { $0.windowId == windowId }),
              candidate.app.pid == slot.lastPid
        else { continue }
        windowBySlotId[slot.id] = candidate
    }

    let previousRoot = workspace.rootTilingContainer // Keep a reference so it isn't collected early
    let potentialOrphans = previousRoot.allLeafWindowsRecursive
    previousRoot.unbindFromParent()
    // Nodes flagged as most recent, children before their parents.
    var mostRecentNodes: [TreeNode] = []

    func build(_ saved: SavedLayoutContainer, parent: NonLeafTreeNodeObject, weight: CGFloat, index: Int) -> TilingContainer {
        let container = TilingContainer(parent: parent, adaptiveWeight: weight, saved.orientation, saved.layout, index: index)
        var boundCount = 0
        for child in saved.children {
            switch child {
                case .slot(let slot):
                    guard let slotWindow = windowBySlotId[slot.id] else { continue }
                    slotWindow.bind(to: container, adaptiveWeight: slot.weight, index: boundCount)
                    boundCount += 1
                    if slot.isMostRecentInParent { mostRecentNodes.append(slotWindow) }
                case .container(let nested):
                    guard nested.allSlots.contains(where: { windowBySlotId[$0.id] != nil }) else { continue }
                    let built = build(nested, parent: container, weight: nested.weight, index: boundCount)
                    boundCount += 1
                    if nested.isMostRecentInParent { mostRecentNodes.append(built) }
            }
        }
        return container
    }
    _ = build(root, parent: workspace, weight: 1, index: INDEX_BIND_LAST)
    // Binding raised every node as it went; replay the saved choices so tab groups show the
    // saved tab and focus returns to the saved window.
    for node in mostRecentNodes {
        node.markAsMostRecentChild()
    }
    for orphan in potentialOrphans where orphan !== window && orphan.nodeWorkspace == nil {
        try await orphan.relayoutWindow(on: workspace, forceTile: true)
    }
}
