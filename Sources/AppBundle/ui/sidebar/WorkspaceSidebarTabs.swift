import AppKit
import SwiftUI

let workspaceSidebarTabRowHeight: CGFloat = 28
let workspaceSidebarTabFolderHeaderHeight: CGFloat = 26
let workspaceSidebarTabIconSize: CGFloat = 16
let workspaceSidebarTabGroupIndent: CGFloat = 14
let workspaceSidebarTabCornerRadius: CGFloat = 7

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

/// The windows of a stack in Tabs mode: every window, not one per tab. Search narrows it to
/// the matching tabs.
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

struct WorkspaceSidebarTabRowView: View {
    let window: WorkspaceSidebarWindowViewModel
    let indent: CGFloat
    let isSearchSelected: Bool
    let isDragSource: Bool
    let actions: WorkspaceSidebarActions
    @State private var isHovered = false

    private var title: String { window.title ?? window.appName }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                guard !isWorkspaceSidebarDragInProgress() else { return }
                actions.send(.selectWindow(window.windowId))
            } label: {
                HStack(spacing: 8) {
                    AppIconView(bundleIdentifier: window.appBundleId, bundlePath: window.appBundlePath) { icon in
                        if let icon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Image(systemName: "macwindow")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                    }
                    .frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
                    Text(title)
                        .font(.system(size: 12.5, weight: window.isFocused ? .semibold : .regular))
                        .foregroundStyle(Color.white.opacity(window.isFocused ? 1 : 0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8 + indent)
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, maxHeight: workspaceSidebarTabRowHeight,
                    alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(window.isFocused ? "Focused" : "")
            .accessibilityAddTraits(window.isFocused ? .isSelected : [])
            .help(window.title.map { "\(window.appName) — \($0)" } ?? window.appName)
            // A sibling of the row button, so closing never also focuses the window.
            if isHovered {
                Button {
                    actions.send(.closeWindow(window.windowId))
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 18, height: 18)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Window")
                .accessibilityLabel("Close \(title)")
                .padding(.trailing, 5)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                .fill(backgroundFill)
        }
        .overlay {
            if window.isFocused {
                RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            }
        }
        .overlay {
            WindowMiddleClickCatcher(windowId: window.windowId) {
                guard !isWorkspaceSidebarDragInProgress() else { return }
                actions.send(.closeWindow(window.windowId))
            }
        }
        .opacity(isDragSource ? 0.45 : 1)
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: true,
            onChanged: { actions.windowDragChanged(window.windowId, $0) },
            onEnded: { actions.windowDragEnded(window.windowId, $0) },
        ))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Close Window") { actions.send(.closeWindow(window.windowId)) }
        }
    }

    private var backgroundFill: Color {
        if window.isFocused { return Color.white.opacity(isHovered ? 0.16 : 0.12) }
        if isHovered || isSearchSelected { return Color.white.opacity(0.06) }
        return .clear
    }
}

struct WorkspaceSidebarTabGroupRowView: View {
    let group: WorkspaceSidebarTabGroupViewModel
    let actions: WorkspaceSidebarActions
    @State private var isHovered = false

    var body: some View {
        let windows = workspaceSidebarTabGroupWindows(group)
        Button {
            guard !isWorkspaceSidebarDragInProgress() else { return }
            actions.send(.selectWindow(group.representativeWindowId))
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: -5) {
                    ForEach(Array(windows.prefix(3).enumerated()), id: \.offset) { _, window in
                        AppIconView(bundleIdentifier: window.appBundleId, bundlePath: window.appBundlePath) { icon in
                            if let icon {
                                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "macwindow").resizable().aspectRatio(contentMode: .fit)
                                    .foregroundStyle(Color.white.opacity(0.6))
                            }
                        }
                        .frame(width: 14, height: 14)
                    }
                }
                .frame(minWidth: workspaceSidebarTabIconSize, alignment: .leading)
                Text(group.title.isEmpty ? "Stack" : group.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text("\(max(group.windowCount, windows.count))")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight - 4, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.05) : .clear)
        }
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: true,
            onChanged: { actions.tabGroupDragChanged(group.representativeWindowId, $0) },
            onEnded: { actions.tabGroupDragEnded(group.representativeWindowId, $0) },
        ))
        .onHover { isHovered = $0 }
        .accessibilityLabel("Stack: \(group.title), \(max(group.windowCount, windows.count)) windows")
    }
}

struct WorkspaceSidebarTabFolderView: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let rows: [WorkspaceSidebarTabRow]
    let windowCount: Int
    let isCollapsed: Bool
    let isActive: Bool
    let isDropTarget: Bool
    let dragSourceWindowId: UInt32?
    let selectedSearchTarget: WorkspaceSidebarSearchSelection?
    let isRenaming: Bool
    @Binding var renamingText: String
    let actions: WorkspaceSidebarActions
    let onToggleCollapsed: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: @MainActor @Sendable () -> Void
    let onCancelRename: @MainActor @Sendable () -> Void
    @State private var isHeaderHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
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
                        )
                    case .group(let group):
                        WorkspaceSidebarTabGroupRowView(group: group, actions: actions)
                }
            }
        }
        .padding(.bottom, 6)
        .background {
            RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius + 2, style: .continuous)
                .strokeBorder(Color.white.opacity(isDropTarget ? 0.45 : 0), lineWidth: 1)
                .background {
                    RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius + 2, style: .continuous)
                        .fill(Color.white.opacity(isDropTarget ? 0.06 : 0))
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
        HStack(spacing: 2) {
            Button(action: onToggleCollapsed) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(isHeaderHovered ? 0.8 : 0.45))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 18, height: workspaceSidebarTabFolderHeaderHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand \(workspace.displayName)" : "Collapse \(workspace.displayName)")
            if isRenaming {
                WorkspaceSidebarWorkspaceRenameField(
                    text: $renamingText,
                    workspaceName: workspace.name,
                    onCommit: onCommitRename,
                    onCancel: onCancelRename,
                )
            } else {
                Button {
                    guard !isWorkspaceSidebarDragInProgress() else { return }
                    actions.send(.selectWorkspace(workspace.name))
                } label: {
                    HStack(spacing: 6) {
                        Text(workspace.displayName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(isActive ? 0.95 : 0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let savedState = workspace.savedState {
                            Image(systemName: savedState.isPinnedToDisplay ? "pin.fill" : "bookmark.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.5))
                                .accessibilityLabel(workspaceSidebarSavedWorkspaceDescription(savedState))
                        }
                        Spacer(minLength: 0)
                        Text("\(windowCount)")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.35))
                            .padding(.trailing, 8)
                    }
                    .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabFolderHeaderHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(workspaceSidebarWorkspaceTooltip(workspace))
                .accessibilityLabel("Workspace \(workspace.displayName), \(windowCount) windows")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .onHover { isHeaderHovered = $0 }
        .contextMenu {
            WorkspaceSidebarWorkspaceMenuContent(workspace: workspace, rename: onBeginRename, send: actions.send)
        }
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
    ) -> some View {
        let pinnedWorkspace = showsPinnedActiveWorkspace
            ? pinnedActiveWorkspace(displayedProjectId: projectId, pageWorkspaces: workspaces)
            : nil
        let folders = (pinnedWorkspace.map { [$0] } ?? []) + workspaces
        let isSearching = !searchText.isEmpty
        return GeometryReader { viewport in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(folders) { workspace in
                        let isCollapsed = collapsedTabFolderNames.contains(workspace.name)
                        WorkspaceSidebarTabFolderView(
                            workspace: workspace,
                            rows: workspaceSidebarTabRows(for: workspace, isCollapsed: isCollapsed, isSearching: isSearching),
                            windowCount: workspaceSidebarTabWindowCount(workspace),
                            isCollapsed: isCollapsed && !isSearching,
                            isActive: workspace.monitorScopeId == snapshot.targetMonitorScopeId && workspace.isVisible,
                            isDropTarget: snapshot.dropPreview?.targetWorkspaceName == workspace.name,
                            dragSourceWindowId: snapshot.dropPreview?.sourceWindowId,
                            selectedSearchTarget: isSearching ? selectedSearchTarget : nil,
                            isRenaming: renamingWorkspaceName == workspace.name,
                            renamingText: $renamingWorkspaceText,
                            actions: actions,
                            onToggleCollapsed: {
                                if collapsedTabFolderNames.remove(workspace.name) == nil {
                                    collapsedTabFolderNames.insert(workspace.name)
                                }
                            },
                            onBeginRename: { beginWorkspaceRename(workspace) },
                            onCommitRename: { finishWorkspaceRename() },
                            onCancelRename: { finishWorkspaceRename(cancelled: true) },
                        )
                    }
                    if showsCreateWorkspace && workspaceSidebarShowsCreateWorkspace(selectedScopeId: snapshot.selectedMonitorScopeId) {
                        createWorkspaceSection(layout: layout, projectId: projectId, expansionProgress: 1)
                            .padding(.top, 4)
                    }
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topPadding)
                .padding(.bottom, 10)
                .frame(width: viewport.size.width, alignment: .leading)
            }
            .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) { targets in
                targets = workspaceSidebarClippedDropTargets(targets,
                    to: viewport.frame(in: .named("workspaceSidebarContent")))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
