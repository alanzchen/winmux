import AppKit
import SwiftUI

/// How a workspace shows in Tabs mode. Most workspaces hold one window and are just a tab;
/// two windows share one row, as a split view does in a browser. A workspace
/// with a name you gave it, a saved one, a stack, or more windows stays a folder.
enum WorkspaceSidebarTabPresentation: Equatable {
    /// An empty workspace, such as a new tab waiting for an app.
    case empty
    case single(WorkspaceSidebarWindowViewModel)
    case split(WorkspaceSidebarWindowViewModel, WorkspaceSidebarWindowViewModel)
    case folder
}

func workspaceSidebarTabPresentation(
    _ workspace: WorkspaceSidebarWorkspaceViewModel,
    showsProjectContext: Bool = false,
    isRenaming: Bool = false,
    isSearching: Bool = false,
) -> WorkspaceSidebarTabPresentation {
    // A search narrows a workspace to its matches; the folder says which workspace they're in.
    guard workspace.isGeneratedName, workspace.savedState == nil, !showsProjectContext, !isRenaming, !isSearching
    else { return .folder }
    let windows = workspace.items.compactMap { item -> WorkspaceSidebarWindowViewModel? in
        if case .window(let window) = item.kind { window } else { nil }
    }
    // A stack keeps the folder that shows it as a group.
    guard windows.count == workspace.items.count else { return .folder }
    switch windows.count {
        case 0: return .empty
        case 1: return .single(windows[0])
        case 2: return .split(windows[0], windows[1])
        default: return .folder
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
    let onBeginRename: () -> Void
    let onCommitOverride: () -> Void
    let onCancelOverride: () -> Void

    var body: some View {
        content
            .frame(minHeight: isShowingOverride ? overrideMinHeight : nil, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(backgroundOpacity))
            }
            // Over the rows, so a focused half's pill doesn't hide it.
            .overlay {
                RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(isDropTarget ? 0.55 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
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
                // Dropping a dragged tab here moves its window into this workspace.
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

    private var backgroundOpacity: Double {
        if isDropTarget { return 0.14 }
        if selectedSearchTarget == .workspace(workspace.name) { return 0.1 }
        switch presentation {
            // Two windows share one tab, shown as one.
            case .split: return isActive ? 0.1 : 0.04
            // The tab on screen stays marked even while its window isn't the focused one.
            case .single: return isActive ? 0.1 : 0
            case .empty, .folder: return 0
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
            case .single(let window):
                row(window, isSplitHalf: false)
            case .split(let left, let right):
                HStack(spacing: 2) {
                    row(left, isSplitHalf: true)
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1, height: 16)
                        .accessibilityHidden(true)
                    row(right, isSplitHalf: true)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Split: \(left.title ?? left.appName) and \(right.title ?? right.appName)")
            case .empty:
                WorkspaceSidebarEmptyTabRowView(isActive: isActive, actions: actions, workspace: workspace,
                    onBeginRename: onBeginRename,
                    onSelect: { activation.select(.selectWorkspace(workspace.name), send: actions.send) })
            case .folder:
                EmptyView()
        }
    }

    private func row(_ window: WorkspaceSidebarWindowViewModel, isSplitHalf: Bool) -> some View {
        WorkspaceSidebarTabRowView(
            window: window,
            indent: 0,
            isSplitHalf: isSplitHalf,
            isSearchSelected: selectedSearchTarget == .window(window.windowId),
            isDragSource: dragSourceWindowId == window.windowId,
            actions: actions,
            workspaceMenu: (workspace, onBeginRename),
            onSelect: { activation.select(.selectWindow(window.windowId), send: actions.send) },
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
                    .foregroundStyle(isActive ? Color.black.opacity(0.55) : Color.white.opacity(0.55))
                    .frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
                Text("Empty Tab")
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Color.black.opacity(0.86) : Color.white.opacity(0.6))
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
                    .foregroundStyle(isActive ? Color.black.opacity(0.55) : Color.white.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isActive ? Color.black.opacity(0.07) : Color.white.opacity(0.1))
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
                .fill(isActive ? Color.white.opacity(0.92) : Color.white.opacity(isHovered ? 0.08 : 0))
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
    }

    private func close() {
        guard !isWorkspaceSidebarDragInProgress() else { return }
        actions.send(.closeEmptyTab(workspace.name))
    }
}
