import AppKit
import Common

enum GlobalObserver {
    private static func onNotif(_ notification: Notification) {
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        let activatedAppPid = WinMuxHooks.globalObserverNotification(notification) // WINMUX-HOOK(globalObserverNotification)
        Task { @MainActor in
            if !TrayMenuModel.shared.isEnabled { return }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                scheduleRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true, activatedAppPid: activatedAppPid)
            } else {
                scheduleRefreshSession(.globalObserver(notifName))
            }
        }
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        _ = Task { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       w.macAppUnsafe.nsApp.isHidden,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
                    {
                        // Force focus
                        _ = w.focusWindow()
                        w.nativeFocus()
                    }
                    for app in MacApp.allAppsMap.values {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    @MainActor
    static func initObserver() {
        guard WinMuxHooks.globalObserverWillInstall() else { return } // WINMUX-HOOK(globalObserverWillInstall)
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp)
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif)
        // WINMUX-HOOK-BEGIN(globalObserverWake)
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: onNotif)
        // WINMUX-HOOK-END(globalObserverWake)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif)

        retainEventMonitor(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            // todo reduce number of refreshSession in the callback
            //  resetManipulatedWithMouseIfPossible might call its own refreshSession
            //  The end of the callback calls refreshSession
            _ = Task { @MainActor in
                noteLeftMousePressBoundaryForDragRefresh()
                finishWorkspaceSidebarDragAfterMouseUp()
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                try await resetManipulatedWithMouseIfPossible()
                // Drag-end releases the sidebar expansion locks without any pointer movement;
                // hover must be re-evaluated for a stationary cursor.
                WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
                let mouseLocation = mouseLocation
                let clickedMonitor = mouseLocation.monitorApproximation
                // A sidebar drop already decided where focus goes, whichever display the pointer is on.
                let wasSidebarDrop = takeWorkspaceSidebarConsumedRelease()
                switch true {
                    // Detect desktop clicks on other monitors, excluding menu bars (AeroSpace cfd4eab2).
                    case !wasSidebarDrop && clickedMonitor.visibleRect.contains(mouseLocation) && clickedMonitor.activeWorkspace != focus.workspace:
                        _ = try await runLightSession(.globalObserverLeftMouseUp, token) {
                            clickedMonitor.activeWorkspace.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        scheduleRefreshSession(.globalObserverLeftMouseUp)
                }
            }
        })
        WinMuxHooks.installGlobalObserverMonitors() // WINMUX-HOOK(installGlobalObserverMonitors)
    }
}
