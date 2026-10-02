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

/// A reopened window placed while a frozen-world restore was under way. The restore works from an
/// older snapshot and may still move it, so the placement is finished once no restore is left.
@MainActor
struct DeferredReopenPlacement {
    let window: Window
    let claim: NewWindowIntentClaim
    /// Where and how the request put the window, which a restore may change.
    let parent: NonLeafTreeNodeObject?
    let isFullscreen: Bool
    let noOuterGapsInFullscreen: Bool
    let layoutReason: LayoutReason
    /// The workspaces that restores under way meanwhile remember the window in: a restore can only
    /// put it back there. A move anywhere else is the user's.
    private(set) var restoreDestinations: Set<String> = []

    init(window: Window, claim: NewWindowIntentClaim) {
        self.window = window
        self.claim = claim
        parent = window.parent
        isFullscreen = window.isFullscreen
        noOuterGapsInFullscreen = window.noOuterGapsInFullscreen
        layoutReason = window.layoutReason
    }

    mutating func noteRestore(of frozenWorld: FrozenWorld) {
        if let name = frozenWorkspaceName(remembering: window.windowId, in: frozenWorld) { restoreDestinations.insert(name) }
    }
}

/// Where focus was when WinMux sent the request to the app.
@MainActor
struct NewWindowFocusSnapshot {
    let generation: UInt64
    let workspace: Workspace
    let window: Window?

    static var current: NewWindowFocusSnapshot {
        NewWindowFocusSnapshot(generation: focusChangeGeneration, workspace: focus.workspace, window: focus.windowOrNil)
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
    func deferPlacement(_ placement: DeferredReopenPlacement, restoresUnderWay: [FrozenWorld]) {
        var placement = placement
        for frozenWorld in restoresUnderWay { placement.noteRestore(of: frozenWorld) }
        deferredPlacements[placement.claim.intent.id] = placement
    }

    /// A restore begins before the waiting placements are finished; it may put their windows back.
    func noteRestoreBegan(_ frozenWorld: FrozenWorld) {
        for id in deferredPlacements.keys { deferredPlacements[id]?.noteRestore(of: frozenWorld) }
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
/// as focus hadn't moved before the request was sent either.
@MainActor
func newWindowIntentMayTakeFocus(_ intent: NewWindowIntent) -> Bool {
    if focusChangeGeneration == intent.focusGeneration { return true }
    guard let sent = intent.focusWhenSent, sent.generation == intent.focusGeneration else { return false }
    return focus.workspace === sent.workspace && focus.windowOrNil === sent.window
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
        NewWindowIntentRegistry.shared.deferPlacement(DeferredReopenPlacement(window: window, claim: claim),
            restoresUnderWay: frozenWorldsBeingRestored)
        return
    }
    if newWindowIntentMayTakeFocus(claim.intent), window.nodeWorkspace?.isVisible == true, window.focusWindow() {
        // The launcher made WinMux frontmost, and neither scripted nor reopened windows activate their app.
        window.nativeFocus()
    }
    // Snapshots kept to restore other windows still have a reopened window where it was before it
    // closed; they mustn't take it back or switch the display away from the tab that asked.
    if claim.intent.reopens { noteExplicitWindowPlacement(window, in: claim.targetWorkspace) }
    NewWindowIntentRegistry.shared.completeClaim(claim, window: window)
}

/// The last restore under way ended: each reopened window placed meanwhile goes back where and as
/// the request put it, if its tab and request still stand and a restore, not the user, moved it.
/// It takes focus, and shows its tab again, only if the user hasn't moved on. Synchronous, so it
/// never waits on the restore that called it.
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
        // Still the window that was placed, closed neither in WinMux nor in a replaced registration.
        guard winMuxWorkspaceState.workspaceById[target.id] === target, !target.isArchived, window.isBound,
              Window.get(byId: window.windowId).map({ $0 === window }) ?? true
        else {
            // The tab or the window went meanwhile; the window stays where it is.
            registry.cancel(claim: claim)
            continue
        }
        let current = window.nodeWorkspace
        let restored = !deferred.restoreDestinations.isEmpty
        // A restore leaves a window only where its snapshot remembers it, or in a root it replaced.
        let putBackByRestore = current == nil ||
            current.map { deferred.restoreDestinations.contains($0.name) && ($0 !== target || window.parent !== deferred.parent) } == true
        if current !== target, !putBackByRestore {
            // The user moved it since; it stays there.
            registry.cancel(claim: claim)
            continue
        }
        if putBackByRestore {
            let binding = newWindowIntentBinding(targetWorkspace: target)
            window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        }
        if restored {
            window.isFullscreen = deferred.isFullscreen
            window.noOuterGapsInFullscreen = deferred.noOuterGapsInFullscreen
            window.layoutReason = deferred.layoutReason
        }
        // The restore may have shown another tab where the user was looking at this one.
        let userWasHere = window.nodeWorkspace?.isVisible == true || claim.intent.focusWhenSent?.workspace === target
        if newWindowIntentMayTakeFocus(claim.intent), userWasHere, window.focusWindow() {
            window.nativeFocus()
        }
        noteExplicitWindowPlacement(window, in: target)
        registry.completeClaim(claim, window: window)
    }
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
