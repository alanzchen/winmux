import AppKit

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

    private init() {}

    func prepareForStartup() {
        refreshMonitorPolicy(refreshReason: "MonitorConfigurationObserver.prepareForStartup")
    }

    func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
        ) { _ in
            Task { @MainActor in
                MonitorConfigurationObserver.shared.handleScreenParametersChanged()
            }
        }
    }

    private func handleScreenParametersChanged() {
        topologyGeneration &+= 1
        isSettling = true
        refreshMonitorPolicy(refreshReason: NSApplication.didChangeScreenParametersNotification.rawValue)
        scheduleSettledRefresh()
    }

    func noteDisplayChangeForTests() { topologyGeneration &+= 1 }

    private func refreshMonitorPolicy(refreshReason: String) {
        WorkspaceSidebarPanel.refreshAll()
        WindowTabStripPanelController.shared.refresh()
        if TrayMenuModel.shared.isEnabled {
            scheduleRefreshSession(.globalObserver(refreshReason))
        }
    }

    private func scheduleSettledRefresh() {
        screenChangeGeneration += 1
        let generation = screenChangeGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard generation == screenChangeGeneration else { return }
            isSettling = false
            refreshMonitorPolicy(refreshReason: "\(NSApplication.didChangeScreenParametersNotification.rawValue).settled")
        }
    }
}
