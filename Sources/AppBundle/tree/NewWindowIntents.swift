import AppKit
import Common

/// How long a requested window has to appear once the app has taken the request.
let newWindowIntentTimeout: TimeInterval = 8

enum NewWindowRequestOutcome: Equatable {
    case placed(windowId: UInt32)
    /// An app with no adapter was launched normally; its windows follow the usual rules.
    case opened
    case timedOut
    case failed(String)
    case cancelled
}

/// "The next new regular window of this app goes to this workspace." Registered before WinMux
/// asks the app for a window, so the window can't be placed anywhere else first.
@MainActor
final class NewWindowIntent {
    let id: Int
    let bundleId: String
    /// Unknown until an app that wasn't running has launched.
    var pid: Int32?
    /// The destination by identity, so a workspace deleted and recreated under the same name
    /// never receives an old request's window. A newer click can take a reopen over.
    var targetWorkspaceId: WorkspaceId
    /// Windows the app had before the request, which aren't the new one: every one, registered
    /// with WinMux or not. For a reopen, those WinMux knows and those on screen; a window the app
    /// hid when it was closed is what a reopen shows again.
    let preexistingWindowIds: Set<UInt32>
    let createdUptime: TimeInterval
    var deadlineUptime: TimeInterval
    /// If the user moves focus while waiting, the window is placed without taking focus.
    var focusGeneration: UInt64
    /// The app was opened again to show its window, as a Dock click does. The window may be one
    /// it hid when it was closed, which WinMux remembers as closed.
    let reopens: Bool
    /// The app's processes when it was asked. If the one asked quits, its relaunch is a new one.
    let instancePidsAtRequest: Set<Int32>
    /// Where focus was when the request went to the app, which may show a permission prompt.
    var focusWhenSent: NewWindowFocusSnapshot?
    var completion: ((NewWindowRequestOutcome) -> Void)?
    /// Withdrawn after its window was claimed: the window then follows the usual rules.
    var isCancelled = false

    init(id: Int, bundleId: String, pid: Int32?, targetWorkspaceId: WorkspaceId, preexistingWindowIds: Set<UInt32>,
         createdUptime: TimeInterval, deadlineUptime: TimeInterval, focusGeneration: UInt64, reopens: Bool = false,
         instancePidsAtRequest: Set<Int32> = [], completion: ((NewWindowRequestOutcome) -> Void)?) {
        self.id = id
        self.bundleId = bundleId
        self.pid = pid
        self.targetWorkspaceId = targetWorkspaceId
        self.preexistingWindowIds = preexistingWindowIds
        self.createdUptime = createdUptime
        self.deadlineUptime = deadlineUptime
        self.focusGeneration = focusGeneration
        self.reopens = reopens
        self.instancePidsAtRequest = instancePidsAtRequest
        self.completion = completion
    }
}

/// A window reserved for an intent. The request completes only once detection confirms the
/// window ended up in its workspace.
@MainActor
struct NewWindowIntentClaim {
    let intent: NewWindowIntent
    let targetWorkspace: Workspace
    let claimedUptime: TimeInterval

    /// The launcher closed after the window was claimed; it goes where any new window would.
    var isWithdrawn: Bool { intent.isCancelled }
}

/// A reopened window placed while a frozen-world restore was under way. Restores leave it alone,
/// and it's finished once none is left, so it reports where it ends up.
@MainActor
struct DeferredReopenPlacement {
    let window: Window
    let claim: NewWindowIntentClaim
}

/// Where focus was when WinMux sent the request to the app.
@MainActor
struct NewWindowFocusSnapshot {
    let generation: UInt64
    let workspace: Workspace
    let window: Window?
    /// The project the focused display was in: with a pin in All Projects on it, not the pin's own.
    var contextProjectId: WorkspaceProjectId? = nil
    /// That display.
    var display: NewWindowRequestDisplay? = nil
    /// The project the user switched a display to since, with the pin kept on screen there, and
    /// that display.
    var switchedProjectId: WorkspaceProjectId? = nil
    var switchedDisplay: NewWindowRequestDisplay? = nil

    static var current: NewWindowFocusSnapshot {
        let monitor = focus.workspace.workspaceMonitor
        return NewWindowFocusSnapshot(generation: focusChangeGeneration, workspace: focus.workspace, window: focus.windowOrNil,
            contextProjectId: winMuxWorkspaceState.activeProjectId(for: monitor), display: NewWindowRequestDisplay(monitor))
    }
}

/// A display as a request saw it, to know it again later: by its identity, and otherwise by its
/// place only while no display has changed, since another display may have taken that place.
struct NewWindowRequestDisplay {
    let topLeftCorner: CGPoint
    let identity: MonitorDisplayIdentity?
    /// Identical panels without serial numbers can share an identity: then it tells nothing.
    let identityIsUnique: Bool
    let topologyGeneration: UInt64

    @MainActor init(_ monitor: Monitor) {
        topLeftCorner = monitor.rect.topLeftCorner
        identity = monitor.displayIdentity
        identityIsUnique = monitor.displayIdentity.map { identity in
            monitors.count(where: { $0.displayIdentity == identity }) == 1
        } ?? false
        topologyGeneration = MonitorConfigurationObserver.shared.topologyGeneration
    }

    @MainActor func isShown(by monitor: Monitor) -> Bool {
        if let identity, let other = monitor.displayIdentity {
            guard identity == other else { return false }
            if identityIsUnique, monitors.count(where: { $0.displayIdentity == identity }) == 1 { return true }
        }
        return topologyGeneration == MonitorConfigurationObserver.shared.topologyGeneration
            && topLeftCorner == monitor.rect.topLeftCorner
    }
}

@MainActor
final class NewWindowIntentRegistry {
    static let shared = NewWindowIntentRegistry()

    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Windows WinMux is about to put back from a saved or closed-window world are never new.
    var isRestorationCandidate: (UInt32) -> Bool = { windowId in
        persistedFrozenWorldContains(windowId: windowId) || closedWindowsCacheContains(windowId: windowId)
    }
    /// Whether WinMux still has this window registered: not closed, and not replaced by a new
    /// registration of the same id. Replaceable for tests, whose windows aren't registered.
    var isRegistered: (Window) -> Bool = { window in MacWindow.allWindowsMap[window.windowId] === window }
    /// Whether the process a reopen asked is still running.
    var isProcessAlive: (Int32) -> Bool = { pid in
        NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
    }
    private(set) var intents: [NewWindowIntent] = []
    private var claims: [UInt32: NewWindowIntentClaim] = [:]
    /// By intent id, until the restores under way end or the claim's deadline passes.
    private var deferredPlacements: [Int: DeferredReopenPlacement] = [:]
    /// Windows registered and not yet through detection, which settles their claims.
    var windowsBeingDetected: Set<UInt32> = []
    private var nextId = 1

    var hasPendingIntents: Bool { !intents.isEmpty }

    /// One request per app at a time: two outstanding requests couldn't tell their windows apart.
    func register(
        bundleId: String,
        pid: Int32?,
        targetWorkspace: Workspace,
        preexistingWindowIds: Set<UInt32>,
        focusGeneration: UInt64,
        timeout: TimeInterval = newWindowIntentTimeout,
        reopens: Bool = false,
        instancePidsAtRequest: Set<Int32> = [],
        completion: ((NewWindowRequestOutcome) -> Void)? = nil,
    ) -> NewWindowIntent? {
        expireOverdueIntents()
        guard !intents.contains(where: { $0.bundleId == bundleId }) else { return nil }
        let created = now()
        let intent = NewWindowIntent(id: nextId, bundleId: bundleId, pid: pid, targetWorkspaceId: targetWorkspace.id,
            preexistingWindowIds: preexistingWindowIds, createdUptime: created, deadlineUptime: created + timeout,
            focusGeneration: focusGeneration, reopens: reopens, instancePidsAtRequest: instancePidsAtRequest,
            completion: completion)
        nextId += 1
        intents.append(intent)
        return intent
    }

    /// Reserves a newly seen window for the intent waiting for it and returns its workspace.
    /// The intent is consumed, so the app's other new windows are placed normally.
    func claim(windowId: UInt32, pid: Int32, bundleId: String?, firstSeenUptime: TimeInterval) -> Workspace? {
        expireOverdueIntents()
        guard let bundleId, !intents.isEmpty else { return nil }
        let isRestorationCandidate = isRestorationCandidate(windowId)
        guard let index = intents.firstIndex(where: { intent in
                  intent.bundleId == bundleId &&
                      // A window the reopen brought back may be one WinMux saw close. It wasn't
                      // on screen when the app was asked, so it's what the reopen showed.
                      (!isRestorationCandidate || intent.reopens) &&
                      // The app a reopen asked may have quit and been launched again before
                      // LaunchServices replied: a process that wasn't running then is the relaunch.
                      (intent.pid.map {
                          $0 == pid || intent.reopens && !isProcessAlive($0) && !intent.instancePidsAtRequest.contains(pid)
                      } ?? true) &&
                      !intent.preexistingWindowIds.contains(windowId) &&
                      // A window first seen before the request, promoted from a popup now, isn't it.
                      firstSeenUptime >= intent.createdUptime
              })
        else { return nil }
        let intent = intents.remove(at: index)
        guard let workspace = winMuxWorkspaceState.workspaceById[intent.targetWorkspaceId], !workspace.isArchived else {
            finish(intent, .cancelled)
            return nil
        }
        claims[windowId] = NewWindowIntentClaim(intent: intent, targetWorkspace: workspace, claimedUptime: now())
        return workspace
    }

    /// Detection asks once whether an intent reserved the window, withdrawn or not.
    func consumeClaim(windowId: UInt32) -> NewWindowIntentClaim? {
        claims.removeValue(forKey: windowId)
    }

    func pendingClaim(windowId: UInt32) -> NewWindowIntentClaim? { claims[windowId] }

    /// Ends a claimed request that can't be placed after all, reporting nothing more.
    func cancel(claim: NewWindowIntentClaim) {
        claim.intent.isCancelled = true
        finish(claim.intent, .cancelled)
    }

    /// Ends the request once detection knows where its window went.
    func completeClaim(_ claim: NewWindowIntentClaim, window: Window) {
        finish(claim.intent, window.nodeWorkspace === claim.targetWorkspace
            ? .placed(windowId: window.windowId)
            : .failed("The new window went to another workspace"))
    }

    func setPid(_ pid: Int32, forIntent id: Int) {
        intents.first { $0.id == id }?.pid = pid
    }

    /// The reopen of this app still waiting for its window. One past its deadline has ended.
    func pendingReopen(bundleId: String) -> NewWindowIntent? {
        expireOverdueIntents()
        return intents.first { $0.reopens && $0.bundleId == bundleId }
    }

    /// A newer click takes a pending reopen over: its tab gets the window and its completion
    /// reports. The app isn't asked again, so it can't open a second window, and the earlier
    /// request ends quietly.
    func takeOver(_ intent: NewWindowIntent, targetWorkspace: Workspace, focusGeneration: UInt64,
                  completion: ((NewWindowRequestOutcome) -> Void)?) {
        guard intents.contains(where: { $0 === intent }) else { return }
        let replaced = intent.completion
        intent.targetWorkspaceId = targetWorkspace.id
        intent.focusGeneration = focusGeneration
        intent.focusWhenSent = nil
        intent.completion = completion
        replaced?(.cancelled)
    }

    /// Once the app has taken the request, its window gets the usual time to appear, however
    /// long a permission prompt the user was reading took.
    func restartDeadline(forIntent id: Int, timeout: TimeInterval = newWindowIntentTimeout) {
        intents.first { $0.id == id }?.deadlineUptime = now() + timeout
    }

    /// `monitor` switched project with the pin in All Projects `pin` on screen: a reopen asked from
    /// that pin comes back to it in the project switched to, on that display.
    func noteProjectSwitch(keeping pin: Workspace, in projectId: WorkspaceProjectId, on monitor: Monitor) {
        let waiting = intents + claims.values.map(\.intent) + deferredPlacements.values.map(\.claim.intent)
        for intent in waiting where intent.focusWhenSent?.workspace === pin {
            intent.focusWhenSent?.switchedProjectId = projectId
            intent.focusWhenSent?.switchedDisplay = NewWindowRequestDisplay(monitor)
        }
    }

    /// Also for a request whose window was claimed before the request was even sent.
    func recordFocusWhenSent(forIntent id: Int, _ snapshot: NewWindowFocusSnapshot) {
        (intents.first { $0.id == id } ?? claims.values.first { $0.intent.id == id }?.intent)?.focusWhenSent = snapshot
    }

    /// Withdraws a request whether or not its window has been claimed yet.
    func cancel(intentId id: Int, outcome: NewWindowRequestOutcome = .cancelled) {
        if let index = intents.firstIndex(where: { $0.id == id }) {
            finish(intents.remove(at: index), outcome)
        } else if let deferred = deferredPlacements.removeValue(forKey: id) {
            // Left where it is: it follows the usual rules, as a withdrawn claim does.
            deferred.claim.intent.isCancelled = true
            finish(deferred.claim.intent, outcome)
        } else if let claim = claims.values.first(where: { $0.intent.id == id && !$0.intent.isCancelled }) {
            claim.intent.isCancelled = true
            finish(claim.intent, outcome)
        }
    }

    func isPending(intentId id: Int) -> Bool { intents.contains { $0.id == id } }

    /// Until the request ends, including while its claimed window is still being detected.
    /// A withdrawn claim is kept for detection to see until it expires.
    func deadline(forIntent id: Int) -> TimeInterval? {
        intents.first { $0.id == id }?.deadlineUptime
            ?? claims.values.first { $0.intent.id == id }.map { $0.claimedUptime + newWindowIntentTimeout }
            ?? deferredPlacements[id].map { $0.claim.claimedUptime + newWindowIntentTimeout }
    }

    /// Waits for the restores under way, within the claim's deadline.
    func deferPlacement(_ placement: DeferredReopenPlacement) {
        deferredPlacements[placement.claim.intent.id] = placement
    }

    /// A reopen claimed this window for a tab and hasn't finished: restores leave it alone.
    func holdsReopenClaim(on window: Window) -> Bool {
        reopenClaimTarget(for: window) != nil
    }

    /// The tab a reopen that hasn't finished claimed this window for.
    func reopenClaimTarget(for window: Window) -> Workspace? {
        if let claim = claims[window.windowId], claim.intent.reopens, !claim.isWithdrawn { return claim.targetWorkspace }
        return deferredPlacements.values.first { $0.window === window }?.claim.targetWorkspace
    }

    /// The placements to finish now, in the order they were claimed.
    func takeDeferredPlacements() -> [DeferredReopenPlacement] {
        defer { deferredPlacements = [:] }
        return deferredPlacements.values.sorted { $0.claim.claimedUptime < $1.claim.claimedUptime }
    }

    /// The app's window is already placed for a tab, waiting for restores to end.
    func hasDeferredPlacement(bundleId: String) -> Bool {
        deferredPlacements.values.contains { $0.claim.intent.bundleId == bundleId }
    }

    func expireOverdueIntents() {
        let time = now()
        let overdue = intents.filter { $0.deadlineUptime < time }
        intents.removeAll { $0.deadlineUptime < time }
        for intent in overdue {
            // A tab closed meanwhile has nothing left to report to.
            let destination = winMuxWorkspaceState.workspaceById[intent.targetWorkspaceId]
            finish(intent, destination.map { !$0.isArchived } == true ? .timedOut : .cancelled)
        }
        // Detection that failed partway never consumes its claim; don't leave the request waiting.
        let stale = claims.filter { $0.value.claimedUptime + newWindowIntentTimeout < time }
        for (windowId, claim) in stale {
            claims.removeValue(forKey: windowId)
            finish(claim.intent, .failed("WinMux couldn't place the new window"))
        }
        // Restores that never end within the claim's time: the window stays where they left it.
        let waitedTooLong = deferredPlacements.filter { $0.value.claim.claimedUptime + newWindowIntentTimeout < time }
        for (id, deferred) in waitedTooLong {
            deferredPlacements.removeValue(forKey: id)
            let target = deferred.claim.targetWorkspace
            // A tab closed meanwhile has nothing left to report to.
            let tabRemains = winMuxWorkspaceState.workspaceById[target.id] === target && !target.isArchived
            finish(deferred.claim.intent, tabRemains ? .failed("WinMux couldn't place the new window") : .cancelled)
        }
    }

    func resetForTests() {
        intents = []
        claims = [:]
        deferredPlacements = [:]
        resetFrozenRestoresForTests()
        windowsBeingDetected = []
        now = { ProcessInfo.processInfo.systemUptime }
        isRestorationCandidate = { windowId in
            persistedFrozenWorldContains(windowId: windowId) || closedWindowsCacheContains(windowId: windowId)
        }
        isProcessAlive = { pid in NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false }
        isRegistered = { window in MacWindow.allWindowsMap[window.windowId] === window }
    }

    private func finish(_ intent: NewWindowIntent, _ outcome: NewWindowRequestOutcome) {
        let completion = intent.completion
        intent.completion = nil
        completion?(outcome)
    }
}

/// Binding for a window an intent claimed: appended to the target workspace, tiled or
/// floating per the usual setting, and never auto-added to a stack.
@MainActor
func newWindowIntentBinding(targetWorkspace: Workspace) -> BindingData {
    config.automaticallyTileNewWindows
        ? workspaceAppendBindingData(targetWorkspace: targetWorkspace, index: INDEX_BIND_LAST)
        : BindingData(parent: targetWorkspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
}

/// Whether the user is still where they were when they chose the app. Focus that went to a
/// permission prompt and came back to the same workspace and window isn't moving on, as long
/// as focus hadn't moved before the request was sent either. A tab that had no window then has
/// `placing` now: focus on it is focus on that tab still, as after switching project with a pin in
/// All Projects on screen.
@MainActor
func newWindowIntentMayTakeFocus(_ intent: NewWindowIntent, placing window: Window? = nil) -> Bool {
    if focusChangeGeneration == intent.focusGeneration { return true }
    guard let sent = intent.focusWhenSent, sent.generation == intent.focusGeneration else { return false }
    return focus.workspace === sent.workspace
        && (focus.windowOrNil === sent.window || sent.window == nil && window != nil && focus.windowOrNil === window)
}

/// A claimed window keeps its destination: saved-workspace routing, on-window-detected rules,
/// and the new-workspace option are skipped, as for windows saved workspaces place. It takes
/// focus unless the user moved on while it was opening. The request then completes.
@MainActor
func finishNewWindowIntentPlacement(_ window: Window, claim: NewWindowIntentClaim, broadcastsDetection: Bool = true) {
    // Another registration may have bound it by the usual rules first.
    if window.nodeWorkspace !== claim.targetWorkspace {
        let binding = newWindowIntentBinding(targetWorkspace: claim.targetWorkspace)
        window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
    }
    if broadcastsDetection { broadcastWindowDetected(window) }
    // A restore under way works from a snapshot older than this placement, across its AX waits, and
    // would put a reopened window back where it was before it closed. It's finished once they end.
    if claim.intent.reopens, activeFrozenRestoreCount > 0 {
        NewWindowIntentRegistry.shared.deferPlacement(DeferredReopenPlacement(window: window, claim: claim))
        return
    }
    if newWindowIntentMayTakeFocus(claim.intent, placing: window), window.nodeWorkspace?.isVisible == true, window.focusWindow() {
        // The launcher made WinMux frontmost, and neither scripted nor reopened windows activate their app.
        window.nativeFocus()
    }
    // Snapshots kept to restore other windows still have a reopened window where it was before it
    // closed; they mustn't take it back or switch the display away from the tab that asked.
    if claim.intent.reopens { noteExplicitWindowPlacement(window, in: claim.targetWorkspace) }
    NewWindowIntentRegistry.shared.completeClaim(claim, window: window)
}

/// The last restore under way ended: each reopened window placed meanwhile is finished where it is,
/// if its tab and request still stand. Restores left it alone, so it's in its tab unless the user
/// moved it, which stands. It takes focus, and shows its tab again, only if the user hasn't moved
/// on. Synchronous, so it never waits on the restore that called it.
@MainActor
func finishDeferredReopenPlacements() {
    let registry = NewWindowIntentRegistry.shared
    // A placement past its deadline is over, however late the expiry watcher wakes.
    registry.expireOverdueIntents()
    for deferred in registry.takeDeferredPlacements() {
        let window = deferred.window
        let claim = deferred.claim
        let target = claim.targetWorkspace
        guard !claim.isWithdrawn else { continue }
        guard winMuxWorkspaceState.workspaceById[target.id] === target, !target.isArchived, registry.isRegistered(window)
        else {
            // The tab or the window went meanwhile; the window stays where it is.
            registry.cancel(claim: claim)
            continue
        }
        guard window.nodeWorkspace === target else {
            // The user moved it since, or it went native full screen or minimized; it stays as it is.
            registry.cancel(claim: claim)
            continue
        }
        // A restore may have shown another tab where the user was looking at this one.
        let userWasHere = target.isVisible || claim.intent.focusWhenSent?.workspace === target
        if newWindowIntentMayTakeFocus(claim.intent, placing: window), userWasHere {
            showPinInAllProjectsWhereItWasClicked(target, claim.intent)
            if window.focusWindow() { window.nativeFocus() }
        }
        noteExplicitWindowPlacement(window, in: target)
        registry.completeClaim(claim, window: window)
    }
}

/// A pin in All Projects shows in the project its display is in, which a restore that showed
/// another project's tab there meanwhile has changed: it comes back in the project it was clicked
/// in, which remembers it as chosen there again, or the one switched to since with it on screen,
/// where nothing was chosen. Only on the display that was in it: on another one, where an older
/// restore took the pin, it shows in that display's own project, and is chosen there neither.
@MainActor
private func showPinInAllProjectsWhereItWasClicked(_ target: Workspace, _ intent: NewWindowIntent) {
    guard workspaceIsPinnedInAllProjects(target) else { return }
    let monitor = target.workspaceMonitor
    if let (projectId, isChosen) = projectThePinWasShownIn(on: monitor, intent.focusWhenSent, target: target),
       winMuxWorkspaceState.projectsById[projectId] != nil {
        _ = monitor.setActiveWorkspace(target, contextProjectId: projectId, isChosen: isChosen)
    } else {
        _ = monitor.setActiveWorkspace(target, isChosen: false)
    }
}

/// The project a reopen's pin in All Projects was shown in on `monitor`, and whether it was chosen
/// there: the one it was clicked in, or switched to since with it on screen. Nil on another display.
@MainActor
private func projectThePinWasShownIn(on monitor: Monitor, _ sent: NewWindowFocusSnapshot?,
                                     target: Workspace) -> (WorkspaceProjectId, isChosen: Bool)? {
    guard let sent, sent.workspace === target else { return nil }
    let isWhereItWasClicked = sent.display?.isShown(by: monitor) == true
    if let switched = sent.switchedProjectId {
        guard sent.switchedDisplay?.isShown(by: monitor) == true else { return nil }
        // Switching back to the project it was clicked in, where it was clicked, is that choice again.
        return (switched, switched == sent.contextProjectId && isWhereItWasClicked)
    }
    guard isWhereItWasClicked, let clicked = sent.contextProjectId else { return nil }
    return (clicked, true)
}

/// The launcher closed after the window was claimed but before detection placed it: it goes
/// where any new window would, not into a workspace the user may have left.
@MainActor
func placeWithdrawnNewWindow(_ window: Window, claim: NewWindowIntentClaim) {
    guard window.nodeWorkspace === claim.targetWorkspace else { return }
    let binding = bindingDataForNewRegularWindow(focus.workspace, window: window)
    window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
}

/// This registration claimed the window, but another registration of the same window got it
/// into the tree first. A detection still in progress settles the claim, at its claim check or
/// when it finishes; otherwise it's settled here.
@MainActor
func settleClaimAfterConcurrentRegistration(_ window: Window) {
    guard !NewWindowIntentRegistry.shared.windowsBeingDetected.contains(window.windowId) else { return }
    settleClaimLeftAfterDetection(window)
}

/// A claim made after detection checked for one: the window still goes where it was asked
/// for, overriding what the usual rules did with it. Detection already announced it.
@MainActor
func settleClaimLeftAfterDetection(_ window: Window) {
    guard let claim = NewWindowIntentRegistry.shared.consumeClaim(windowId: window.windowId), !claim.isWithdrawn else { return }
    finishNewWindowIntentPlacement(window, claim: claim, broadcastsDetection: false)
}
