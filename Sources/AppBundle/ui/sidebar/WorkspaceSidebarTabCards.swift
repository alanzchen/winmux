import AppKit
import SwiftUI

/// How a workspace shows in Tabs mode. Most workspaces hold one window and are just a tab;
/// tiled windows share one row, as a split view does in a browser. Naming or saving
/// a tab never implicitly turns it into an organizational group.
enum WorkspaceSidebarTabPresentation: Equatable {
    /// An empty workspace, such as a new tab waiting for an app.
    case empty
    case single(WorkspaceSidebarWindowViewModel)
    case split(WorkspaceSidebarWindowViewModel, WorkspaceSidebarWindowViewModel)
    case multiple([WorkspaceSidebarWindowViewModel])
    case folder
}

struct WorkspaceSidebarSplitIdentity: Equatable {
    let name: String?
    let emoji: String?

    init?(_ workspace: WorkspaceSidebarWorkspaceViewModel) {
        guard !workspace.sidebarLabel.isEmpty || workspace.appearance.emoji != nil else { return nil }
        name = workspace.sidebarLabel.isEmpty ? nil : workspace.displayName
        emoji = workspace.appearance.emoji
    }
}

struct WorkspaceSidebarSplitIdentityLabel: View {
    let identity: WorkspaceSidebarSplitIdentity

    var body: some View {
        HStack(spacing: 5) {
            if let emoji = identity.emoji { Text(emoji) }
            if let name = identity.name { Text(name).lineLimit(1).truncationMode(.tail) }
        }
    }
}

func workspaceSidebarTabPresentation(
    _ workspace: WorkspaceSidebarWorkspaceViewModel,
    showsProjectContext: Bool = false,
    isRenaming: Bool = false,
    isSearching: Bool = false,
) -> WorkspaceSidebarTabPresentation {
    let windows = workspace.items.compactMap { item -> WorkspaceSidebarWindowViewModel? in
        if case .window(let window) = item.kind { window } else { nil }
    }
    // A stack keeps the folder that shows it as a group.
    guard !workspace.preservesFolderPresentation, windows.count == workspace.items.count else { return .folder }
    switch windows.count {
        case 0: return .empty
        case 1: return .single(windows[0])
        case 2: return .split(windows[0], windows[1])
        default: return .multiple(windows)
    }
}

/// A workspace shown as one tab: a window, two windows split, or an empty new tab. It takes
/// dropped tabs like a folder does, and offers the workspace's menu.
struct WorkspaceSidebarTabCardView: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let presentation: WorkspaceSidebarTabPresentation
    let isActive: Bool
    let isDropTarget: Bool
    let dragSourceWindowId: UInt32?
    let selectedSearchTarget: WorkspaceSidebarSearchSelection?
    let activation: WorkspaceSidebarTabActivation
    let isShowingOverride: Bool
    let overrideMinHeight: CGFloat
    let actions: WorkspaceSidebarActions
    @ObservedObject var badgeModel: WorkspaceSidebarDockBadgeModel = .shared
    @Environment(\.workspaceSidebarBadgeOwners) private var badgeOwners
    /// Where a dragged tab would go on this tab, while one is over it.
    var dropPlacement: WorkspaceSidebarTabDropPlacement? = nil
    /// The edge a dragged tab would be inserted at, while one is over it.
    var insertionEdge: VerticalEdge? = nil
    /// The page's project and display, which a drop between tabs lands in; nil for none.
    var gapTarget: (projectId: WorkspaceProjectId, monitorScopeId: String)? = nil
    var collectionId: String? = nil
    var allowsDragAndDrop = true
    var browserTabs: [UInt32: BrowserWindowTabs] = [:]
    var browserQuery: String = ""
    var browserSearchContext: String = ""
    var isSearching = false
    let onBeginRename: () -> Void
    let onCommitOverride: () -> Void
    let onCancelOverride: () -> Void

    var body: some View {
        content
            .frame(minHeight: isShowingOverride ? overrideMinHeight : nil, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                    .fill(workspace.appearance.colorHex.flatMap(workspaceSidebarColor)?.opacity(0.12) ?? Color.primary.opacity(backgroundOpacity))
            }
            // Over the rows, so a focused half's pill doesn't hide it.
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isDropTarget ? 0.55 : 0), lineWidth: 1)
                    .frame(height: hasBrowserGroups ? workspaceSidebarTabRowHeight : nil)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                WorkspaceSidebarTabDropSideHighlight(placement: isDropTarget ? dropPlacement : nil)
                    .frame(height: hasBrowserGroups ? workspaceSidebarTabRowHeight : nil)
            }
            .overlay { WorkspaceSidebarTabInsertionLine(edge: insertionEdge) }
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
                // Dropping a dragged tab here moves its window into this workspace, and
                // between tabs moves it there.
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: WorkspaceSidebarDropTargetPreferenceKey.self,
                        value: allowsDragAndDrop ? workspaceSidebarTabDropTargets(workspaceName: workspace.name,
                            frame: geometry.frame(in: .named("workspaceSidebarContent")), gapTarget: gapTarget,
                            // An empty tab has no window to go beside.
                            acceptsSides: presentation != .empty, collectionId: collectionId).map { target in
                                guard case .workspace = target.kind, hasBrowserGroups else { return target }
                                return WorkspaceSidebarDropTargetFrame(kind: target.kind,
                                    frame: CGRect(x: target.frame.minX, y: target.frame.minY, width: target.frame.width,
                                        height: min(workspaceSidebarTabRowHeight, target.frame.height)),
                                    acceptsSides: target.acceptsSides, tabReorderDestination: target.tabReorderDestination)
                            } : [],
                    )
                }
            }
    }

    private var backgroundOpacity: Double {
        if isDropTarget { return 0.14 }
        if selectedSearchTarget == .workspace(workspace.name) { return 0.1 }
        switch presentation {
            // Two windows share one tab, shown as one.
            case .split, .multiple: return isActive ? 0.1 : 0.04
            // The tab on screen stays marked even while its window isn't the focused one.
            case .single: return isActive ? 0.1 : 0
            case .empty, .folder: return 0
        }
    }

    private var hasBrowserGroups: Bool {
        workspaceSidebarPinnedTabWindows(workspace).contains { browserTabs[$0.windowId]?.isGroup == true }
    }

    @ViewBuilder
    private func browserGroup<Header: View>(_ window: WorkspaceSidebarWindowViewModel, @ViewBuilder header: @escaping () -> Header) -> some View {
        if let snapshot = browserTabs[window.windowId], snapshot.isGroup {
            let tabs = workspaceSidebarMatchingBrowserTabs(snapshot, window: window, workspace: workspace,
                query: browserQuery, context: browserSearchContext)
            if !tabs.isEmpty {
                WorkspaceSidebarBrowserTabGroupView(snapshot: snapshot, window: window, tabs: tabs,
                    isActive: isActive, isSearching: isSearching,
                    selectedSearchTarget: selectedSearchTarget, activation: activation, actions: actions, header: header)
                    .id(snapshot.windowSession)
            }
        }
    }

    private func browserMembers(_ windows: [WorkspaceSidebarWindowViewModel]) -> some View {
        ForEach(windows.filter { browserTabs[$0.windowId]?.isGroup == true }) { window in
            browserGroup(window) {
                Button { activation.select(.selectWindow(window.windowId), send: actions.send) } label: {
                    Text(window.appName).font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
            case .single(let window):
                if !workspaceSidebarMatchingBrowserTabs(browserTabs[window.windowId], window: window, workspace: workspace,
                    query: browserQuery, context: browserSearchContext).isEmpty {
                    browserGroup(window) { row(window, isSplitHalf: false) }
                } else { row(window, isSplitHalf: false) }
            case .split(let left, let right):
                VStack(spacing: 2) {
                    splitRows([left, right])
                    browserMembers([left, right])
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Split: \(left.title ?? left.appName) and \(right.title ?? right.appName)")
            case .multiple(let windows):
                VStack(spacing: 2) {
                    splitRows(windows)
                    browserMembers(windows)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Split: \(windows.map { $0.title ?? $0.appName }.joined(separator: ", "))")
            case .empty:
                WorkspaceSidebarEmptyTabRowView(isActive: isActive, actions: actions, workspace: workspace,
                    onBeginRename: onBeginRename,
                    onSelect: { activation.select(.selectWorkspace(workspace.name), send: actions.send) })
            case .folder:
                EmptyView()
        }
    }

    private func splitRows(_ windows: [WorkspaceSidebarWindowViewModel]) -> some View {
        GeometryReader { geometry in
            let identity = WorkspaceSidebarSplitIdentity(workspace)
            let badgeWidths = windows.map { window in
                workspaceSidebarBadgeWidth(label: badgeModel.snapshot.showsAppBadges
                    ? badgeModel.snapshot.label(forPath: window.appBundlePath) : nil,
                    showsDot: window.appBundlePath.flatMap { badgeOwners[$0] }.map { $0 != window.windowId } == true)
            }
            let iconOnly = identity != nil || workspaceSidebarSplitUsesIcons(width: geometry.size.width,
                windowCount: windows.count, badgeWidths: badgeWidths)
            let memberSpace = max(0, geometry.size.width - CGFloat(windows.count - 1) * 5)
            // Prioritize separate targets over the label when a many-window split is narrow.
            let showsIdentity = identity != nil && memberSpace >= CGFloat(windows.count) * 28 + 50
            let memberWidth = showsIdentity
                ? min(40, (memberSpace - 50) / CGFloat(windows.count))
                : memberSpace / CGFloat(windows.count)
            HStack(spacing: 2) {
                if showsIdentity, let identity {
                    Button { activation.select(.selectWorkspace(workspace.name), send: actions.send) } label: {
                        WorkspaceSidebarSplitIdentityLabel(identity: identity)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.leading, 10)
                            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(workspace.displayName)
                    .accessibilityLabel(workspace.displayName)
                    .sidebarIdentityMenu(.tab(workspace.name, windowId: nil))
                }
                ForEach(windows) { window in
                    if window.id != windows.first?.id {
                        Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 16).accessibilityHidden(true)
                    }
                    row(window, isSplitHalf: true, iconOnly: iconOnly,
                        showsCountOnIcon: identity != nil && memberWidth >= 36,
                        iconSize: iconOnly ? min(workspaceSidebarTabIconSize, max(1, memberWidth - 6)) : workspaceSidebarTabIconSize)
                        .frame(width: showsIdentity ? memberWidth : nil)
                }
            }
        }.frame(height: workspaceSidebarTabRowHeight)
    }

    private func row(_ window: WorkspaceSidebarWindowViewModel, isSplitHalf: Bool, iconOnly: Bool = false,
                     showsCountOnIcon: Bool = false, iconSize: CGFloat = workspaceSidebarTabIconSize) -> some View {
        WorkspaceSidebarTabRowView(
            window: window,
            indent: 0,
            isSplitHalf: isSplitHalf,
            iconOnly: iconOnly,
            showsCountOnIcon: showsCountOnIcon,
            iconSize: iconSize,
            allowsDrag: allowsDragAndDrop,
            activeOverride: isActive && window.isFocused &&
                workspaceSidebarMatchingBrowserTabs(browserTabs[window.windowId], window: window, workspace: workspace,
                    query: browserQuery, context: browserSearchContext).isEmpty,
            isSearchSelected: selectedSearchTarget == .window(window.windowId),
            isDragSource: dragSourceWindowId == window.windowId,
            actions: actions,
            workspaceMenu: (workspace, onBeginRename),
            onSelect: { activation.select(.selectWindow(window.windowId), send: actions.send) },
            titleOverride: !isSplitHalf ? (!workspace.sidebarLabel.isEmpty ? workspace.displayName
                : browserTabs[window.windowId]?.isGroup == true ? window.appName : nil) : nil,
            emojiOverride: !isSplitHalf ? workspace.appearance.emoji : nil,
            badgeModel: badgeModel,
        )
        .id("window:\(window.windowId)")
    }
}

/// The tab of an empty workspace, such as a new tab waiting for an app. Closing it moves to
/// the next tab and removes the workspace; the only tab can't be closed.
struct WorkspaceSidebarEmptyTabRowView: View {
    let isActive: Bool
    let actions: WorkspaceSidebarActions
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let onBeginRename: () -> Void
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                Image(systemName: "square.dashed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
                Text(workspace.sidebarLabel.isEmpty ? "Empty Tab" : workspace.displayName)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(Color.primary.opacity(isActive ? 0.9 : 0.65))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, workspaceSidebarTabCloseSlotWidth)
            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, maxHeight: workspaceSidebarTabRowHeight,
                alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Empty tab")
        .accessibilityLabel("Empty tab")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityAction(named: "Close") { close() }
        .overlay(alignment: .trailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Tab")
            .accessibilityHidden(true)
            .frame(width: workspaceSidebarTabCloseSlotWidth)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .background {
            RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                .fill(isActive ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(isHovered ? 0.06 : 0))
                .shadow(color: isActive ? Color.black.opacity(0.22) : .clear, radius: 3, y: 1)
        }
        .overlay {
            // Any id pairs the press with its release; there is no window to close.
            WindowMiddleClickCatcher(windowId: 0) { close() }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Close Tab") { close() }
            Divider()
            // Rename or save it to keep it; Close Tab above already removes it.
            WorkspaceSidebarWorkspaceMenuContent(workspace: workspace, rename: onBeginRename, send: actions.send,
                excludingDelete: true)
        }
        .sidebarIdentityMenu(.workspace(workspace.name))
    }

    private func close() {
        guard !isWorkspaceSidebarDragInProgress() else { return }
        actions.send(.closeEmptyTab(workspace.name))
    }
}

func workspaceSidebarSplitUsesIcons(width: CGFloat, windowCount: Int, badgeWidths: [CGFloat] = []) -> Bool {
    guard windowCount > 1 else { return false }
    let memberWidth = (width - CGFloat(windowCount - 1) * 5) / CGFloat(windowCount)
    let badge = badgeWidths.max() ?? 0
    let titleWidth = memberWidth - 10 - workspaceSidebarTabIconSize - 9 - 8 - (badge > 0 ? badge + 9 : 0)
    return titleWidth < 56
}

/// A tab's drop targets: the tab, then its edges, which win where they overlap it.
func workspaceSidebarTabDropTargets(
    workspaceName: String,
    frame: CGRect,
    gapTarget: (projectId: WorkspaceProjectId, monitorScopeId: String)?,
    acceptsSides: Bool = false,
    gapInside: CGFloat = 7,
    collectionId: String? = nil,
) -> [WorkspaceSidebarDropTargetFrame] {
    var targets = [WorkspaceSidebarDropTargetFrame(kind: .workspace(workspaceName), frame: frame, acceptsSides: acceptsSides,
        tabReorderDestination: gapTarget.map {
            .init(projectId: $0.projectId, monitorScopeId: $0.monitorScopeId, collectionId: collectionId)
        })]
    if let gapTarget {
        let bands = workspaceSidebarTabGapBands(for: frame, inside: gapInside)
        targets += [(bands.before, false), (bands.after, true)].map { band, isAfter in
            WorkspaceSidebarDropTargetFrame(
                kind: .tabGap(projectId: gapTarget.projectId, monitorScopeId: gapTarget.monitorScopeId,
                    gap: WorkspaceSidebarTabGap(workspaceName: workspaceName, isAfter: isAfter, collectionId: collectionId)),
                frame: band,
            )
        }
    }
    return targets
}

/// The half of a tab a dragged tab would join, or the whole tab for a stack.
struct WorkspaceSidebarTabDropSideHighlight: View {
    let placement: WorkspaceSidebarTabDropPlacement?

    var body: some View {
        GeometryReader { geometry in
            if let placement {
                let width = placement == .stack ? geometry.size.width : geometry.size.width / 2
                RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.18))
                    .overlay {
                        if placement == .stack {
                            Image(systemName: "square.stack")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, 8)
                        } else {
                            Text(placement == .left ? "Split left" : "Split right")
                                .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(.regularMaterial, in: Capsule())
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                    }
                    .frame(width: width)
                    .offset(x: placement == .right ? geometry.size.width - width : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where a dragged tab would be inserted between tabs.
struct WorkspaceSidebarTabInsertionLine: View {
    let edge: VerticalEdge?

    var body: some View {
        if let edge {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.85))
                .frame(height: 2)
                .frame(maxHeight: .infinity, alignment: edge == .top ? .top : .bottom)
                .offset(y: edge == .top ? -2 : 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
