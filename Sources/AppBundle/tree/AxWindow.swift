import AppKit

final class AxWindow {
    let windowId: UInt32
    let ax: AXUIElement
    private let axSubscriptions: [AxSubscription]
    // Created, used and released on this window's owning AX thread.
    var browserTabScanner: BrowserTabScanner<NativeBrowserTabNode>?
    var browserTabObservation: BrowserTabAXObservation?
    /// What the app made of the size WinMux last asked for.
    var frameFit = WindowFrameFit()
    /// Refreshes in a row the window server hasn't listed it while its app was busy (`windowLivenessVerdict`).
    var windowServerAbsences = 0
    /// Its element answers for nothing, and no fresh one could be taken yet (`refreshRegisteredAxWindows`): no frame is
    /// written to it until it's rebound.
    var isUnbound = false
    /// When it was registered (`RegisteredWindowLiveness`); a rebound one keeps the stale one's.
    private(set) var livenessStamp = nextWindowLivenessStamp()

    private init(windowId: UInt32, _ ax: AXUIElement, _ axSubscriptions: [AxSubscription]) {
        self.windowId = windowId
        self.ax = ax
        assert(!axSubscriptions.isEmpty)
        self.axSubscriptions = axSubscriptions
    }

    /// The same window under a fresh element, when the one it was registered with went stale and the app lists it under
    /// another: subscribed anew, keeping what was learned of the window itself (its frame fit). Only the window itself:
    /// not a sheet or another attached element listed with its id, nor an open/save panel, as `getOrRegisterAxWindow`.
    static func rebound(_ stale: AxWindow, to ax: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        if nsApp.bundleIdentifier == KnownBundleId.openAndSavePanelService.rawValue || ax.isAttachedTransientHeuristic() {
            return nil
        }
        guard let fresh = try new(windowId: stale.windowId, ax, nsApp, job) else { return nil }
        fresh.frameFit = stale.frameFit
        fresh.livenessStamp = stale.livenessStamp
        return fresh
    }

    static func new(windowId: UInt32, _ ax: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        // The 1s messaging-timeout cap set on the app element does not extend to window
        // elements — they'd use the 6s global default, so one CPU-starved app with N windows
        // could stall its AX thread for 6×N seconds per refresh.
        AXUIElementSetMessagingTimeout(ax, 1.0)
        let handlers: HandlerToNotifKeyMapping = [
            (refreshObs, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
            (movedObs, [kAXMovedNotification]),
            (resizedObs, [kAXResizedNotification]),
        ]
        let subscriptions = try AxSubscription.bulkSubscribe(nsApp, ax, job, handlers)
        return !subscriptions.isEmpty ? AxWindow(windowId: windowId, ax, subscriptions) : nil
    }
}

extension AxWindow: RegisteredWindowLiveness {
    func containingWindowIdWithError() -> (windowId: CGWindowID?, error: AXError) { ax.containingWindowIdWithError() }
}
