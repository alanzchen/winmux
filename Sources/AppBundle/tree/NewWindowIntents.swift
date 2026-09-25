import AppKit
import Common

/// How long a requested window has to appear before the request gives up.
let newWindowIntentTimeout: TimeInterval = 8

enum NewWindowRequestOutcome: Equatable {
    case placed(windowId: UInt32)
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
    let targetWorkspaceName: String
    /// The app's windows before the request; none of them is the requested window.
    let preexistingWindowIds: Set<UInt32>
    let createdUptime: TimeInterval
    let deadlineUptime: TimeInterval
    /// If the user moves focus while waiting, the window is placed without taking focus.
    let focusGeneration: UInt64
    var completion: ((NewWindowRequestOutcome) -> Void)?

    init(id: Int, bundleId: String, pid: Int32?, targetWorkspaceName: String, preexistingWindowIds: Set<UInt32>,
         createdUptime: TimeInterval, deadlineUptime: TimeInterval, focusGeneration: UInt64,
         completion: ((NewWindowRequestOutcome) -> Void)?) {
        self.id = id
        self.bundleId = bundleId
        self.pid = pid
        self.targetWorkspaceName = targetWorkspaceName
        self.preexistingWindowIds = preexistingWindowIds
        self.createdUptime = createdUptime
        self.deadlineUptime = deadlineUptime
        self.focusGeneration = focusGeneration
        self.completion = completion
    }
}

struct NewWindowIntentClaim: Equatable {
    let targetWorkspaceName: String
    let focusGeneration: UInt64
}

@MainActor
final class NewWindowIntentRegistry {
    static let shared = NewWindowIntentRegistry()

    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private(set) var intents: [NewWindowIntent] = []
    /// Windows an intent placed, which detection then leaves where they are.
    private var claims: [UInt32: NewWindowIntentClaim] = [:]
    private var nextId = 1

    var hasPendingIntents: Bool { !intents.isEmpty }

    /// One request per app at a time: two outstanding requests couldn't tell their windows apart.
    func register(
        bundleId: String,
        pid: Int32?,
        targetWorkspaceName: String,
        preexistingWindowIds: Set<UInt32>,
        focusGeneration: UInt64,
        timeout: TimeInterval = newWindowIntentTimeout,
        completion: ((NewWindowRequestOutcome) -> Void)? = nil,
    ) -> NewWindowIntent? {
        expireOverdueIntents()
        guard !intents.contains(where: { $0.bundleId == bundleId }) else { return nil }
        let created = now()
        let intent = NewWindowIntent(id: nextId, bundleId: bundleId, pid: pid, targetWorkspaceName: targetWorkspaceName,
            preexistingWindowIds: preexistingWindowIds, createdUptime: created, deadlineUptime: created + timeout,
            focusGeneration: focusGeneration, completion: completion)
        nextId += 1
        intents.append(intent)
        return intent
    }

    /// The workspace a newly seen window belongs to, if it is the window an intent is waiting
    /// for. Claiming consumes the intent, so an app's other new windows are placed normally.
    func claim(windowId: UInt32, pid: Int32, bundleId: String?, firstSeenUptime: TimeInterval) -> Workspace? {
        expireOverdueIntents()
        guard let bundleId,
              let index = intents.firstIndex(where: { intent in
                  intent.bundleId == bundleId &&
                      (intent.pid == nil || intent.pid == pid) &&
                      !intent.preexistingWindowIds.contains(windowId) &&
                      // A window first seen before the request, promoted from a popup now, isn't it.
                      firstSeenUptime >= intent.createdUptime
              })
        else { return nil }
        let intent = intents[index]
        guard let workspace = Workspace.existing(byName: intent.targetWorkspaceName), !workspace.isArchived else {
            // The destination is gone; never recreate it by name.
            intents.remove(at: index)
            finish(intent, .cancelled)
            return nil
        }
        intents.remove(at: index)
        claims[windowId] = NewWindowIntentClaim(targetWorkspaceName: intent.targetWorkspaceName,
            focusGeneration: intent.focusGeneration)
        finish(intent, .placed(windowId: windowId))
        return workspace
    }

    /// Detection asks once whether an intent placed the window.
    func consumeClaim(windowId: UInt32) -> NewWindowIntentClaim? {
        claims.removeValue(forKey: windowId)
    }

    func setPid(_ pid: Int32, forIntent id: Int) {
        intents.first { $0.id == id }?.pid = pid
    }

    func cancel(intentId id: Int, outcome: NewWindowRequestOutcome = .cancelled) {
        guard let index = intents.firstIndex(where: { $0.id == id }) else { return }
        let intent = intents.remove(at: index)
        finish(intent, outcome)
    }

    func isPending(intentId id: Int) -> Bool { intents.contains { $0.id == id } }

    func expireOverdueIntents() {
        let time = now()
        let overdue = intents.filter { $0.deadlineUptime < time }
        guard !overdue.isEmpty else { return }
        intents.removeAll { $0.deadlineUptime < time }
        for intent in overdue { finish(intent, .timedOut) }
    }

    func resetForTests() {
        intents = []
        claims = [:]
        now = { ProcessInfo.processInfo.systemUptime }
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

/// A claimed window keeps its destination: saved-workspace routing, on-window-detected rules,
/// and the new-workspace option are skipped, as for windows saved workspaces place. It takes
/// focus unless the user moved on while it was opening.
@MainActor
func finishNewWindowIntentPlacement(_ window: Window, claim: NewWindowIntentClaim) {
    broadcastWindowDetected(window)
    guard focusChangeGeneration == claim.focusGeneration, window.nodeWorkspace?.isVisible == true else { return }
    _ = window.focusWindow()
}
