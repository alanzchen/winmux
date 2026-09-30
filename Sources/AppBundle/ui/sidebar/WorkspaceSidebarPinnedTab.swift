import SwiftUI

func workspaceSidebarPinnedTabWindows(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> [WorkspaceSidebarWindowViewModel] {
    workspace.items.flatMap { item in
        switch item.kind {
            case .window(let window): [window]
            case .tabGroup(let group): workspaceSidebarTabGroupWindows(group)
        }
    }
}

struct WorkspaceSidebarPinnedGridLayout {
    let columns: Int
    let height: CGFloat

    init(workspaces: [WorkspaceSidebarWorkspaceViewModel], width: CGFloat) {
        let widestSplit = workspaces.map { workspaceSidebarPinnedTabWindows($0).count }.max() ?? 1
        let minimumTileWidth = max(72, CGFloat(widestSplit) * 46)
        columns = max(1, Int((max(width, 0) + 8) / (minimumTileWidth + 8)))
        height = workspaces.isEmpty ? 0 : CGFloat(min(3, (workspaces.count + columns - 1) / columns) * 62 - 8)
    }
}

let workspaceSidebarPinnedGridSpacing: CGFloat = 8
let workspaceSidebarPinnedGridRowHeight: CGFloat = 54

/// Pins are a small, bounded-height surface. Measure them eagerly so revealing a
/// zero-width, auto-hidden sidebar never depends on a lazy scroll viewport refresh.
/// Keeping one flat set of subviews also preserves tile identity across columns.
struct WorkspaceSidebarPinnedGrid: SwiftUI.Layout {
    let columns: Int
    private let spacing = workspaceSidebarPinnedGridSpacing
    private let rowHeight = workspaceSidebarPinnedGridRowHeight

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = max(columns, 1)
        let rows = (subviews.count + count - 1) / count
        return CGSize(width: max(proposal.width ?? CGFloat(count) * 72, 0),
            height: rows == 0 ? 0 : CGFloat(rows) * (rowHeight + spacing) - spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = max(columns, 1)
        let width = max((bounds.width - CGFloat(count - 1) * spacing) / CGFloat(count), 0)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index % count) * (width + spacing),
                y: bounds.minY + CGFloat(index / count) * (rowHeight + spacing)), anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: rowHeight))
        }
    }
}

/// Layout animation follows membership and order, independent of title/focus updates.
struct WorkspaceSidebarPinnedTabIdentity: Equatable {
    let name: String
    let windowIds: [UInt32]

    init(_ workspace: WorkspaceSidebarWorkspaceViewModel) {
        name = workspace.name
        windowIds = workspaceSidebarPinnedTabWindows(workspace).map(\.windowId)
    }
}

struct WorkspaceSidebarPinnedTab: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let badgeModel: WorkspaceSidebarDockBadgeModel
    var compact = false
    var targetMonitorScopeId: String? = nil
    /// Expanded, a pin drags as its whole tab: among the pins to rearrange them, or into the list
    /// to unpin it there. Nil for the compact rail.
    var actions: WorkspaceSidebarActions? = nil
    /// The side a dragged tab would go beside this pin.
    var insertionEdge: HorizontalEdge? = nil
    /// A dragged window joins this pin: beside its window on `dropPlacement`'s side, or, with no
    /// side, into it.
    var isDropTarget = false
    var dropPlacement: WorkspaceSidebarTabDropPlacement? = nil
    var dropLabelSlot: WorkspaceSidebarTabDropLabelSlot? = nil
    /// Selects a saved pin whose windows are gone and opens its apps in it, as a click that
    /// activates it does; one that only chooses it, with Shift or Command, opens nothing.
    var onOpenSavedApps: (() -> Void)? = nil
    let onSelect: (UInt32?) -> Void
    @State private var isHovered = false
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion
    @ObservedObject private var selection = WorkspaceSidebarTabSelection.shared
    @ObservedObject private var drag = WorkspaceSidebarTabDragState.shared

    var body: some View {
        let windows = workspaceSidebarPinnedTabWindows(workspace)
        let identity = windows.count > 1 ? WorkspaceSidebarSplitIdentity(workspace) : nil
        let showsIdentity = !compact && identity != nil
        let summarizesWorkspace = compact && windows.count > 2
        let displayedWindows = summarizesWorkspace ? Array(windows.prefix(1)) : windows
        return VStack(spacing: 0) {
            if showsIdentity, let identity {
                Button { onSelect(nil) } label: {
                    WorkspaceSidebarSplitIdentityLabel(identity: identity)
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 7)
                        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(workspace.displayName)
                .accessibilityLabel(workspace.displayName)
                .sidebarIdentityMenu(.tab(workspace.name, windowId: nil))
            }
            HStack(spacing: 0) {
                if windows.isEmpty {
                    // A saved pin whose app isn't open shows that app, greyed; clicking opens it again.
                    let savedApps = workspace.savedState?.apps ?? []
                    let appNames = workspaceSidebarSavedAppNames(savedApps)
                    Button {
                        if !savedApps.isEmpty, let onOpenSavedApps { onOpenSavedApps() } else { onSelect(nil) }
                    } label: {
                        Group {
                            if savedApps.isEmpty || (savedApps.count == 1 && workspace.appearance.emoji != nil) {
                                icon(nil, windowCount: 0)
                            } else {
                                WorkspaceSidebarSavedAppIcons(apps: savedApps, size: compact ? 18 : 22)
                            }
                        }
                        .opacity(savedApps.isEmpty ? 1 : 0.45)
                        .saturation(savedApps.isEmpty ? 1 : 0)
                        .frame(maxWidth: .infinity, minHeight: compact ? 34 : 54)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help(savedApps.isEmpty ? workspace.displayName : "Open \(appNames)")
                        .accessibilityLabel(savedApps.isEmpty ? workspace.displayName : "\(workspace.displayName), \(appNames) not open")
                        .accessibilityHint(savedApps.isEmpty ? "" : "Opens \(appNames)")
                        .sidebarIdentityMenu(.workspace(workspace.name))
                } else {
                    ForEach(displayedWindows) { window in
                        if window.id != windows.first?.id {
                            Rectangle().fill(.primary.opacity(0.14)).frame(width: 1, height: compact ? 14 : 24).accessibilityHidden(true)
                        }
                        Button { onSelect(summarizesWorkspace ? nil : window.windowId) } label: {
                            icon(window, windowCount: displayedWindows.count)
                                .frame(maxWidth: .infinity, minHeight: compact || showsIdentity ? 34 : 54)
                                .contentShape(Rectangle())
                                .overlay(alignment: .topTrailing) {
                                    WorkspaceSidebarTabBadge(appName: window.appName, bundlePath: window.appBundlePath,
                                        model: badgeModel, compact: compact, windowId: window.windowId)
                                        .fixedSize().padding(compact ? 2 : 3)
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    WorkspaceSidebarTabAudioIndicator(window: window, size: compact ? 7 : 9)
                                        .padding(compact ? 3 : 6)
                                }
                        }
                        .buttonStyle(.plain)
                        .background {
                            if window.isFocused && isActiveHere {
                                RoundedRectangle(cornerRadius: compact ? 6 : 10)
                                    .fill(Color(nsColor: .controlBackgroundColor)).padding(compact ? 1 : 3)
                            }
                        }
                        .help(summarizesWorkspace ? workspace.displayName : (window.title.map { "\(window.appName) — \($0)" } ?? window.appName))
                        .accessibilityLabel(summarizesWorkspace ? workspace.displayName : (window.title ?? window.appName))
                        .accessibilityAddTraits(isActiveHere && (summarizesWorkspace ? workspace.isFocused : window.isFocused) ? .isSelected : [])
                        .sidebarIdentityMenu(.tab(workspace.name, windowId: summarizesWorkspace ? nil : window.windowId))
                    }
                }
            }
        }
        .background((workspace.appearance.colorHex.flatMap(workspaceSidebarColor) ?? Color.primary)
            .opacity(isActiveHere ? 0.18 : (compact ? (isHovered ? 0.07 : 0) : (isHovered ? 0.12 : 0.08))),
            in: RoundedRectangle(cornerRadius: compact ? 8 : 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(compact ? 0 : 0.10), lineWidth: 0.5))
        .overlay {
            WorkspaceSidebarTabSelectionHighlight(isSelected: selection.contains(workspace.name), cornerRadius: compact ? 8 : 13)
        }
        .opacity(drag.draggedPinnedTab == workspace.name ? 0.45 : 1)
        .animation(WorkspaceSidebarTabMotion.feedback, value: drag.draggedPinnedTab == workspace.name)
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: actions != nil,
            onChanged: { actions?.pinnedTabDragChanged(workspace.name, $0) },
            onEnded: { actions?.pinnedTabDragEnded(workspace.name, $0) },
        ))
        .overlay {
            let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
            shape.fill(Color.accentColor.opacity(isDropTarget && dropPlacement == nil ? 0.14 : 0))
                .overlay { shape.strokeBorder(Color.accentColor.opacity(isDropTarget && dropPlacement == nil ? 0.65 : 0), lineWidth: 1) }
                .allowsHitTesting(false)
                .animation(WorkspaceSidebarTabMotion.feedback, value: isDropTarget)
        }
        .overlay {
            WorkspaceSidebarTabDropSideHighlight(placement: isDropTarget ? dropPlacement : nil, labelSlot: dropLabelSlot,
                cornerRadius: 13)
        }
        .overlay { WorkspaceSidebarPinnedInsertionLine(edge: insertionEdge) }
        .animation(WorkspaceSidebarTabMotion.selection(reducesMotion: reducesMotion), value: isActiveHere)
        .animation(WorkspaceSidebarTabMotion.selection(reducesMotion: reducesMotion), value: windows.first(where: \.isFocused)?.windowId)
        .onHover { hovering in withAnimation(WorkspaceSidebarTabMotion.hover) { isHovered = hovering } }
        .overlay(alignment: .topLeading) {
            if compact, windows.count == 2, let emoji = identity?.emoji {
                Text(emoji).font(.system(size: 9)).padding(1).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(workspace.displayName)
    }

    private var isActiveHere: Bool {
        workspaceSidebarTabIsActive(workspace, on: targetMonitorScopeId)
    }

    @ViewBuilder
    private func icon(_ window: WorkspaceSidebarWindowViewModel?, windowCount: Int) -> some View {
        if windowCount <= 1, let emoji = workspace.appearance.emoji {
            Text(emoji).font(.system(size: compact ? 19 : 23))
        } else if let window {
            WorkspaceSidebarTabIcon(bundleId: window.appBundleId, bundlePath: window.appBundlePath,
                size: compact ? min(20, 26 / CGFloat(max(windowCount, 1))) : 22)
        } else { Image(systemName: "macwindow").font(.system(size: compact ? 19 : 22)) }
    }
}

/// A saved tab's apps while none of its windows are open: one icon per app, up to three.
struct WorkspaceSidebarSavedAppIcons: View {
    let apps: [WorkspaceSidebarSavedApp]
    var size: CGFloat = 22

    var body: some View {
        let shown = workspaceSidebarDistinctSavedApps(apps).prefix(3)
        HStack(spacing: 4) {
            ForEach(Array(shown), id: \.bundleId) { app in
                WorkspaceSidebarTabIcon(bundleId: app.bundleId, bundlePath: app.bundlePath,
                    size: shown.count > 1 ? size * 0.8 : size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Each app once, in the order its windows were saved.
func workspaceSidebarDistinctSavedApps(_ apps: [WorkspaceSidebarSavedApp]) -> [WorkspaceSidebarSavedApp] {
    var seen: Set<String> = []
    return apps.filter { seen.insert($0.bundleId).inserted }
}

func workspaceSidebarSavedAppNames(_ apps: [WorkspaceSidebarSavedApp]) -> String {
    ListFormatter.localizedString(byJoining: workspaceSidebarDistinctSavedApps(apps).map(\.name))
}

/// Where a dragged tab would go among the pins: an accent line centered in the space beside a pin.
struct WorkspaceSidebarPinnedInsertionLine: View {
    let edge: HorizontalEdge?
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion

    var body: some View {
        ZStack(alignment: edge == .trailing ? .trailing : .leading) {
            Color.clear
            if let edge {
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .offset(x: (edge == .leading ? -1 : 1) * (workspaceSidebarPinnedGridSpacing + 3) / 2)
                    .transition(reducesMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(reducesMotion ? nil : WorkspaceSidebarTabMotion.feedback, value: edge)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The side of this pin a dragged tab would go, while one is beside it.
func workspaceSidebarPinnedInsertionEdge(_ preview: WorkspaceSidebarDropPreviewViewModel?, workspaceName: String,
                                         projectId: WorkspaceProjectId) -> HorizontalEdge? {
    guard let preview, preview.targetsPinned, preview.targetProjectId == projectId,
          let gap = preview.targetPinnedGap, gap.workspaceName == workspaceName else { return nil }
    return gap.isAfter ? .trailing : .leading
}

func workspaceSidebarTabIsActive(_ workspace: WorkspaceSidebarWorkspaceViewModel, on scope: String?) -> Bool {
    guard workspace.isVisible else { return false }
    guard let scope else { return true }
    return workspaceSidebarMonitorScopeIsSentinel(scope) || workspace.monitorScopeId == scope
}
