import AppKit
import Common

/// The one way WinMux gets ready to quit, however it quits: Quit WinMux, the CLI, a handled signal, die(), or
/// NSApp.terminate from anywhere else, as a Sparkle update installing or logging out does. Those reach AppKit's
/// willTerminate without going through Quit WinMux. It runs once: Quit WinMux prepares and then terminates,
/// which posts willTerminate too.
@MainActor
final class TerminationPreparation {
    static let shared = TerminationPreparation(prepare: prepareWinMuxForTermination)

    private let prepare: @MainActor () -> Void
    private(set) var hasRun = false
    private var observer: NSObjectProtocol?

    init(prepare: @escaping @MainActor () -> Void) {
        self.prepare = prepare
    }

    func run() {
        guard !hasRun else { return }
        hasRun = true
        prepare()
    }

    /// Prepares when `center` says the app will terminate. AppKit posts it on the main thread and exits once
    /// observers return, so this runs there, before returning.
    func observeTermination(on center: NotificationCenter) {
        if let observer { center.removeObserver(observer) }
        observer = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
    }
}

/// Saves what WinMux restores after it starts again (window-state.json, saved workspaces) and puts the windows it
/// manages back on screen. Synchronous, on the main thread (upstream 8b236f1b): an awaiting handler deadlocked when
/// die() ran on the main thread.
@MainActor
private func prepareWinMuxForTermination() {
    if TrayMenuModel.shared.accessibilityPermissionStatus == .granted {
        SystemDockCoordinator.shared.shutdown()
        prepareManagedWindowsForTermination()
    }
    if isDebug {
        let semaphore = DispatchSemaphore(value: 0)
        // Task.detached doesn't inherit @MainActor, which would deadlock here.
        Task.detached {
            await toggleReleaseServerIfDebug(.on)
            semaphore.signal()
        }
        semaphore.wait()
    }
}
