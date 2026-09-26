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
    let onSelect: (UInt32?) -> Void

    var body: some View {
        let windows = workspaceSidebarPinnedTabWindows(workspace)
        let summarizesWorkspace = compact && (windows.count > 2 || workspace.appearance.emoji != nil)
        let displayedWindows = summarizesWorkspace ? Array(windows.prefix(1)) : windows
        return HStack(spacing: 0) {
            if windows.isEmpty {
                Button { onSelect(nil) } label: {
                    icon(nil, windowCount: 0).frame(maxWidth: .infinity, minHeight: compact ? 34 : 54)
                }.buttonStyle(.plain).accessibilityLabel(workspace.displayName)
            } else {
                ForEach(displayedWindows) { window in
                    if window.id != windows.first?.id {
                        Rectangle().fill(.primary.opacity(0.14)).frame(width: 1, height: compact ? 14 : 24).accessibilityHidden(true)
                    }
                    Button { onSelect(summarizesWorkspace ? nil : window.windowId) } label: {
                        icon(window, windowCount: displayedWindows.count)
                            .frame(maxWidth: .infinity, minHeight: compact ? 34 : 54)
                            .contentShape(Rectangle())
                            .overlay(alignment: .topTrailing) {
                                WorkspaceSidebarTabBadge(appName: window.appName, bundlePath: window.appBundlePath,
                                    model: badgeModel, compact: compact)
                                    .fixedSize().padding(compact ? 2 : 3)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(summarizesWorkspace ? workspace.displayName : (window.title.map { "\(window.appName) — \($0)" } ?? window.appName))
                    .accessibilityLabel(summarizesWorkspace ? workspace.displayName : (window.title ?? window.appName))
                    .accessibilityAddTraits((summarizesWorkspace ? workspace.isFocused : window.isFocused) ? .isSelected : [])
                }
            }
        }
        .background((workspace.appearance.colorHex.flatMap(workspaceSidebarColor) ?? Color.primary)
            .opacity(workspace.isVisible ? 0.18 : (compact ? 0 : 0.08)), in: RoundedRectangle(cornerRadius: compact ? 8 : 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(compact ? 0 : 0.10), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(workspace.displayName)
        .sidebarIdentityMenu(.workspace(workspace.name))
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
