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
    /// never receives an old request's window.
    let targetWorkspaceId: WorkspaceId
    /// Every window the app had before the request, registered with WinMux or not.
    let preexistingWindowIds: Set<UInt32>
    let createdUptime: TimeInterval
    var deadlineUptime: TimeInterval
    /// If the user moves focus while waiting, the window is placed without taking focus.
    let focusGeneration: UInt64
    /// Where focus was when the request went to the app, which may show a permission prompt.
    var focusWhenSent: NewWindowFocusSnapshot?
    var completion: ((NewWindowRequestOutcome) -> Void)?
    /// Withdrawn after its window was claimed: the window then follows the usual rules.
    var isCancelled = false

    init(id: Int, bundleId: String, pid: Int32?, targetWorkspaceId: WorkspaceId, preexistingWindowIds: Set<UInt32>,
         createdUptime: TimeInterval, deadlineUptime: TimeInterval, focusGeneration: UInt64,
         completion: ((NewWindowRequestOutcome) -> Void)?) {
        self.id = id
        self.bundleId = bundleId
        self.pid = pid
        self.targetWorkspaceId = targetWorkspaceId
        self.preexistingWindowIds = preexistingWindowIds
        self.createdUptime = createdUptime
        self.deadlineUptime = deadlineUptime
        self.focusGeneration = focusGeneration
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
    private(set) var intents: [NewWindowIntent] = []
    private var claims: [UInt32: NewWindowIntentClaim] = [:]
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
        completion: ((NewWindowRequestOutcome) -> Void)? = nil,
    ) -> NewWindowIntent? {
        expireOverdueIntents()
        guard !intents.contains(where: { $0.bundleId == bundleId }) else { return nil }
        let created = now()
        let intent = NewWindowIntent(id: nextId, bundleId: bundleId, pid: pid, targetWorkspaceId: targetWorkspace.id,
            preexistingWindowIds: preexistingWindowIds, createdUptime: created, deadlineUptime: created + timeout,
            focusGeneration: focusGeneration, completion: completion)
        nextId += 1
        intents.append(intent)
        return intent
    }

    /// Reserves a newly seen window for the intent waiting for it and returns its workspace.
    /// The intent is consumed, so the app's other new windows are placed normally.
    func claim(windowId: UInt32, pid: Int32, bundleId: String?, firstSeenUptime: TimeInterval) -> Workspace? {
        expireOverdueIntents()
        guard let bundleId, !isRestorationCandidate(windowId),
              let index = intents.firstIndex(where: { intent in
                  intent.bundleId == bundleId &&
                      (intent.pid == nil || intent.pid == pid) &&
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

    /// Ends the request once detection knows where its window went.
    func completeClaim(_ claim: NewWindowIntentClaim, window: Window) {
        finish(claim.intent, window.nodeWorkspace === claim.targetWorkspace
            ? .placed(windowId: window.windowId)
            : .failed("The new window went to another workspace"))
    }

    func setPid(_ pid: Int32, forIntent id: Int) {
        intents.first { $0.id == id }?.pid = pid
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
    }

    func expireOverdueIntents() {
        let time = now()
        let overdue = intents.filter { $0.deadlineUptime < time }
        intents.removeAll { $0.deadlineUptime < time }
        for intent in overdue { finish(intent, .timedOut) }
        // Detection that failed partway never consumes its claim; don't leave the request waiting.
        let stale = claims.filter { $0.value.claimedUptime + newWindowIntentTimeout < time }
        for (windowId, claim) in stale {
            claims.removeValue(forKey: windowId)
            finish(claim.intent, .failed("WinMux couldn't place the new window"))
        }
    }

    func resetForTests() {
        intents = []
        claims = [:]
        windowsBeingDetected = []
        now = { ProcessInfo.processInfo.systemUptime }
        isRestorationCandidate = { windowId in
            persistedFrozenWorldContains(windowId: windowId) || closedWindowsCacheContains(windowId: windowId)
        }
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
    if newWindowIntentMayTakeFocus(claim.intent), window.nodeWorkspace?.isVisible == true, window.focusWindow() {
        // The launcher made WinMux frontmost and scripted windows don't activate their app.
        window.nativeFocus()
    }
    NewWindowIntentRegistry.shared.completeClaim(claim, window: window)
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
