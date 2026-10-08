import AppKit

@MainActor
func canSplitWorkspaceSidebarTabWindow(_ window: Window, with target: Workspace) -> Bool {
    guard config.usesBrowserTabs, !serverArgs.isReadOnly, window.parent is TilingContainer, !window.isFullscreen,
          let source = window.nodeWorkspace, source !== target, !source.isArchived, !target.isArchived,
          // The same project as the sidebar shows them: a pin in All Projects is in every one.
          workspaceContextProjectId(of: source) == workspaceContextProjectId(of: target),
          !target.rootTilingContainer.isEffectivelyEmpty, workspaceSidebarPinPolicyAllows(window, into: target),
          source.workspaceMonitor.rect == target.workspaceMonitor.rect,
          workspaceSidebarMenuCanMove(window, workspaceName: source.name, destination: target),
          target.rootTilingContainer.allLeafWindowsRecursive.allSatisfy({
              !$0.isFullscreen && $0.lastKnownNativeFullscreen != true && $0.lastKnownNativeMinimized != true
          }) else { return false }
    return !savedPinBlocks(target, on: source.workspaceMonitor) &&
        isValidAssignment(workspace: target, screen: source.workspaceMonitor.rect.topLeftCorner)
}

@MainActor
func workspaceSidebarSplitDestinations(windowId: UInt32) -> [Workspace] {
    guard let window = Window.get(byId: windowId), let source = window.nodeWorkspace else { return [] }
    return workspaceNavigationTabs(current: source).filter { canSplitWorkspaceSidebarTabWindow(window, with: $0) }
}

@MainActor
func splitWorkspaceSidebarTabWindow(_ windowId: UInt32, fromWorkspace sourceId: WorkspaceId, withWorkspace targetId: WorkspaceId) throws {
    guard let window = Window.get(byId: windowId), let target = winMuxWorkspaceState.workspaceById[targetId],
          window.nodeWorkspace?.id == sourceId,
          canSplitWorkspaceSidebarTabWindow(window, with: target) else {
        throw NSError(domain: "WinMux.SidebarSplit", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "These windows can no longer be split on this display."])
    }
    syncClosedWindowsCacheToCurrentWorld()
    suppressPostDragAxObserverEvents(for: [windowId])
    // Match a drop on the right half. Only the clicked member moves; an ordinary destination keeps
    // its group, name and other split members, and a pin with one window keeps it as its own: the
    // split goes to an ordinary tab instead.
    try moveWorkspaceSidebarNodeKeepingPins(window, onto: target) { destination in
        applyTabDrop(sourceNode: window, sourceWindow: window, targetWorkspace: destination, placement: .right)
    }
}

@MainActor
/// `keepsGroup` is false when the new tab is pinned right after, which takes it out of any group.
/// `destination` is the project and display of the list the window is dropped on, when that's
/// another project's than the one its tab is listed in: the new tab is made there.
func detachWorkspaceTabWindow(_ window: Window, keepsGroup: Bool = true,
                              destination: (projectId: WorkspaceProjectId, monitor: Monitor)? = nil) throws {
    guard config.usesBrowserTabs, let source = window.nodeWorkspace, source.allLeafWindowsRecursive.count > 1 else { return }
    // A pinned split it's taken out of keeps track of its windows, saved first.
    try saveWorkspaceSidebarPinCompositions(of: [source])
    let tab = createWorkspace(after: source, projectId: destination?.projectId ?? workspaceContextProjectId(of: source),
        monitor: destination?.monitor ?? source.workspaceMonitor)
    do {
        if keepsGroup, let group = workspaceSidebarOrganizationStore.collection(containing: source.name),
           group.projectId == tab.projectId {
            try assignWorkspaceToSidebarCollection(tab, collectionId: group.id, keepWhenEmpty: false)
        }
    } catch {
        removeWorkspaceFromRegistry(tab, reason: .deleted)
        throw error
    }
    window.bind(to: window.isFloating ? tab : tab.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    captureNewAutomaticWorkspaceIdentity(tab)
    _ = window.focusWindow()
}

@MainActor
func closeWorkspaceSidebarTabWindows(_ name: String) {
    guard config.usesBrowserTabs, !serverArgs.isReadOnly,
          let workspace = Workspace.existing(byName: name) else { return }
    let windows = workspace.allLeafWindowsRecursive
    guard !windows.isEmpty else { return }
    if windows.count > 1 {
        let alert = NSAlert()
        alert.messageText = "Close all \(windows.count) windows in this split?"
        alert.informativeText = "This closes the application windows. Each app may ask you to save changes."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Windows")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .popUpMenu
        guard alert.runModal() == .alertSecondButtonReturn else { return }
    }
    runWorkspaceSidebarSession {
        await closeWorkspaceSidebarSplitWindows(windows, in: workspace) { window in
            if let macWindow = window as? MacWindow {
                return await macWindow.requestCloseForProjectDeletion()
            }
            window.closeAxWindow()
            return true
        }
    }
}

/// Whether every window closed; false when one stopped at a save sheet or refused.
@MainActor
@discardableResult
func closeWorkspaceSidebarSplitWindows(_ windows: [Window], in workspace: Workspace,
                                      requestClose: @MainActor (Window) async -> Bool) async -> Bool {
    WorkspaceSidebarTabUndo.shared.clear()
    for window in windows {
        guard Window.get(byId: window.windowId) === window, window.nodeWorkspace === workspace else { continue }
        if !(await requestClose(window)) {
            // Stop at a save sheet or a refused close, and bring it forward.
            if Window.get(byId: window.windowId) === window { _ = window.focusWindow() }
            return false
        }
    }
    return true
}
