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
    var dropLabelSlot: WorkspaceSidebarTabDropLabelSlot? = nil
    var dropLabelText: String? = nil
    /// The edge a dragged tab would be inserted at, while one is over it.
    var insertionEdge: VerticalEdge? = nil
    var insertionLabel: String? = nil
    /// The page's project and display, which a drop between tabs lands in; nil for none.
    var gapTarget: (projectId: WorkspaceProjectId, monitorScopeId: String)? = nil
    var collectionId: String? = nil
    var allowsDragAndDrop = true
    var browserTabs: [UInt32: BrowserWindowTabs] = [:]
    var browserQuery: String = ""
    var browserSearchContext: String = ""
    var isSearching = false
    /// False while Music's player sits at the bottom of the sidebar instead.
    var showsNowPlaying = true
    let onBeginRename: () -> Void
    let onCommitOverride: () -> Void
    let onCancelOverride: () -> Void
    @Environment(\.workspaceSidebarTabIndent) private var indent
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion
    @ObservedObject private var selection = WorkspaceSidebarTabSelection.shared
    @ObservedObject private var drag = WorkspaceSidebarTabDragState.shared

    /// One of the chosen tabs a drag carries together: the whole card dims, not just a row.
    private var isBatchSource: Bool { drag.draggedTabs.contains(workspace.name) }

    /// A browser window's tabs draw their own card, which marks the tab in use and takes its color.
    private var drawsBrowserCard: Bool {
        guard case .single(let window) = presentation else { return false }
        return !workspaceSidebarMatchingBrowserTabs(browserTabs[window.windowId], window: window, workspace: workspace,
            query: browserQuery, context: browserSearchContext).isEmpty
    }

    /// Music's tab shows what it's playing under its row.
    private var drawsNowPlaying: Bool {
        guard case .single(let window) = presentation else { return false }
        return showsNowPlaying && !drawsBrowserCard && workspaceSidebarShowsNowPlaying(window)
    }

    /// The row heading a card shows where a drop goes. Only a browser card's row takes drops
    /// itself: its tabs below are targets of their own, while all of Music's card takes them.
    private var headsCard: Bool { hasBrowserGroups || drawsNowPlaying }

    var body: some View {
        content
            .frame(minHeight: isShowingOverride ? overrideMinHeight : nil, alignment: .top)
            .background {
                if !drawsBrowserCard {
                    RoundedRectangle(cornerRadius: indent.rowCornerRadius, style: .continuous)
                        .fill(isDropTarget ? Color.accentColor.opacity(0.14)
                            : workspace.appearance.colorHex.flatMap(workspaceSidebarColor)?.opacity(0.12) ?? Color.primary.opacity(backgroundOpacity))
                        .animation(WorkspaceSidebarTabMotion.selection(reducesMotion: reducesMotion), value: isActive)
                }
            }
            // Over the rows, so a focused half's pill doesn't hide it.
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: hasBrowserGroups ? indent.header.rowCornerRadius : indent.rowCornerRadius,
                    style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isDropTarget ? 0.65 : 0), lineWidth: 1)
                    .frame(height: headsCard ? workspaceSidebarTabRowHeight : nil)
                    .padding(hasBrowserGroups && drawsBrowserCard ? workspaceSidebarTabGroupInset : 0)
                    .allowsHitTesting(false)
                    .animation(WorkspaceSidebarTabMotion.feedback, value: isDropTarget)
            }
            .overlay(alignment: .top) {
                WorkspaceSidebarTabDropSideHighlight(placement: isDropTarget ? dropPlacement : nil,
                    labelSlot: dropLabelSlot, labelText: dropLabelText)
                    .frame(height: headsCard ? workspaceSidebarTabRowHeight : nil)
                    .padding(hasBrowserGroups && drawsBrowserCard ? workspaceSidebarTabGroupInset : 0)
            }
            .overlay { WorkspaceSidebarTabInsertionLine(edge: insertionEdge, label: insertionLabel) }
            // Chosen with Shift or Command, for acting on several tabs at once.
            .overlay {
                WorkspaceSidebarTabSelectionHighlight(isSelected: selection.contains(workspace.name),
                    cornerRadius: indent.rowCornerRadius)
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
                                // The header row of the window's tabs, inside their card's padding.
                                let inset = drawsBrowserCard ? workspaceSidebarTabGroupInset : 0
                                return WorkspaceSidebarDropTargetFrame(kind: target.kind,
                                    frame: CGRect(x: target.frame.minX, y: target.frame.minY, width: target.frame.width,
                                        height: min(workspaceSidebarTabRowHeight + inset, target.frame.height)),
                                    acceptsSides: target.acceptsSides, tabReorderDestination: target.tabReorderDestination)
                            } : [],
                    )
                }
            }
            .opacity(isBatchSource ? 0.45 : 1)
            .animation(WorkspaceSidebarTabMotion.feedback, value: isBatchSource)
    }

    private var backgroundOpacity: Double {
        if isDropTarget { return 0.14 }
        if selectedSearchTarget == .workspace(workspace.name) { return 0.1 }
        switch presentation {
            // Two windows share one tab, shown as one.
            case .split, .multiple: return isActive ? 0.1 : 0.04
            // The tab on screen stays marked even while its window isn't the focused one.
            case .single: return isActive ? 0.1 : (drawsNowPlaying ? 0.05 : 0)
            case .empty, .folder: return 0
        }
    }

    private var hasBrowserGroups: Bool {
        workspaceSidebarPinnedTabWindows(workspace).contains { browserTabs[$0.windowId]?.isGroup == true }
    }

    @ViewBuilder
    private func browserGroup<Header: View>(_ window: WorkspaceSidebarWindowViewModel, tint: Color? = nil,
                                            cornerRadius: CGFloat? = nil,
                                            @ViewBuilder header: @escaping (_ count: Int) -> Header) -> some View {
        if let snapshot = browserTabs[window.windowId], snapshot.isGroup {
            let tabs = workspaceSidebarMatchingBrowserTabs(snapshot, window: window, workspace: workspace,
                query: browserQuery, context: browserSearchContext)
            if !tabs.isEmpty {
                WorkspaceSidebarBrowserTabGroupView(snapshot: snapshot, window: window, tabs: tabs,
                    isActive: isActive, isSearching: isSearching, tint: tint, cardCornerRadius: cornerRadius,
                    selectedSearchTarget: selectedSearchTarget, activation: activation, actions: actions,
                    header: { header(tabs.count) })
                    .id(snapshot.windowSession)
            }
        }
    }

    /// A browser window in a split lists its tabs under the split, headed like any group.
    private func browserMembers(_ windows: [WorkspaceSidebarWindowViewModel]) -> some View {
        ForEach(windows.filter { browserTabs[$0.windowId]?.isGroup == true }) { window in
            // Flush with the split's row, so it takes the row's corners.
            browserGroup(window, cornerRadius: indent.rowCornerRadius) { count in
                Button { activation.select(.selectWindow(window.windowId), send: actions.send) } label: {
                    WorkspaceSidebarTabGroupHeaderLabel(isExpanded: true, count: count, drawsChevron: false) {
                        WorkspaceSidebarTabIcon(bundleId: window.appBundleId, bundlePath: window.appBundlePath)
                    } title: {
                        WorkspaceSidebarTabGroupTitle(text: window.appName)
                    }
                }
                .buttonStyle(.plain)
                .help(window.title.map { "\(window.appName) — \($0)" } ?? window.appName)
                .accessibilityLabel("\(window.appName), \(count) browser tabs")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
            case .single(let window):
                if drawsBrowserCard {
                    browserGroup(window, tint: workspace.appearance.colorHex.flatMap(workspaceSidebarColor)) { count in
                        // The window's own row heads its tabs: its icon and title sit where the
                        // group's rows start, after the chevron.
                        row(window, isSplitHalf: false, indent: workspaceSidebarTabIndentStep, trailingCount: count,
                            groupTint: workspace.appearance.colorHex.flatMap(workspaceSidebarColor))
                    }
                } else if drawsNowPlaying {
                    VStack(spacing: 0) {
                        row(window, isSplitHalf: false)
                        WorkspaceSidebarMusicNowPlayingView(
                            onSelect: { activation.select(.selectWindow(window.windowId), send: actions.send) })
                    }
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
                    onSelect: { activation.select(.selectWorkspace(workspace.name), send: actions.send) },
                    onOpenSavedApps: { activation.select(.openSavedTab(workspace.name), send: actions.send) })
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
                            .padding(.leading, indent.leadingPadding)
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
                        iconSize: iconOnly ? min(workspaceSidebarTabIconSize, max(1, memberWidth - 6)) : workspaceSidebarTabIconSize,
                        // Only the split's first title starts on the tabs' icon column.
                        followsIndent: !showsIdentity && window.id == windows.first?.id)
                        .frame(width: showsIdentity ? memberWidth : nil)
                }
            }
        }.frame(height: workspaceSidebarTabRowHeight)
    }

    private func row(_ window: WorkspaceSidebarWindowViewModel, isSplitHalf: Bool, iconOnly: Bool = false,
                     showsCountOnIcon: Bool = false, iconSize: CGFloat = workspaceSidebarTabIconSize,
                     followsIndent: Bool = true, indent: CGFloat = 0, trailingCount: Int? = nil,
                     groupTint: Color? = nil) -> some View {
        WorkspaceSidebarTabRowView(
            window: window,
            indent: indent,
            isSplitHalf: isSplitHalf,
            iconOnly: iconOnly,
            showsCountOnIcon: showsCountOnIcon,
            iconSize: iconSize,
            allowsDrag: allowsDragAndDrop,
            activeOverride: isActive && window.isFocused &&
                workspaceSidebarMatchingBrowserTabs(browserTabs[window.windowId], window: window, workspace: workspace,
                    query: browserQuery, context: browserSearchContext).isEmpty,
            isSearchSelected: selectedSearchTarget == .window(window.windowId),
            isDragSource: !isBatchSource && dragSourceWindowId == window.windowId,
            actions: actions,
            workspaceMenu: (workspace, onBeginRename),
            followsIndent: followsIndent,
            trailingCount: trailingCount,
            groupTint: groupTint,
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
/// the next tab and removes the workspace; the only tab can't be closed. A saved tab whose
/// apps aren't open shows them, greyed, and clicking it opens them again.
struct WorkspaceSidebarEmptyTabRowView: View {
    let isActive: Bool
    let actions: WorkspaceSidebarActions
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let onBeginRename: () -> Void
    let onSelect: () -> Void
    /// Selects it and opens its saved apps, as a click that activates it does.
    var onOpenSavedApps: () -> Void = {}
    @State private var isHovered = false
    @Environment(\.workspaceSidebarTabIndent) private var indent
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion

    private var savedApps: [WorkspaceSidebarSavedApp] { workspace.savedState?.apps ?? [] }
    private var title: String {
        if !workspace.sidebarLabel.isEmpty { return workspace.displayName }
        return savedApps.isEmpty ? "Empty Tab" : workspaceSidebarSavedAppNames(savedApps)
    }

    var body: some View {
        Button {
            if savedApps.isEmpty { onSelect() } else { onOpenSavedApps() }
        } label: {
            HStack(spacing: 9) {
                if let app = savedApps.first {
                    WorkspaceSidebarTabIcon(bundleId: app.bundleId, bundlePath: app.bundlePath)
                        .saturation(0).opacity(0.45)
                } else {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
                }
                Text(title)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(Color.primary.opacity(isActive ? 0.9 : (savedApps.isEmpty ? 0.65 : 0.5)))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, indent.leadingPadding)
            .padding(.trailing, workspaceSidebarTabCloseSlotWidth)
            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, maxHeight: workspaceSidebarTabRowHeight,
                alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(savedApps.isEmpty ? "Empty tab" : "Open \(workspaceSidebarSavedAppNames(savedApps))")
        .accessibilityLabel(savedApps.isEmpty ? "Empty tab" : "\(title), not open")
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
            RoundedRectangle(cornerRadius: indent.rowCornerRadius, style: .continuous)
                .fill(isActive ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(isHovered ? 0.06 : 0))
                .shadow(color: isActive ? Color.black.opacity(0.22) : .clear, radius: 3, y: 1)
        }
        .animation(WorkspaceSidebarTabMotion.selection(reducesMotion: reducesMotion), value: isActive)
        .overlay {
            // Any id pairs the press with its release; there is no window to close.
            WindowMiddleClickCatcher(windowId: 0) { close() }
        }
        .onHover { hovering in withAnimation(WorkspaceSidebarTabMotion.hover) { isHovered = hovering } }
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

/// The half of a tab a dragged tab would join, or the whole tab for a stack. It uses the
/// insertion line's accent, so every drop target in the list reads the same way.
struct WorkspaceSidebarTabDropSideHighlight: View {
    let placement: WorkspaceSidebarTabDropPlacement?
    /// Where its label sits; without a pointer to avoid, the half's outer end.
    var labelSlot: WorkspaceSidebarTabDropLabelSlot? = nil
    /// A pinned tile's corners; rows take their level's.
    var cornerRadius: CGFloat? = nil
    /// In place of the side it splits to.
    var labelText: String? = nil
    @Environment(\.workspaceSidebarTabIndent) private var indent
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion

    var body: some View {
        GeometryReader { geometry in
            if let placement {
                let width = placement == .stack ? geometry.size.width : geometry.size.width / 2
                let shape = RoundedRectangle(cornerRadius: cornerRadius ?? indent.rowCornerRadius, style: .continuous)
                shape
                    .fill(Color.accentColor.opacity(0.16))
                    .overlay { shape.strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1) }
                    .overlay {
                        if placement == .stack {
                            Image(systemName: "square.stack")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, 8)
                        }
                    }
                    .frame(width: width)
                    .offset(x: placement == .right ? geometry.size.width - width : 0)
                    .transition(.opacity)
                // Clear of the dragged tab, which is centered on the pointer.
                let slot = labelSlot ?? WorkspaceSidebarTabDropLabelSlot(half: placement == .left ? .leading : .trailing,
                    edge: placement == .left ? .leading : .trailing)
                if placement != .stack, !slot.isHidden {
                    WorkspaceSidebarTabDropLabel(text: labelText ?? workspaceSidebarTabDropLabelText(placement))
                        .padding(.horizontal, workspaceSidebarTabDropLabelInset)
                        .frame(width: geometry.size.width / 2, height: geometry.size.height,
                            alignment: slot.edge == .leading ? .leading : .trailing)
                        .offset(x: slot.half == .trailing ? geometry.size.width / 2 : 0)
                        .transition(.opacity)
                }
            }
        }
        // Moving to the other half slides the highlight across; with Reduce Motion it just moves.
        .animation(reducesMotion ? nil : WorkspaceSidebarTabMotion.feedback, value: placement)
        .animation(reducesMotion ? nil : WorkspaceSidebarTabMotion.feedback, value: labelSlot)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What a drop will do, in the accent that marks drop targets.
struct WorkspaceSidebarTabDropLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Color.accentColor, in: Capsule(style: .continuous))
    }
}

/// Where a dragged tab would be inserted between tabs: an accent line from the tabs' icon
/// column, and a label when the drop pulls a window out of its tab into a new one.
struct WorkspaceSidebarTabInsertionLine: View {
    let edge: VerticalEdge?
    var label: String? = nil
    @Environment(\.workspaceSidebarTabIndent) private var indent
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion

    var body: some View {
        ZStack {
            if let edge {
                HStack(spacing: 0) {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: 6, height: 6)
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.leading, -1)
                }
                .overlay(alignment: .trailing) {
                    // On this tab's side of the line, so a group's card never cuts it off.
                    if let label {
                        WorkspaceSidebarTabDropLabel(text: label)
                            .offset(y: edge == .top ? 10 : -10)
                            .padding(.trailing, 6)
                            .transition(.opacity)
                    }
                }
                .padding(.leading, max(0, indent.leadingPadding - 3))
                .padding(.trailing, 4)
                .frame(height: 16)
                // Centered on the gap: just outside the tab, halfway to its neighbor.
                .frame(maxHeight: .infinity, alignment: edge == .top ? .top : .bottom)
                .offset(y: edge == .top ? -9 : 9)
                .transition(reducesMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
        // Moving to the tab's other edge slides the line; with Reduce Motion it just moves.
        .animation(reducesMotion ? nil : WorkspaceSidebarTabMotion.feedback, value: edge)
        .animation(WorkspaceSidebarTabMotion.feedback, value: label)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A chosen tab's accent wash and outline, over its rows so an active pill doesn't hide it.
struct WorkspaceSidebarTabSelectionHighlight: View {
    let isSelected: Bool
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(Color.accentColor.opacity(isSelected ? 0.12 : 0))
            .overlay { shape.strokeBorder(Color.accentColor.opacity(isSelected ? 0.7 : 0), lineWidth: 1.5) }
            .animation(WorkspaceSidebarTabMotion.feedback, value: isSelected)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
