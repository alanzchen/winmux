import AppKit

@MainActor
func detachWorkspaceTabWindow(_ window: Window) throws {
    guard config.usesBrowserTabs, let source = window.nodeWorkspace, source.allLeafWindowsRecursive.count > 1 else { return }
    let tab = createWorkspace(after: source, projectId: source.projectId, monitor: source.workspaceMonitor)
    do {
        if let group = workspaceSidebarOrganizationStore.collection(containing: source.name) {
            try assignWorkspaceToSidebarCollection(tab, collectionId: group.id)
        }
    } catch {
        removeWorkspaceFromRegistry(tab, reason: .deleted)
        throw error
    }
    window.bind(to: window.isFloating ? tab : tab.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
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

@MainActor
func closeWorkspaceSidebarSplitWindows(_ windows: [Window], in workspace: Workspace,
                                      requestClose: @MainActor (Window) async -> Bool) async {
    WorkspaceSidebarTabUndo.shared.clear()
    for window in windows {
        guard Window.get(byId: window.windowId) === window, window.nodeWorkspace === workspace else { continue }
        if !(await requestClose(window)) {
            // Stop at a save sheet or a refused close, and bring it forward.
            if Window.get(byId: window.windowId) === window { _ = window.focusWindow() }
            return
        }
    }
}
