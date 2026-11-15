import AppKit
import Common
import HotKey

/// WinMux's part of GlobalObserver: app-activation, Space and wake bookkeeping, and the pointer, drag, key and
/// modifier monitors behind the sidebar, tab strips, drag/resize engine and tap/sequence bindings.
extension GlobalObserver {
    @MainActor fileprivate static var isInitialized = false
    @MainActor fileprivate static var eventMonitorTokens: [Any] = []
    @MainActor fileprivate static var menuTrackingPointerMonitor: MenuTrackingPointerMonitor?

    // NSEvent monitor callbacks arrive on the main thread. Running their bodies synchronously
    // instead of spawning a Task avoids an allocation + run-loop hop per input event — pointer
    // events fire at 60-120Hz, so the Task-per-event pattern adds constant latency and churn.
    fileprivate static func runOnMainActor(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    fileprivate static func onKeyDown(_ event: NSEvent) {
        let keyCode = event.keyCode
        let modifierFlags = event.modifierFlags
        runOnMainActor {
            // Another app's Escape can't be taken, but still cancels a sidebar drag.
            _ = workspaceSidebarHandleEscapeDuringDrag(keyCode: Int64(keyCode))
            noteTapBindingKeyDown()
            SystemDockCoordinator.shared.noteKeyboardActivity(keyCode: keyCode, modifierFlags: modifierFlags)
        }
    }

    fileprivate static func onFlagsChanged(_ event: NSEvent) {
        let keyCode = event.keyCode
        let modifierFlags = event.modifierFlags
        runOnMainActor {
            noteTapBindingFlagsChanged(keyCode: keyCode, modifierFlags: modifierFlags)
            // Option toggles whether a tab dragged in Tabs mode stacks; show it without a move.
            refreshActiveWorkspaceSidebarDragPreviewIfNeeded()
        }
    }

    static func onPointerActivity(_ event: NSEvent) {
        let isLeftMouseDownEvent = event.type == .leftMouseDown
        let timestamp = event.timestamp
        let screenPoint = NSEvent.mouseLocation
        let point = normalizeAppKitScreenPoint(screenPoint)
        runOnMainActor {
            if isLeftMouseDownEvent {
                WorkspaceSidebarDragSessions.shared.noteLeftMouseDown()
                noteLeftMousePressBoundaryForDragRefresh()
            }
            MousePointerTracker.shared.note(point: point, timestamp: timestamp)
            WorkspaceSidebarPanel.trapCursorForVisiblePanelsIfNeeded()
            // Edge hold may have warped the cursor back onto this display.
            let current = MousePointerTracker.shared.currentSample.point
            WorkspaceSidebarPanel.noteHoverPointerActivityForVisiblePanels(timestamp: timestamp,
                screenPoint: CGPoint(x: current.x, y: mainMonitor.height - current.y))
            if isLeftMouseDownEvent {
                Task { @MainActor in
                    await WindowMouseInteractionDriver.shared.capturePendingResizeCandidate()
                }
            }
            noteTapBindingKeyDown()
        }
    }

    /// Event monitors are kept for the app's lifetime ("Keep key listeners alive", 9d693761).
    @MainActor static func retainEventMonitor(_ monitor: Any?) {
        guard let monitor else { return }
        eventMonitorTokens.append(monitor)
    }
}

extension WinMuxHooks {
    /// First thing in `GlobalObserver.initObserver`: installs once (later calls return false), then the window
    /// gesture, the front-window watcher and the frontmost app's activation, before any observer is added.
    @MainActor
    static func globalObserverWillInstall() -> Bool {
        guard !GlobalObserver.isInitialized else { return false }
        GlobalObserver.isInitialized = true
        DoubleSidedWindowGesture.shared.install()
        startSystemFrontWindowWatcher()
        // The app in use is taken as active since now: it became so earlier, which only makes this stricter.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { noteAppActivatedForAuxiliaryWindows(pid: pid) }
        return true
    }

    /// In `GlobalObserver.onNotif`, synchronously on the main queue, before the refresh is scheduled. Returns the
    /// activated app's pid for an activation notification.
    static func globalObserverNotification(_ notification: Notification) -> pid_t? {
        let notifName = notification.name.rawValue
        let activatedAppPid = notifName == NSWorkspace.didActivateApplicationNotification.rawValue
            ? (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            : nil
        if activatedAppPid != nil { nativeFocusEvents.note() }
        if notifName == NSWorkspace.activeSpaceDidChangeNotification.rawValue {
            MainActor.assumeIsolated { lastActiveSpaceChangeUptime = ProcessInfo.processInfo.systemUptime }
        }
        // At once, on the main queue it's delivered on: a window that app opens next is judged by it.
        if let activatedAppPid { MainActor.assumeIsolated { noteAppActivatedForAuxiliaryWindows(pid: activatedAppPid) } }
        if notifName == NSWorkspace.didWakeNotification.rawValue || notifName == NSWorkspace.screensDidWakeNotification.rawValue {
            // Before the refresh this schedules lays windows out.
            MainActor.assumeIsolated { MonitorConfigurationObserver.shared.noteScreensWoke() }
        }
        return activatedAppPid
    }

    /// Last in `GlobalObserver.initObserver`: the local mouse-up, drag, pointer, modifier and key monitors.
    @MainActor
    static func installGlobalObserverMonitors() {
        typealias G = GlobalObserver
        G.retainEventMonitor(NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            // Local drops are not observed by the global monitor. Dispatch after
            // SwiftUI handles the event; cleanup is idempotent if onEnded ran first.
            Task { @MainActor in
                noteLeftMousePressBoundaryForDragRefresh()
                finishWorkspaceSidebarDragAfterMouseUp()
            }
            return event
        })

        G.retainEventMonitor(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { event in
            let timestamp = event.timestamp
            let point = normalizeAppKitScreenPoint(NSEvent.mouseLocation)
            G.runOnMainActor {
                MousePointerTracker.shared.note(point: point, timestamp: timestamp)
                WorkspaceSidebarPanel.trapCursorForVisiblePanelsIfNeeded()
                refreshPendingWindowDragIntentFromGlobalMouseDrag()
            }
        })

        let pointerActivityMask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel,
        ]
        let pointerMonitor = MenuTrackingPointerMonitor(
            installMonitor: { NSEvent.addGlobalMonitorForEvents(matching: pointerActivityMask, handler: G.onPointerActivity) },
            removeMonitor: { NSEvent.removeMonitor($0) },
            didResume: {
                // Closing with Escape can leave the pointer stationary over the Dock.
                // Resample input now; defer hover until the close notifications settle.
                let screenPoint = NSEvent.mouseLocation
                MousePointerTracker.shared.note(point: normalizeAppKitScreenPoint(screenPoint))
                SystemDockCoordinator.shared.notePointerActivity(screenPoint)
                WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
            })
        G.menuTrackingPointerMonitor = pointerMonitor
        pointerMonitor.start()
        G.retainEventMonitor(NSEvent.addLocalMonitorForEvents(matching: pointerActivityMask) { event in
            G.onPointerActivity(event)
            return event
        })

        G.retainEventMonitor(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: G.onFlagsChanged))
        G.retainEventMonitor(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            G.onFlagsChanged(event)
            return event
        })

        G.retainEventMonitor(NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: G.onKeyDown))
        G.retainEventMonitor(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Before sequence bindings, whose prefix keys include Escape.
            if event.keyCode == 53, isWorkspaceSidebarDragSessionActive() {
                _ = workspaceSidebarHandleEscapeDuringDrag(keyCode: 53)
                return nil
            }
            G.onKeyDown(event)
            // Check if this key matches a recently-pressed prefix (sequence binding)
            if handleSequenceKeyDown(event: event) {
                return nil // consume the event
            }
            // If this is a sequence prefix key (e.g. Escape), arm the sequence detector
            if let prefix = Key(carbonKeyCode: UInt32(event.keyCode)),
               sequenceBindingsPrefixKeys.contains(prefix) {
                noteSequencePrefixKeyPressed(prefix)
            }
            if event.modifierFlags.contains(.control), event.keyCode == 34 {
                return nil // consume the event
            }
            return event
        })
    }
}
