import AppKit
import SwiftUI

// Proportions follow Dia's sidebar: airy rows, a bright pill for the active tab, and
// tinted, rounded cards for groups. WorkspaceSidebarTabLayout.swift holds the grid.
let workspaceSidebarTabRowHeight: CGFloat = 36
let workspaceSidebarTabIconSize: CGFloat = 16
let workspaceSidebarTabCornerRadius: CGFloat = 10
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

/// Windows a folder holds, counting every window of each stack. A search counts its matches.
func workspaceSidebarTabWindowCount(_ workspace: WorkspaceSidebarWorkspaceViewModel, isSearching: Bool = false) -> Int {
    workspace.items.reduce(0) { count, item in
        switch item.kind {
            case .window: count + 1
            case .tabGroup(let group): count + workspaceSidebarTabGroupWindowCount(group, isSearching: isSearching)
        }
    }
}

func workspaceSidebarTabGroupWindowCount(_ group: WorkspaceSidebarTabGroupViewModel, isSearching: Bool) -> Int {
    let windows = workspaceSidebarTabGroupWindows(group)
    return isSearching ? windows.count : max(group.windowCount, windows.count)
}

/// Folders get a stable color of their own, like Dia's tab groups. The prefix keeps a
/// workspace from borrowing the hue of a project with the same id.
func workspaceSidebarTabFolderColor(_ workspaceName: String) -> Color {
    Color(hue: workspaceSidebarProjectHue(projectId: WorkspaceProjectId("workspace-folder:\(workspaceName)")),
        saturation: 0.42, brightness: 0.92)
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
    var dismissOverride: () -> Void = {}
    /// The tab these rows belong to, which Shift and Command clicks choose instead of opening,
    /// and its page's tabs as shown, with the one on screen. Nil while searching.
    var tabName: String? = nil
    var selectionContext: (() -> (order: [String], active: String?))? = nil

    func select(_ action: WorkspaceSidebarAction, send: @MainActor (WorkspaceSidebarAction) -> Void) {
        guard !isWorkspaceSidebarDragInProgress() else { return }
        if let tabName, let selectionContext, config.usesBrowserTabs {
            let context = selectionContext()
            if WorkspaceSidebarTabSelection.shared.handleClick(on: tabName, modifiers: NSEvent.modifierFlags,
                order: context.order, active: context.active) { return }
        }
        guard allowsActivation else { return }
        if isInUseOnOtherDisplay {
            requestOverride()
            // Keep the panel open at full width so the prompt can be read, as in the Sidebar.
            send(.expandForWorkspaceOverride)
            return
        }
        // A prompt left open on another folder no longer applies.
        dismissOverride()
        send(action)
    }
}

struct WorkspaceSidebarTabRowView: View {
    let window: WorkspaceSidebarWindowViewModel
    let indent: CGFloat
    var isInStack = false
    /// One half of a two-window tab: tighter, so both titles fit.
    var isSplitHalf = false
    var iconOnly = false
    var showsCountOnIcon = false
    var iconSize = workspaceSidebarTabIconSize
    var allowsDrag = true
    var activeOverride: Bool? = nil
    let isSearchSelected: Bool
    let isDragSource: Bool
    let actions: WorkspaceSidebarActions
    /// A tab that is its workspace also offers the workspace's menu.
    var workspaceMenu: (workspace: WorkspaceSidebarWorkspaceViewModel, rename: () -> Void)? = nil
    /// The second half of a split starts right after the divider, not on the grid's column.
    var followsIndent = true
    /// A count shown where the close button appears on hover, for a row that heads a group.
    /// Such a row titles itself like every group's header.
    var trailingCount: Int? = nil
    var groupTint: Color? = nil
    let onSelect: () -> Void
    @State private var isHovered = false
    @Environment(\.workspaceSidebarTabIndent) private var tabIndent
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion

    var titleOverride: String? = nil
    var emojiOverride: String? = nil
    @ObservedObject var badgeModel: WorkspaceSidebarDockBadgeModel = .shared
    @Environment(\.workspaceSidebarBadgeOwners) private var badgeOwners
    private var title: String { titleOverride ?? window.title ?? window.appName }
    private var isActive: Bool { activeOverride ?? window.isFocused }
    private var badgeWidth: CGFloat {
        let label = badgeModel.snapshot.showsAppBadges ? badgeModel.snapshot.label(forPath: window.appBundlePath) : nil
        let showsDot = window.appBundlePath.flatMap { badgeOwners[$0] }.map { $0 != window.windowId } == true
        return workspaceSidebarBadgeWidth(label: label, showsDot: showsDot)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: iconOnly ? 0 : 9) {
                if iconOnly { Spacer(minLength: 0) }
                Group {
                    if let emojiOverride { Text(emojiOverride).frame(width: iconSize) }
                    else {
                        WorkspaceSidebarWindowIcon(window: window, size: iconSize, isOnLightBackground: isActive)
                    }
                }.overlay(alignment: .topTrailing) {
                    if iconOnly {
                        WorkspaceSidebarTabBadge(appName: window.appName, bundlePath: window.appBundlePath, model: badgeModel,
                            compact: !showsCountOnIcon, windowId: window.windowId).offset(x: showsCountOnIcon ? 5 : 2, y: -3)
                    }
                }.overlay(alignment: .bottomTrailing) {
                    if iconOnly {
                        WorkspaceSidebarTabAudioIndicator(window: window, size: 7).offset(x: 4, y: 3)
                    }
                }
                if !iconOnly, trailingCount != nil {
                    WorkspaceSidebarTabGroupTitle(text: title, tint: groupTint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !iconOnly { Text(title)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(Color.primary.opacity(isActive ? 0.95 : 0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading) }
                if iconOnly { Spacer(minLength: 0) }
                if !iconOnly {
                    WorkspaceSidebarTabAudioIndicator(window: window)
                    WorkspaceSidebarTabBadge(appName: window.appName, bundlePath: window.appBundlePath, model: badgeModel,
                        windowId: window.windowId)
                }
            }
            .padding(.leading, iconOnly ? 0 : (followsIndent ? tabIndent.leadingPadding : workspaceSidebarTabLeadingPadding) + indent)
            // Split titles use the hover-close space at rest; the badge keeps its own slot.
            .padding(.trailing, iconOnly ? 0 : (isSplitHalf ? 8 : workspaceSidebarTabCloseSlotWidth))
            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, maxHeight: workspaceSidebarTabRowHeight,
                alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(window.appName)")
        .accessibilityValue(isInStack ? "In stack" : "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityAction(named: "Close") { close() }
        .help(window.title.map { "\(window.appName) — \($0)" } ?? window.appName)
        .overlay(alignment: .trailing) {
            // A group's count rests where the close button appears on hover.
            if let trailingCount, !iconOnly {
                WorkspaceSidebarTabCountLabel(count: trailingCount)
                    .opacity(isHovered ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // Layered over the row button rather than inside it: closing never also focuses the
        // window, and an unhovered click in this corner still selects the tab.
        .overlay(alignment: .trailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isSplitHalf ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(0.08))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Window")
            .accessibilityHidden(true)
            .frame(width: isSplitHalf ? workspaceSidebarTabCloseSlotWidth - 4 : workspaceSidebarTabCloseSlotWidth)
            .padding(.trailing, isSplitHalf ? 8 + badgeWidth + (badgeWidth > 0 ? 9 : 0) : 0)
            .opacity(isHovered && !iconOnly ? 1 : 0)
            .allowsHitTesting(isHovered && !iconOnly)
        }
        .background {
            RoundedRectangle(cornerRadius: tabIndent.rowCornerRadius, style: .continuous)
                .fill(backgroundFill)
                .shadow(color: isActive ? Color.black.opacity(0.22) : .clear, radius: 3, y: 1)
        }
        // The selected tab's pill fades to its new row instead of jumping there.
        .animation(WorkspaceSidebarTabMotion.selection(reducesMotion: reducesMotion), value: isActive)
        .overlay {
            WindowMiddleClickCatcher(windowId: window.windowId) { close() }
        }
        .opacity(isDragSource ? 0.45 : 1)
        .animation(WorkspaceSidebarTabMotion.feedback, value: isDragSource)
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: allowsDrag,
            onChanged: { actions.windowDragChanged(window.windowId, $0) },
            onEnded: { actions.windowDragEnded(window.windowId, $0) },
        ))
        .onHover { hovering in withAnimation(WorkspaceSidebarTabMotion.hover) { isHovered = hovering } }
        .modifier(WorkspaceSidebarTabRowMenu(
            target: workspaceMenu.map { .tab($0.workspace.name, windowId: window.windowId) }, close: close))
    }

    private func close() {
        // A drag that started on the close button must not close the window on release.
        guard !isWorkspaceSidebarDragInProgress() else { return }
        actions.send(.closeWindow(window.windowId))
    }

    private var backgroundFill: Color {
        if isActive { return Color(nsColor: .controlBackgroundColor) }
        if isHovered || isSearchSelected { return Color.primary.opacity(0.07) }
        return .clear
    }
}

struct WorkspaceSidebarTabIcon: View {
    let bundleId: String?
    let bundlePath: String?
    var size: CGFloat = workspaceSidebarTabIconSize
    /// The active tab's white pill needs a dark fallback glyph.
    var isOnLightBackground = false

    var body: some View {
        AppIconView(bundleIdentifier: bundleId, bundlePath: bundlePath) { icon in
            if let icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "macwindow").resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct WorkspaceSidebarTabGroupRowView: View {
    let group: WorkspaceSidebarTabGroupViewModel
    var isSearching = false
    var isDragSource = false
    let actions: WorkspaceSidebarActions
    let onSelect: () -> Void
    @State private var isHovered = false
    @Environment(\.workspaceSidebarTabIndent) private var tabIndent

    var body: some View {
        let windows = workspaceSidebarTabGroupWindows(group)
        let count = workspaceSidebarTabGroupWindowCount(group, isSearching: isSearching)
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                WorkspaceSidebarTabCountLabel(count: count)
            }
            .padding(.leading, tabIndent.leadingPadding)
            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: tabIndent.rowCornerRadius, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
        }
        .opacity(isDragSource ? 0.45 : 1)
        .animation(WorkspaceSidebarTabMotion.feedback, value: isDragSource)
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: true,
            onChanged: { actions.tabGroupDragChanged(group.representativeWindowId, $0) },
            onEnded: { actions.tabGroupDragEnded(group.representativeWindowId, $0) },
        ))
        .onHover { hovering in withAnimation(WorkspaceSidebarTabMotion.hover) { isHovered = hovering } }
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
    let overrideMinHeight: CGFloat
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
    /// Tabs mode: the edge a dragged tab would be inserted at, and where drops between tabs land.
    var insertionEdge: VerticalEdge? = nil
    var insertionLabel: String? = nil
    var gapTarget: (projectId: WorkspaceProjectId, monitorScopeId: String)? = nil
    /// The group holding the folder, so drops at its edges stay in that group.
    var collectionId: String? = nil
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion

    private var color: Color { workspaceSidebarTabFolderColor(workspace.name) }

    private var headerAccessibilityLabel: String {
        var parts = ["Workspace \(workspace.displayName)"]
        if let projectContext { parts.append("project \(projectContext.label)") }
        if let savedState = workspace.savedState { parts.append(workspaceSidebarSavedWorkspaceDescription(savedState)) }
        parts.append("\(windowCount) windows")
        return parts.joined(separator: ", ")
    }

    @ObservedObject private var drag = WorkspaceSidebarTabDragState.shared

    /// One of the chosen tabs a drag carries together: the whole folder dims, not just a row.
    private var isBatchSource: Bool { drag.draggedTabs.contains(workspace.name) }

    var body: some View {
        WorkspaceSidebarTabGroupCard(tint: color, isExpanded: !rows.isEmpty, isActive: isActive, isDropTarget: isDropTarget) {
            header
        } content: {
            ForEach(rows) { row in
                switch row {
                    case .window(let window, let isGroupChild):
                        WorkspaceSidebarTabRowView(
                            window: window,
                            indent: isGroupChild ? workspaceSidebarTabIndentStep : 0,
                            isInStack: isGroupChild,
                            isSearchSelected: selectedSearchTarget == .window(window.windowId),
                            isDragSource: !isBatchSource && dragSourceWindowId == window.windowId,
                            actions: actions,
                            onSelect: { activation.select(.selectWindow(window.windowId), send: actions.send) },
                        )
                        .id(row.id)
                        .transition(.workspaceSidebarTabReveal)
                    case .group(let group):
                        WorkspaceSidebarTabGroupRowView(group: group, isSearching: isSearching,
                            isDragSource: !isBatchSource && dragSourceWindowId == group.representativeWindowId,
                            actions: actions,
                            onSelect: { activation.select(.selectWindow(group.representativeWindowId), send: actions.send) })
                        .transition(.workspaceSidebarTabReveal)
                }
            }
        }
        // A collapsed folder keeps its focused window, so its rows change without the card closing.
        .animation(WorkspaceSidebarTabMotion.disclosure(reducesMotion: reducesMotion), value: isCollapsed)
        // The take-over prompt needs the same room as in the Sidebar, even for a collapsed folder.
        .frame(minHeight: isShowingOverride ? overrideMinHeight : nil, alignment: .top)
        .overlay {
            if isShowingOverride {
                WorkspaceSidebarInUseOverrideOverlay(
                    text: workspace.monitorName.map { "In use on \($0)" } ?? "In use on another display",
                    onOverride: onCommitOverride,
                    onCancel: onCancelOverride,
                )
            }
        }
        .overlay { WorkspaceSidebarTabInsertionLine(edge: insertionEdge, label: insertionLabel) }
        .background {
            // Dropping a dragged tab anywhere on the folder moves the window into it, and at
            // its edges, between it and the next tab.
            GeometryReader { geometry in
                Color.clear.preference(
                    key: WorkspaceSidebarDropTargetPreferenceKey.self,
                    value: workspaceSidebarTabDropTargets(workspaceName: workspace.name,
                        frame: geometry.frame(in: .named("workspaceSidebarContent")), gapTarget: gapTarget, gapInside: 0,
                        collectionId: collectionId),
                )
            }
        }
        .opacity(isBatchSource ? 0.45 : 1)
        .animation(WorkspaceSidebarTabMotion.feedback, value: isBatchSource)
    }

    private var header: some View {
        ZStack(alignment: .leading) {
            if isRenaming {
                WorkspaceSidebarTabGroupHeaderLabel(isExpanded: !isCollapsed, tint: color, count: windowCount,
                    canToggle: !isSearching, drawsChevron: false) {
                    folderIcon
                } title: {
                    WorkspaceSidebarWorkspaceRenameField(
                        text: $renamingText,
                        workspaceName: workspace.name,
                        onCommit: onCommitRename,
                        onCancel: onCancelRename,
                    )
                }
            } else {
                Button {
                    activation.select(.selectWorkspace(workspace.name), send: actions.send)
                } label: {
                    WorkspaceSidebarTabGroupHeaderLabel(isExpanded: !isCollapsed, tint: color, count: windowCount,
                        canToggle: !isSearching, drawsChevron: false) {
                        folderIcon
                    } title: {
                        HStack(spacing: 6) {
                            WorkspaceSidebarTabGroupTitle(text: workspace.displayName, tint: color, isActive: isActive)
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
                        }
                    }
                    .background {
                        // The arrow keys can select a folder itself; show where Enter goes.
                        RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(selectedSearchTarget == .workspace(workspace.name) ? 0.1 : 0))
                    }
                }
                .buttonStyle(.plain)
                .help(workspaceSidebarWorkspaceTooltip(workspace))
                .accessibilityLabel(headerAccessibilityLabel)
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
            // A search shows every match, so collapsing would visibly do nothing. The chevron
            // hides, while titles keep their place.
            if !isSearching {
                WorkspaceSidebarTabDisclosureButton(isExpanded: !isCollapsed, tint: color,
                    label: "\(workspace.displayName) folder", toggle: onToggleCollapsed)
                    .accessibilityHint(isCollapsed ? "Shows the folder's windows" : "Hides the folder's windows")
            }
        }
        .sidebarIdentityMenu(.tab(workspace.name, windowId: nil))
    }

    @ViewBuilder
    private var folderIcon: some View {
        if let emoji = workspace.appearance.emoji {
            Text(emoji).font(.system(size: 13))
        } else {
            Image(systemName: "folder.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color.opacity(0.8))
        }
    }
}

/// Dia's quiet "+ New Tab" row, at the top of the list: a new workspace right after the
/// current one, with the launcher. A dragged tab dropped on it gets a workspace of its own.
struct WorkspaceSidebarTabNewWorkspaceRow: View {
    let projectId: WorkspaceProjectId
    let monitorScopeId: String
    let isDropTarget: Bool
    let onCreate: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onCreate) {
            HStack(spacing: 9) {
                // On the tabs' icon column, like the search glass above it.
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
                Text("New Tab")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.primary.opacity(isHovered || isDropTarget ? 0.8 : 0.45))
            .padding(.leading, workspaceSidebarTabLeadingPadding)
            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            let shape = RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
            shape.fill(isDropTarget ? Color.accentColor.opacity(0.14) : Color.primary.opacity(isHovered ? 0.06 : 0))
                .overlay { shape.strokeBorder(Color.accentColor.opacity(isDropTarget ? 0.65 : 0), lineWidth: 1) }
        }
        .animation(WorkspaceSidebarTabMotion.feedback, value: isDropTarget)
        .onHover { hovering in withAnimation(WorkspaceSidebarTabMotion.hover) { isHovered = hovering } }
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
        .accessibilityLabel("New Tab")
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
        let scrollTarget = workspaceSidebarTabScrollTarget(folders: folders,
            searchSelection: isSearching ? selectedSearchTarget : nil, browserTabs: browserTabs)
        let createMonitorScopeId = workspaceSidebarWorkspaceCreateScope(
            selectedScopeId: snapshot.selectedMonitorScopeId,
            targetMonitorScopeId: snapshot.targetMonitorScopeId,
            focusedScopeId: snapshot.focusedMonitorScopeId,
        )
        let sections = workspaceSidebarTabSections(workspaces: folders.filter { isSearching || !$0.appearance.isFavorite },
            collections: snapshot.configuration.tabCollections, projectId: projectId)
        let tailGap = isSearching || !snapshot.configuration.usesTabsList ? nil
            // The last of the project's own pins: a pin in All Projects may be another project's tab.
            : workspaceSidebarTabsTailGap(sections: sections,
                lastPin: folders.last { $0.appearance.isFavorite && $0.projectId == projectId }?.name)
        return GeometryReader { viewport in
            // Measured once per page: every folder shares the width.
            let overrideMinHeight = workspaceSidebarInUseOverrideMinHeight(sectionWidth: viewport.size.width - leadingInset - trailingInset)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Tabs sit close together, as in a browser; folders keep room around them.
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if showsCreateWorkspace && workspaceSidebarShowsCreateWorkspace(selectedScopeId: snapshot.selectedMonitorScopeId) {
                                WorkspaceSidebarTabNewWorkspaceRow(
                                    projectId: projectId,
                                    monitorScopeId: createMonitorScopeId,
                                    isDropTarget: snapshot.dropPreview?.targetsNewWorkspace == true
                                        && snapshot.dropPreview?.targetProjectId == projectId
                                        && workspaceSidebarDropPreview(snapshot.dropPreview, targetsList: createMonitorScopeId),
                                    onCreate: {
                                        actions.send(.createWorkspace(projectId: projectId, monitorScopeId: createMonitorScopeId))
                                    },
                                )
                            }
                            ForEach(sections) { section in
                                switch section {
                                    case .tab(let workspace):
                                        tabEntry(workspace, isPinned: workspace.id == pinnedWorkspace?.id,
                                            projectId: projectId, pageAllowsActivation: pageAllowsActivation, isSearching: isSearching,
                                            overrideMinHeight: overrideMinHeight, monitorScopeId: createMonitorScopeId)
                                            .id(workspaceSidebarTabFolderRowId(workspace.name))
                                    case .collection(let group, let workspaces):
                                        tabCollection(group, workspaces: workspaces, projectId: projectId,
                                            pageAllowsActivation: pageAllowsActivation, isSearching: isSearching,
                                            overrideMinHeight: overrideMinHeight, monitorScopeId: createMonitorScopeId)
                                }
                            }
                        }
                        // Tabs that open, close, move, or join a group slide to their new places.
                        .animation(WorkspaceSidebarTabMotion.reorder(reducesMotion: reduceDockMotion),
                            value: sections.map(\.id))
                        // The space below the last tab takes a dropped tab too, and puts it last.
                        if let tailGap {
                            WorkspaceSidebarTabsTailDropZone(
                                target: .tabGap(projectId: projectId, monitorScopeId: createMonitorScopeId, gap: tailGap.gap),
                                showsLine: tailGap.drawsOwnLine && snapshot.dropPreview?.targetGap == tailGap.gap
                                    && snapshot.dropPreview?.targetProjectId == projectId,
                                label: snapshot.dropPreview?.separatesFromTab == true ? "New Tab" : nil)
                                .frame(minHeight: workspaceSidebarTabRowHeight, maxHeight: .infinity)
                        }
                    }
                    .padding(.leading, leadingInset)
                    .padding(.trailing, trailingInset)
                    .padding(.top, topPadding)
                    .padding(.bottom, 10)
                    .frame(width: viewport.size.width, alignment: .leading)
                    .frame(minHeight: viewport.size.height, alignment: .top)
                }
                // The list is rebuilt when the panel expands; show the window in use, or while
                // searching, the result the arrow keys selected.
                .onAppear { workspaceSidebarScrollTabsList(to: scrollTarget, with: proxy) }
                .onChange(of: scrollTarget) { workspaceSidebarScrollTabsList(to: $0, with: proxy) }
            }
            .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) { targets in
                targets = workspaceSidebarClippedDropTargets(targets,
                    to: viewport.frame(in: .named("workspaceSidebarContent")))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A workspace as a single tab, a split tab, an empty new tab, or a folder.
    @ViewBuilder
    func tabEntry(
        _ workspace: WorkspaceSidebarWorkspaceViewModel,
        isPinned: Bool,
        projectId: WorkspaceProjectId,
        pageAllowsActivation: Bool,
        isSearching: Bool,
        overrideMinHeight: CGFloat,
        monitorScopeId: String,
        collectionId: String? = nil,
    ) -> some View {
        let showsProjectContext = isPinned || (browsedProjectId != nil && projectId != snapshot.activeProjectId)
        // Only this page's own tabs take drops between them, and only in Tabs mode's tab list.
        let gapTarget = isPinned || isSearching || !snapshot.configuration.usesTabsList ? nil
            : (projectId: projectId, monitorScopeId: monitorScopeId)
        let insertionEdge = workspaceSidebarTabInsertionEdge(snapshot.dropPreview, workspaceName: workspace.name,
            collectionId: collectionId, projectId: projectId)
        let insertionLabel = insertionEdge != nil && snapshot.dropPreview?.separatesFromTab == true ? "New Tab" : nil
        let presentation = workspaceSidebarTabPresentation(workspace, showsProjectContext: showsProjectContext,
            isRenaming: renamingWorkspaceName == workspace.name, isSearching: isSearching)
        if presentation == .folder {
            tabFolder(workspace, isPinned: isPinned, projectId: projectId, pageAllowsActivation: pageAllowsActivation,
                isSearching: isSearching, overrideMinHeight: overrideMinHeight, insertionEdge: insertionEdge,
                insertionLabel: insertionLabel, gapTarget: gapTarget, collectionId: collectionId)
                .padding(.vertical, 3)
        } else {
            let (activation, isShowingOverride) = tabActivation(workspace, isPinned: isPinned,
                pageAllowsActivation: pageAllowsActivation)
            WorkspaceSidebarTabCardView(
                workspace: workspace,
                presentation: presentation,
                isActive: workspaceSidebarTabIsActive(workspace, on: snapshot.targetMonitorScopeId),
                isDropTarget: snapshot.dropPreview?.targetWorkspaceName == workspace.name,
                dragSourceWindowId: snapshot.dropPreview?.sourceWindowId,
                selectedSearchTarget: isSearching ? selectedSearchTarget : nil,
                activation: activation,
                isShowingOverride: isShowingOverride,
                overrideMinHeight: overrideMinHeight,
                actions: actions,
                badgeModel: dockBadgeModel,
                dropPlacement: snapshot.dropPreview?.targetPlacement,
                dropLabelSlot: snapshot.dropPreview?.targetLabelSlot,
                dropLabelText: workspaceSidebarTabDropLabelText(for: snapshot.dropPreview),
                insertionEdge: insertionEdge,
                insertionLabel: insertionLabel,
                gapTarget: gapTarget,
                collectionId: collectionId,
                allowsDragAndDrop: !isSearching,
                browserTabs: browserTabs,
                browserQuery: isSearching ? searchText : "",
                browserSearchContext: workspaceSidebarBrowserSearchContext(workspace, projects: snapshot.projects,
                    collections: snapshot.configuration.tabCollections),
                isSearching: isSearching,
                showsNowPlaying: !snapshot.configuration.musicPlayerAtBottom,
                onBeginRename: { beginWorkspaceRename(workspace) },
                onCommitOverride: {
                    activeInUseOverrideWorkspaceName = nil
                    actions.send(.overrideWorkspaceInUse(workspace.name))
                },
                onCancelOverride: { activeInUseOverrideWorkspaceName = nil },
            )
        }
    }

    /// A project's tabs as this sidebar shows them, for Shift-click ranges: the pinned tiles, then
    /// the list, groups included. The tab on screen on this sidebar's display anchors a first range.
    func workspaceSidebarTabSelectionContext(projectId: WorkspaceProjectId) -> (order: [String], active: String?) {
        let tabs = snapshot.tabsListedWorkspaces(for: projectId)
        let listed = workspaceSidebarTabSections(workspaces: tabs.filter { !$0.appearance.isFavorite },
            collections: snapshot.configuration.tabCollections, projectId: projectId).flatMap { section -> [String] in
                switch section {
                    case .tab(let workspace): [workspace.name]
                    case .collection(_, let workspaces): workspaces.map(\.name)
                }
            }
        return (tabs.filter(\.appearance.isFavorite).map(\.name) + listed,
            snapshot.workspaces.first { workspaceSidebarTabIsActive($0, on: snapshot.targetMonitorScopeId) }?.name)
    }

    /// How clicks on a workspace's rows behave; shared by folders and tabs.
    func tabActivation(
        _ workspace: WorkspaceSidebarWorkspaceViewModel,
        isPinned: Bool,
        pageAllowsActivation: Bool,
    ) -> (WorkspaceSidebarTabActivation, isShowingOverride: Bool) {
        // The pinned active workspace is already in use: its header does nothing, as in the Sidebar.
        let allowsActivation = pageAllowsActivation && !isPinned
        // A shared pin comes to the display it's clicked on, without asking.
        let isInUseOnOtherDisplay = allowsActivation &&
            workspaceSidebarWorkspaceIsInUseOnOtherDisplay(workspace, selectedScopeId: snapshot.targetMonitorScopeId) &&
            !workspaceSidebarSharedPinComesToClick(workspace, representedMonitorScopeId: snapshot.targetMonitorScopeId,
                sharesPinnedTabs: snapshot.configuration.sharesPinnedTabs)
        let activation = WorkspaceSidebarTabActivation(
            allowsActivation: allowsActivation,
            isInUseOnOtherDisplay: isInUseOnOtherDisplay,
            requestOverride: {
                pendingInUseOverrideAppId = nil
                activeInUseOverrideWorkspaceName = workspace.name
            },
            dismissOverride: { activeInUseOverrideWorkspaceName = nil },
            tabName: workspace.name,
            selectionContext: searchText.isEmpty && !isSearchEditing
                ? { workspaceSidebarTabSelectionContext(projectId: workspaceSidebarListedProjectId(workspace,
                    contextProjectId: snapshot.activeProjectId)) } : nil,
        )
        return (activation, isInUseOnOtherDisplay && activeInUseOverrideWorkspaceName == workspace.name)
    }

    private func tabFolder(
        _ workspace: WorkspaceSidebarWorkspaceViewModel,
        isPinned: Bool,
        projectId: WorkspaceProjectId,
        pageAllowsActivation: Bool,
        isSearching: Bool,
        overrideMinHeight: CGFloat,
        insertionEdge: VerticalEdge? = nil,
        insertionLabel: String? = nil,
        gapTarget: (projectId: WorkspaceProjectId, monitorScopeId: String)? = nil,
        collectionId: String? = nil,
    ) -> WorkspaceSidebarTabFolderView {
        let isCollapsed = collapsedTabFolderNames.contains(workspace.name)
        let (activation, isShowingOverride) = tabActivation(workspace, isPinned: isPinned,
            pageAllowsActivation: pageAllowsActivation)
        let showsProjectContext = isPinned || (browsedProjectId != nil && projectId != snapshot.activeProjectId)
        let contextProjectId = isPinned ? snapshot.activeProjectId : projectId
        return WorkspaceSidebarTabFolderView(
            workspace: workspace,
            rows: workspaceSidebarTabRows(for: workspace, isCollapsed: isCollapsed, isSearching: isSearching),
            windowCount: workspaceSidebarTabWindowCount(workspace, isSearching: isSearching),
            isCollapsed: isCollapsed && !isSearching,
            isSearching: isSearching,
            isActive: workspace.monitorScopeId == snapshot.targetMonitorScopeId && workspace.isVisible,
            isDropTarget: snapshot.dropPreview?.targetWorkspaceName == workspace.name,
            dragSourceWindowId: snapshot.dropPreview?.sourceWindowId,
            selectedSearchTarget: isSearching ? selectedSearchTarget : nil,
            activation: activation,
            isShowingOverride: isShowingOverride,
            overrideMinHeight: overrideMinHeight,
            projectContext: showsProjectContext
                ? (projectName(contextProjectId), projectColor(contextProjectId))
                : nil,
            isRenaming: renamingWorkspaceName == workspace.name,
            renamingText: $renamingWorkspaceText,
            actions: actions,
            onToggleCollapsed: {
                withAnimation(WorkspaceSidebarTabMotion.disclosure(reducesMotion: reduceDockMotion)) {
                    if collapsedTabFolderNames.remove(workspace.name) == nil {
                        collapsedTabFolderNames.insert(workspace.name)
                    }
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
            insertionEdge: insertionEdge,
            insertionLabel: insertionLabel,
            gapTarget: gapTarget,
            collectionId: collectionId,
        )
    }
}

/// The edge of a tab where the dragged tab would go between tabs. A gap belongs to one group,
/// so the line never shows inside a group the drop won't join.
func workspaceSidebarTabInsertionEdge(_ preview: WorkspaceSidebarDropPreviewViewModel?, workspaceName: String,
                                      collectionId: String?, projectId: WorkspaceProjectId) -> VerticalEdge? {
    guard let preview, let gap = preview.targetGap, gap.workspaceName == workspaceName,
          gap.collectionId == collectionId, preview.targetProjectId == projectId else { return nil }
    return gap.isAfter ? .bottom : .top
}

/// The gap the space below the last tab stands for: after the last tab, outside any group.
/// A group's line would draw inside the group, so below a group the zone draws its own.
/// Empty groups, which always come last, hold no tab to go after. With every tab pinned, it
/// goes after the last pin, so a pin dragged there is unpinned into the empty list.
func workspaceSidebarTabsTailGap(sections: [WorkspaceSidebarTabSection],
                                 lastPin: String? = nil) -> (gap: WorkspaceSidebarTabGap, drawsOwnLine: Bool)? {
    for section in sections.reversed() {
        switch section {
            case .tab(let workspace): return (WorkspaceSidebarTabGap(workspaceName: workspace.name, isAfter: true), false)
            case .collection(_, let workspaces):
                if let last = workspaces.last { return (WorkspaceSidebarTabGap(workspaceName: last.name, isAfter: true), true) }
        }
    }
    return lastPin.map { (WorkspaceSidebarTabGap(workspaceName: $0, isAfter: true), true) }
}

/// The empty space under the tabs, which takes a dropped tab as the last tab.
struct WorkspaceSidebarTabsTailDropZone: View {
    let target: WorkspaceSidebarDropTargetKind
    let showsLine: Bool
    let label: String?

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                WorkspaceSidebarTabInsertionLine(edge: showsLine ? .top : nil, label: label)
                    .frame(height: workspaceSidebarTabRowHeight)
                    .padding(.top, 4)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: WorkspaceSidebarDropTargetPreferenceKey.self,
                        value: [WorkspaceSidebarDropTargetFrame(kind: target,
                            frame: geometry.frame(in: .named("workspaceSidebarContent")))])
                }
            }
            .accessibilityHidden(true)
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

func workspaceSidebarTabFolderRowId(_ workspaceName: String) -> String { "folder:\(workspaceName)" }

/// A row to keep in view, with the folder holding it. Folders are lazy, so an unrealized
/// folder's rows can't be found until the folder itself is scrolled to.
struct WorkspaceSidebarTabScrollTarget: Equatable {
    let folderId: String
    let rowId: String?
}

/// The search result the arrow keys selected, which Enter will activate, and otherwise the
/// window in use.
func workspaceSidebarTabScrollTarget(
    folders: [WorkspaceSidebarWorkspaceViewModel],
    searchSelection: WorkspaceSidebarSearchSelection?,
    browserTabs: [UInt32: BrowserWindowTabs] = [:],
) -> WorkspaceSidebarTabScrollTarget? {
    switch searchSelection {
        case .browserTab(let target):
            guard let folder = folders.first(where: { workspaceSidebarTabWindowIds(in: $0).contains(target.windowId) }),
                  workspaceSidebarTabPresentation(folder) != .folder else {
                return workspaceSidebarTabScrollTarget(folders: folders, searchSelection: nil, browserTabs: browserTabs)
            }
            return .init(folderId: workspaceSidebarTabFolderRowId(folder.name), rowId: target.rowId)
        case .workspace(let name):
            return WorkspaceSidebarTabScrollTarget(folderId: workspaceSidebarTabFolderRowId(name), rowId: nil)
        case .window(let windowId):
            if let folder = folders.first(where: { workspaceSidebarTabWindowIds(in: $0).contains(windowId) }) {
                return WorkspaceSidebarTabScrollTarget(folderId: workspaceSidebarTabFolderRowId(folder.name), rowId: "window:\(windowId)")
            }
            // The selected result is on another project's page; this page keeps its own window in view.
            return workspaceSidebarTabScrollTarget(folders: folders, searchSelection: nil, browserTabs: browserTabs)
        case nil:
            for folder in folders {
                if workspaceSidebarTabPresentation(folder) != .folder,
                   let window = workspaceSidebarPinnedTabWindows(folder).first(where: \.isFocused),
                   let browser = browserTabs[window.windowId], browser.isGroup,
                   let selected = browser.tabs.first(where: \.isSelected) {
                    return .init(folderId: workspaceSidebarTabFolderRowId(folder.name), rowId: selected.target.rowId)
                }
                if let rowId = workspaceSidebarFocusedTabRowId(in: folder) {
                    return WorkspaceSidebarTabScrollTarget(folderId: workspaceSidebarTabFolderRowId(folder.name), rowId: rowId)
                }
            }
            return nil
    }
}

func workspaceSidebarTabWindowIds(in workspace: WorkspaceSidebarWorkspaceViewModel) -> [UInt32] {
    workspace.items.flatMap { item -> [UInt32] in
        switch item.kind {
            case .window(let window): [window.windowId]
            case .tabGroup(let group): workspaceSidebarTabGroupWindows(group).map(\.windowId)
        }
    }
}

/// Scrolls once layout settles: a scroll requested while the list is being created is dropped.
@MainActor
func workspaceSidebarScrollTabsList(to target: WorkspaceSidebarTabScrollTarget?, with proxy: ScrollViewProxy) {
    guard let target else { return }
    DispatchQueue.main.async {
        proxy.scrollTo(target.folderId)
        guard let rowId = target.rowId else { return }
        DispatchQueue.main.async { proxy.scrollTo(rowId) }
    }
}

/// Tabs mode replaces the workspace sections only once rows are revealed; the collapsed rail
/// and every other mode keep the sections page.
func workspaceSidebarUsesTabsPage(layout: WorkspaceSidebarConfiguration, expansionProgress: CGFloat) -> Bool {
    layout.usesTabsList && expansionProgress >= workspaceSidebarRowsRevealProgress
}
