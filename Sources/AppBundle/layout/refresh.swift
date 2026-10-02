import AppKit
import Common

@MainActor
private var activeRefreshTask: Task<(), any Error>? = nil

@MainActor
private var activeScheduledRefreshEvent: RefreshSessionEvent? = nil

/// What the active scheduled session runs for: the union of every event it coalesced.
@MainActor
private var activeScheduledRefreshRequirements: RefreshSessionRequirements? = nil

@MainActor
private var activeScheduledRefreshGeneration: UInt64 = 0

@MainActor
private var scheduledRefreshOverrideForTests: (@MainActor @Sendable (RefreshSessionEvent, Bool, Int32?) async throws -> Void)? = nil

@MainActor
private var refreshOverrideForTests: (@MainActor @Sendable () async throws -> Void)? = nil

@MainActor
private var normalizeLayoutReasonOverrideForTests: (@MainActor @Sendable () async throws -> Void)? = nil

private func isAxGeometryRefreshEvent(_ event: RefreshSessionEvent) -> Bool {
    guard case .ax(let notif) = event else { return false }
    return notif == kAXMovedNotification as String || notif == kAXResizedNotification as String
}

private func shouldDropScheduledRefresh(_ newEvent: RefreshSessionEvent, activeEvent: RefreshSessionEvent?) -> Bool {
    guard isAxGeometryRefreshEvent(newEvent), let activeEvent else { return false }
    if isAxGeometryRefreshEvent(activeEvent) {
        return true
    }
    if case .resetManipulatedWithMouse = activeEvent {
        return true
    }
    return false
}

@MainActor
func shouldSyncFocusBackToMacOs(
    nativeFocused: Window?,
    frontmostActivationPolicy: NSApplication.ActivationPolicy?,
    nativeFocusIsTransient: Bool = false,
    systemSettingsIsOpening: Bool = false,
) -> Bool {
    if nativeFocusIsTransient { return false }
    if nativeFocused?.participatesInWorkspaceFocus == false {
        return false
    }
    if nativeFocused == nil && frontmostActivationPolicy == .accessory {
        return false
    }
    // System Settings activates before its window exists; focusing the previous window would bury it.
    if nativeFocused == nil && systemSettingsIsOpening {
        return false
    }
    return true
}

private struct PendingRefreshRequest {
    var event: RefreshSessionEvent
    /// The union of every coalesced event's requirements; `event` alone may need less.
    var requirements: RefreshSessionRequirements
    var optimisticallyPreLayoutWorkspaces: Bool
    var activatedAppPid: Int32?

    mutating func absorb(_ event: RefreshSessionEvent, _ requirements: RefreshSessionRequirements,
                         optimisticallyPreLayoutWorkspaces: Bool, activatedAppPid: Int32?)
    {
        self.event = mergeRefreshEvents(self.event, event)
        self.requirements = self.requirements.union(requirements)
        self.optimisticallyPreLayoutWorkspaces = self.optimisticallyPreLayoutWorkspaces || optimisticallyPreLayoutWorkspaces
        self.activatedAppPid = activatedAppPid ?? self.activatedAppPid
    }
}

@MainActor
private var pendingRefreshRequest: PendingRefreshRequest? = nil

/// When two refresh requests coalesce, keep the event whose session does more work as the one
/// the session reports. What the session must do is the union of their requirements, kept
/// separately, so no event's requirement is lost to the other.
private func mergeRefreshEvents(_ old: RefreshSessionEvent, _ new: RefreshSessionEvent) -> RefreshSessionEvent {
    func score(_ e: RefreshSessionEvent) -> Int {
        (e.requiresWindowRefreshBarrier ? 2 : 0) + (e.canReuseLastAppliedWindowFrames ? 0 : 1)
    }
    return score(new) >= score(old) ? new : old
}

@MainActor
func scheduleRefreshSession(
    _ event: RefreshSessionEvent,
    optimisticallyPreLayoutWorkspaces: Bool = false,
    activatedAppPid activationPid: Int32? = nil,
) {
    scheduleRefreshSession(event, requirements: event.requirements,
                           optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces, activatedAppPid: activationPid)
}

@MainActor
private func scheduleRefreshSession(
    _ event: RefreshSessionEvent,
    requirements: RefreshSessionRequirements,
    optimisticallyPreLayoutWorkspaces: Bool,
    activatedAppPid activationPid: Int32?,
) {
    // A dropped event's requirements must already be covered by the session it defers to.
    if shouldDropScheduledRefresh(event, activeEvent: activeScheduledRefreshEvent) &&
        activeScheduledRefreshRequirements.map({ $0.union(requirements) == $0 }) == true ||
        shouldDropScheduledRefresh(event, activeEvent: pendingRefreshRequest?.event) &&
        pendingRefreshRequest.map({ $0.requirements.union(requirements) == $0.requirements }) == true
    {
        debugFocusLog("scheduleRefreshSession dropped event=\(event) active=\(activeScheduledRefreshEvent?.description ?? "nil") pending=\(pendingRefreshRequest?.event.description ?? "nil")")
        return
    }
    // Coalesce instead of cancel-and-restart: cancelling the in-flight session on every event
    // meant that during event bursts (app launch, window storms) the refresh kept restarting
    // and never completed until the burst quieted down. Let the active session finish, then
    // run a single follow-up session on behalf of all events that arrived in the meantime.
    if activeRefreshTask != nil {
        queuePendingRefresh(event, requirements, optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces, activatedAppPid: activationPid)
        return
    }
    activeScheduledRefreshGeneration += 1
    let generation = activeScheduledRefreshGeneration
    activeScheduledRefreshEvent = event
    activeScheduledRefreshRequirements = requirements
    let override = scheduledRefreshOverrideForTests
    activeRefreshTask = Task { @MainActor in
        defer {
            // Generation mismatch means someone took over (light session, test setup); they are
            // responsible for the next refresh, so don't drain the pending request from here.
            if activeScheduledRefreshGeneration == generation {
                activeRefreshTask = nil
                activeScheduledRefreshEvent = nil
                activeScheduledRefreshRequirements = nil
                if let pending = pendingRefreshRequest {
                    pendingRefreshRequest = nil
                    scheduleRefreshSession(pending.event, requirements: pending.requirements,
                                           optimisticallyPreLayoutWorkspaces: pending.optimisticallyPreLayoutWorkspaces,
                                           activatedAppPid: pending.activatedAppPid)
                }
            }
        }
        do {
            try checkCancellation()
            if let override {
                try await $refreshSessionRequirementsOverride.withValue(requirements) {
                    try await override(event, optimisticallyPreLayoutWorkspaces, activationPid)
                }
            } else {
                try await runRefreshSessionBlocking(event, requirements: requirements,
                                                    optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces,
                                                    activatedAppPid: activationPid)
            }
        } catch is CancellationError {
            return
        }
    }
}

@MainActor
private func queuePendingRefresh(
    _ event: RefreshSessionEvent,
    _ requirements: RefreshSessionRequirements,
    optimisticallyPreLayoutWorkspaces: Bool,
    activatedAppPid: Int32?,
) {
    if pendingRefreshRequest == nil {
        pendingRefreshRequest = PendingRefreshRequest(event: event, requirements: requirements,
                                                      optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces,
                                                      activatedAppPid: activatedAppPid)
    } else {
        pendingRefreshRequest?.absorb(event, requirements, optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces,
                                      activatedAppPid: activatedAppPid)
    }
}

@MainActor
func runRefreshSessionBlocking(
    _ event: RefreshSessionEvent,
    requirements: RefreshSessionRequirements? = nil,
    layoutWorkspaces shouldLayoutWorkspaces: Bool = true,
    optimisticallyPreLayoutWorkspaces: Bool = false,
    activatedAppPid activationPid: Int32? = nil,
) async throws {
    let requirements = requirements ?? event.requirements
    workspaceInteractionSessionGeneration &+= 1
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    let performanceRefresh = DockPerformanceRecorder.shared.beginRefresh()
    defer { DockPerformanceRecorder.shared.endRefresh(performanceRefresh) }
    if !TrayMenuModel.shared.isEnabled { return }
    let focusSnapshot = captureRefreshSessionFocusSnapshot()
    debugFocusLog("runRefreshSessionBlocking begin event=\(event) snapshot=\(debugDescribe(focusSnapshot))")
    let presentation = NewFloatingWindowPresentation(
        isStartup: event.isStartup,
        frontmostAppPid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        activatedAppPid: activationPid,
    )
    try await $newFloatingWindowPresentation.withValue(presentation) {
        try await $refreshSessionEvent.withValue(event) {
            try await $refreshSessionRequirementsOverride.withValue(requirements) {
            try await $_isStartup.withValue(event.isStartup) {
                try await $_refreshSessionFocusSnapshot.withValue(focusSnapshot) {
                    let frontmostApplication = NSWorkspace.shared.frontmostApplication
                    let frontmostActivationPolicy = frontmostApplication?.activationPolicy
                    let nativeObservation = try await getNativeFocusObservation()
                    let nativeFocused = nativeObservation.window
                    try checkCancellation()
                    if let nativeFocused { try await debugWindowsIfRecording(nativeFocused) }
                    // The activated app is resolved directly: the frontmost app may lag its notification.
                    let activatedApp = activationPid.flatMap { NSRunningApplication(processIdentifier: $0) }
                    if let activationPid, activatedApp?.bundleIdentifier == SystemFrontApp.systemSettings {
                        noteSystemSettingsActivation()
                        if let nativeFocused, nativeFocused.app.pid == activationPid {
                            bringSystemSettingsToFocusedWorkspace(nativeFocused)
                        }
                    }
                    if !nativeObservation.isTransient { updateFocusCache(nativeFocused, preserveLogicalFocus: presentation.callbacksChangedFocus) }
                    presentation.recordNativeFocusBeforeLayout(nativeFocused)
                    try checkCancellation()

                    if shouldLayoutWorkspaces && optimisticallyPreLayoutWorkspaces { try await layoutWorkspaces() }
                    try checkCancellation()

                    refreshModel()
                    if requirements.windowRefreshBarrier {
                        if let refreshOverrideForTests {
                            try await refreshOverrideForTests()
                        } else {
                            try await refresh()
                        }
                        try checkCancellation()
                        gcMonitors()
                    }

                    if requirements.layoutReasonNormalization {
                        if let normalizeLayoutReasonOverrideForTests {
                            try await normalizeLayoutReasonOverrideForTests()
                        } else {
                            try await normalizeLayoutReason()
                        }
                        try checkCancellation()
                        refreshModel()
                    }
                    await updateNativeFullscreenChromeSuppression(nativeFocused: nativeFocused)
                    try checkCancellation()
                    updateTrayText()
                    await updateWorkspaceSidebarModel()
                    SecureInputPanel.shared.refresh()
                    WorkspaceLauncherPanel.shared.revalidate()
                    if shouldLayoutWorkspaces {
                        try await layoutWorkspaces()
                        try checkCancellation()
                        var didPresentFloatingWindow = false
                        if !nativeObservation.isTransient {
                            didPresentFloatingWindow = try await presentation.presentAfterLayout()
                        }
                        if !didPresentFloatingWindow && !presentation.suppressFocusSync && shouldSyncFocusBackToMacOs(
                            nativeFocused: nativeFocused,
                            frontmostActivationPolicy: frontmostActivationPolicy,
                            nativeFocusIsTransient: nativeObservation.isTransient,
                            systemSettingsIsOpening: (activatedApp?.bundleIdentifier ?? frontmostApplication?.bundleIdentifier) ==
                                SystemFrontApp.systemSettings && isSystemSettingsOpening(),
                        ) {
                            let logicalFocused = focus.windowOrNil
                            if logicalFocused?.windowId != nativeFocused?.windowId {
                                debugFocusLog(
                                    "runRefreshSessionBlocking syncFocus event=\(event) nativeFocused=\(nativeFocused?.windowId.description ?? "nil") logicalFocused=\(logicalFocused?.windowId.description ?? "nil")"
                                )
                                logicalFocused?.nativeFocus()
                            } else {
                                debugFocusLog(
                                    "runRefreshSessionBlocking skipSyncFocus event=\(event) nativeFocused=\(nativeFocused?.windowId.description ?? "nil") logicalFocused=\(logicalFocused?.windowId.description ?? "nil")"
                                )
                            }
                        }
                    }
                    await updateWindowTabModel()
                    updateSystemFrontWindows()
                    debugFocusLog("runRefreshSessionBlocking end event=\(event) nativeFocused=\(nativeFocused?.windowId.description ?? "nil") focus=\(debugDescribe(focus))")
                }
            }
            }
        }
    }
}

/// A sidebar edit must not absorb another command/refresh that ran while it awaited AX.
@MainActor private(set) var workspaceInteractionSessionGeneration: UInt64 = 0

@MainActor
func runLightSession<T>(
    _ event: RefreshSessionEvent,
    _: RunSessionGuard,
    shouldSchedulePostRefresh: Bool = true,
    body: @MainActor () async throws -> T,
) async throws -> T {
    workspaceInteractionSessionGeneration &+= 1
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    // Give priority to runSession. The cancelled session's work is still owed (a settled
    // display's re-park, say): the post-refresh runs it too, or, if this session ends without
    // one, it waits as the pending request.
    var cancelledSession: (event: RefreshSessionEvent, requirements: RefreshSessionRequirements)? =
        activeRefreshTask == nil ? nil : activeScheduledRefreshEvent.flatMap { event in activeScheduledRefreshRequirements.map { (event, $0) } }
    defer {
        if let cancelledSession {
            queuePendingRefresh(cancelledSession.event, cancelledSession.requirements, optimisticallyPreLayoutWorkspaces: false, activatedAppPid: nil)
        }
        // Without a post-refresh (this session threw), no running session would drain it.
        if activeRefreshTask == nil, let pending = pendingRefreshRequest {
            pendingRefreshRequest = nil
            scheduleRefreshSession(pending.event, requirements: pending.requirements,
                                   optimisticallyPreLayoutWorkspaces: pending.optimisticallyPreLayoutWorkspaces,
                                   activatedAppPid: pending.activatedAppPid)
        }
    }
    activeRefreshTask?.cancel()
    activeRefreshTask = nil
    activeScheduledRefreshEvent = nil
    activeScheduledRefreshRequirements = nil
    // Invalidate the cancelled task's generation so its defer doesn't spawn a coalesced
    // follow-up session in the middle of this light session. The post-refresh scheduled at
    // the end of the light session (or any later event) picks the pending request up instead.
    activeScheduledRefreshGeneration += 1
    // The command supersedes presentation intent, but pending model refresh work remains.
    pendingRefreshRequest?.activatedAppPid = nil
    let focusSnapshot = captureRefreshSessionFocusSnapshot()
    debugFocusLog("runLightSession begin event=\(event) snapshot=\(debugDescribe(focusSnapshot))")
    let presentation = NewFloatingWindowPresentation(isStartup: event.isStartup, frontmostAppPid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    return try await $newFloatingWindowPresentation.withValue(presentation) {
        return try await $refreshSessionEvent.withValue(event) {
            // Runs for its own event, never for a scheduled session it may be called from.
            try await $refreshSessionRequirementsOverride.withValue(nil) {
            try await $_isStartup.withValue(event.isStartup) {
                try await $_refreshSessionFocusSnapshot.withValue(focusSnapshot) {
                    let nativeObservation = try await getNativeFocusObservation()
                    let nativeFocused = nativeObservation.window
                    try checkCancellation()
                    if let nativeFocused { try await debugWindowsIfRecording(nativeFocused) }
                    if !nativeObservation.isTransient { updateFocusCache(nativeFocused, preserveLogicalFocus: presentation.callbacksChangedFocus) }
                    presentation.recordNativeFocusBeforeLayout(nativeFocused)
                    try checkCancellation()
                    let focusBefore = focus.windowOrNil

                    // Commands that open sidebar search must see fullscreen suppression
                    // before their body can activate the panel or acquire keyboard input.
                    await updateNativeFullscreenChromeSuppression(nativeFocused: nativeFocused)
                    try checkCancellation()

                    refreshModel()
                    let result = try await body()
                    try checkCancellation()
                    refreshModel()

                    let focusAfter = focus.windowOrNil

                    updateTrayText()
                    await updateWorkspaceSidebarModel()
                    SecureInputPanel.shared.refresh()
                    WorkspaceLauncherPanel.shared.revalidate()
                    try await layoutWorkspaces()
                    try checkCancellation()
                    var didPresentFloatingWindow = false
                    if !nativeObservation.isTransient {
                        didPresentFloatingWindow = try await presentation.presentAfterLayout()
                    }
                    await updateWindowTabModel()
                    let callbackChoseDifferentNativeFocus = presentation.callbacksChangedFocus && focusAfter != nativeFocused
                    let selectionIsStillCurrent = focusAfter == focus.windowOrNil
                    if selectionIsStillCurrent && !nativeObservation.isTransient && !didPresentFloatingWindow && !presentation.suppressFocusSync && (focusBefore != focusAfter || callbackChoseDifferentNativeFocus) {
                        focusAfter?.nativeFocus() // syncFocusToMacOs
                    }
                    if shouldSchedulePostRefresh {
                        scheduleRefreshSession(event, requirements: cancelledSession.map { event.requirements.union($0.requirements) } ?? event.requirements,
                                               optimisticallyPreLayoutWorkspaces: false, activatedAppPid: nil)
                        cancelledSession = nil
                    }
                    debugFocusLog("runLightSession end event=\(event) nativeFocused=\(nativeFocused?.windowId.description ?? "nil") focusBefore=\(focusBefore?.windowId.description ?? "nil") focusAfter=\(focusAfter?.windowId.description ?? "nil") logicalFocus=\(debugDescribe(focus))")
                    return result
                }
            }
            }
        }
    }
}

@MainActor
func setScheduledRefreshOverrideForTests(
    _ override: (@MainActor @Sendable (RefreshSessionEvent, Bool, Int32?) async throws -> Void)?
) {
    activeRefreshTask?.cancel()
    activeRefreshTask = nil
    activeScheduledRefreshEvent = nil
    activeScheduledRefreshRequirements = nil
    pendingRefreshRequest = nil
    scheduledRefreshOverrideForTests = override
}

@MainActor
func setBlockingRefreshOverridesForTests(
    refresh: (@MainActor @Sendable () async throws -> Void)? = nil,
    normalizeLayoutReason: (@MainActor @Sendable () async throws -> Void)? = nil,
) {
    activeRefreshTask?.cancel()
    activeRefreshTask = nil
    activeScheduledRefreshEvent = nil
    activeScheduledRefreshRequirements = nil
    pendingRefreshRequest = nil
    owedHiddenWindowsReassertion = nil
    refreshOverrideForTests = refresh
    normalizeLayoutReasonOverrideForTests = normalizeLayoutReason
}

@MainActor
func waitForScheduledRefreshForTests() async throws {
    // A completing session may schedule a coalesced follow-up session; drain until quiet.
    for _ in 0 ..< 100 {
        guard let task = activeRefreshTask else { return }
        activeRefreshTask = nil
        try await task.value
    }
}

struct RunSessionGuard: Sendable {
    @MainActor
    static var isServerEnabled: RunSessionGuard? { TrayMenuModel.shared.isEnabled ? forceRun : nil }
    @MainActor
    static func isServerEnabled(orIsEnableCommand command: (any Command)?) -> RunSessionGuard? {
        command is EnableCommand ? .forceRun : .isServerEnabled
    }
    @MainActor
    static func checkServerIsEnabledOrDie(
        file: StaticString = #fileID,
        line: Int = #line,
        column: Int = #column,
        function: String = #function,
    ) -> RunSessionGuard {
        .isServerEnabled ?? dieT("server is disabled", file: file, line: line, column: column, function: function)
    }
    static let forceRun = RunSessionGuard()
    private init() {}
}

@MainActor
func refreshModel() {
    migrateWindowStacksToSidebarTabs()
    Workspace.reconcileWorkspaceState()
    checkOnFocusChangedCallbacks()
    normalizeContainers()
}

@MainActor
private func refresh() async throws {
    // Garbage collect terminated apps and windows before working with all windows
    let mapping = try await MacApp.refreshAllAndGetAliveWindowIds(frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    let aliveWindowIds = mapping.values.flatMap { $0 }.toSet()

    for window in MacWindow.allWindows {
        if !aliveWindowIds.contains(window.windowId) {
            window.garbageCollect(skipClosedWindowsCache: false)
        }
    }
    // Saved-workspace routing must not give a slot whose window is alive but not registered yet
    // to another window of the same app.
    savedWorkspaceRuntime.aliveWindowPidsDuringRefresh = savedWorkspaceStore.isEmpty ? [:] : Dictionary(
        mapping.flatMap { app, windowIds in windowIds.map { ($0, app.pid) } },
        uniquingKeysWith: { first, _ in first },
    )
    defer { savedWorkspaceRuntime.aliveWindowPidsDuringRefresh = [:] }
    // One task per app so the per-window AX round-trips of different apps overlap;
    // a single slow app no longer delays every other app's window registration.
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (app, windowIds) in mapping {
            group.addTask { @Sendable @MainActor in
                for windowId in windowIds {
                    try await MacWindow.getOrRegister(windowId: windowId, macApp: app)
                }
            }
        }
        try await group.waitForAll()
    }
    // Floating windows are the only windows whose real frame can't be derived from the applied
    // layout, and some synchronous consumers (interaction-opacity parking, agent pane info)
    // read the cached rect directly. Re-warm just the ones invalidated by move/resize events —
    // typically none — instead of polling every window's frame each barrier.
    let staleFloatingWindows = Workspace.all.flatMap { workspace in
        workspace.floatingWindows.filter { $0.lastKnownActualRect == nil }
    }
    if !staleFloatingWindows.isEmpty {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for window in staleFloatingWindows {
                group.addTask { @Sendable @MainActor in
                    _ = try? await window.getAxRect()
                }
            }
            try await group.waitForAll()
        }
    }
    finalizePersistedFrozenWorldAfterRefresh(aliveWindowIds: aliveWindowIds)

    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.reconcileWorkspaceState()
}

func refreshObs(_: AXObserver, _ ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    if notif == kAXFocusedWindowChangedNotification as String || notif == kAXUIElementDestroyedNotification as String {
        debugFocusLog("refreshObs notif=\(notif)")
    }
    // Minimize state changed: drop the event-invalidated native-state cache for this window so
    // the next normalizeLayoutReason pass fetches it live. containingWindowId runs here on the
    // app's AX thread, not on the main thread.
    let isMinimizeStateNotif =
        notif == kAXWindowMiniaturizedNotification as String || notif == kAXWindowDeminiaturizedNotification as String
    let invalidateNativeStateWindowId: UInt32? = isMinimizeStateNotif ? ax.containingWindowId() : nil
    // A busy app can time out the windowId resolution. Losing this invalidation would poison
    // the cache permanently (a minimized window emits no further geometry events), so fall
    // back to invalidating every window of the emitting app.
    let invalidateNativeStateAppPid: pid_t? =
        isMinimizeStateNotif && invalidateNativeStateWindowId == nil ? axTaskLocalAppThreadToken?.pid : nil
    Task { @MainActor in
        if let invalidateNativeStateWindowId {
            Window.get(byId: invalidateNativeStateWindowId)?.invalidateLastKnownNativeState()
        } else if let invalidateNativeStateAppPid {
            for window in MacWindow.allWindows where window.macApp.pid == invalidateNativeStateAppPid {
                window.invalidateLastKnownNativeState()
            }
        }
        if !TrayMenuModel.shared.isEnabled { return }
        scheduleRefreshSession(.ax(notif))
    }
}

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

/// Hidden windows are parked in a bottom corner of their monitor. Prefer the corner that doesn't
/// touch another monitor: e.g. a portrait monitor arranged right of a shorter landscape monitor
/// covers the landscape monitor's bottom-right corner, so windows parked there peek out on the
/// portrait monitor. Ties, including when neither or both corners touch another monitor, keep
/// bottom-right.
@MainActor
func optimalHideCorner(for monitor: Monitor, among monitors: [Monitor]) -> OptimalHideCorner {
    let xOff = monitor.width * 0.1
    let yOff = monitor.height * 0.1
    // brc = bottomRightCorner
    let brc1 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: -yOff)
    let brc2 = monitor.rect.bottomRightCorner + CGPoint(x: -xOff, y: 2)
    let brc3 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: 2)

    // blc = bottomLeftCorner
    let blc1 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: -yOff)
    let blc2 = monitor.rect.bottomLeftCorner + CGPoint(x: xOff, y: 2)
    let blc3 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: 2)

    func contains(_ monitor: Monitor, _ point: CGPoint) -> Int { monitor.rect.contains(point) ? 1 : 0 }
    let important = 10

    return monitors.sumOfInt { contains($0, blc1) + contains($0, blc2) + important * contains($0, blc3) } <
        monitors.sumOfInt { contains($0, brc1) + contains($0, brc2) + important * contains($0, brc3) }
        ? .bottomLeftCorner
        : .bottomRightCorner
}

@MainActor
func optimalHideCorner(for monitor: Monitor) -> OptimalHideCorner {
    optimalHideCorner(for: monitor, among: monitors)
}

@MainActor
private var workspaceLayoutGeneration: UInt64 = 0

/// A reassertion a session asked for that no complete layout pass has carried out yet. A newer
/// pass can supersede the one that asked (a command's layout during a settled refresh's); the
/// next pass to complete re-parks instead.
@MainActor
private var owedHiddenWindowsReassertion: HiddenWindowsReassertion? = nil

/// Counts parks a layout gave up on because what it was hiding changed while it awaited AX. A
/// pass with such a park hasn't carried out an owed reassertion for every window.
@MainActor
private var abandonedHiddenWindowParks: UInt64 = 0

/// Whether this pass must re-park hidden windows even where WinMux believes them parked: wake
/// and startup always; a settled display change only while no newer change has arrived.
@MainActor
func sessionRequiresHiddenWindowsReassertion() -> Bool {
    let topology = MonitorConfigurationObserver.shared.topologyGeneration
    return refreshSessionRequirements?.hiddenWindowsReassertion?.applies(atTopologyGeneration: topology) == true ||
        owedHiddenWindowsReassertion?.applies(atTopologyGeneration: topology) == true
}

/// Parks a window that must not be seen (an inactive workspace's window, an inactive tab, a
/// window behind a fullscreen tab). Windows confirmed parked cost nothing; see `parkInCorner`.
@MainActor
func parkHiddenWindow(
    _ window: Window,
    in corner: OptimalHideCorner,
    reasserting: Bool,
    ifStillValid: () -> Bool = { true },
) async throws {
    guard let visibility = window as? any WorkspaceWindowVisibility else { return }
    try await visibility.hideInCorner(corner, reassert: reasserting) {
        let valid = ifStillValid()
        if !valid { abandonedHiddenWindowParks &+= 1 }
        return valid
    }
}

@MainActor
func layoutWorkspaces() async throws {
    workspaceLayoutGeneration += 1
    let generation = workspaceLayoutGeneration
    // With every display gone mid-reconfiguration, `monitors` is a placeholder. Frames computed
    // against it would put windows anywhere, so write nothing until a real display is back:
    // its own screen-change refresh lays everything out, and re-parks once it settles.
    if !hasRealMonitorTopology { return }
    if !TrayMenuModel.shared.isEnabled {
        for workspace in Workspace.all {
            workspace.allLeafWindowsRecursive.forEach { window in
                guard let visibility = window as? any WorkspaceWindowVisibility else { return }
                if shouldKeepWindowHiddenForVisibleWorkspaceLayout(window) {
                    return
                }
                visibility.unhideFromCorner()
            }
            try await workspace.layoutWorkspace() // Unhide tiling windows from corner
        }
        return
    }
    if let requested = refreshSessionRequirements?.hiddenWindowsReassertion {
        owedHiddenWindowsReassertion = requested.union(owedHiddenWindowsReassertion)
    }
    let owedAtStart = owedHiddenWindowsReassertion
    let abandonedParksAtStart = abandonedHiddenWindowParks
    let layoutMonitors = monitors
    let topologyGeneration = MonitorConfigurationObserver.shared.topologyGeneration
    let presentation = layoutMonitors.map { (rect: $0.rect, visibleRect: $0.visibleRect, workspace: $0.activeWorkspace) }
    // A display change makes this pass stale even where the new displays have the same rects.
    func isCurrentPresentation() -> Bool {
        guard generation == workspaceLayoutGeneration, TrayMenuModel.shared.isEnabled,
              MonitorConfigurationObserver.shared.topologyGeneration == topologyGeneration,
              monitors.count == presentation.count else { return false }
        return zip(monitors, presentation).allSatisfy { monitor, expected in
            monitor.rect == expected.rect && monitor.visibleRect == expected.visibleRect &&
                monitor.activeWorkspace === expected.workspace
        }
    }
    var visibleApps: [(monitor: MonitorViewportId, app: any AbstractApp)] = []

    // Queue the incoming frames before hiding anything on the outgoing workspace.
    for expected in presentation {
        guard isCurrentPresentation() else { return }
        let workspace = expected.workspace
        workspace.allLeafWindowsRecursive.forEach { window in
            guard let visibility = window as? any WorkspaceWindowVisibility else { return }
            if shouldKeepWindowHiddenForVisibleWorkspaceLayout(window) {
                return
            }
            visibleApps.append((MonitorViewportId(topLeftCorner: expected.rect.topLeftCorner), window.app))
            visibility.unhideFromCorner()
        }
        try await workspace.layoutWorkspace()
    }
    guard isCurrentPresentation() else { return }
    let outgoingMonitors = Set(Workspace.all.compactMap { workspace -> MonitorViewportId? in
        guard !workspace.isVisible, workspace.allLeafWindowsRecursive.contains(where: {
            $0 is any WorkspaceWindowVisibility && !$0.isHiddenInCorner
        }) else { return nil }
        return MonitorViewportId(workspace.workspaceMonitor)
    })
    if !outgoingMonitors.isEmpty {
        // Different apps have independent AX threads. Merely queuing "show, then hide"
        // can hide the old window first. Wait once per incoming app, concurrently. Include
        // already-unhidden windows: an overlapping refresh may still be revealing them.
        // A slow app on an unaffected display must not delay this transition.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var waitingPids: Set<Int32> = []
            for (monitor, app) in visibleApps where outgoingMonitors.contains(monitor) && waitingPids.insert(app.pid).inserted {
                group.addTask { @Sendable @MainActor in try await app.waitForPendingFrameWrites() }
            }
            try await group.waitForAll()
        }
    }
    try checkCancellation()
    guard isCurrentPresentation() else { return }
    let shouldReassertHiddenWindows = sessionRequiresHiddenWindowsReassertion()
    for workspace in Workspace.all where !workspace.isVisible {
        let corner = optimalHideCorner(for: workspace.workspaceMonitor, among: layoutMonitors)
        for window in workspace.allLeafWindowsRecursive {
            guard isCurrentPresentation() else { return }
            guard window is any WorkspaceWindowVisibility else { continue }
            window.lastAppliedLayoutPhysicalRect = nil
            window.lastAppliedLayoutVirtualRect = nil
            try await parkHiddenWindow(window, in: corner, reasserting: shouldReassertHiddenWindows) {
                isCurrentPresentation() && window.nodeWorkspace === workspace && !workspace.isVisible
            }
        }
    }
    // Carried out, unless this pass was superseded (its last park may just have been rejected),
    // gave up a park, or a session asked for more while it ran.
    try checkCancellation()
    if isCurrentPresentation(), abandonedHiddenWindowParks == abandonedParksAtStart, owedHiddenWindowsReassertion == owedAtStart {
        owedHiddenWindowsReassertion = nil
    }
}

@MainActor
private func shouldKeepWindowHiddenForVisibleWorkspaceLayout(_ window: Window) -> Bool {
    guard let tabGroup = window.nearestWindowTabGroup, tabGroup.usesWindowTabBehavior else { return false }
    return tabGroup.tabActiveWindow != window
}

@MainActor
private func normalizeContainers() {
    // Can't do it only for visible workspace because most of the commands support --window-id and --workspace flags
    for workspace in Workspace.all {
        workspace.normalizeContainers()
    }
}
