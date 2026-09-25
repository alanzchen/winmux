import AppKit
import Common

/// Runs the restore paths for a newly detected window, then the `on-window-detected` callbacks
/// when nothing restored it. Returns whether the window was restored.
@MainActor
func restoreOrDetectNewWindow(_ window: Window, isRegularWindow: Bool) async throws -> Bool {
    let didRestorePersisted = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: window)
    let didRestoreClosed = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window)
    if isRegularWindow {
        savedWorkspaceRuntime.noteWindowSeen(pid: window.app.pid)
    }
    if didRestorePersisted || didRestoreClosed { return true }
    if try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: isRegularWindow) {
        // Subscribers still learn about the window; callbacks don't move it out again.
        broadcastWindowDetected(window)
        return true
    }
    let detectedIn = window.nodeWorkspace
    try await tryOnWindowDetected(window)
    moveNewWindowToNewWorkspaceIfNeeded(window, detectedIn: detectedIn, isNewRegularWindow: isRegularWindow)
    return false
}

/// Routes a window that was first classified as a popup and has just been promoted. Dialogs
/// never claim slots, so the window is classified again.
@MainActor
func routePromotedPopupToSavedWorkspaceIfNeeded(_ window: MacWindow) async throws -> Bool {
    guard !savedWorkspaceStore.isEmpty,
          let bundleId = window.app.rawAppBundleId,
          savedWorkspaceStore.hasSlots(bundleId: bundleId)
    else { return false }
    let type = try await window.macApp.getAxUiElementWindowType(window.windowId, getWindowLevel(for: window.windowId))
    return try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: type == .window)
}

/// Checks windows that arrived without a title with a backoff (0.5 s, then doubling up to
/// 4 s). Each is routed once its title is known, or by saved order once its wait is over.
@MainActor
func scheduleSavedWorkspaceTitleRetry() {
    guard !isUnitTest else { return }
    let runtime = savedWorkspaceRuntime
    guard runtime.titleRetryTask == nil, !runtime.windowsAwaitingTitle.isEmpty else { return }
    runtime.titleRetryTask = Task { @MainActor in
        var delay: TimeInterval = 0.5
        while !runtime.windowsAwaitingTitle.isEmpty, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { break }
            delay = min(delay * 2, 4)
            await retrySavedWorkspaceRoutingForWindowsAwaitingTitles()
        }
        // A cancelled task was replaced (or cleared on resume); leave the handle alone.
        if !Task.isCancelled {
            runtime.titleRetryTask = nil
        }
    }
}

/// One retry pass: drops waits past `titleWaitLimit` and windows that went away, then routes
/// the waiting windows whose title is known now, or whose wait is over.
@MainActor
func retrySavedWorkspaceRoutingForWindowsAwaitingTitles() async {
    dropEndedSavedTitleWaits()
    guard !savedWorkspaceRuntime.windowsAwaitingTitle.isEmpty, savedTitleRoutingToken != nil else { return }
    let ready = await savedWorkspaceWindowsReadyToRoute()
    // Fetching titles awaited; check again.
    guard !ready.isEmpty, let token = savedTitleRoutingToken else { return }
    if isUnitTest {
        await routeSavedWorkspaceWindows(ready)
    } else {
        _ = try? await runLightSession(.ax(kAXTitleChangedNotification as String), token) {
            await routeSavedWorkspaceWindows(ready)
        }
    }
}

/// Same guards as checkpoints: nothing moves while the screen is locked, the Mac sleeps,
/// displays are still reconfiguring, or WinMux is disabled.
@MainActor
private var savedTitleRoutingToken: RunSessionGuard? {
    let runtime = savedWorkspaceRuntime
    guard !runtime.isCaptureSuspended,
          !MonitorConfigurationObserver.shared.isSettling,
          runtime.environment.frontmostAppBundleId() != lockScreenAppBundleId
    else { return nil }
    return .isServerEnabled
}

@MainActor
private func dropEndedSavedTitleWaits() {
    let runtime = savedWorkspaceRuntime
    let now = runtime.now
    let ended = runtime.windowsAwaitingTitle.filter { windowId, wait in
        now.timeIntervalSince(wait.since) >= SavedWorkspaceTiming.titleWaitLimit || savedWindowAwaitingTitle(windowId, wait) == nil
    }
    guard !ended.isEmpty else { return }
    for windowId in ended.keys {
        runtime.windowsAwaitingTitle.removeValue(forKey: windowId)
    }
    // Captures skipped these window ids while they waited.
    scheduleSavedWorkspaceCheckpoint()
}

/// The waiting window, unless it went away, became a popup, or its id now belongs to another
/// process.
@MainActor
private func savedWindowAwaitingTitle(_ windowId: UInt32, _ wait: SavedTitleWait) -> Window? {
    guard let window = Window.get(byId: windowId),
          window.app.pid == wait.pid,
          window.isBound,
          window.parent !== macosPopupWindowsContainer
    else { return nil }
    return window
}

/// Waiting windows whose title is known now or whose wait is over. Drops windows that went
/// away meanwhile.
@MainActor
private func savedWorkspaceWindowsReadyToRoute() async -> [Window] {
    let runtime = savedWorkspaceRuntime
    var ready: [Window] = []
    for (windowId, wait) in runtime.windowsAwaitingTitle {
        guard let window = savedWindowAwaitingTitle(windowId, wait) else {
            runtime.windowsAwaitingTitle.removeValue(forKey: windowId)
            continue
        }
        if runtime.now.timeIntervalSince(wait.since) >= SavedWorkspaceTiming.titleWait {
            ready.append(window)
        } else if normalizedSavedWindowTitle(try? await window.title) != nil {
            ready.append(window)
        }
    }
    return ready
}

@MainActor
private func routeSavedWorkspaceWindows(_ windows: [Window]) async {
    for window in windows where window.isBound && savedWorkspaceRuntime.windowsAwaitingTitle.removeValue(forKey: window.windowId) != nil {
        // It was armed when it arrived; the wait must not cost it that.
        _ = try? await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true, wasAdmitted: true)
    }
    // Captures skipped these windows while they waited, including any that found no place.
    scheduleSavedWorkspaceCheckpoint()
}

/// Title parts between " — ", " – ", " - ", and " | " separators, at least 4 characters long.
func savedTitleParts(_ title: String) -> Set<String> {
    var parts = [title]
    for separator in [" — ", " – ", " - ", " | "] {
        parts = parts.flatMap { $0.components(separatedBy: separator) }
    }
    return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 4 }.toSet()
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
/// - Parameter wasAdmitted: the window already passed the arming check and waited for its
///   title; it isn't checked again, and without a title it takes a place by saved order.
@MainActor
func routeNewWindowToSavedWorkspaceIfNeeded(_ window: Window, isRegularWindow: Bool, wasAdmitted: Bool = false) async throws -> Bool {
    guard !serverArgs.isReadOnly,
          !savedWorkspaceStore.isEmpty,
          isRegularWindow,
          window.parent !== macosPopupWindowsContainer,
          let bundleId = window.app.rawAppBundleId,
          savedWorkspaceStore.hasSlots(bundleId: bundleId)
    else { return false }

    let runtime = savedWorkspaceRuntime
    runtime.noteWindowSeen(pid: window.app.pid)
    runtime.routingInFlightWindowIds.insert(window.windowId)
    defer { runtime.routingInFlightWindowIds.remove(window.windowId) }

    if let location = waitingSavedSlots(bundleId: bundleId, routingWindow: window).first(where: {
        $0.slot.lastWindowId == window.windowId && $0.slot.lastPid == window.app.pid
    }) {
        return try await placeWindowInSavedSlot(window, location)
    }

    guard wasAdmitted || isStartup || runtime.isStartupRestoreActive ||
        runtime.isArmed(bundleId: bundleId, launchDate: window.app.launchDate, pid: window.app.pid)
    else {
        return false
    }
    let title = normalizedSavedWindowTitle(try? await window.title)
    // The title fetch awaited, so the saved state may have changed.
    guard window.isBound, window.parent !== macosPopupWindowsContainer else { return false }
    // A slot of the same still-running process belongs to a window of that process that is
    // either not registered yet or was closed; another window of it must not take the slot.
    let candidates = waitingSavedSlots(bundleId: bundleId, routingWindow: window).filter {
        $0.slot.lastPid != window.app.pid
    }
    // Titles often appear a moment after the window. With several titled places to choose
    // from, wait for it rather than guess.
    if !wasAdmitted, title == nil, candidates.count > 1, candidates.contains(where: { $0.slot.title?.isEmpty == false }) {
        runtime.windowsAwaitingTitle[window.windowId] = SavedTitleWait(since: runtime.now, pid: window.app.pid)
        scheduleSavedWorkspaceTitleRetry()
        return false
    }
    guard let location = bestSavedSlot(for: title, among: candidates, appName: window.app.name) else {
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

/// Picks the slot whose saved title best matches; ties go to the first slot in saved order.
/// A window whose title matches no slot only takes a slot when the choice is safe: it is the
/// app's only waiting slot, or one of the two titles is unknown. Otherwise an unrelated window
/// of a just-launched app would be moved into some saved workspace.
func bestSavedSlot(for title: String?, among candidates: [SavedSlotLocation], appName: String? = nil) -> SavedSlotLocation? {
    // A part every candidate's title has ("Gmail", "Chrome") says nothing about which one fits.
    let partsInEveryCandidate = candidates.count < 2 ? [] : candidates
        .map { savedTitleParts($0.slot.title?.lowercased() ?? "") }
        .reduce(nil as Set<String>?) { common, parts in common.map { $0.intersection(parts) } ?? parts } ?? []
    var best: (location: SavedSlotLocation, score: Int)?
    for candidate in candidates {
        let score = savedTitleMatchScore(
            title,
            candidate.slot.title,
            appName: appName ?? candidate.slot.appName,
            ignoring: partsInEveryCandidate,
        )
        let isEligible = score > 0 || candidates.count == 1 || title?.isEmpty != false || candidate.slot.title?.isEmpty != false
        guard isEligible else { continue }
        if best == nil || score > best!.score {
            best = (candidate, score)
        }
    }
    return best?.location
}

/// 3: same title. 2: the titles share a part between " — ", " - ", or " | " separators (for
/// example the document or folder). 1: one title contains the other. The app's own name
/// ("Chrome - Page") is never a match.
func savedTitleMatchScore(_ lhs: String?, _ rhs: String?, appName: String? = nil, ignoring ignoredParts: Set<String> = []) -> Int {
    guard let lhs = lhs?.lowercased(), let rhs = rhs?.lowercased(), !lhs.isEmpty, !rhs.isEmpty else { return 0 }
    if lhs == rhs { return 3 }
    let appName = appName?.lowercased()
    func parts(_ title: String) -> Set<String> {
        savedTitleParts(title).filter { $0 != appName && !ignoredParts.contains($0) }
    }
    if !parts(lhs).isDisjoint(with: parts(rhs)) { return 2 }
    let shorter = lhs.count <= rhs.count ? lhs : rhs
    if shorter.count >= 4, shorter != appName, !ignoredParts.contains(shorter), lhs.contains(rhs) || rhs.contains(lhs) { return 1 }
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
    savedWorkspaceRuntime.vanishedSlots.removeValue(forKey: slotId)
    savedWorkspaceStore.scheduleWrite()

    // Fold edits made since the last checkpoint into the saved layout before rebuilding from it.
    captureSavedWorkspace(
        named: workspace.name,
        facts: currentSavedWorkspaceCaptureFacts(titleByWindowId: [:]),
        excludingWindowId: window.windowId,
        forceKeepSlotIds: [slotId],
    )
    guard let record = savedWorkspaceStore.record(named: workspace.name) else { return false }
    guard let slot = record.layout.allSlots.first(where: { $0.id == slotId }) else {
        // Can't happen (the claimed slot is protected), but never leave the window unplaced.
        try await window.relayoutWindow(on: workspace, forceTile: config.automaticallyTileNewWindows)
        return true
    }
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
    // Nodes flagged as most recent, with their depth.
    var mostRecentNodes: [(node: TreeNode, depth: Int)] = []

    func build(_ saved: SavedLayoutContainer, parent: NonLeafTreeNodeObject, weight: CGFloat, index: Int, depth: Int) -> TilingContainer {
        let container = TilingContainer(parent: parent, adaptiveWeight: weight, saved.orientation, saved.layout, index: index)
        var boundCount = 0
        for child in saved.children {
            switch child {
                case .slot(let slot):
                    guard let slotWindow = windowBySlotId[slot.id] else { continue }
                    slotWindow.bind(to: container, adaptiveWeight: slot.weight, index: boundCount)
                    boundCount += 1
                    if slot.isMostRecentInParent { mostRecentNodes.append((slotWindow, depth + 1)) }
                case .container(let nested):
                    guard nested.allSlots.contains(where: { windowBySlotId[$0.id] != nil }) else { continue }
                    let built = build(nested, parent: container, weight: nested.weight, index: boundCount, depth: depth + 1)
                    boundCount += 1
                    if nested.isMostRecentInParent { mostRecentNodes.append((built, depth + 1)) }
            }
        }
        return container
    }
    _ = build(root, parent: workspace, weight: 1, index: INDEX_BIND_LAST, depth: 0)
    // Binding raised every node as it went; replay the saved choices so tab groups show the
    // saved tab and focus returns to the saved window. Marking a node also raises its
    // ancestors, so deeper nodes go first and each level ends with its own saved choice.
    for entry in mostRecentNodes.enumerated().sorted(by: { lhs, rhs in
        lhs.element.depth != rhs.element.depth ? lhs.element.depth > rhs.element.depth : lhs.offset < rhs.offset
    }) {
        entry.element.node.markAsMostRecentChild()
    }
    for orphan in potentialOrphans where orphan !== window && orphan.nodeWorkspace == nil {
        try await orphan.relayoutWindow(on: workspace, forceTile: true)
    }
}
