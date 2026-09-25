import AppKit
import SwiftUI

// Proportions follow Dia's sidebar: airy rows, a bright pill for the active tab, and
// tinted, rounded cards for groups.
let workspaceSidebarTabRowHeight: CGFloat = 30
let workspaceSidebarTabFolderHeaderHeight: CGFloat = 30
let workspaceSidebarTabIconSize: CGFloat = 16
let workspaceSidebarTabGroupIndent: CGFloat = 14
let workspaceSidebarTabCornerRadius: CGFloat = 8
let workspaceSidebarTabFolderCornerRadius: CGFloat = 12
let workspaceSidebarTabCloseSlotWidth: CGFloat = 24

/// One line of a workspace folder in Tabs mode.
enum WorkspaceSidebarTabRow: Hashable, Identifiable {
    case window(WorkspaceSidebarWindowViewModel, isGroupChild: Bool)
    case group(WorkspaceSidebarTabGroupViewModel)

    var id: String {
        switch self {
            case .window(let window, _): "window:\(window.windowId)"
            case .group(let group): group.id
        }
    }
}

/// The windows a stack shows: every window, not one per tab, unless a search narrowed it.
/// Search filtering and keyboard selection use the same list.
func workspaceSidebarTabGroupWindows(_ group: WorkspaceSidebarTabGroupViewModel) -> [WorkspaceSidebarWindowViewModel] {
    if let matches = group.searchVisibleTabs { return matches }
    return group.allWindows.isEmpty ? group.tabs : group.allWindows
}

/// Rows for one folder. A collapsed folder still shows its focused window, so the window in
/// use is never hidden; a search shows every match regardless of collapsing.
func workspaceSidebarTabRows(
    for workspace: WorkspaceSidebarWorkspaceViewModel,
    isCollapsed: Bool,
    isSearching: Bool,
) -> [WorkspaceSidebarTabRow] {
    let showsAll = !isCollapsed || isSearching
    var rows: [WorkspaceSidebarTabRow] = []
    for item in workspace.items {
        switch item.kind {
            case .window(let window):
                if showsAll || window.isFocused { rows.append(.window(window, isGroupChild: false)) }
            case .tabGroup(let group):
                let windows = workspaceSidebarTabGroupWindows(group)
                if showsAll {
                    rows.append(.group(group))
                    rows += windows.map { .window($0, isGroupChild: true) }
                } else {
                    rows += windows.filter(\.isFocused).map { .window($0, isGroupChild: false) }
                }
        }
    }
    return rows
}

/// Windows a folder holds, counting every window of each stack.
func workspaceSidebarTabWindowCount(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> Int {
    workspace.items.reduce(0) { count, item in
        switch item.kind {
            case .window: count + 1
            case .tabGroup(let group): count + max(group.windowCount, workspaceSidebarTabGroupWindows(group).count)
        }
    }
}

/// Folders get a stable color of their own, like Dia's tab groups.
func workspaceSidebarTabFolderColor(_ workspaceName: String) -> Color {
    Color(hue: workspaceSidebarProjectHue(projectId: WorkspaceProjectId(workspaceName)), saturation: 0.42, brightness: 0.92)
}

/// Collapsed folders whose workspace no longer exists, so a new workspace reusing the name
/// starts open.
func workspaceSidebarPrunedCollapsedFolders(_ collapsed: Set<String>, workspaceNames: [String]) -> Set<String> {
    collapsed.intersection(workspaceNames)
}

/// How a folder responds to clicks. It mirrors the Sidebar's rules: a browsed or pinned
/// workspace isn't activated from its rows, and one shown on another display asks first.
@MainActor
struct WorkspaceSidebarTabActivation {
    let allowsActivation: Bool
    let isInUseOnOtherDisplay: Bool
    let requestOverride: () -> Void

    func select(_ action: WorkspaceSidebarAction, send: @MainActor (WorkspaceSidebarAction) -> Void) {
        guard allowsActivation, !isWorkspaceSidebarDragInProgress() else { return }
        if isInUseOnOtherDisplay {
            requestOverride()
            return
        }
        send(action)
    }
}

struct WorkspaceSidebarTabRowView: View {
    let window: WorkspaceSidebarWindowViewModel
    let indent: CGFloat
    let isSearchSelected: Bool
    let isDragSource: Bool
    let actions: WorkspaceSidebarActions
    let onSelect: () -> Void
    @State private var isHovered = false

    private var title: String { window.title ?? window.appName }
    private var isActive: Bool { window.isFocused }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    WorkspaceSidebarTabIcon(bundleId: window.appBundleId, bundlePath: window.appBundlePath)
                    Text(title)
                        .font(.system(size: 13, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? Color.black.opacity(0.86) : Color.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10 + indent)
                .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, maxHeight: workspaceSidebarTabRowHeight,
                    alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(window.appName)")
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityAction(named: "Close") { close() }
            .help(window.title.map { "\(window.appName) — \($0)" } ?? window.appName)
            // A sibling of the row button in a reserved slot: closing never also focuses the
            // window, and the title doesn't shift when the button appears.
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isActive ? Color.black.opacity(0.55) : Color.white.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isActive ? Color.black.opacity(0.07) : Color.white.opacity(0.1))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Window")
            .accessibilityHidden(true)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .frame(width: workspaceSidebarTabCloseSlotWidth)
        }
        .background {
            RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                .fill(backgroundFill)
                .shadow(color: isActive ? Color.black.opacity(0.22) : .clear, radius: 3, y: 1)
        }
        .overlay {
            WindowMiddleClickCatcher(windowId: window.windowId) { close() }
        }
        .opacity(isDragSource ? 0.45 : 1)
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: true,
            onChanged: { actions.windowDragChanged(window.windowId, $0) },
            onEnded: { actions.windowDragEnded(window.windowId, $0) },
        ))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Close Window") { close() }
        }
    }

    private func close() {
        // A drag that started on the close button must not close the window on release.
        guard !isWorkspaceSidebarDragInProgress() else { return }
        actions.send(.closeWindow(window.windowId))
    }

    private var backgroundFill: Color {
        if isActive { return Color.white.opacity(0.92) }
        if isHovered || isSearchSelected { return Color.white.opacity(0.08) }
        return .clear
    }
}

struct WorkspaceSidebarTabIcon: View {
    let bundleId: String?
    let bundlePath: String?
    var size: CGFloat = workspaceSidebarTabIconSize

    var body: some View {
        AppIconView(bundleIdentifier: bundleId, bundlePath: bundlePath) { icon in
            if let icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "macwindow").resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
    }
}

struct WorkspaceSidebarTabGroupRowView: View {
    let group: WorkspaceSidebarTabGroupViewModel
    let actions: WorkspaceSidebarActions
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        let windows = workspaceSidebarTabGroupWindows(group)
        let count = max(group.windowCount, windows.count)
        Button(action: onSelect) {
            HStack(spacing: 9) {
                // A small cluster of the stack's icons, as Dia shows a collapsed group.
                ZStack {
                    ForEach(Array(windows.prefix(2).enumerated()), id: \.offset) { index, window in
                        WorkspaceSidebarTabIcon(bundleId: window.appBundleId, bundlePath: window.appBundlePath, size: 11)
                            .offset(x: index == 0 ? -3 : 3, y: index == 0 ? -3 : 3)
                    }
                }
                .frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
                Text(group.title.isEmpty ? "Stack" : group.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.4))
                    .frame(width: workspaceSidebarTabCloseSlotWidth)
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.06) : .clear)
        }
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: true,
            onChanged: { actions.tabGroupDragChanged(group.representativeWindowId, $0) },
            onEnded: { actions.tabGroupDragEnded(group.representativeWindowId, $0) },
        ))
        .onHover { isHovered = $0 }
        .accessibilityLabel("Stack: \(group.title), \(count) windows")
    }
}

struct WorkspaceSidebarTabFolderView: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let rows: [WorkspaceSidebarTabRow]
    let windowCount: Int
    let isCollapsed: Bool
    let isSearching: Bool
    let isActive: Bool
    let isDropTarget: Bool
    let dragSourceWindowId: UInt32?
    let selectedSearchTarget: WorkspaceSidebarSearchSelection?
    let activation: WorkspaceSidebarTabActivation
    let isShowingOverride: Bool
    let projectContext: (label: String, color: Color)?
    let isRenaming: Bool
    @Binding var renamingText: String
    let actions: WorkspaceSidebarActions
    let onToggleCollapsed: () -> Void
    let onCommitOverride: () -> Void
    let onCancelOverride: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: @MainActor @Sendable () -> Void
    let onCancelRename: @MainActor @Sendable () -> Void
    @State private var isHeaderHovered = false

    private var color: Color { workspaceSidebarTabFolderColor(workspace.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            ForEach(rows) { row in
                switch row {
                    case .window(let window, let isGroupChild):
                        WorkspaceSidebarTabRowView(
                            window: window,
                            indent: isGroupChild ? workspaceSidebarTabGroupIndent : 0,
                            isSearchSelected: selectedSearchTarget == .window(window.windowId),
                            isDragSource: dragSourceWindowId == window.windowId,
                            actions: actions,
                            onSelect: { activation.select(.selectWindow(window.windowId), send: actions.send) },
                        )
                        .id(row.id)
                    case .group(let group):
                        WorkspaceSidebarTabGroupRowView(group: group, actions: actions,
                            onSelect: { activation.select(.selectWindow(group.representativeWindowId), send: actions.send) })
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.bottom, rows.isEmpty ? 0 : 5)
        .background {
            RoundedRectangle(cornerRadius: workspaceSidebarTabFolderCornerRadius, style: .continuous)
                .fill(color.opacity(isDropTarget ? 0.26 : (isActive ? 0.16 : 0.1)))
                .overlay {
                    RoundedRectangle(cornerRadius: workspaceSidebarTabFolderCornerRadius, style: .continuous)
                        .strokeBorder(color.opacity(isDropTarget ? 0.7 : 0.18), lineWidth: isDropTarget ? 1 : 0.5)
                }
        }
        .overlay {
            if isShowingOverride {
                WorkspaceSidebarInUseOverrideOverlay(
                    text: workspace.monitorName.map { "In use on \($0)" } ?? "In use on another display",
                    onOverride: onCommitOverride,
                    onCancel: onCancelOverride,
                )
            }
        }
        .background {
            // Dropping a dragged tab anywhere on the folder moves the window into it.
            GeometryReader { geometry in
                Color.clear.preference(
                    key: WorkspaceSidebarDropTargetPreferenceKey.self,
                    value: [WorkspaceSidebarDropTargetFrame(
                        kind: .workspace(workspace.name),
                        frame: geometry.frame(in: .named("workspaceSidebarContent")),
                    )],
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            // A search shows every match, so collapsing would visibly do nothing.
            if !isSearching {
                Button(action: onToggleCollapsed) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(color.opacity(isHeaderHovered ? 1 : 0.75))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 16, height: workspaceSidebarTabFolderHeaderHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(workspace.displayName)
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                .accessibilityHint(isCollapsed ? "Shows the folder's windows" : "Hides the folder's windows")
            }
            if isRenaming {
                WorkspaceSidebarWorkspaceRenameField(
                    text: $renamingText,
                    workspaceName: workspace.name,
                    onCommit: onCommitRename,
                    onCancel: onCancelRename,
                )
            } else {
                Button {
                    activation.select(.selectWorkspace(workspace.name), send: actions.send)
                } label: {
                    HStack(spacing: 6) {
                        Text(workspace.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(color.opacity(isActive ? 1 : 0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let savedState = workspace.savedState {
                            Image(systemName: savedState.isPinnedToDisplay ? "pin.fill" : "bookmark.fill")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(color.opacity(0.7))
                                .accessibilityLabel(workspaceSidebarSavedWorkspaceDescription(savedState))
                        }
                        if let projectContext {
                            Text(projectContext.label)
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(projectContext.color.opacity(0.9))
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .frame(height: 15)
                                .background { Capsule(style: .continuous).fill(projectContext.color.opacity(0.14)) }
                        }
                        Spacer(minLength: 0)
                        Text("\(windowCount)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.38))
                            .frame(width: workspaceSidebarTabCloseSlotWidth)
                    }
                    .padding(.leading, isSearching ? 10 : 0)
                    .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabFolderHeaderHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(workspaceSidebarWorkspaceTooltip(workspace))
                .accessibilityLabel("Workspace \(workspace.displayName), \(windowCount) windows")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(.leading, 5)
        .onHover { isHeaderHovered = $0 }
        .contextMenu {
            WorkspaceSidebarWorkspaceMenuContent(workspace: workspace, rename: onBeginRename, send: actions.send)
        }
    }
}

/// Dia's quiet "+ New Tab" row, here making a workspace. A dragged tab dropped on it gets a
/// workspace of its own.
struct WorkspaceSidebarTabNewWorkspaceRow: View {
    let projectId: WorkspaceProjectId
    let monitorScopeId: String
    let isDropTarget: Bool
    let onCreate: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onCreate) {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
                Text("New Workspace")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(isHovered || isDropTarget ? 0.8 : 0.45))
            .padding(.leading, 15)
            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                .fill(Color.white.opacity(isDropTarget ? 0.12 : (isHovered ? 0.06 : 0)))
        }
        .onHover { isHovered = $0 }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: WorkspaceSidebarDropTargetPreferenceKey.self,
                    value: [WorkspaceSidebarDropTargetFrame(
                        kind: .newWorkspace(projectId: projectId, monitorScopeId: monitorScopeId),
                        frame: geometry.frame(in: .named("workspaceSidebarContent")),
                    )],
                )
            }
        }
        .accessibilityLabel("New Workspace")
    }
}

extension WorkspaceSidebarView {
    func tabsWorkspacePage(
        layout: WorkspaceSidebarConfiguration,
        projectId: WorkspaceProjectId,
        workspaces: [WorkspaceSidebarWorkspaceViewModel],
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        topPadding: CGFloat,
        showsPinnedActiveWorkspace: Bool,
        showsCreateWorkspace: Bool,
        allowsActivation: Bool?,
    ) -> some View {
        let pinnedWorkspace = showsPinnedActiveWorkspace
            ? pinnedActiveWorkspace(displayedProjectId: projectId, pageWorkspaces: workspaces)
            : nil
        let folders = (pinnedWorkspace.map { [$0] } ?? []) + workspaces
        let isSearching = !searchText.isEmpty
        let pageAllowsActivation = allowsActivation ?? allowsWorkspaceActivation(projectId: projectId)
        let focusedRowId = folders.lazy.compactMap { workspaceSidebarFocusedTabRowId(in: $0) }.first
        let createMonitorScopeId = workspaceSidebarWorkspaceCreateScope(
            selectedScopeId: snapshot.selectedMonitorScopeId,
            targetMonitorScopeId: snapshot.targetMonitorScopeId,
            focusedScopeId: snapshot.focusedMonitorScopeId,
        )
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(folders) { workspace in
                            tabFolder(workspace, isPinned: workspace.id == pinnedWorkspace?.id,
                                projectId: projectId, pageAllowsActivation: pageAllowsActivation, isSearching: isSearching)
                        }
                        if showsCreateWorkspace && workspaceSidebarShowsCreateWorkspace(selectedScopeId: snapshot.selectedMonitorScopeId) {
                            WorkspaceSidebarTabNewWorkspaceRow(
                                projectId: projectId,
                                monitorScopeId: createMonitorScopeId,
                                isDropTarget: snapshot.dropPreview?.targetsNewWorkspace == true
                                    && snapshot.dropPreview?.targetProjectId == projectId,
                                onCreate: {
                                    actions.send(.createWorkspace(projectId: projectId, monitorScopeId: createMonitorScopeId))
                                },
                            )
                        }
                    }
                    .padding(.leading, leadingInset)
                    .padding(.trailing, trailingInset)
                    .padding(.top, topPadding)
                    .padding(.bottom, 10)
                    .frame(width: viewport.size.width, alignment: .leading)
                }
                // The list is rebuilt when the panel expands; show the window in use.
                .onAppear {
                    if let focusedRowId { proxy.scrollTo(focusedRowId) }
                }
                .onChange(of: focusedRowId) { rowId in
                    if let rowId { proxy.scrollTo(rowId) }
                }
            }
            .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) { targets in
                targets = workspaceSidebarClippedDropTargets(targets,
                    to: viewport.frame(in: .named("workspaceSidebarContent")))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tabFolder(
        _ workspace: WorkspaceSidebarWorkspaceViewModel,
        isPinned: Bool,
        projectId: WorkspaceProjectId,
        pageAllowsActivation: Bool,
        isSearching: Bool,
    ) -> WorkspaceSidebarTabFolderView {
        let isCollapsed = collapsedTabFolderNames.contains(workspace.name)
        // The pinned active workspace is already in use: its header does nothing, as in the Sidebar.
        let allowsActivation = pageAllowsActivation && !isPinned
        let isInUseOnOtherDisplay = allowsActivation &&
            workspaceSidebarWorkspaceIsInUseOnOtherDisplay(workspace, selectedScopeId: snapshot.targetMonitorScopeId)
        let showsProjectContext = isPinned || (browsedProjectId != nil && projectId != snapshot.activeProjectId)
        let contextProjectId = isPinned ? snapshot.activeProjectId : projectId
        return WorkspaceSidebarTabFolderView(
            workspace: workspace,
            rows: workspaceSidebarTabRows(for: workspace, isCollapsed: isCollapsed, isSearching: isSearching),
            windowCount: workspaceSidebarTabWindowCount(workspace),
            isCollapsed: isCollapsed && !isSearching,
            isSearching: isSearching,
            isActive: workspace.monitorScopeId == snapshot.targetMonitorScopeId && workspace.isVisible,
            isDropTarget: snapshot.dropPreview?.targetWorkspaceName == workspace.name,
            dragSourceWindowId: snapshot.dropPreview?.sourceWindowId,
            selectedSearchTarget: isSearching ? selectedSearchTarget : nil,
            activation: WorkspaceSidebarTabActivation(
                allowsActivation: allowsActivation,
                isInUseOnOtherDisplay: isInUseOnOtherDisplay,
                requestOverride: {
                    pendingInUseOverrideAppId = nil
                    activeInUseOverrideWorkspaceName = workspace.name
                },
            ),
            isShowingOverride: isInUseOnOtherDisplay && activeInUseOverrideWorkspaceName == workspace.name,
            projectContext: showsProjectContext
                ? (projectName(contextProjectId), projectColor(contextProjectId))
                : nil,
            isRenaming: renamingWorkspaceName == workspace.name,
            renamingText: $renamingWorkspaceText,
            actions: actions,
            onToggleCollapsed: {
                if collapsedTabFolderNames.remove(workspace.name) == nil {
                    collapsedTabFolderNames.insert(workspace.name)
                }
            },
            onCommitOverride: {
                activeInUseOverrideWorkspaceName = nil
                actions.send(.overrideWorkspaceInUse(workspace.name))
            },
            onCancelOverride: { activeInUseOverrideWorkspaceName = nil },
            onBeginRename: { beginWorkspaceRename(workspace) },
            onCommitRename: { finishWorkspaceRename() },
            onCancelRename: { finishWorkspaceRename(cancelled: true) },
        )
    }
}

/// The row of the window in use, for scrolling it into view.
func workspaceSidebarFocusedTabRowId(in workspace: WorkspaceSidebarWorkspaceViewModel) -> String? {
    for item in workspace.items {
        switch item.kind {
            case .window(let window) where window.isFocused:
                return "window:\(window.windowId)"
            case .tabGroup(let group):
                if let window = workspaceSidebarTabGroupWindows(group).first(where: \.isFocused) {
                    return "window:\(window.windowId)"
                }
            default:
                continue
        }
    }
    return nil
}
