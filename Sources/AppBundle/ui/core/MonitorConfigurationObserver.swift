import AppKit
import Common

@MainActor
final class MonitorConfigurationObserver {
    static let shared = MonitorConfigurationObserver()

    private var observer: NSObjectProtocol?
    private var screenChangeGeneration: UInt64 = 0
    /// True between a display change and the settled refresh. Saved workspaces don't record
    /// display affinity while displays are still reconfiguring.
    private(set) var isSettling = false
    /// Bumped on every display change, so something captured before one can tell.
    private(set) var topologyGeneration: UInt64 = 0
    /// Bumped on every display change, again once displays have settled, and when displays wake: a size an app kept
    /// in a cell before any of these may have been AppKit fitting the window to displays in flux, so it's asked
    /// for again (`WindowFrameFit`).
    private(set) var frameFitEpoch: UInt64 = 0

    private init() {}

    func prepareForStartup() {
        refreshMonitorPolicy(.globalObserver("MonitorConfigurationObserver.prepareForStartup"))
    }

    func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
        ) { _ in
            // Delivered on the main queue. The epoch moves on now, not a turn later: a follow-up already due mustn't pair
            // the new screen indices with the old epoch.
            MainActor.assumeIsolated { MonitorConfigurationObserver.shared.noteScreenParametersChanging() }
            Task { @MainActor in
                MonitorConfigurationObserver.shared.handleScreenParametersChanged()
            }
        }
    }

    /// Lays out for the new displays at once, then, once displays have stopped changing for
    /// `settleDelay`, refreshes again and re-parks hidden windows: macOS may still have moved
    /// them after the first pass (it relocates windows off a display that's gone).
    func handleScreenParametersChanged(settleDelay: Duration = .milliseconds(750)) {
        topologyGeneration &+= 1
        frameFitEpoch &+= 1
        isSettling = true
        refreshMonitorPolicy(.globalObserver(NSApplication.didChangeScreenParametersNotification.rawValue))
        scheduleSettledRefresh(after: settleDelay)
    }

    func noteDisplayChangeForTests() {
        topologyGeneration &+= 1
        frameFitEpoch &+= 1
    }

    /// NSWorkspace.didWake or screensDidWake: displays may come back the same, after macOS moved windows meanwhile.
    func noteScreensWoke() { frameFitEpoch &+= 1 }

    /// NSApplication.didChangeScreenParameters, as it's delivered, ahead of `handleScreenParametersChanged`.
    func noteScreenParametersChanging() { frameFitEpoch &+= 1 }

    private func refreshMonitorPolicy(_ event: RefreshSessionEvent) {
        WorkspaceSidebarPanel.refreshAll()
        WindowTabStripPanelController.shared.refresh()
        if TrayMenuModel.shared.isEnabled {
            scheduleRefreshSession(event)
        }
    }

    private func scheduleSettledRefresh(after delay: Duration) {
        screenChangeGeneration += 1
        let generation = screenChangeGeneration
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            // A newer change has its own settled refresh coming.
            guard generation == screenChangeGeneration else { return }
            isSettling = false
            frameFitEpoch &+= 1
            // Stale (and so not re-parking) if the displays changed again before it runs.
            refreshMonitorPolicy(.displayTopologySettled(generation: topologyGeneration))
        }
    }
}
