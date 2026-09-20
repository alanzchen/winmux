import AppKit

/// AppKit's global mouse-move monitor can delay native menu highlights even
/// with an empty handler. Remove that monitor while this app tracks a menu;
/// skipping its callback's work does not fix event delivery.
@MainActor
final class MenuTrackingPointerMonitor {
    private let center: NotificationCenter
    private let installMonitor: () -> Any?
    private let removeMonitor: (Any) -> Void
    private let didResume: () -> Void
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var trackingMenus: Set<ObjectIdentifier> = []

    init(center: NotificationCenter = .default,
         installMonitor: @escaping () -> Any?,
         removeMonitor: @escaping (Any) -> Void,
         didResume: @escaping () -> Void) {
        self.center = center
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor
        self.didResume = didResume
    }

    /// The application retains this owner for its lifetime. A shorter-lived
    /// owner must call stop() before releasing it, just like NSEvent monitors.
    func start() {
        guard observers.isEmpty else { return }
        observers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
                guard let menu = note.object as? NSMenu else { return }
                let id = ObjectIdentifier(menu)
                MainActor.assumeIsolated { self?.beginTracking(id) }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] note in
                guard let menu = note.object as? NSMenu else { return }
                let id = ObjectIdentifier(menu)
                MainActor.assumeIsolated { self?.endTracking(id) }
            },
        ]
        monitor = installMonitor()
    }

    func stop() {
        observers.forEach(center.removeObserver)
        observers = []
        trackingMenus = []
        removeCurrentMonitor()
    }

    private func beginTracking(_ id: ObjectIdentifier) {
        trackingMenus.insert(id)
        removeCurrentMonitor()
    }

    private func endTracking(_ id: ObjectIdentifier) {
        guard trackingMenus.remove(id) != nil, trackingMenus.isEmpty else { return }
        monitor = installMonitor()
        didResume()
    }

    private func removeCurrentMonitor() {
        guard let monitor else { return }
        removeMonitor(monitor)
        self.monitor = nil
    }
}
