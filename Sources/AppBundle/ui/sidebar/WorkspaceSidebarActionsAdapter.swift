import Foundation

@MainActor
func makeWorkspaceSidebarActionsAdapter(
    viewModel: TrayMenuModel = TrayMenuModel.shared,
    targetMonitorScopeId: String? = nil,
) -> WorkspaceSidebarActions {
    WorkspaceSidebarActions(
        send: { action in
            handleWorkspaceSidebarAction(action, viewModel: viewModel, targetMonitorScopeId: targetMonitorScopeId)
        },
        setDropTargets: { targets in
            let scopeId = targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId
            WorkspaceSidebarPanel.panel(for: scopeId)?.updateDropTargets(targets)
        },
        setSurfaceFrame: { frame in
            let scopeId = targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId
            WorkspaceSidebarPanel.panel(for: scopeId)?.updateSurfaceFrame(frame)
        },
        setExpandedSurfaceFrame: { frame in
            let scopeId = targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId
            WorkspaceSidebarPanel.panel(for: scopeId)?.updateExpandedSurfaceFrame(frame)
        },
        setExpandedDropTargets: { targets in
            let scopeId = targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId
            WorkspaceSidebarPanel.panel(for: scopeId)?.updateExpandedDropTargets(targets)
        },
        setDockRestingWidth: { width in
            let scopeId = targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId
            WorkspaceSidebarPanel.panel(for: scopeId)?.updateDockRestingWidth(width)
        },
        setDockIconFrames: { frames in
            let scopeId = targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId
            WorkspaceSidebarPanel.panel(for: scopeId)?.updateDockIconFrames(frames)
        },
        hoverWorkspace: { name, isHovering in
            TrayMenuModel.shared.setIfChanged(\.workspaceSidebarHoveredWorkspaceName, nextWorkspaceSidebarHoveredWorkspaceName(
                currentHoveredWorkspaceName: TrayMenuModel.shared.workspaceSidebarHoveredWorkspaceName,
                workspaceName: name,
                isHovering: isHovering,
            ))
        },
        resolveAppDragWindow: { workspaceName, appId in
            if let targetMonitorScopeId, workspaceSidebarMonitor(forScopeId: targetMonitorScopeId) == nil {
                return nil
            }
            guard let workspace = Workspace.existing(byName: workspaceName) else { return nil }
            return workspaceSidebarAppWindow(in: workspace, appId: appId)?.windowId
        },
        windowDragChanged: { windowId, pointer in
            noteWorkspaceSidebarDragReported(byPanel: targetMonitorScopeId)
            updateSidebarWindowDrag(windowId, subject: .window, pointer: pointer, previewStyle: workspaceSidebarRowDragPreviewStyle())
        },
        windowDragEnded: { _, pointer in
            finishSidebarWindowDrag(pointer: pointer)
        },
        tabGroupDragChanged: { windowId, pointer in
            noteWorkspaceSidebarDragReported(byPanel: targetMonitorScopeId)
            updateSidebarWindowDrag(windowId, subject: .group, pointer: pointer, previewStyle: workspaceSidebarRowDragPreviewStyle())
        },
        tabGroupDragEnded: { _, pointer in
            finishSidebarWindowDrag(pointer: pointer)
        },
        appIconDragChanged: { windowId, pointer, size in
            noteWorkspaceSidebarDragReported(byPanel: targetMonitorScopeId)
            updateSidebarWindowDrag(windowId, pointer: pointer, previewStyle: .appIcon(size: size))
        },
        pinnedTabDragChanged: { name, pointer in
            noteWorkspaceSidebarDragReported(byPanel: targetMonitorScopeId)
            updateSidebarPinnedTabDrag(name, pointer: pointer)
        },
        pinnedTabDragEnded: { name, pointer in
            finishSidebarPinnedTabDrag(name, pointer: pointer)
        },
    )
}

/// Tabs mode leaves the dragged row dimmed in place, so the pointer carries only the app's
/// icon: a row-sized preview would hide the line and labels that show where the drop goes.
@MainActor
func workspaceSidebarRowDragPreviewStyle() -> WorkspaceSidebarDragPreviewStyle {
    config.usesBrowserTabs ? .appIcon(size: 22) : .row
}

@MainActor
func handleWorkspaceSidebarAction(
    _ action: WorkspaceSidebarAction,
    viewModel: TrayMenuModel = TrayMenuModel.shared,
    targetMonitorScopeId: String? = nil,
) {
    switch action {
        case .selectBrowserTab(let target):
            let monitorScopeId = targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId
            let choice = noteWorkspaceSidebarBrowserTabChoice()
            // A browser tab of a shared pin on another display: the pin comes here, then the tab is
            // chosen. Both wait for the session, so both check again that nothing has been chosen
            // since, that the tab may still be chosen, and that its window is the same one, in the pin.
            if workspaceSidebarBrowserTabCanBeChosen(target), let window = Window.get(byId: target.windowId),
               let pin = workspaceSidebarSharedPinClicked(windowId: target.windowId, targetMonitorScopeId: monitorScopeId),
               workspaceSidebarSharedPinClickDestination(pin, targetMonitorScopeId: monitorScopeId) != nil {
                let stillChosen: @MainActor () -> Bool = {
                    workspaceSidebarBrowserTabChoiceIsLatest(choice) && workspaceSidebarBrowserTabCanBeChosen(target)
                        && Window.get(byId: target.windowId) === window && window.nodeWorkspace === pin
                }
                showSharedPinnedTabFromSidebar(pin, windowId: target.windowId, targetMonitorScopeId: monitorScopeId,
                    proceeds: stillChosen, afterShown: { _ in
                        if stillChosen() { BrowserTabsModel.shared.select(target, monitorScopeId: monitorScopeId) }
                    })
            } else {
                BrowserTabsModel.shared.select(target, monitorScopeId: monitorScopeId)
            }
        case .closeBrowserTab(let target):
            BrowserTabsModel.shared.close(target, monitorScopeId: targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId)
        case .setWorkspaceColor, .setWorkspaceEmoji, .setWorkspaceFavorite, .setWorkspacePinScope, .createTabCollection,
             .renameTabCollection, .setTabCollectionColor, .setTabCollectionEmoji, .toggleTabCollection,
             .assignTabCollection, .ungroupTabCollection, .moveTabCollection, .createTabInCollection, .toggleTabsSidebar,
             .createTabCollectionFromTabs, .assignTabsToCollection, .setTabsFavorite, .setTabsPinScope:
            handleWorkspaceSidebarOrganizationAction(action,
                targetMonitorScopeId: targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId)
        case .selectWorkspace(let name):
            if let pin = workspaceSidebarSharedPinClicked(name, targetMonitorScopeId: targetMonitorScopeId) {
                showSharedPinnedTabFromSidebar(pin, targetMonitorScopeId: targetMonitorScopeId)
            } else {
                focusWorkspaceFromSidebar(name, targetMonitorScopeId: targetMonitorScopeId)
            }
        case .overrideWorkspaceInUse(let name):
            overrideWorkspaceInUseFromSidebar(name, targetMonitorScopeId: targetMonitorScopeId)
        case .expandForWorkspaceOverride, .expandSidebar:
            let scopeId = targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId
            if let panel = WorkspaceSidebarPanel.panel(for: scopeId) {
                panel.expandSidebar(to: CGFloat(panel.sidebarSettings.width))
            }
        case .selectWindow(let windowId):
            if let pin = workspaceSidebarSharedPinClicked(windowId: windowId, targetMonitorScopeId: targetMonitorScopeId) {
                showSharedPinnedTabFromSidebar(pin, windowId: windowId, targetMonitorScopeId: targetMonitorScopeId)
            } else {
                focusWindowFromSidebar(windowId, targetMonitorScopeId: targetMonitorScopeId)
            }
        case .focusWindowInPlace(let windowId):
            focusWindowFromSidebar(windowId)
        case .closeWindow(let windowId):
            if config.usesBrowserTabs { WorkspaceSidebarTabUndo.shared.clear() }
            closeWindowFromMiddleClick(windowId, monitorScopeId: targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId) {
                focusWindowFromSidebar(windowId)
            }
        case .closeTabWindows(let name):
            closeWorkspaceSidebarTabWindows(name)
        case .closeTabs(let names):
            closeWorkspaceSidebarTabs(names)
        case .detachTabWindow(let windowId):
            runWorkspaceSidebarSession(undoTitle: "Move to New Tab") {
                guard let window = Window.get(byId: windowId) else { return }
                try detachWorkspaceTabWindow(window)
            }
        case .splitTabWindow(let windowId, let sourceId, let targetId):
            runWorkspaceSidebarSession(undoTitle: "Split Tabs") {
                try splitWorkspaceSidebarTabWindow(windowId, fromWorkspace: sourceId, withWorkspace: targetId)
            }
        case .undoTabAction:
            runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }
        case .suggestTopicGroups(let projectId, let tabs):
            let scope = targetMonitorScopeId ?? viewModel.workspaceSidebarTargetMonitorScopeId
            // After the menu that asked has closed, so the preview can take key.
            DispatchQueue.main.async { openWorkspaceTopicSuggestions(projectId: projectId, tabs: tabs, panelScopeId: scope) }
        case .selectApp(let workspaceName, let appId):
            focusAppFromSidebar(workspaceName: workspaceName, appId: appId, targetMonitorScopeId: targetMonitorScopeId)
        case .overrideWorkspaceInUseAndSelectApp(let workspaceName, let appId):
            focusAppFromSidebar(
                workspaceName: workspaceName,
                appId: appId,
                targetMonitorScopeId: targetMonitorScopeId,
                overrideWorkspaceInUse: true,
            )
        case .selectProject(let projectId):
            debugWorkspaceSidebarProjectLog(
                "adapterSelectProject project=\(projectId.rawValue) targetScope=\(targetMonitorScopeId ?? "nil") modelActive=\(viewModel.workspaceSidebarActiveProjectId.rawValue)"
            )
            selectWorkspaceSidebarProject(projectId, viewModel: viewModel, targetMonitorScopeId: targetMonitorScopeId)
        case .createProject:
            createWorkspaceSidebarProject(viewModel: viewModel, targetMonitorScopeId: targetMonitorScopeId)
        case .renameProject(let projectId, let displayName):
            renameWorkspaceSidebarProject(projectId, displayName: displayName)
        case .setProjectColor(let projectId, let colorHex):
            if let project = workspaceSidebarProjectViewModel(projectId) {
                setWorkspaceSidebarProjectColor(project, colorHex: colorHex)
            }
        case .editProjectEmoji(let projectId):
            if let project = workspaceSidebarProjectViewModel(projectId) {
                // Let the context menu finish tracking before presenting a modal.
                DispatchQueue.main.async { editWorkspaceSidebarProjectEmoji(project) }
            }
        case .setProjectEmoji(let projectId, let emoji):
            setWorkspaceSidebarProjectEmoji(projectId, emoji: emoji)
        case .deleteProject(let projectId):
            if let project = workspaceSidebarProjectViewModel(projectId) {
                deleteWorkspaceSidebarProject(project, viewModel: viewModel)
            }
        case .selectMonitorScope(let scopeId):
            selectWorkspaceSidebarMonitorScope(scopeId, viewModel: viewModel)
        case .createWorkspace(let projectId, let monitorScopeId):
            createWorkspaceFromSidebarButton(projectId: projectId, monitorScopeId: monitorScopeId)
        case .renameWorkspace(let name, let displayName):
            renameWorkspaceFromSidebar(name, displayName: displayName)
        case .deleteWorkspace(let name):
            if let workspace = workspaceSidebarWorkspaceViewModel(name) {
                deleteWorkspaceFromSidebar(workspace)
            }
        case .separateWorkspaceIntoTabs(let name):
            runWorkspaceSidebarSession(undoTitle: "Separate Tabs") {
                guard let workspace = Workspace.existing(byName: name) else { return }
                separateWorkspaceIntoTabs(workspace)
                await updateWorkspaceSidebarModel()
            }
        case .closeEmptyTab(let name):
            runWorkspaceSidebarSession {
                guard let workspace = Workspace.existing(byName: name) else { return }
                try closeWorkspaceSidebarEmptyTab(workspace)
                await updateWorkspaceSidebarModel()
            }
        case .saveWorkspace(let name):
            saveWorkspaceFromSidebar(name)
        case .forgetSavedWorkspace(let name):
            forgetSavedWorkspaceFromSidebar(name, targetMonitorScopeId: targetMonitorScopeId)
        case .setSavedWorkspacePinned(let name, let pinned):
            setSavedWorkspacePinnedFromSidebar(name, pinned: pinned)
        case .openSavedWorkspaceApps(let name):
            openSavedWorkspaceAppsFromSidebar(name)
        case .openSavedTab(let name):
            if let pin = workspaceSidebarSharedPinClicked(name, targetMonitorScopeId: targetMonitorScopeId) {
                showSharedPinnedTabFromSidebar(pin, targetMonitorScopeId: targetMonitorScopeId,
                    afterShown: { openSharedPinnedTabApps($0) })
            } else {
                openSavedTabFromSidebar(name, targetMonitorScopeId: targetMonitorScopeId)
            }
        case .moveProject(let projectId, let targetId, let after):
            moveWorkspaceSidebarProject(projectId, relativeTo: targetId, after: after)
        case .moveWorkspace(let workspaceName, let projectId):
            runWorkspaceSidebarSession(undoTitle: "Move to Project") {
                _ = moveWorkspaceToProject(workspaceName: workspaceName, projectId: projectId)
            }
        case .moveWindow(let windowId, let workspaceName):
            moveWindowFromSidebar(windowId, toWorkspace: workspaceName)
        case .moveTabGroup(let windowId, let workspaceName):
            moveTabGroupFromSidebar(windowId, toWorkspace: workspaceName)
        case .moveWindowToNewWorkspace(let windowId, let projectId, let monitorScopeId):
            moveWindowToNewWorkspaceFromSidebar(windowId, projectId: projectId, monitorScopeId: monitorScopeId)
        case .moveTabGroupToNewWorkspace(let windowId, let projectId, let monitorScopeId):
            moveTabGroupToNewWorkspaceFromSidebar(windowId, projectId: projectId, monitorScopeId: monitorScopeId)
        case .previewWindowDrop(let windowId, let target):
            previewWorkspaceSidebarDrop(windowId, subject: .window, target: target)
        case .previewTabGroupDrop(let windowId, let target):
            previewWorkspaceSidebarDrop(windowId, subject: .group, target: target)
        case .clearDropPreview:
            clearWorkspaceSidebarDropPreview()
    }
}

@MainActor
private func workspaceSidebarProjectViewModel(_ id: WorkspaceProjectId) -> WorkspaceSidebarProjectViewModel? {
    TrayMenuModel.shared.workspaceSidebarProjects.first { $0.id == id }
}

@MainActor
private func workspaceSidebarWorkspaceViewModel(_ name: String) -> WorkspaceSidebarWorkspaceViewModel? {
    TrayMenuModel.shared.workspaceSidebarWorkspaces.first { $0.name == name }
}
