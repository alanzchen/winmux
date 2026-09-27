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
    let onSelect: (UInt32?) -> Void

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
                    Button { onSelect(nil) } label: {
                        icon(nil, windowCount: 0).frame(maxWidth: .infinity, minHeight: compact ? 34 : 54)
                    }.buttonStyle(.plain).accessibilityLabel(workspace.displayName)
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
            .opacity(isActiveHere ? 0.18 : (compact ? 0 : 0.08)), in: RoundedRectangle(cornerRadius: compact ? 8 : 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(compact ? 0 : 0.10), lineWidth: 0.5))
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

func workspaceSidebarTabIsActive(_ workspace: WorkspaceSidebarWorkspaceViewModel, on scope: String?) -> Bool {
    guard workspace.isVisible else { return false }
    guard let scope else { return true }
    return workspaceSidebarMonitorScopeIsSentinel(scope) || workspace.monitorScopeId == scope
}
