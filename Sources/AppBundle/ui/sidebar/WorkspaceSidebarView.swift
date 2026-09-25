import AppKit
import Common
import SwiftUI

struct WorkspaceSidebarView: View {
    let snapshot: WorkspaceSidebarSnapshot
    let actions: WorkspaceSidebarActions
    let dockBadgeModel: WorkspaceSidebarDockBadgeModel
    @ObservedObject var dockBadgePresence: WorkspaceSidebarDockBadgePresence
    @State var projectSwipeTranslation: CGFloat = 0
    @State var projectSwipeStartProjectId: WorkspaceProjectId? = nil
    @State var projectSwipeDidCrossBreakPoint = false
    @State var projectPagerWidth: CGFloat = 0
    @State var browseMode: WorkspaceSidebarBrowseMode = .activeProject
    @State var collapsedProjectIds: Set<WorkspaceProjectId> = []
    @State var projectColumnsListHeight: CGFloat = 0
    @State var projectColumnsSearchListHeight: CGFloat = 0
    @State var projectColumnsNewProjectWidth: CGFloat = 0
    @State var projectColumnsToolbarHeight: CGFloat = 44
    @State var activeInUseOverrideWorkspaceName: String? = nil
    @State var pendingInUseOverrideAppId: String? = nil
    @State var isSidebarCollapsing = false
    @State var isSidebarExpanding = false
    @State var renamingProjectId: WorkspaceProjectId? = nil
    @State var renamingProjectText = ""
    @State var renamingWorkspaceName: String? = nil
    @State var renamingWorkspaceText = ""
    @State var searchText = ""
    @State var isSearchEditing = false
    @State var searchEditingPanel: WorkspaceSidebarPanel? = nil
    @State var selectedSearchTarget: WorkspaceSidebarSearchSelection? = nil
    /// Tabs mode folders the user collapsed, by workspace name. Kept for the panel's lifetime.
    @State var collapsedTabFolderNames: Set<String> = []
    @State var lastProjectEdgeDragDirection: Int? = nil
    @State var lastProjectEdgeDragSwitchAt: Date = .distantPast
    @State var showsPinnedActiveWorkspaceForBrowsedProject = true
    @State var dockMotion = WorkspaceSidebarDockMotionController()
    @State var dockMenuTracking = false
    @State var dockHitRegions = WorkspaceSidebarDockHitRegions()
    @State private var dockColumnOrigins: [WorkspaceProjectId: CGFloat] = [:]
    @Environment(\.workspaceSidebarDockPointer) var inheritedDockPointer
    @Environment(\.accessibilityReduceMotion) private var systemReduceDockMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceSidebarTransparency
    private let reduceMotionOverride: Bool?
    private let reduceTransparencyOverride: Bool?
    var reduceDockMotion: Bool { reduceMotionOverride ?? systemReduceDockMotion }
    var reduceSidebarTransparency: Bool { reduceTransparencyOverride ?? systemReduceSidebarTransparency }

    init(snapshot: WorkspaceSidebarSnapshot, actions: WorkspaceSidebarActions = WorkspaceSidebarActions(),
         reduceMotionOverride: Bool? = nil, reduceTransparencyOverride: Bool? = nil,
         dockBadgeModel: WorkspaceSidebarDockBadgeModel = .shared) {
        self.snapshot = snapshot
        self.dockBadgeModel = dockBadgeModel
        self.dockBadgePresence = dockBadgeModel.presence
        self.actions = actions
        self.reduceMotionOverride = reduceMotionOverride
        self.reduceTransparencyOverride = reduceTransparencyOverride
    }

    var body: some View {
        let collapsedWidth = snapshot.configuration.expansionStartWidth
        let expandedWidth = snapshot.configuration.expandedWidth
        let expansionProgress = max(
            0,
            min(1, (snapshot.visibleWidth - collapsedWidth) / max(expandedWidth - collapsedWidth, 1)),
        )
        
        // A collapsible Dock keeps its resting shape; only the floating columns expand.
        let dockExpansionProgress = usesProjectColumns ? 0 : expansionProgress
        GeometryReader { viewport in
            let layout = dockLayout(availableHeight: snapshot.configuration.dockPosition == .bottom
                ? viewport.size.width : viewport.size.height)
            ZStack(alignment: .topLeading) {
                if usesNativeDock {
                    nativeDock(layout: layout)
                        .preference(key: WorkspaceSidebarDockRestingWidthPreferenceKey.self,
                            value: layout.compactRailWidth)
                } else {
                    WorkspaceSidebarDockAnimationHost(
                        configuration: layout,
                        visibleWidth: fittedVisibleWidth(layout: layout),
                        compactHeight: compactDockContentHeight(layout: layout),
                        expansionProgress: dockExpansionProgress,
                        blockers: dockMagnificationBlockers,
                        overflow: dockMagnificationOverflow(layout: layout),
                        shape: sidebarShape(layout: layout),
                        hitRegions: dockHitRegions,
                        motion: dockMotion,
                        growth: dockColumnGrowth(layout: layout),
                        content: dockOrSidebarContent(expansionProgress: dockExpansionProgress, layout: layout)
                            .environment(\.workspaceSidebarDockDrag, snapshot.dockDrag)
                    )
                    .preference(key: WorkspaceSidebarDockRestingWidthPreferenceKey.self,
                        value: layout.showAppIcons ? layout.compactRailWidth : nil)
                }
                if usesProjectColumns, expansionProgress > 0 {
                    floatingProjectColumns(layout: layout, availableSize: viewport.size, progress: expansionProgress)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .coordinateSpace(name: "workspaceSidebarContent")
        .environment(\.workspaceSidebarTooltipVisibility, WorkspaceSidebarTooltipVisibility(
            workspace: snapshot.configuration.showWorkspaceTooltips,
            app: snapshot.configuration.showAppTooltips))
        // Keep the gesture coordinator mounted while compact rendering switches to
        // the project paging or expanded SwiftUI presentation.
        .overlay { sidebarSwipeCaptureOverlay(expansionProgress: expansionProgress) }
        .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) {
            if !usesNativeDock { actions.setDropTargets($0) }
        }
        .onPreferenceChange(WorkspaceSidebarDockColumnOriginPreference.self) { origins in
            dockMotion.recordColumnOrigins(origins, previous: dockColumnOrigins)
            let stable = workspaceSidebarStableDockColumnOrigins(origins, previous: dockColumnOrigins)
            if stable != dockColumnOrigins { dockColumnOrigins = stable }
        }
        .animation(snapshot.configuration.showAppIcons && !reduceDockMotion ? workspaceSidebarDockSettleAnimation : nil,
                   value: WorkspaceSidebarDockLayoutState(snapshot))
        .onReceive(NotificationCenter.default.publisher(for: workspaceSidebarDragPointerChangedNotification)) { _ in
            dockMotion.reset()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            dockMenuTracking = true
            dockMotion.reset()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            dockMenuTracking = false
        }
        .onPreferenceChange(WorkspaceSidebarSurfaceFramePreferenceKey.self) { frame in
            if let frame {
                dockMotion.recordGeometry(surfaceY: frame.minY)
                dockHitRegions.surface = frame
                actions.setSurfaceFrame(frame)
            }
        }
        .onPreferenceChange(WorkspaceSidebarDockRestingWidthPreferenceKey.self) { width in
            actions.setDockRestingWidth(width)
        }
        .onPreferenceChange(WorkspaceSidebarDockIconFramesPreference.self) { frames in
            guard !usesNativeDock else { return }
            dockMotion.recordGeometry(icons: frames.count)
            dockHitRegions.icons = frames
            actions.setDockIconFrames(allowsDockMagnification ? frames : [])
        }
        .onChange(of: snapshot.configuration.dockPosition) { _ in
            dockMotion.reset()
            dockColumnOrigins = [:]
            browseMode = .activeProject
        }
        .onChange(of: allowsDockMagnification) { allowed in
            if !allowed {
                dockMotion.reset(publishFrame: false)
                actions.setDockIconFrames([])
            } else if !usesNativeDock { actions.setDockIconFrames(dockHitRegions.icons) }
        }
        .background(Color.clear)
        .onChange(of: activeInUseOverrideWorkspaceName) { name in
            if name == nil { pendingInUseOverrideAppId = nil }
        }
        .onChange(of: snapshot.visibleWidth) { visibleWidth in
            // During expansion SwiftUI may still retain the outgoing native view.
            // Reset its clock without letting its old compact snapshot republish
            // hit regions after the expanded renderer has cleared them. A Dock beside
            // floating project columns remains the only renderer of its hit regions.
            dockMotion.reset(publishFrame: usesProjectColumns || visibleWidth <= collapsedWidth)
            if visibleWidth <= collapsedWidth + 0.5 {
                resetTransientSidebarState()
                finishSidebarSearch(clearText: true)
            } else if visibleWidth >= collapsedWidth + 8 {
                isSidebarCollapsing = false
            }
            if visibleWidth >= expandedWidth - 0.5 {
                isSidebarExpanding = false
            }
        }
        .onChange(of: snapshot.activeProjectId) { projectId in
            debugWorkspaceSidebarProjectLog(
                "snapshotActiveProjectChanged active=\(projectId.rawValue) visibleWidth=\(snapshot.visibleWidth) projects=\(snapshot.projects.map(\.id.rawValue))"
            )
            browseMode = .activeProject
            showsPinnedActiveWorkspaceForBrowsedProject = true
            activeInUseOverrideWorkspaceName = nil
            // In the floating columns, a double-click's first click switches to the project its
            // second click starts renaming. Switching to any other project still ends the rename.
            if !usesProjectColumns || renamingProjectId != projectId { finishProjectRename(cancelled: true) }
            finishSidebarSearch(clearText: true)
            resetProjectSwipeWithoutAnimation()
        }
        .onChange(of: browseMode) { mode in
            guard snapshot.visibleWidth > collapsedWidth + 0.5,
                  let panel = WorkspaceSidebarPanel.panel(for: snapshot.targetMonitorScopeId)
            else { return }
            let targetWidth = mode.isSplit ? expandedWidth * 2 : expandedWidth
            debugWorkspaceSidebarHoverLog("browseProjectWidthChange panel=\(snapshot.targetMonitorScopeId) project=\(mode.otherProjectId?.rawValue ?? "nil") snapshotWidth=\(snapshot.visibleWidth) target=\(targetWidth) frame=\(panel.frame) mouse=\(NSEvent.mouseLocation)")
            panel.cancelExpansionWork()
            panel.viewModel.isWorkspaceSidebarExpanded = true
            panel.splitBrowseCollapseSuppressedUntil = mode.isSplit ? Date().addingTimeInterval(0.65) : .distantPast
            isSidebarCollapsing = false
            isSidebarExpanding = false
            panel.animateVisibleSidebarWidth(targetWidth, animation: .easeInOut(duration: panel.animationDuration))
        }
        .onChange(of: snapshot.projects) { _ in
            if let browsedProjectId, !snapshot.projects.contains(where: { $0.id == browsedProjectId }) {
                browseMode = .activeProject
            }
            if let renamingProjectId, !snapshot.projects.contains(where: { $0.id == renamingProjectId }) {
                finishProjectRename(cancelled: true)
            }
            if let renamingWorkspaceName, !snapshot.workspaces.contains(where: { $0.name == renamingWorkspaceName }) {
                finishWorkspaceRename(cancelled: true)
            }
            resetProjectSwipeWithoutAnimation()
        }
        .onReceive(NotificationCenter.default.publisher(for: workspaceSidebarWillCollapseNotification)) { notification in
            guard notificationPanel(from: notification)?.monitorScopeId == snapshot.targetMonitorScopeId else { return }
            guard snapshot.visibleWidth > collapsedWidth + 0.5 else {
                isSidebarCollapsing = false
                return
            }
            activeInUseOverrideWorkspaceName = nil
            finishSidebarSearch(clearText: true)
            withAnimation(.easeOut(duration: 0.08)) {
                isSidebarCollapsing = true
                isSidebarExpanding = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: workspaceSidebarWillExpandNotification)) { notification in
            guard notificationPanel(from: notification)?.monitorScopeId == snapshot.targetMonitorScopeId else { return }
            isSidebarCollapsing = false
            isSidebarExpanding = true
            if notification.userInfo?[workspaceSidebarExpansionStartsSearchKey] as? Bool == true,
               let panel = notificationPanel(from: notification) {
                beginSidebarSearchIfNeeded(panel: panel)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: workspaceSidebarInputDidEndNotification)) { notification in
            guard let panel = notificationPanel(from: notification), searchEditingPanel === panel else { return }
            finishSidebarSearch(clearText: true)
        }
        .onChange(of: snapshot.selectedMonitorScopeId) { _ in
            activeInUseOverrideWorkspaceName = nil
        }
        .onChange(of: snapshot.workspaces) { workspaces in
            if !collapsedTabFolderNames.isEmpty {
                let prunedFolders = workspaceSidebarPrunedCollapsedFolders(collapsedTabFolderNames, workspaceNames: workspaces.map(\.name))
                if prunedFolders != collapsedTabFolderNames { collapsedTabFolderNames = prunedFolders }
            }
            if let name = activeInUseOverrideWorkspaceName,
               !workspaces.contains(where: { $0.name == name }) {
                activeInUseOverrideWorkspaceName = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: workspaceSidebarCommandSearchKeyNotification)) { notification in
            guard let panel = notificationPanel(from: notification),
                  panel.monitorScopeId == snapshot.targetMonitorScopeId
            else { return }
            adoptCommandSidebarSearchIfNeeded(panel: panel)
        }
        .onReceive(NotificationCenter.default.publisher(for: workspaceSidebarDragPointerChangedNotification)) { notification in
            guard let pointer = workspaceSidebarDragPointer(from: notification) else { return }
            handleProjectEdgeDrag(pointer: pointer, expansionProgress: expansionProgress)
        }
        .onReceive(NotificationCenter.default.publisher(for: workspaceSidebarDragPointerEndedNotification)) { _ in
            resetProjectEdgeDrag()
        }
    }

    func beginProjectRename(_ project: WorkspaceSidebarProjectViewModel) {
        debugWorkspaceSidebarRenameLog("beginProjectRename project=\(project.id.rawValue) displayName=\(project.displayName) active=\(snapshot.activeProjectId.rawValue) visibleWidth=\(snapshot.visibleWidth)")
        finishSidebarSearch(clearText: false)
        if !showsAllProjects, project.id != snapshot.activeProjectId {
            browseMode = .split(otherProjectId: project.id)
        }
        renamingProjectId = project.id
        renamingProjectText = project.displayName
        currentPanel()?.prepareForInlineTextEditing()
    }

    func finishProjectRename(cancelled: Bool = false) {
        guard let projectId = renamingProjectId else { return }
        let displayName = renamingProjectText.trimmingCharacters(in: .whitespacesAndNewlines)
        debugWorkspaceSidebarRenameLog("finishProjectRename project=\(projectId.rawValue) cancelled=\(cancelled) raw=\(renamingProjectText) trimmed=\(displayName)")
        renamingProjectId = nil
        renamingProjectText = ""
        currentPanel()?.endInlineTextEditing()
        guard !cancelled, !displayName.isEmpty else { return }
        actions.send(.renameProject(projectId, displayName: displayName))
    }

    func beginWorkspaceRename(_ workspace: WorkspaceSidebarWorkspaceViewModel) {
        debugWorkspaceSidebarRenameLog("beginWorkspaceRename workspace=\(workspace.name) displayName=\(workspace.displayName) targetScope=\(snapshot.targetMonitorScopeId) activeProject=\(snapshot.activeProjectId.rawValue) visibleWidth=\(snapshot.visibleWidth)")
        finishSidebarSearch(clearText: false)
        finishProjectRename(cancelled: true)
        renamingWorkspaceName = workspace.name
        renamingWorkspaceText = workspace.displayName
        currentPanel()?.prepareForInlineTextEditing()
    }

    func finishWorkspaceRename(cancelled: Bool = false) {
        guard let workspaceName = renamingWorkspaceName else { return }
        let displayName = renamingWorkspaceText.trimmingCharacters(in: .whitespacesAndNewlines)
        debugWorkspaceSidebarRenameLog("finishWorkspaceRename workspace=\(workspaceName) cancelled=\(cancelled) raw=\(renamingWorkspaceText) trimmed=\(displayName) targetScope=\(snapshot.targetMonitorScopeId)")
        renamingWorkspaceName = nil
        renamingWorkspaceText = ""
        currentPanel()?.endInlineTextEditing()
        guard !cancelled, !displayName.isEmpty else { return }
        actions.send(.renameWorkspace(workspaceName, displayName: displayName))
    }

    func currentPanel() -> WorkspaceSidebarPanel? {
        WorkspaceSidebarPanel.panel(for: snapshot.targetMonitorScopeId)
    }

    func beginSidebarSearchIfNeeded(panel: WorkspaceSidebarPanel? = nil) {
        guard renamingProjectId == nil, renamingWorkspaceName == nil, !isSearchEditing else { return }
        guard snapshot.visibleWidth > snapshot.configuration.expansionStartWidth + 0.5 || isSidebarExpanding else { return }
        let editingPanel = panel ?? currentPanel() ?? WorkspaceSidebarPanel.shared
        adoptCommandSidebarSearchIfNeeded(panel: editingPanel)
    }

    func adoptCommandSidebarSearchIfNeeded(panel editingPanel: WorkspaceSidebarPanel) {
        guard renamingProjectId == nil, renamingWorkspaceName == nil else { return }
        if !isSearchEditing {
            isSearchEditing = true
            searchEditingPanel = editingPanel
            selectFirstSearchTarget()
        }
        let locksExpansion = editingPanel.commandExpansionLocksCollapse || editingPanel.shouldLockNextSidebarSearchExpansion
        editingPanel.shouldLockNextSidebarSearchExpansion = false
        editingPanel.beginInlineTextEditing(
            locksExpansion: locksExpansion,
            cancelsOnPointerExit: false,
            onCancel: {
                finishSidebarSearch(clearText: true)
            },
            onKeyDown: { key in
                handleSidebarSearchKey(key)
            },
        )
        let bufferedKeys = editingPanel.bufferedCommandSidebarSearchKeys
        editingPanel.bufferedCommandSidebarSearchKeys = []
        for key in bufferedKeys {
            handleSidebarSearchKey(key)
        }
    }

    func finishSidebarSearch(clearText: Bool) {
        let panel = searchEditingPanel
        if isSearchEditing {
            isSearchEditing = false
            (panel ?? currentPanel() ?? WorkspaceSidebarPanel.shared).endInlineTextEditing()
            searchEditingPanel = nil
        }
        if clearText {
            searchText = ""
        }
        selectedSearchTarget = nil
    }

    func handleSidebarSearchKey(_ key: WorkspaceSidebarInlineTextKey) {
        switch key {
            case .text(let inserted):
                searchText += inserted
                selectFirstSearchTarget()
            case .deleteBackward:
                if !searchText.isEmpty {
                    searchText.removeLast()
                }
                selectFirstSearchTarget()
            case .deleteWordBackward:
                searchText.deleteLastWord()
                selectFirstSearchTarget()
            case .deleteToBeginningOfLine:
                searchText = ""
                selectedSearchTarget = nil
            case .deleteForward:
                break
            case .commit:
                activateSelectedSearchTarget()
            case .cancel:
                let panel = searchEditingPanel ?? WorkspaceSidebarPanel.shared
                closeWorkspaceSidebarFromCommand(panel, restorePreviousApplication: true)
            case .moveUp:
                moveSearchSelection(delta: -1)
            case .moveDown:
                moveSearchSelection(delta: 1)
            case .ignored:
                break
        }
    }

    func selectFirstSearchTarget() {
        selectedSearchTarget = searchText.isEmpty ? nil : currentSearchSelections().first
    }

    func moveSearchSelection(delta: Int) {
        let selections = currentSearchSelections()
        guard !selections.isEmpty else {
            selectedSearchTarget = nil
            return
        }
        guard let selectedSearchTarget,
              let index = selections.firstIndex(of: selectedSearchTarget)
        else {
            self.selectedSearchTarget = selections.first
            return
        }
        let nextIndex = max(0, min(selections.count - 1, index + delta))
        self.selectedSearchTarget = selections[nextIndex]
    }

    func activateSelectedSearchTarget() {
        guard let selectedSearchTarget else { return }
        let panel = searchEditingPanel ?? WorkspaceSidebarPanel.shared
        switch selectedSearchTarget {
            case .workspace(let workspaceName):
                actions.send(.selectWorkspace(workspaceName))
            case .window(let windowId):
                actions.send(.selectWindow(windowId))
        }
        finishSidebarSearch(clearText: true)
        closeWorkspaceSidebarFromCommand(panel)
    }

    func currentSearchSelections() -> [WorkspaceSidebarSearchSelection] {
        let workspaces = currentFilteredProjectWorkspaces(allProjects: showsAllProjects)
        return workspaceSidebarSearchSelections(workspaces: workspaces)
    }

    func currentFilteredProjectWorkspaces(allProjects: Bool = false) -> [WorkspaceSidebarWorkspaceViewModel] {
        let visibleWorkspacesByProject = workspaceSidebarVisibleWorkspacesByProject(
            workspaces: snapshot.workspaces,
            selectedScopeId: snapshot.selectedMonitorScopeId,
            focusedMonitorScopeId: snapshot.focusedMonitorScopeId,
            browsedProjectId: browsedProjectId,
        )
        // Floating project columns list the results; the resting Dock beside them keeps every workspace.
        let filteredWorkspacesByProject = workspaceSidebarFilteredWorkspacesByProject(
            visibleWorkspacesByProject,
            projects: snapshot.projects,
            query: usesProjectColumns && !allProjects ? "" : searchText,
        )
        if allProjects, !snapshot.projects.isEmpty {
            return snapshot.projects.flatMap { project in
                searchText.isEmpty && collapsedProjectIds.contains(project.id)
                    ? [] : filteredWorkspacesByProject[project.id] ?? []
            }
        }
        let projectId: WorkspaceProjectId
        if let index = projectPagerDisplayIndex, snapshot.projects.indices.contains(index) {
            projectId = snapshot.projects[index].id
        } else {
            projectId = snapshot.activeProjectId
        }
        return filteredWorkspacesByProject[projectId] ?? []
    }
}

extension WorkspaceSidebarView {
    var browsedProjectId: WorkspaceProjectId? {
        showsAllProjects ? nil : browseMode.otherProjectId
    }
}

private func workspaceSidebarDragPointer(from notification: Notification) -> CGPoint? {
    (notification.userInfo?[workspaceSidebarDragPointerUserInfoKey] as? NSValue)?.pointValue
}

private func notificationPanel(from notification: Notification) -> WorkspaceSidebarPanel? {
    notification.object as? WorkspaceSidebarPanel
}

struct WorkspaceSidebarContainerView: View {
    @ObservedObject var viewModel: TrayMenuModel
    let actions: WorkspaceSidebarActions

    var body: some View {
        WorkspaceSidebarView(
            snapshot: workspaceSidebarSnapshot(from: viewModel),
            actions: actions
        )
    }
}
extension WorkspaceSidebarView {
    @ViewBuilder
    func projectPagerContent(
        layout: WorkspaceSidebarConfiguration,
        expansionProgress: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        topPadding: CGFloat,
        visibleWorkspacesByProject: [WorkspaceProjectId: [WorkspaceSidebarWorkspaceViewModel]],
        swipeDirection: Int?,
    ) -> some View {
        if usesExpandedProjectList, !snapshot.projects.isEmpty, expansionProgress >= workspaceSidebarRowsRevealProgress {
            allProjectsContent(
                layout: layout,
                leadingInset: leadingInset,
                trailingInset: trailingInset,
                topPadding: topPadding,
                workspacesByProject: visibleWorkspacesByProject
            )
        } else if let browsedProjectId,
           browsedProjectId != snapshot.activeProjectId
        {
            splitWorkspacePage(
                layout: layout,
                activeProjectId: snapshot.activeProjectId,
                browsedProjectId: browsedProjectId,
                expansionProgress: expansionProgress,
                leadingInset: leadingInset,
                trailingInset: trailingInset,
                topPadding: topPadding,
                visibleWorkspacesByProject: visibleWorkspacesByProject
            )
        } else if snapshot.projects.isEmpty {
            workspacePage(
                layout: layout,
                projectId: snapshot.activeProjectId,
                workspaces: visibleWorkspacesByProject[snapshot.activeProjectId] ?? [],
                expansionProgress: expansionProgress,
                leadingInset: leadingInset,
                trailingInset: trailingInset,
                topPadding: topPadding,
                isInteractive: true,
                showsPinnedActiveWorkspace: true,
                showsCreateWorkspace: true,
                allowsActivation: allowsWorkspaceActivation(projectId: snapshot.activeProjectId),
            )
        } else {
            projectPagerPages(
                layout: layout,
                expansionProgress: expansionProgress,
                leadingInset: leadingInset,
                trailingInset: trailingInset,
                topPadding: topPadding,
                visibleWorkspacesByProject: visibleWorkspacesByProject,
                swipeDirection: swipeDirection,
            )
        }
    }

    func projectPagerPages(
        layout: WorkspaceSidebarConfiguration,
        expansionProgress: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        topPadding: CGFloat,
        visibleWorkspacesByProject: [WorkspaceProjectId: [WorkspaceSidebarWorkspaceViewModel]],
        swipeDirection: Int?,
    ) -> some View {
        GeometryReader { geometry in
            let pageWidth = max(geometry.size.width, 1)
            let displayIndex = projectPagerDisplayIndex ?? 0
            let dragOffset = workspaceSidebarProjectPagerDragOffset(
                horizontalTranslation: projectSwipeTranslation,
                currentIndex: displayIndex,
                projectCount: snapshot.projects.count,
                pageWidth: pageWidth,
            )

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(snapshot.projects.enumerated()), id: \.element.id) { index, project in
                    projectPageSlot(
                        layout: layout,
                        index: index,
                        project: project,
                        displayIndex: displayIndex,
                        pageWidth: pageWidth,
                        expansionProgress: expansionProgress,
                        leadingInset: leadingInset,
                        trailingInset: trailingInset,
                        topPadding: topPadding,
                        visibleWorkspacesByProject: visibleWorkspacesByProject,
                        swipeDirection: swipeDirection,
                    )
                }
            }
            .offset(x: -CGFloat(displayIndex) * pageWidth + dragOffset)
            .onAppear { projectPagerWidth = pageWidth }
            .onChange(of: pageWidth) { projectPagerWidth = $0 }
        }
        .modifier(WorkspaceSidebarTrailingOverflowModifier(base: Rectangle(), overflow: dockMagnificationOverflow(layout: layout)))
    }
}
extension WorkspaceSidebarView {
    func projectPagerSection(
        layout: WorkspaceSidebarConfiguration,
        expansionProgress: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        swipeDirection: Int?,
        switchProgress: CGFloat,
        edgeProgress: CGFloat,
    ) -> some View {
        WorkspaceSidebarProjectPager(
            projects: snapshot.projects,
            selectedProjectId: snapshot.activeProjectId,
            expansionProgress: expansionProgress,
            layout: layout,
            renamingProjectId: $renamingProjectId,
            renamingProjectText: $renamingProjectText,
            onSelectProject: { projectId in
                debugWorkspaceSidebarProjectLog(
                    "pagerSectionSelect project=\(projectId.rawValue) active=\(snapshot.activeProjectId.rawValue) browsed=\(browsedProjectId?.rawValue ?? "nil")"
                )
                browseMode = .activeProject
                actions.send(.selectProject(projectId))
            },
            onCreateProject: { actions.send(.createProject) },
            onBeginRenameProject: { project in
                beginProjectRename(project)
            },
            onCommitRenameProject: {
                finishProjectRename()
            },
            onCancelRenameProject: {
                finishProjectRename(cancelled: true)
            },
            onSetProjectColor: { project, colorHex in
                actions.send(.setProjectColor(project.id, colorHex: colorHex))
            },
            onDeleteProject: { project in
                actions.send(.deleteProject(project.id))
            },
            onEditProjectEmoji: { project in
                actions.send(.editProjectEmoji(project.id))
            },
            onResetProjectEmoji: { project in
                actions.send(.setProjectEmoji(project.id, emoji: nil))
            },
        )
        .zIndex(2)
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .padding(.top, layout.dockPosition == .bottom && expansionProgress == 0 ? 0 : 6)
        .padding(.bottom, layout.dockPosition == .bottom && expansionProgress == 0 ? 0 : 2)
    }
}
extension WorkspaceSidebarView {
    func validProjectSwipeEndDirection(
        horizontalTranslation: CGFloat,
        verticalTranslation: CGFloat,
        expansionProgress: CGFloat,
    ) -> Int? {
        guard shouldHandleProjectSwipe(
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: verticalTranslation,
            expansionProgress: expansionProgress,
        ) else {
            return nil
        }
        return workspaceSidebarProjectSwipeDirection(
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: verticalTranslation,
        )
    }

    func finishProjectSwipeNavigation(to projectId: WorkspaceProjectId, direction: Int) {
        let startProjectId = projectSwipeStartProjectId
        let fullPageOffset = -CGFloat(direction) * max(projectPagerWidth, snapshot.configuration.expandedWidth, 1)
        withAnimation(.easeOut(duration: 0.12)) {
            projectSwipeTranslation = fullPageOffset
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard projectSwipeStartProjectId == startProjectId else { return }
            actions.send(.selectProject(projectId))
            resetProjectSwipeWithoutAnimation()
        }
    }

    func finishProjectSwipeCreation() {
        withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.9)) {
            resetProjectSwipe()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard projectSwipeStartProjectId == nil else { return }
            actions.send(.createProject)
        }
    }
}
extension WorkspaceSidebarView {
    func handleProjectSwipeEnded(
        horizontalTranslation: CGFloat,
        verticalTranslation: CGFloat,
        expansionProgress: CGFloat,
    ) {
        guard let direction = validProjectSwipeEndDirection(
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: verticalTranslation,
            expansionProgress: expansionProgress,
        ) else {
            finishProjectSwipeSnapBack()
            return
        }
        if projectSwipeStartProjectId == nil,
           let selectedProjectIndex {
            projectSwipeStartProjectId = snapshot.projects[selectedProjectIndex].id
        }
        if finishProjectSwipeCreationIfNeeded(direction: direction, distance: abs(horizontalTranslation)) {
            return
        }
        finishProjectSwipeNavigationIfNeeded(direction: direction, distance: abs(horizontalTranslation))
    }

    func finishProjectSwipeSnapBack() {
        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.9)) {
            resetProjectSwipe()
        }
    }

    private func finishProjectSwipeCreationIfNeeded(direction: Int, distance: CGFloat) -> Bool {
        guard shouldCreateWorkspaceSidebarProjectAfterSwipe(
            currentIndex: projectPagerDisplayIndex,
            projectCount: snapshot.projects.count,
            direction: direction,
            distance: distance,
        ) else {
            return false
        }
        performWorkspaceSidebarProjectHaptic(.levelChange)
        finishProjectSwipeCreation()
        return true
    }

    private func finishProjectSwipeNavigationIfNeeded(direction: Int, distance: CGFloat) {
        guard let nextIndex = workspaceSidebarProjectIndexAfterSwipe(
            currentIndex: projectPagerDisplayIndex,
            projectCount: snapshot.projects.count,
            direction: direction,
        ), distance >= workspaceSidebarProjectSwipeNavigateThreshold else {
            performWorkspaceSidebarProjectHaptic(.alignment)
            finishProjectSwipeSnapBack()
            return
        }
        finishProjectSwipeNavigation(to: snapshot.projects[nextIndex].id, direction: direction)
    }
}
extension WorkspaceSidebarView {
    var selectedProjectIndex: Int? {
        let projectId = browsedProjectId ?? snapshot.activeProjectId
        return snapshot.projects.firstIndex { $0.id == projectId }
            ?? snapshot.projects.indices.first
    }

    var projectPagerDisplayIndex: Int? {
        if let projectSwipeStartProjectId,
           let index = snapshot.projects.firstIndex(where: { $0.id == projectSwipeStartProjectId }) {
            return index
        }
        return selectedProjectIndex
    }

    func resetProjectSwipe() {
        projectSwipeTranslation = 0
        projectSwipeStartProjectId = nil
        projectSwipeDidCrossBreakPoint = false
    }

    func resetProjectSwipeWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            resetProjectSwipe()
        }
    }

    func resetTransientSidebarState() {
        browseMode = .activeProject
        showsPinnedActiveWorkspaceForBrowsedProject = true
        activeInUseOverrideWorkspaceName = nil
        isSidebarCollapsing = false
        isSidebarExpanding = false
        finishWorkspaceRename(cancelled: true)
        resetProjectEdgeDrag()
        resetProjectSwipeWithoutAnimation()
    }

    func performWorkspaceSidebarProjectHaptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    func handleProjectEdgeDrag(pointer: CGPoint, expansionProgress: CGFloat) {
        resetProjectEdgeDrag()
    }

    func resetProjectEdgeDrag() {
        // Drag-pointer notifications arrive at pointer frequency; avoid rebuilding every column.
        if lastProjectEdgeDragDirection != nil { lastProjectEdgeDragDirection = nil }
        if lastProjectEdgeDragSwitchAt != .distantPast { lastProjectEdgeDragSwitchAt = .distantPast }
    }

}
extension WorkspaceSidebarView {
    func monitorSelectorSection(
        layout: WorkspaceSidebarConfiguration,
        expansionProgress: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
    ) -> some View {
        WorkspaceSidebarMonitorSelector(
            scopes: snapshot.monitorScopes,
            projects: snapshot.projects,
            selectedScopeId: snapshot.selectedMonitorScopeId,
            activeProjectId: snapshot.activeProjectId,
            browsedProjectId: browsedProjectId,
            expansionProgress: expansionProgress,
            sectionWidth: workspaceSidebarTopSectionWidth(expansionProgress: expansionProgress, layout: layout),
            onSelectScope: { scopeId in
                if scopeId == workspaceSidebarDefaultScopeId {
                    browseMode = .activeProject
                }
                actions.send(.selectMonitorScope(scopeId))
            },
            onSelectProject: { projectId in
                WorkspaceSidebarPanel.panel(for: snapshot.targetMonitorScopeId)?.cancelExpansionWork()
                browseMode = projectId.map { .split(otherProjectId: $0) } ?? .activeProject
                showsPinnedActiveWorkspaceForBrowsedProject = false
            },
            onRenameProject: { project in
                beginProjectRename(project)
            },
            renamingProjectId: $renamingProjectId,
            renamingProjectText: $renamingProjectText,
            onCommitRenameProject: {
                finishProjectRename()
            },
            onCancelRenameProject: {
                finishProjectRename(cancelled: true)
            },
            onSetProjectColor: { project, colorHex in
                actions.send(.setProjectColor(project.id, colorHex: colorHex))
            },
            onDeleteProject: { project in
                actions.send(.deleteProject(project.id))
            },
            showsProjectSelector: !showsAllProjects,
        )
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .padding(.top, snapshot.configuration.topPadding)
        .padding(.bottom, workspaceSidebarSectionGap)
        .zIndex(100)
    }

    func workspaceSidebarTopSectionWidth(expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration? = nil) -> CGFloat {
        let layout = layout ?? snapshot.configuration
        if browsedProjectId != nil {
            return workspaceSidebarSplitSectionWidth(expansionProgress: expansionProgress, layout: layout)
        }
        return workspaceSidebarSectionWidth(expansionProgress, layout: layout)
    }

    func statusSection(
        layout: WorkspaceSidebarConfiguration,
        expansionProgress: CGFloat,
        isCompact: Bool,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
    ) -> some View {
        WorkspaceSidebarStatusView(
            sectionWidth: workspaceSidebarSectionWidth(expansionProgress, layout: layout),
            isCompact: isCompact,
            showsSeconds: snapshot.configuration.showsSeconds,
            showsDate: snapshot.configuration.showsDate,
            showsWeekday: snapshot.configuration.showsWeekday,
            compactScale: layout.compactDockScale,
        )
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .padding(.top, 4)
        .padding(.bottom, workspaceSidebarStatusBottomPadding(isCompact: isCompact, layout: layout) + 4)
    }

    func sidebarSearchSection(
        layout: WorkspaceSidebarConfiguration,
        expansionProgress: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.66))
                .frame(width: 14)

            Text(searchText)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                finishSidebarSearch(clearText: true)
                beginSidebarSearchIfNeeded()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Clear search")
        }
        .padding(.horizontal, 8)
        .frame(width: workspaceSidebarSectionWidth(expansionProgress, layout: layout), height: workspaceSidebarSearchHeight)
        .background {
            RoundedRectangle(cornerRadius: workspaceSidebarDropdownCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.11))
        }
        .overlay {
            RoundedRectangle(cornerRadius: workspaceSidebarDropdownCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .padding(.bottom, workspaceSidebarSectionGap)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
extension WorkspaceSidebarView {
    var dockSurfaceProgress: CGFloat {
        guard snapshot.configuration.showAppIcons else { return 1 }
        let collapsed = snapshot.configuration.expansionStartWidth
        return min(max((dockVisibleWidth - collapsed) / max(snapshot.configuration.expandedWidth - collapsed, 1), 0), 1)
    }

    /// Floating project columns leave the Dock at its resting width while expanded.
    var dockVisibleWidth: CGFloat {
        usesProjectColumns ? min(snapshot.visibleWidth, snapshot.configuration.expansionStartWidth) : snapshot.visibleWidth
    }

    func sidebarShape(layout: WorkspaceSidebarConfiguration) -> some Shape {
        let compactRadius = layout.compactRailWidth / 3
        let outer = snapshot.configuration.showAppIcons ? compactRadius * (1 - dockSurfaceProgress) : 0
        let inner = snapshot.configuration.showAppIcons
            ? compactRadius + (workspaceSidebarPanelRightCornerRadius - compactRadius) * dockSurfaceProgress
            : workspaceSidebarPanelRightCornerRadius
        return WorkspaceSidebarPanelShape(
            leftCornerRadius: layout.dockPosition == .left ? outer : inner,
            rightCornerRadius: layout.dockPosition == .right ? outer : inner,
            continuous: snapshot.configuration.showAppIcons
        )
    }

    func sidebarSurface<S: Shape>(in shape: S) -> some View {
        // Fade to the readable Sidebar backdrop as the Dock expands. At either
        // endpoint only its own background exists; magnification keeps the compact path.
        ZStack {
            if snapshot.configuration.showAppIcons && dockSurfaceProgress < 1 {
                if reduceSidebarTransparency {
                    shape.fill(snapshot.configuration.chromeStyle == .solid
                        ? snapshot.configuration.resolvedSolidChromeColor : Color(white: 0.18))
                } else {
                    WorkspaceSidebarDockSurface(shape: shape, configuration: snapshot.configuration)
                        // Keep an opaque outgoing surface under the incoming fallback.
                        // Two complementary alpha values alone create a transparency dip.
                        .opacity(snapshot.configuration.effectiveGlassOpacity
                            * (snapshot.configuration.sidebarBlur ? Double(1 - dockSurfaceProgress) : 1))
                }
            }
            if dockSurfaceProgress > 0 {
                WorkspaceSidebarSurface(shape: shape, configuration: snapshot.configuration,
                    reduceTransparencyOverride: reduceSidebarTransparency)
                    .opacity(Double(dockSurfaceProgress))
            }
            if snapshot.configuration.usesTabsList {
                // Like a Dia space, the panel takes on the current project's color.
                shape.fill(projectColor(snapshot.activeProjectId).opacity(0.14))
            }
        }
        // This panel has no safe-area inset. Expanding the material here gives the native
        // glass backing layer a rectangular area outside the rounded trailing corners.
        .clipShape(shape)
    }

    func sidebarSwipeCaptureOverlay(expansionProgress: CGFloat) -> some View {
        WorkspaceSidebarProjectSwipeScrollCapture(
            isEnabled: !snapshot.projects.isEmpty &&
                !(showsAllProjects && expansionProgress >= workspaceSidebarRowsRevealProgress),
            onChanged: { horizontalTranslation, verticalTranslation in
                handleProjectSwipeChanged(
                    horizontalTranslation: horizontalTranslation,
                    verticalTranslation: verticalTranslation,
                    expansionProgress: expansionProgress,
                )
            },
            onEnded: { horizontalTranslation, verticalTranslation in
                handleProjectSwipeEnded(
                    horizontalTranslation: horizontalTranslation,
                    verticalTranslation: verticalTranslation,
                    expansionProgress: expansionProgress,
                )
            },
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct WorkspaceSidebarPanelShape: Shape {
    var leftCornerRadius: CGFloat
    var rightCornerRadius: CGFloat
    var continuous: Bool = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(leftCornerRadius, rightCornerRadius) }
        set {
            leftCornerRadius = newValue.first
            rightCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rightCornerRadius, rect.width / 2, rect.height / 2)
        let leftRadius = min(leftCornerRadius, rect.width / 2, rect.height / 2)

        if continuous {
            if #available(macOS 14.0, *) {
                return UnevenRoundedRectangle(cornerRadii: .init(
                    topLeading: leftRadius, bottomLeading: leftRadius,
                    bottomTrailing: radius, topTrailing: radius
                ), style: .continuous).path(in: rect)
            } else if leftRadius == radius {
                return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
            }
        }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + leftRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + leftRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - leftRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + leftRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + leftRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
extension WorkspaceSidebarView {
    @ViewBuilder
    func projectPageSlot(
        layout: WorkspaceSidebarConfiguration,
        index: Int,
        project: WorkspaceSidebarProjectViewModel,
        displayIndex: Int,
        pageWidth: CGFloat,
        expansionProgress: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        topPadding: CGFloat,
        visibleWorkspacesByProject: [WorkspaceProjectId: [WorkspaceSidebarWorkspaceViewModel]],
        swipeDirection: Int?,
    ) -> some View {
        if shouldRenderWorkspaceSidebarProjectPage(
            index: index,
            displayIndex: displayIndex,
            swipeDirection: swipeDirection,
            projectCount: snapshot.projects.count,
        ) {
            workspacePage(
                layout: layout,
                projectId: project.id,
                workspaces: visibleWorkspacesByProject[project.id] ?? [],
                expansionProgress: expansionProgress,
                leadingInset: leadingInset,
                trailingInset: trailingInset,
                topPadding: topPadding,
                isInteractive: index == displayIndex,
                showsPinnedActiveWorkspace: showsPinnedActiveWorkspaceForBrowsedProject,
                showsCreateWorkspace: browsedProjectId == nil,
                allowsActivation: allowsWorkspaceActivation(projectId: project.id),
            )
                    .frame(width: pageWidth, alignment: .topLeading)
                    .allowsHitTesting(index == displayIndex)
        } else {
            Color.clear
                .frame(width: pageWidth, alignment: .topLeading)
                .allowsHitTesting(false)
        }
    }

    /// Tabs mode lists windows as tabs once expanded; the collapsed rail stays the workspace rail.
    @ViewBuilder
    func workspacePage(
        layout: WorkspaceSidebarConfiguration,
        projectId: WorkspaceProjectId,
        workspaces: [WorkspaceSidebarWorkspaceViewModel],
        expansionProgress: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        topPadding: CGFloat,
        isInteractive: Bool,
        showsPinnedActiveWorkspace: Bool = true,
        showsCreateWorkspace: Bool = true,
        allowsActivation: Bool? = nil,
    ) -> some View {
        if workspaceSidebarUsesTabsPage(layout: layout, expansionProgress: expansionProgress) {
            tabsWorkspacePage(layout: layout, projectId: projectId, workspaces: workspaces,
                leadingInset: leadingInset, trailingInset: trailingInset, topPadding: topPadding,
                showsPinnedActiveWorkspace: showsPinnedActiveWorkspace, showsCreateWorkspace: showsCreateWorkspace,
                allowsActivation: allowsActivation)
        } else {
            sectionsWorkspacePage(layout: layout, projectId: projectId, workspaces: workspaces,
                expansionProgress: expansionProgress, leadingInset: leadingInset, trailingInset: trailingInset,
                topPadding: topPadding, isInteractive: isInteractive, showsPinnedActiveWorkspace: showsPinnedActiveWorkspace,
                showsCreateWorkspace: showsCreateWorkspace, allowsActivation: allowsActivation)
        }
    }

    func createWorkspaceSection(layout: WorkspaceSidebarConfiguration, projectId: WorkspaceProjectId,
                                expansionProgress: CGFloat) -> some View {
        let createMonitorScopeId = workspaceSidebarWorkspaceCreateScope(
            selectedScopeId: snapshot.selectedMonitorScopeId,
            targetMonitorScopeId: snapshot.targetMonitorScopeId,
            focusedScopeId: snapshot.focusedMonitorScopeId,
        )
        return WorkspaceSidebarCreateWorkspaceSection(
            projectId: projectId,
            monitorScopeId: createMonitorScopeId,
            dragPreview: snapshot.dropPreview,
            expansionProgress: expansionProgress,
            layout: layout,
            emitsDropTarget: true,
            onCreateWorkspace: {
                actions.send(.createWorkspace(
                    projectId: projectId,
                    monitorScopeId: createMonitorScopeId
                ))
            },
            onDropPayload: { payload in
                switch payload {
                    case .window(let windowId):
                        actions.send(.moveWindowToNewWorkspace(
                            windowId,
                            projectId: projectId,
                            monitorScopeId: createMonitorScopeId,
                        ))
                    case .tabGroup(let representativeWindowId):
                        actions.send(.moveTabGroupToNewWorkspace(
                            representativeWindowId,
                            projectId: projectId,
                            monitorScopeId: createMonitorScopeId,
                        ))
                }
            },
            actions: actions,
        )
    }

    func sectionsWorkspacePage(
        layout: WorkspaceSidebarConfiguration,
        projectId: WorkspaceProjectId,
        workspaces: [WorkspaceSidebarWorkspaceViewModel],
        expansionProgress: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        topPadding: CGFloat,
        isInteractive: Bool,
        showsPinnedActiveWorkspace: Bool = true,
        showsCreateWorkspace: Bool = true,
        allowsActivation: Bool? = nil,
    ) -> some View {
        let horizontal = layout.showAppIcons && layout.dockPosition == .bottom && expansionProgress == 0
        let overflow = dockMagnificationOverflow(layout: layout)
        let growsLeft = layout.dockPosition == .right
        let pinnedWorkspace = showsPinnedActiveWorkspace
            ? pinnedActiveWorkspace(displayedProjectId: projectId, pageWorkspaces: workspaces)
            : nil
        let columnWorkspaces = (pinnedWorkspace.map { [$0] } ?? []) + workspaces
        let appCounts = columnWorkspaces.map { $0.apps.count }
        let origins = workspaceSidebarDockSectionOrigins(appCounts: appCounts, itemSize: layout.dockIconSize)
        let columnOrigin = dockColumnOrigins[projectId] ?? topPadding
        func sectionMotion(index: Int) -> WorkspaceSidebarDockSectionMotion {
            WorkspaceSidebarDockSectionMotion(
                columnOrigin: columnOrigin, sectionOrigin: origins[index],
                itemSize: layout.dockIconSize, appCount: appCounts[index],
                amount: layout.dockMagnificationAmount,
                isEnabled: allowsDockMagnification && expansionProgress == 0 && isInteractive,
                position: layout.dockPosition
            )
        }
        // Build the workspace/action tree from the snapshot once. Only the small section
        // modifiers below read the per-frame environment; cursor motion must not recreate
        // every workspace's menus, gestures and controls through a ForEach closure.
        let content = WorkspaceSidebarWorkspaceStack(isLazy: layout.showAppIcons, horizontal: horizontal) {
            if let pinnedWorkspace {
                workspaceSection(
                    layout: layout,
                    workspace: pinnedWorkspace,
                    expansionProgress: expansionProgress,
                    emitsDropTarget: true,
                    allowsWorkspaceActivation: false,
                    isPinnedActiveWorkspace: true,
                    projectContextLabel: projectName(snapshot.activeProjectId),
                    projectContextColor: projectColor(snapshot.activeProjectId)
                )
                .modifier(sectionMotion(index: 0))
            }
            ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                workspaceSection(
                    layout: layout,
                    workspace: workspace,
                    expansionProgress: expansionProgress,
                    emitsDropTarget: true,
                    allowsWorkspaceActivation: allowsActivation ?? allowsWorkspaceActivation(projectId: projectId),
                    isPinnedActiveWorkspace: false,
                    projectContextLabel: browsedProjectId != nil && projectId != snapshot.activeProjectId ? projectName(projectId) : nil,
                    projectContextColor: browsedProjectId != nil && projectId != snapshot.activeProjectId ? projectColor(projectId) : nil
                )
                .modifier(sectionMotion(index: index + (pinnedWorkspace == nil ? 0 : 1)))
                .overlay(alignment: .topLeading) {
                    if layout.showAppIcons,
                       pinnedWorkspace != nil || workspace.id != workspaces.first?.id
                    {
                        WorkspaceSidebarDockSeparator(
                            expansionProgress: expansionProgress,
                            layout: layout
                        )
                        .offset(x: horizontal ? -3 : 0, y: horizontal ? 0 : -3)
                    }
                }
            }
            if showsCreateWorkspace && workspaceSidebarShowsCreateWorkspace(selectedScopeId: snapshot.selectedMonitorScopeId) {
                createWorkspaceSection(layout: layout, projectId: projectId, expansionProgress: expansionProgress)
            }
        }
        return GeometryReader { viewport in
            ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
                content
                .background {
                    GeometryReader { content in
                        let rect = content.frame(in: .named("workspaceSidebarSurface"))
                        Color.clear.preference(key: WorkspaceSidebarDockColumnOriginPreference.self,
                            value: [projectId: horizontal ? rect.minX : rect.minY])
                    }
                }
                .padding(horizontal ? .top : .leading, leadingInset)
                .padding(horizontal ? .bottom : .trailing, trailingInset)
                .padding(horizontal ? .leading : .top, topPadding)
                .padding(horizontal ? .trailing : .bottom, 10)
                .frame(width: horizontal ? nil : viewport.size.width,
                    height: horizontal ? viewport.size.height : nil, alignment: .leading)
                .padding(horizontal ? .top : (growsLeft ? .leading : .trailing), overflow)
            }
            .frame(width: viewport.size.width + (horizontal ? 0 : overflow),
                height: viewport.size.height + (horizontal ? overflow : 0), alignment: .leading)
            .offset(x: growsLeft && !horizontal ? -overflow : 0, y: horizontal ? -overflow : 0)
            .transformPreference(WorkspaceSidebarDockIconFramesPreference.self) { frames in
                let frame = viewport.frame(in: .named("workspaceSidebarContent"))
                let visible = CGRect(x: frame.minX - (growsLeft && !horizontal ? overflow : 0),
                    y: frame.minY - (horizontal ? overflow : 0),
                    width: frame.width + (horizontal ? 0 : overflow),
                    height: frame.height + (horizontal ? overflow : 0))
                frames = frames.map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
            }
            .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) { targets in
                targets = workspaceSidebarClippedDropTargets(targets,
                    to: viewport.frame(in: .named("workspaceSidebarContent")))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func splitWorkspacePage(
        layout: WorkspaceSidebarConfiguration,
        activeProjectId: WorkspaceProjectId,
        browsedProjectId: WorkspaceProjectId,
        expansionProgress: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        topPadding: CGFloat,
        visibleWorkspacesByProject: [WorkspaceProjectId: [WorkspaceSidebarWorkspaceViewModel]],
    ) -> some View {
        let sectionWidth = workspaceSidebarSectionWidth(expansionProgress, layout: layout)
        return HStack(alignment: .top, spacing: workspaceSidebarSplitPaneGap) {
            workspacePage(
                layout: layout,
                projectId: activeProjectId,
                workspaces: visibleWorkspacesByProject[activeProjectId] ?? [],
                expansionProgress: expansionProgress,
                leadingInset: leadingInset,
                trailingInset: 0,
                topPadding: topPadding,
                isInteractive: true,
                showsPinnedActiveWorkspace: false,
                showsCreateWorkspace: true,
                allowsActivation: true,
            )
            .frame(width: sectionWidth + leadingInset, alignment: .topLeading)

            workspacePage(
                layout: layout,
                projectId: browsedProjectId,
                workspaces: visibleWorkspacesByProject[browsedProjectId] ?? [],
                expansionProgress: expansionProgress,
                leadingInset: 0,
                trailingInset: trailingInset,
                topPadding: topPadding,
                isInteractive: true,
                showsPinnedActiveWorkspace: false,
                showsCreateWorkspace: true,
                allowsActivation: false,
            )
            .frame(width: sectionWidth + trailingInset, alignment: .topLeading)
        }
        .frame(
            width: workspaceSidebarSplitSectionWidth(expansionProgress: expansionProgress) + leadingInset + trailingInset,
            alignment: .topLeading
        )
    }

    func workspaceSection(
        layout: WorkspaceSidebarConfiguration,
        workspace: WorkspaceSidebarWorkspaceViewModel,
        expansionProgress: CGFloat,
        emitsDropTarget: Bool,
        allowsWorkspaceActivation: Bool,
        isPinnedActiveWorkspace: Bool,
        projectContextLabel: String? = nil,
        projectContextColor: Color? = nil,
        allowsProjectMove: Bool = false
    ) -> WorkspaceSidebarWorkspaceSection {
        let isFromOtherDisplay = false
        let isInUseOnOtherDisplay = allowsWorkspaceActivation &&
            !isPinnedActiveWorkspace &&
            workspaceSidebarWorkspaceIsInUseOnOtherDisplay(
                workspace,
                selectedScopeId: snapshot.targetMonitorScopeId
            )
        return WorkspaceSidebarWorkspaceSection(
            workspace: workspace,
            dragPreview: snapshot.dropPreview,
            expansionProgress: expansionProgress,
            layout: layout,
            emitsDropTarget: emitsDropTarget,
            isFromOtherDisplay: isFromOtherDisplay,
            isInUseOnOtherDisplay: isInUseOnOtherDisplay,
            isOnFocusedMonitor: workspace.monitorScopeId == snapshot.focusedMonitorScopeId,
            allowsWorkspaceActivation: allowsWorkspaceActivation,
            isPinnedActiveWorkspace: isPinnedActiveWorkspace,
            isActiveOnTargetMonitor: workspace.monitorScopeId == snapshot.targetMonitorScopeId && workspace.isVisible,
            projectContextLabel: projectContextLabel,
            projectContextColor: projectContextColor,
            renamingWorkspaceName: $renamingWorkspaceName,
            renamingWorkspaceText: $renamingWorkspaceText,
            onBeginRenameWorkspace: {
                beginWorkspaceRename(workspace)
            },
            onCommitRenameWorkspace: {
                finishWorkspaceRename()
            },
            onCancelRenameWorkspace: {
                finishWorkspaceRename(cancelled: true)
            },
            selectedSearchTarget: searchText.isEmpty ? nil : selectedSearchTarget,
            isSearchFiltering: !searchText.isEmpty,
            activeInUseOverrideWorkspaceName: $activeInUseOverrideWorkspaceName,
            pendingInUseOverrideAppId: $pendingInUseOverrideAppId,
            actions: actions,
            allowsProjectMove: allowsProjectMove,
        )
    }

    func allowsWorkspaceActivation(projectId: WorkspaceProjectId) -> Bool {
        let showsLocalDock = snapshot.configuration.showAppIcons &&
            snapshot.selectedMonitorScopeId == snapshot.targetMonitorScopeId
        return (snapshot.selectedMonitorScopeId == workspaceSidebarDefaultScopeId || showsLocalDock) &&
            browsedProjectId == nil &&
            projectId == snapshot.activeProjectId
    }

    private func projectColorHex(_ projectId: WorkspaceProjectId) -> String? {
        snapshot.projects.first { $0.id == projectId }?.colorHex
    }

    func projectName(_ projectId: WorkspaceProjectId) -> String {
        snapshot.projects.first { $0.id == projectId }?.displayName ?? "Project"
    }

    func projectColor(_ projectId: WorkspaceProjectId) -> Color {
        workspaceSidebarProjectColor(projectId: projectId, configuredHex: projectColorHex(projectId))
    }

    func pinnedActiveWorkspace(
        displayedProjectId: WorkspaceProjectId,
        pageWorkspaces: [WorkspaceSidebarWorkspaceViewModel]
    ) -> WorkspaceSidebarWorkspaceViewModel? {
        guard browsedProjectId != nil,
              displayedProjectId != snapshot.activeProjectId,
              !pageWorkspaces.contains(where: { workspaceIsActiveOnTargetMonitor($0) }),
              let focusedWorkspace = snapshot.workspaces.first(where: { workspaceIsActiveOnTargetMonitor($0) }),
              workspaceSidebarWorkspaceMatchesScope(
                focusedWorkspace,
                selectedScopeId: snapshot.selectedMonitorScopeId,
                focusedMonitorScopeId: snapshot.focusedMonitorScopeId
              )
        else {
            return nil
        }
        return focusedWorkspace
    }

    private func workspaceIsActiveOnTargetMonitor(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> Bool {
        workspace.isVisible && workspace.monitorScopeId == snapshot.targetMonitorScopeId
    }

    var allowsDockMagnification: Bool {
        dockMagnificationBlockers.isEmpty
    }

    var dockMagnificationBlockers: WorkspaceSidebarDockPointerBlockers {
        var blockers: WorkspaceSidebarDockPointerBlockers = []
        if !snapshot.configuration.showAppIcons || !snapshot.configuration.dockMagnification { blockers.insert(.disabled) }
        // Floating project columns appear as soon as expansion begins; the Dock stops magnifying then too.
        if snapshot.visibleWidth > snapshot.configuration.compactRailWidth + 0.5
            || (usesProjectColumns && snapshot.visibleWidth > snapshot.configuration.expansionStartWidth) {
            blockers.insert(.expanded)
        }
        if reduceDockMotion { blockers.insert(.reduceMotion) }
        if dockMenuTracking { blockers.insert(.menu) }
        if isSearchEditing || renamingProjectId != nil || renamingWorkspaceName != nil { blockers.insert(.editing) }
        if snapshot.dropPreview != nil { blockers.insert(.drop) }
        if projectSwipeTranslation != 0 { blockers.insert(.swipe) }
        return blockers
    }

    func dockMagnificationOverflow(layout: WorkspaceSidebarConfiguration) -> CGFloat {
        dockSurfaceProgress == 0 && projectSwipeTranslation == 0 ? layout.dockMagnificationOverflow : 0
    }

    func dockMagnificationPointer(_ pointer: CGPoint?, in surfaceFrame: CGRect,
                                  layout: WorkspaceSidebarConfiguration, iconFrames: [CGRect] = []) -> CGPoint? {
        // The panel also covers transparent space beside and above the compact Dock.
        // Only the glass surface and actual protruding icons own hover magnification.
        guard allowsDockMagnification, let pointer,
              sidebarShape(layout: layout).path(in: surfaceFrame).contains(pointer) || iconFrames.contains(where: { $0.contains(pointer) })
        else { return nil }
        return pointer
    }

    func dockColumnGrowth(layout: WorkspaceSidebarConfiguration) -> (CGPoint?, CGFloat, CGRect) -> CGFloat {
        guard allowsDockMagnification, dockSurfaceProgress == 0 else { return { _, _, _ in 0 } }
        let projectId = projectPagerDisplayIndex.flatMap { snapshot.projects.indices.contains($0) ? snapshot.projects[$0].id : nil } ?? snapshot.activeProjectId
        var workspaces = currentFilteredProjectWorkspaces()
        if showsPinnedActiveWorkspaceForBrowsedProject,
           let pinned = pinnedActiveWorkspace(displayedProjectId: projectId, pageWorkspaces: workspaces) {
            workspaces.insert(pinned, at: 0)
        }
        // Filtering and grouping depend on the snapshot, not the display frame.
        let appCounts = workspaces.map { $0.apps.count }
        let itemSize = layout.dockIconSize
        let amount = layout.dockMagnificationAmount
        let horizontal = layout.dockPosition == .bottom
        let origin = dockColumnOrigins[projectId] ?? (shouldShowCompactMonitorSelector ? 0 : snapshot.configuration.topPadding)
        return { pointer, strength, restingSurface in
            guard let pointer else { return 0 }
            return WorkspaceSidebarDockColumnMagnification(appCounts: appCounts, itemSize: itemSize,
                amount: amount, pointerY: (horizontal ? pointer.x - restingSurface.minX : pointer.y - restingSurface.minY) - origin,
                strength: strength).growth
        }
    }

    var compactDockContentHeight: CGFloat {
        compactDockContentHeight(layout: snapshot.configuration)
    }

    func compactDockContentHeight(layout: WorkspaceSidebarConfiguration) -> CGFloat {
        let reminderCount = hiddenWorkspaceAppReminders.count
        return dockSizingPages.map { workspaces in
            workspaceSidebarDockContentHeight(
                appCounts: workspaces.map { $0.apps.count },
                configuration: layout,
                showsCreateWorkspace: browsedProjectId == nil && workspaceSidebarShowsCreateWorkspace(selectedScopeId: snapshot.selectedMonitorScopeId),
                showsMonitorSelector: shouldShowCompactMonitorSelector,
                projectCount: snapshot.projects.count, reminderCount: reminderCount
            )
        }.max() ?? 0
    }

    func dockLayout(availableHeight: CGFloat) -> WorkspaceSidebarConfiguration {
        var layout = snapshot.configuration
        guard layout.showAppIcons else { return layout }
        let reminderCount = hiddenWorkspaceAppReminders.count
        let sizes = dockSizingPages.map { workspaces in
            workspaceSidebarFittedDockIconSize(
                appCounts: workspaces.map { snapshot.dockRestingAppCounts?[$0.name] ?? $0.apps.count },
                configuration: layout, availableHeight: availableHeight,
                showsCreateWorkspace: browsedProjectId == nil && workspaceSidebarShowsCreateWorkspace(selectedScopeId: snapshot.selectedMonitorScopeId),
                showsMonitorSelector: shouldShowCompactMonitorSelector,
                projectCount: snapshot.projects.count, reminderCount: reminderCount
            )
        }
        layout.dockIconSize = sizes.min() ?? layout.dockIconSize
        return layout
    }

    func fittedVisibleWidth(layout: WorkspaceSidebarConfiguration) -> CGFloat {
        guard layout.showAppIcons else { return snapshot.visibleWidth }
        let configuredWidth = snapshot.configuration.compactRailWidth
        let visibleWidth = dockVisibleWidth
        // Hidden -> compact has its own proportional reveal, including intermediate
        // hover cues. Subtracting the fitted difference would hide the first part.
        if visibleWidth < configuredWidth {
            return max(visibleWidth, 0) * layout.compactRailWidth / configuredWidth
        }
        // Expansion is driven by the native panel's configured width. Blend from the
        // fitted resting shelf to that same expanded endpoint without resizing on hover.
        return max(0, visibleWidth + (layout.compactRailWidth - configuredWidth)
            * (1 - dockSurfaceProgress))
    }

    private var dockSizingPages: [[WorkspaceSidebarWorkspaceViewModel]] {
        let visibleByProject = workspaceSidebarVisibleWorkspacesByProject(
            workspaces: snapshot.workspaces,
            selectedScopeId: snapshot.selectedMonitorScopeId,
            focusedMonitorScopeId: snapshot.focusedMonitorScopeId,
            browsedProjectId: browsedProjectId
        )
        var projectIds = [snapshot.activeProjectId]
        if let index = projectPagerDisplayIndex, snapshot.projects.indices.contains(index) {
            projectIds = [snapshot.projects[index].id]
            if let direction = workspaceSidebarProjectSwipeDirection(
                horizontalTranslation: projectSwipeTranslation,
                verticalTranslation: 0,
                minimumDistance: 1
            ), let nextIndex = workspaceSidebarProjectIndexAfterSwipe(
                currentIndex: index,
                projectCount: snapshot.projects.count,
                direction: direction
            ) {
                projectIds.append(snapshot.projects[nextIndex].id)
            }
        }
        return projectIds.map { projectId in
            var workspaces = visibleByProject[projectId] ?? []
            if showsPinnedActiveWorkspaceForBrowsedProject,
               let pinned = pinnedActiveWorkspace(displayedProjectId: projectId, pageWorkspaces: workspaces) {
                workspaces.insert(pinned, at: 0)
            }
            return workspaces
        }
    }
}
