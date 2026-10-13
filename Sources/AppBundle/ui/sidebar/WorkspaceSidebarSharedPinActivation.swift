import AppKit

// Shared pins: a pin whose tab is on another display, as its badge shows, is shown there by a
// plain click, where it is, unless `remote-pin-click` says to bring it. ⌘-click always brings it to
// the display clicked. A brought tab moves as a tab dropped on that display's list does, and that
// display is recorded as its own, so it stays listed there. A tab held to its display, by
// `workspace-to-monitor-force-assignment` or a saved tab kept on its display, or with a window in
// full screen, isn't brought: asked to come, by ⌘-click or the setting, it stays, nothing else is
// focused instead, and a notice says why. Showing or bringing one keeps the pointer where it is.
// A pin that isn't anywhere yet, with no windows open, comes to the display clicked, as before.

/// How a shared pin was clicked: plainly, or with ⌘, which always brings it to the display clicked.
enum WorkspaceSidebarSharedPinClick: Equatable {
    case plain
    case command
}

/// What a click on a shared pin does, decided as its session runs.
enum WorkspaceSidebarSharedPinClickPlan: Equatable {
    /// Brought to the clicked display, as a tab dropped on its list.
    case bringHere(monitorScopeId: String)
    /// Shown on its own display, `monitorScopeId`, as a click in that display's list shows it.
    case showThere(monitorScopeId: String)
    /// Asked to come, by ⌘-click or `remote-pin-click`, a pin that can't, held to its display or in
    /// full screen: nothing moves or is focused, and `message` says why.
    case refused(message: String)
    /// Activated as any tab, from the clicked display.
    case here
}

/// The display a shared pin is on when that's another connected display than the clicked one, as
/// its badge says: on screen there, or held, saved or last placed there with windows open, or one
/// in full screen. Nil for one on the clicked display, one that isn't anywhere yet, or one whose
/// display isn't known.
@MainActor
func workspaceSidebarSharedPinRemoteScopeId(_ tab: Workspace, targetMonitorScopeId: String?) -> String? {
    guard config.usesBrowserTabs, config.workspaceSidebar.sharesPinnedTabs,
          workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite == true,
          let targetMonitorScopeId, workspaceSidebarMonitor(forScopeId: targetMonitorScopeId) != nil,
          tab.isVisible || workspaceHasSidebarVisibleWindows(tab) || workspaceTabHasNativeFullscreenWindow(tab),
          let display = workspaceSidebarTabKnownDisplay(tab, among: sortedMonitors),
          display.monitorScopeId != targetMonitorScopeId
    else { return nil }
    return display.monitorScopeId
}

/// What `click` on the shared pin `tab` in the panel for `targetMonitorScopeId` does now.
/// `remoteScopeId` is where it was when that has to be known before the session changes it.
@MainActor
func workspaceSidebarSharedPinClickPlan(_ tab: Workspace, targetMonitorScopeId: String?, click: WorkspaceSidebarSharedPinClick,
                                        remoteScopeId: String?? = nil) -> WorkspaceSidebarSharedPinClickPlan {
    let remote = remoteScopeId ?? workspaceSidebarSharedPinRemoteScopeId(tab, targetMonitorScopeId: targetMonitorScopeId)
    let bringsHere = click == .command || config.workspaceSidebar.remotePinClick == .bringToThisDisplay
    if let remote, !bringsHere { return .showThere(monitorScopeId: remote) }
    if let targetMonitorScopeId, workspaceSidebarSharedPinClickDestination(tab, targetMonitorScopeId: targetMonitorScopeId) != nil {
        return .bringHere(monitorScopeId: targetMonitorScopeId)
    }
    // One asked to come that can't: it stays, and says why.
    if let remote {
        return .refused(message: workspaceSidebarPinStaysMessage(tab, on: remote, targetMonitorScopeId: targetMonitorScopeId))
    }
    return .here
}

/// Why a pin on the display `scopeId`, asked to come to `targetMonitorScopeId`'s, stays there: it's
/// held to another display, or one of its windows is in full screen. Its badge gives the same reason.
@MainActor
func workspaceSidebarPinStaysMessage(_ tab: Workspace, on scopeId: String, targetMonitorScopeId: String?) -> String {
    let name = "“\(workspaceDisplayName(tab.name))”"
    let display = workspaceSidebarMonitor(forScopeId: scopeId)
        .map { "“\(workspaceSidebarMonitorDisplayName($0, among: sortedMonitors))”" } ?? "its display"
    let isHeldElsewhere = workspaceSidebarTabHeldMonitorScopeId(tab).map { $0 != targetMonitorScopeId } ?? false
    if !isHeldElsewhere, workspaceTabHasNativeFullscreenWindow(tab) {
        return "\(name) is in full screen on \(display), so it stays there. Exit full screen to move it."
    }
    return "\(name) is kept on \(display), so it stays there."
}

/// What ⌘-click sends for `action` on the shared pin `pin`: bring it here, focusing the window
/// clicked, or choosing the browser tab clicked once it's here, or first bringing back the windows
/// it lent. Nil for an action that isn't showing it.
func workspaceSidebarBringPinnedTabHereAction(_ action: WorkspaceSidebarAction, pin: String) -> WorkspaceSidebarAction? {
    switch action {
        case .selectWorkspace(let name) where name == pin: .bringPinnedTabHere(pin, windowId: nil, recalls: false)
        case .selectWindow(let windowId): .bringPinnedTabHere(pin, windowId: windowId, recalls: false)
        case .selectBrowserTab(let target): .bringBrowserTabHere(pin, target)
        case .recallPinWindows(let name, let windowId) where name == pin: .bringPinnedTabHere(pin, windowId: windowId, recalls: true)
        default: nil
    }
}

/// Whether a click on this shared pin in a list representing `representedMonitorScopeId` brings
/// it there instead of asking first. One held to another display asks, as other displays' tabs
/// do. The click itself checks again before anything moves.
func workspaceSidebarSharedPinComesToClick(_ workspace: WorkspaceSidebarWorkspaceViewModel, representedMonitorScopeId: String,
                                           sharesPinnedTabs: Bool) -> Bool {
    guard sharesPinnedTabs, workspace.appearance.isFavorite else { return false }
    return workspace.heldMonitorScopeId.map { $0 == representedMonitorScopeId } ?? true
}

/// The display a click in the panel for `targetMonitorScopeId` brings `tab` to: a shared pin on
/// another display, which may go there. Nil when the click activates it where it is, and for one
/// with a window in full screen, which isn't taken out of it.
@MainActor
func workspaceSidebarSharedPinClickDestination(_ tab: Workspace, targetMonitorScopeId: String?) -> Monitor? {
    guard let monitor = workspaceSidebarSharedPinClickMonitor(tab, targetMonitorScopeId: targetMonitorScopeId),
          tab.workspaceMonitor.rect != monitor.rect, !workspaceTabHasNativeFullscreenWindow(tab) else { return nil }
    return monitor
}

/// The clicked panel's display, for a shared pin that may be shown there, wherever it is now.
@MainActor
private func workspaceSidebarSharedPinClickMonitor(_ tab: Workspace, targetMonitorScopeId: String?) -> Monitor? {
    guard config.usesBrowserTabs, config.workspaceSidebar.sharesPinnedTabs,
          workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite == true,
          let targetMonitorScopeId, let monitor = workspaceSidebarMonitor(forScopeId: targetMonitorScopeId),
          workspaceTabCanMove(tab, to: monitor)
    else { return nil }
    return monitor
}

/// Brings `tab` to `monitor` and focuses it there, or `window` in it. The display it leaves shows
/// another tab. If it can't be shown there, everything goes back as it was. `move` is for tests.
@MainActor
func showSharedPinnedTab(_ tab: Workspace, on monitor: Monitor, focusing window: Window?,
                         move: @MainActor (Workspace, Monitor, Window?) throws -> Void = moveWorkspaceTabToDisplay) throws {
    let before = WorkspaceSidebarTabUndoSnapshot()
    do {
        try move(tab, monitor, window)
    } catch {
        before.restore(replacing: WorkspaceSidebarTabUndoSnapshot())
        throw error
    }
}

/// The shared pin a click on `name`, or on the window `windowId`, in the panel for
/// `targetMonitorScopeId` goes to: every one that may be shown on that display, wherever it is
/// when the click comes, since it may move before the click's session runs. Nil for a pin held
/// to another display, and without shared pins: the click activates it as any tab.
@MainActor
func workspaceSidebarSharedPinClicked(_ name: String? = nil, windowId: UInt32? = nil,
                                      targetMonitorScopeId: String?) -> Workspace? {
    // A window that closed just now is found in the sidebar's last list, as any click finds it.
    let tab = name.flatMap { Workspace.existing(byName: $0) } ?? windowId.flatMap {
        Window.get(byId: $0)?.nodeWorkspace ?? workspaceSidebarFallbackWorkspaceName(for: $0).flatMap(Workspace.existing(byName:))
    }
    // One held to another display is shown there, or says why it stays, rather than asking.
    guard let tab, workspaceSidebarSharedPinClickMonitor(tab, targetMonitorScopeId: targetMonitorScopeId) != nil
        || workspaceSidebarSharedPinRemoteScopeId(tab, targetMonitorScopeId: targetMonitorScopeId) != nil
    else { return nil }
    return tab
}

/// A click on the shared pin `tab`, or on its window `windowId`, in the panel for
/// `targetMonitorScopeId`. The session decides where the pin is and what `click` does with it, as
/// `workspaceSidebarSharedPinClickPlan` says. `proceeds`, checked when the session runs, before
/// anything moves, can call it off. `afterShown` runs after the layout, once it's shown.
@MainActor
@discardableResult
func showSharedPinnedTabFromSidebar(_ tab: Workspace, windowId: UInt32? = nil, targetMonitorScopeId: String?,
                                    click: WorkspaceSidebarSharedPinClick = .plain, remoteScopeId: String?? = nil,
                                    proceeds: (@MainActor () -> Bool)? = nil,
                                    afterShown: (@MainActor (Workspace) -> Void)? = nil) -> Task<Void, Never>? {
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    if windowId == nil {
        switch workspaceSidebarSharedPinClickPlan(tab, targetMonitorScopeId: targetMonitorScopeId, click: click,
            remoteScopeId: remoteScopeId) {
            case .showThere, .here: optimisticallyMarkWorkspaceFocusedInSidebar(tab.name)
            case .bringHere, .refused: break
        }
    }
    let name = tab.name
    var shown: Workspace?
    return runWorkspaceSidebarSession(afterLayout: {
        guard let shown, winMuxWorkspaceState.workspaceById[shown.id] === shown else { return }
        afterShown?(shown)
    }) {
        // The session runs after other events: the tab may have closed, moved, or given its name
        // away, and the display it was clicked on may have gone, which leaves everything as it is.
        guard Workspace.existing(byName: name) === tab, proceeds?() ?? true else { return }
        if try performSharedPinClick(tab, windowId: windowId, targetMonitorScopeId: targetMonitorScopeId, click: click,
            remoteScopeId: remoteScopeId) { shown = tab }
    }
}

/// What a click's session does with the shared pin `tab`, as `workspaceSidebarSharedPinClickPlan`
/// says now. True once it's shown; false when nothing changed: a display gone since, a pin held
/// to its own, or a focus refused. A pin that couldn't come isn't focused where it is instead.
@MainActor
func performSharedPinClick(_ tab: Workspace, windowId: UInt32?, targetMonitorScopeId: String?,
                           click: WorkspaceSidebarSharedPinClick, remoteScopeId: String?? = nil) throws -> Bool {
    guard let targetMonitorScopeId, workspaceSidebarMonitor(forScopeId: targetMonitorScopeId) != nil else { return false }
    let window = windowId.flatMap { Window.get(byId: $0) }.flatMap { $0.nodeWorkspace === tab ? $0 : nil }
    switch workspaceSidebarSharedPinClickPlan(tab, targetMonitorScopeId: targetMonitorScopeId, click: click,
        remoteScopeId: remoteScopeId) {
        case .bringHere(let scopeId):
            // A display that's gone since, or a tab held to its own since, leaves everything as it is.
            guard let monitor = workspaceSidebarMonitor(forScopeId: scopeId),
                  workspaceSidebarSharedPinClickDestination(tab, targetMonitorScopeId: scopeId) != nil else { return false }
            try showSharedPinnedTab(tab, on: monitor, focusing: window)
            noteFocusKeepsPointer()
            return true
        case .showThere(let scopeId):
            // Where it is, as a click in that display's list shows it: nothing comes to this one.
            guard workspaceSidebarMonitor(forScopeId: scopeId) != nil else { return false }
            let shown = window.map { focusWindowFromSidebar($0, targetMonitorScopeId: scopeId) }
                ?? focusWorkspaceFromSidebar(tab, targetMonitorScopeId: scopeId)
            if shown { noteFocusKeepsPointer() }
            return shown
        case .refused(let message):
            showWorkspaceSidebarNotice(.init(title: "Pinned Tab", body: message, monitorScopeId: targetMonitorScopeId))
            return false
        case .here:
            return window.map { focusWindowFromSidebar($0, targetMonitorScopeId: targetMonitorScopeId) }
                ?? focusWorkspaceFromSidebar(tab, targetMonitorScopeId: targetMonitorScopeId)
    }
}

/// ⌘-click on the shared pin `name` from another display, or on its window `windowId`: it comes to
/// the display clicked, the windows it lent first when `recalls`, whatever a plain click does. One
/// held to its display stays, and a notice says why. Nothing else is focused instead.
@MainActor
func bringPinnedTabHereFromSidebar(_ name: String, windowId: UInt32?, recalls: Bool, targetMonitorScopeId: String?) {
    if recalls {
        recallPinWindowsFromSidebar(name, focusing: windowId, targetMonitorScopeId: targetMonitorScopeId, click: .command)
    } else if let pin = workspaceSidebarSharedPinClicked(name, targetMonitorScopeId: targetMonitorScopeId) {
        showSharedPinnedTabFromSidebar(pin, windowId: windowId, targetMonitorScopeId: targetMonitorScopeId, click: .command)
    }
}

/// The sidebar's In Use prompt answered for `name`: a shared pin on another display comes here as
/// ⌘-click brings it, or stays and says why; any other tab is shown here as the prompt always has.
@MainActor
func overrideWorkspaceInUseFromSidebarRespectingPins(_ name: String, targetMonitorScopeId: String?) {
    if let pin = Workspace.existing(byName: name),
       workspaceSidebarSharedPinRemoteScopeId(pin, targetMonitorScopeId: targetMonitorScopeId) != nil {
        showSharedPinnedTabFromSidebar(pin, targetMonitorScopeId: targetMonitorScopeId, click: .command)
    } else {
        overrideWorkspaceInUseFromSidebar(name, targetMonitorScopeId: targetMonitorScopeId)
    }
}

/// A browser tab chosen in the sidebar of `monitorScopeId`, by a plain click, or by ⌘-click on the
/// row of the shared pin `pin`, from another display. In a shared pin on another display it's
/// chosen where it is, or, asked to come, the pin comes here first, the same window, and the tab is
/// chosen once it's here; a pin that can't come stays and says why. Everything is checked again as
/// the pin's session runs and again before the tab is chosen: that it's still the latest choice,
/// the same window of the same process in that pin, and the tab still listed in that window's
/// session. A ⌘-click that no longer finds that pin's window there does nothing at all.
@MainActor
func chooseBrowserTabFromSidebar(_ target: BrowserTabTarget, monitorScopeId: String?, click: WorkspaceSidebarSharedPinClick,
                                 pin pinName: String? = nil) {
    let choice = noteWorkspaceSidebarBrowserTabChoice()
    let window = Window.get(byId: target.windowId)
    let pin = workspaceSidebarBrowserTabCanBeChosen(target)
        ? workspaceSidebarSharedPinClicked(windowId: target.windowId, targetMonitorScopeId: monitorScopeId) : nil
    if click == .command {
        guard let pin, let window, pin.name == pinName, window.nodeWorkspace === pin else { return }
    }
    let stillChosen: @MainActor () -> Bool = {
        workspaceSidebarBrowserTabChoiceIsLatest(choice) && workspaceSidebarBrowserTabCanBeChosen(target)
            && workspaceSidebarBrowserTabIsListed(target)
            && window != nil && Window.get(byId: target.windowId) === window && window?.nodeWorkspace === pin
    }
    let plan = pin.map { workspaceSidebarSharedPinClickPlan($0, targetMonitorScopeId: monitorScopeId, click: click) }
    switch plan {
        case .showThere, .bringHere:
            // A pin on another display whose tab, window or choice has changed since: nothing at all.
            guard stillChosen() else { return }
        case .refused, .here, nil: break
    }
    switch plan {
        case .showThere(let scopeId):
            // Chosen where it is, as that display's list chooses it, the pointer staying put.
            selectWorkspaceSidebarBrowserTab(target, scopeId, true)
        case .bringHere:
            guard let pin else { return }
            showSharedPinnedTabFromSidebar(pin, windowId: target.windowId, targetMonitorScopeId: monitorScopeId, click: click,
                proceeds: stillChosen, afterShown: { _ in
                    if stillChosen() { selectWorkspaceSidebarBrowserTab(target, monitorScopeId, true) }
                })
        case .refused(let message):
            showWorkspaceSidebarNotice(.init(title: "Pinned Tab", body: message, monitorScopeId: monitorScopeId))
        case .here:
            selectWorkspaceSidebarBrowserTab(target, monitorScopeId, false)
        case nil:
            // Not a shared pin elsewhere, as an ordinary row is chosen; a ⌘-click returned above.
            selectWorkspaceSidebarBrowserTab(target, monitorScopeId, false)
    }
}

/// Chooses `target`, in the sidebar of the display given, keeping the pointer where it is if asked,
/// with all the checks choosing a browser tab makes. Tests replace it.
@MainActor
var selectWorkspaceSidebarBrowserTab: @MainActor (BrowserTabTarget, String?, _ keepsPointer: Bool) -> Void = { target, scopeId, keepsPointer in
    BrowserTabsModel.shared.select(target, monitorScopeId: scopeId, keepsPointer: keepsPointer)
}

/// Whether the sidebar still lists `target`, in the same session of the same window. Tests replace it.
@MainActor
var workspaceSidebarBrowserTabIsListed: @MainActor (BrowserTabTarget) -> Bool = { BrowserTabsModel.shared.lists($0) }

/// A saved shared pin whose windows are gone opens its apps once it's here, if they're still
/// gone. Replaceable for tests.
@MainActor
var openSharedPinnedTabApps: @MainActor (Workspace) -> Void = { shown in
    if !workspaceHasLifecycleWindows(shown) { openSavedTabApps(shown) }
}

/// Each browser tab chosen from the sidebar, in order. Choosing one of a pin on another display
/// waits for the pin to come; if another is chosen meanwhile, the first isn't chosen after it.
@MainActor
private var workspaceSidebarBrowserTabChoices = 0

@MainActor
func noteWorkspaceSidebarBrowserTabChoice() -> Int {
    workspaceSidebarBrowserTabChoices &+= 1
    return workspaceSidebarBrowserTabChoices
}

@MainActor
func workspaceSidebarBrowserTabChoiceIsLatest(_ choice: Int) -> Bool {
    choice == workspaceSidebarBrowserTabChoices
}

/// Whether choosing `target` may go ahead, as choosing it checks: browser tabs shown, WinMux on and
/// writable, and its window still the one the browser listed it in.
@MainActor
func workspaceSidebarBrowserTabCanBeChosen(_ target: BrowserTabTarget) -> Bool {
    config.workspaceSidebar.usesTabsList && config.workspaceSidebar.browserTabs && TrayMenuModel.shared.isEnabled
        && !serverArgs.isReadOnly && Window.get(byId: target.windowId)?.app.pid == target.pid
}
