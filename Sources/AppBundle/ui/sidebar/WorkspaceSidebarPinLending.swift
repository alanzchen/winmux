import AppKit
import Common

// Tabs mode: a pin with one window is the entry to that window alone. A split with it never makes
// a pinned split: the split goes to an ordinary tab, and the pin lends its window there, showing
// grey until a click on it brings that same window back. A pinned split is made only from a split
// tab's menu, with Pin. It keeps the windows it was made with, as far as they're still there: one
// its own pin took back comes back to it when it's clicked.

extension WorkspaceSidebarPinWindow {
    @MainActor
    init(_ window: Window) {
        self.init(windowId: window.windowId, pid: window.app.pid)
    }

    /// The window, if it's still open, in the same process.
    @MainActor
    var live: Window? {
        Window.get(byId: windowId).flatMap { $0.app.pid == pid ? $0 : nil }
    }
}

@MainActor
func workspaceSidebarIsPinned(_ workspace: Workspace) -> Bool {
    workspaceSidebarOrganizationStore.state.workspaces[workspace.name]?.isFavorite == true
}

/// The window `pin` lent to another tab's split, while it's there: not closed, and not back in the pin.
@MainActor
func workspaceSidebarLentWindow(of pin: Workspace) -> Window? {
    guard config.usesBrowserTabs, let appearance = workspaceSidebarOrganizationStore.state.workspaces[pin.name],
          appearance.isFavorite, let window = appearance.lentWindow?.live, window.nodeWorkspace !== pin else { return nil }
    return window
}

/// What a split does with a pin it's made with.
enum WorkspaceSidebarPinSplitRole: Equatable {
    /// No window, and none lent: it takes a dropped window in, as it always has.
    case empty
    /// One window, laid out: the split goes to an ordinary tab with that window, which the pin lends.
    case single(Window)
    /// Its window lent to another tab, a pinned split, or one window that isn't laid out: no split.
    case refuses

    /// The one window of a pin that has one.
    var window: Window? { if case .single(let window) = self { window } else { nil } }
}

@MainActor
func workspaceSidebarPinSplitRole(_ pin: Workspace) -> WorkspaceSidebarPinSplitRole {
    let windows = pin.allLeafWindowsRecursive
    if windows.isEmpty { return workspaceSidebarLentWindow(of: pin) == nil ? .empty : .refuses }
    guard windows.count == 1, let window = windows.first, window.parent is TilingContainer else { return .refuses }
    return .single(window)
}

/// Whether a split or a dropped window may go to `workspace`: any tab but a pin that refuses.
@MainActor
func workspaceSidebarTakesSplit(_ workspace: Workspace) -> Bool {
    !config.usesBrowserTabs || !workspaceSidebarIsPinned(workspace) || workspaceSidebarPinSplitRole(workspace) != .refuses
}

/// Moves `node` into `target` by `move`, which is given the tab it goes to, keeping every pin with one
/// window the entry to that window alone. Split with such a pin, `node` goes to an ordinary tab with
/// the pin's window instead: the ordinary tab `node` is the whole of, else a new one after it, or after
/// the pin when `node` comes from a pin, on `newTabMonitor` if given. A pin whose one window `node` takes
/// out to an ordinary tab lends it as well. A pin that refuses changes nothing, and gives false. If any
/// of it can't be done, nothing changes.
@MainActor
@discardableResult
func moveWorkspaceSidebarNodeKeepingPins(_ node: TreeNode, onto target: Workspace, newTabMonitor: Monitor? = nil,
                                        _ move: (Workspace) -> Void) throws -> Bool {
    guard config.usesBrowserTabs else {
        move(target)
        return true
    }
    let source = node.nodeWorkspace
    let lending: (pin: Workspace, window: Window)? = source.flatMap { pin in
        guard pin !== target, workspaceSidebarIsPinned(pin), case .single(let window) = workspaceSidebarPinSplitRole(pin),
              node.allLeafWindowsRecursive.contains(where: { $0 === window }) else { return nil }
        return (pin, window)
    }
    var targetWindow: Window?
    if workspaceSidebarIsPinned(target) {
        switch workspaceSidebarPinSplitRole(target) {
            case .empty: break
            case .refuses: return false
            case .single(let window): targetWindow = window
        }
    }
    return try withWorkspaceSidebarDropTransaction {
        var destination = target
        if let targetWindow {
            let ordinarySource = source.flatMap { workspaceSidebarIsPinned($0) ? nil : $0 }
            if let ordinarySource, !workspaceTabDragLeavesWindowsBehind(node) {
                destination = ordinarySource
            } else {
                let anchor = ordinarySource ?? target
                destination = createWorkspace(after: anchor, projectId: workspaceContextProjectId(of: anchor),
                    monitor: newTabMonitor ?? anchor.workspaceMonitor)
            }
            targetWindow.bind(to: destination.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            try lendWorkspaceSidebarPinWindow(targetWindow, from: target)
        }
        move(destination)
        // Lent only to an ordinary tab's split: a window moved into an empty pin is that pin's now.
        if let lending, let now = lending.window.nodeWorkspace, now !== lending.pin, !workspaceSidebarIsPinned(now) {
            try lendWorkspaceSidebarPinWindow(lending.window, from: lending.pin)
        }
        return true
    }
}

@MainActor
private func lendWorkspaceSidebarPinWindow(_ window: Window, from pin: Workspace) throws {
    try workspaceSidebarOrganizationStore.update { $0.workspaces[pin.name, default: .init()].lentWindow = .init(window) }
}

/// The windows a click on `pin` brings back: the one it lent, or, for a pinned split, those of its
/// own that are back alone in their pins.
@MainActor
func workspaceSidebarPinRecallsWindows(_ pin: Workspace) -> Bool {
    workspaceSidebarLentWindow(of: pin) != nil || !workspaceSidebarRecallableWindows(of: pin).isEmpty
}

/// A pinned split's windows that went back to their own pins and are still there, alone.
@MainActor
private func workspaceSidebarRecallableWindows(of split: Workspace) -> [(entry: WorkspaceSidebarRecallWindow, window: Window, pin: Workspace)] {
    guard config.usesBrowserTabs, let appearance = workspaceSidebarOrganizationStore.state.workspaces[split.name],
          appearance.isFavorite else { return [] }
    return (appearance.recallWindows ?? []).compactMap { entry in
        guard let window = entry.window.live, let pin = Workspace.existing(byName: entry.pinName), pin !== split,
              workspaceSidebarIsPinned(pin), window.nodeWorkspace === pin,
              pin.allLeafWindowsRecursive.count == 1, window.parent is TilingContainer else { return nil }
        return (entry, window, pin)
    }
}

/// What a click on a pin that recalls windows did.
enum WorkspaceSidebarPinRecall: Equatable {
    /// The lent window is back in its pin, alone.
    case returned(Window)
    /// The lent window is hidden, minimized or full screen where it is: it stays there.
    case elsewhere(Window)
    /// The pinned split has these of its windows back.
    case recalled([Window])
    case nothing
}

/// A click on `pin`: brings back the same window it lent, from wherever it is now, leaving the rest
/// of that split in its tab, or, for a pinned split, its windows that are back alone in their pins.
/// It never opens a window. An ordinary tab the lent window leaves empty closes. A pinned split the
/// lent window leaves keeps where it was, to bring it back when that split is clicked.
@MainActor
func recallWorkspaceSidebarPinWindows(_ pin: Workspace) throws -> WorkspaceSidebarPinRecall {
    guard config.usesBrowserTabs, workspaceSidebarIsPinned(pin) else { return .nothing }
    if pin.allLeafWindowsRecursive.isEmpty, let window = workspaceSidebarLentWindow(of: pin) {
        let isFloating = window.parent is Workspace
        guard window.parent is TilingContainer || isFloating else { return .elsewhere(window) }
        let from = window.nodeWorkspace
        let index = from.map { workspaceSidebarTopLevelIndex(of: window, in: $0) } ?? 0
        syncClosedWindowsCacheToCurrentWorld()
        suppressPostDragAxObserverEvents(for: [window.windowId])
        _ = try withWorkspaceSidebarDropTransaction {
            window.bind(to: isFloating ? pin : pin.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            try workspaceSidebarOrganizationStore.update { state in
                state.workspaces[pin.name]?.lentWindow = nil
                if let from, state.workspaces[from.name]?.isFavorite == true {
                    let kept = (state.workspaces[from.name]?.recallWindows ?? []).filter { $0.window.windowId != window.windowId }
                    state.workspaces[from.name]?.recallWindows = kept + [.init(window: .init(window), pinName: pin.name, index: index)]
                }
            }
            return true
        }
        // No empty ordinary tab stays behind.
        if let from, !workspaceSidebarIsPinned(from), !workspaceHasLifecycleWindows(from) { closeEmptyTab(from) }
        return .returned(window)
    }
    let recallable = workspaceSidebarRecallableWindows(of: pin)
    guard !recallable.isEmpty else { return .nothing }
    syncClosedWindowsCacheToCurrentWorld()
    suppressPostDragAxObserverEvents(for: recallable.map(\.window.windowId))
    _ = try withWorkspaceSidebarDropTransaction {
        for (entry, window, _) in recallable.sorted(by: { $0.entry.index < $1.entry.index }) {
            let row = pin.rootTilingContainer
            window.bind(to: row, adaptiveWeight: WEIGHT_AUTO, index: min(max(entry.index, 0), row.children.count))
        }
        try workspaceSidebarOrganizationStore.update { state in
            for (_, window, home) in recallable { state.workspaces[home.name]?.lentWindow = .init(window) }
            let back = Set(recallable.map(\.window.windowId))
            // Windows closed since are forgotten; those elsewhere for now are kept for later.
            let kept = (state.workspaces[pin.name]?.recallWindows ?? []).filter { $0.window.live != nil && !back.contains($0.window.windowId) }
            state.workspaces[pin.name]?.recallWindows = kept.isEmpty ? nil : kept
        }
        return true
    }
    return .recalled(recallable.map(\.window))
}

/// Where `window` is among `workspace`'s laid-out windows: the place of the piece holding it.
@MainActor
private func workspaceSidebarTopLevelIndex(of window: Window, in workspace: Workspace) -> Int {
    var node: TreeNode = window
    while let parent = node.parent, parent !== workspace.rootTilingContainer, !(parent is Workspace) { node = parent }
    return workspace.rootTilingContainer.children.firstIndex { $0 === node } ?? workspace.rootTilingContainer.children.count
}

/// A click on a pin that recalls windows: they come back as `recallWorkspaceSidebarPinWindows` says,
/// then the pin shows as any clicked pin does, on the display it was clicked on.
@MainActor
func recallPinWindowsFromSidebar(_ name: String, focusing windowId: UInt32?, targetMonitorScopeId: String?) {
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    var shown: (pin: String, window: UInt32?)?
    runWorkspaceSidebarSession(afterLayout: {
        guard let shown else { return }
        if let windowId = shown.window {
            if let pin = workspaceSidebarSharedPinClicked(windowId: windowId, targetMonitorScopeId: targetMonitorScopeId) {
                showSharedPinnedTabFromSidebar(pin, windowId: windowId, targetMonitorScopeId: targetMonitorScopeId)
            } else {
                focusWindowFromSidebar(windowId, targetMonitorScopeId: targetMonitorScopeId)
            }
        } else if let pin = workspaceSidebarSharedPinClicked(shown.pin, targetMonitorScopeId: targetMonitorScopeId) {
            showSharedPinnedTabFromSidebar(pin, targetMonitorScopeId: targetMonitorScopeId)
        } else {
            focusWorkspaceFromSidebar(shown.pin, targetMonitorScopeId: targetMonitorScopeId)
        }
    }) {
        guard let pin = Workspace.existing(byName: name) else { return }
        switch try recallWorkspaceSidebarPinWindows(pin) {
            case .returned(let window): shown = (name, window.windowId)
            case .elsewhere(let window):
                // Not laid out where it is: shown there, as it is, and never opened again.
                _ = window.focusWindow()
            case .recalled(let windows): shown = (name, windowId ?? windows.first?.windowId)
            case .nothing: shown = (name, windowId)
        }
        await updateWorkspaceSidebarModel()
    }
}
