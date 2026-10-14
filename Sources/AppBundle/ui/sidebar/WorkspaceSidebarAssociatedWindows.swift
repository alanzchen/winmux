import AppKit
import SwiftUI

/// Which tabs list their auxiliary windows folded into one row. Only the list changes: no window
/// is closed, minimized or moved, and nothing is saved.
@MainActor
final class WorkspaceSidebarAssociatedWindowsDisclosure: ObservableObject {
    static let shared = WorkspaceSidebarAssociatedWindowsDisclosure()
    @Published private(set) var collapsedTabs: Set<String> = []

    func isCollapsed(_ tabName: String) -> Bool { collapsedTabs.contains(tabName) }

    func toggle(_ tabName: String) {
        if collapsedTabs.contains(tabName) { collapsedTabs.remove(tabName) } else { collapsedTabs.insert(tabName) }
    }

    func reset() { collapsedTabs = [] }
}

/// "2 windows", for a folded row and its help.
func workspaceSidebarAssociatedWindowsCountText(_ count: Int) -> String {
    count == 1 ? "1 window" : "\(count) windows"
}

/// What an auxiliary window is, in a sentence: "Mail compose window".
func workspaceSidebarAuxiliaryWindowKind(_ role: AuxiliaryWindowRole, appName: String) -> String {
    switch role {
        case .mailCompose: "\(appName) compose window"
        case .mailMessage: "\(appName) message window"
        case .dialog: "\(appName) dialog"
    }
}

/// Whether a tab's windows opened from its own can be folded: as a browser window's tabs, not while
/// the tab is in use or a search lists them, so the window in use is never folded away.
func workspaceSidebarAssociatedWindowsCanFold(isActive: Bool, isSearching: Bool) -> Bool { !isActive && !isSearching }

/// Windows of a tab opened from one of its own, in one card with the row they belong to, as a browser
/// window's tabs are: that row heads the card, with the disclosure on its icon column and how many
/// there are in its trailing slot, and they're listed one level in, under it. Each selects and closes
/// only itself. Folding hides only their rows: no window is closed, minimized or moved.
struct WorkspaceSidebarAssociatedWindowsGroupView<Header: View>: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    /// Those under this header: all of the tab's, or one window's in a split.
    let windows: [WorkspaceSidebarAssociatedWindowViewModel]
    let isActive: Bool
    let isSearching: Bool
    let selectedSearchTarget: WorkspaceSidebarSearchSelection?
    let dragSourceWindowId: UInt32?
    let allowsDrag: Bool
    let activation: WorkspaceSidebarTabActivation
    let actions: WorkspaceSidebarActions
    var badgeModel: WorkspaceSidebarDockBadgeModel = .shared
    var tint: Color? = nil
    /// A card flush inside another shape, such as a split's, takes that shape's corners.
    var cornerRadius: CGFloat? = nil
    /// The row heading the card, given how many windows it lists.
    @ViewBuilder let header: (_ count: Int) -> Header
    @ObservedObject private var disclosure = WorkspaceSidebarAssociatedWindowsDisclosure.shared

    private var canToggle: Bool { workspaceSidebarAssociatedWindowsCanFold(isActive: isActive, isSearching: isSearching) }
    private var isCollapsed: Bool { canToggle && disclosure.isCollapsed(workspace.name) }

    var body: some View {
        let count = workspaceSidebarAssociatedWindowsCountText(windows.count)
        WorkspaceSidebarTabGroupCard(tint: tint, isExpanded: !isCollapsed, isActive: isActive, cornerRadius: cornerRadius) {
            header(windows.count)
                .overlay(alignment: .leading) {
                    WorkspaceSidebarTabDisclosureButton(isExpanded: !isCollapsed, tint: tint, canToggle: canToggle,
                        label: isCollapsed ? "Show \(count) opened from this window" : "Fold \(count) opened from this window",
                        toggle: { disclosure.toggle(workspace.name) })
                }
        } content: {
            ForEach(windows) { child in
                childRow(child).transition(.workspaceSidebarTabReveal)
            }
        }
    }

    private func parentTitle(_ child: WorkspaceSidebarAssociatedWindowViewModel) -> String? {
        workspaceSidebarPinnedTabWindows(workspace).first { $0.windowId == child.parentWindowId }
            .map { $0.title ?? $0.appName } ?? workspace.lentWindow.map { $0.title ?? $0.appName }
    }

    /// A window's own row, one level in: highlighted alone while it's the one in use.
    private func childRow(_ child: WorkspaceSidebarAssociatedWindowViewModel) -> some View {
        WorkspaceSidebarTabRowView(
            window: child.window,
            indent: 0,
            allowsDrag: allowsDrag,
            activeOverride: isActive && child.window.isFocused,
            isSearchSelected: selectedSearchTarget == .window(child.window.windowId),
            isDragSource: dragSourceWindowId == child.window.windowId,
            actions: actions,
            detach: { actions.send(.detachTabWindow(child.window.windowId)) },
            onSelect: { activation.select(.selectWindow(child.window.windowId), send: actions.send) },
            badgeModel: badgeModel,
        )
        // What it is and where it came from: "Mail compose window, opened from Inbox".
        .accessibilityHint([workspaceSidebarAuxiliaryWindowKind(child.role, appName: child.window.appName),
            parentTitle(child).map { "opened from \($0)" }].compactMap { $0 }.joined(separator: ", "))
        .id("window:\(child.window.windowId)")
    }
}

/// A tab's windows opened from its own, by the window each was opened from, in the order of the tab's
/// windows; any whose window isn't one of them last, together, with no window to name.
struct WorkspaceSidebarAssociatedWindowGroup {
    let parent: WorkspaceSidebarWindowViewModel?
    let windows: [WorkspaceSidebarAssociatedWindowViewModel]
    var id: String { parent.map { "parent:\($0.windowId)" } ?? "parent:none" }
}

func workspaceSidebarAssociatedWindowGroups(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> [WorkspaceSidebarAssociatedWindowGroup] {
    let parents = workspaceSidebarPinnedTabWindows(workspace)
    var groups = parents.compactMap { parent -> WorkspaceSidebarAssociatedWindowGroup? in
        let windows = workspace.associatedWindows.filter { $0.parentWindowId == parent.windowId }
        return windows.isEmpty ? nil : .init(parent: parent, windows: windows)
    }
    let ids = Set(parents.map(\.windowId))
    let others = workspace.associatedWindows.filter { !ids.contains($0.parentWindowId) }
    if !others.isEmpty { groups.append(.init(parent: nil, windows: others)) }
    return groups
}

/// A tab's windows opened from its own in the order they're listed, by the window each came from: the
/// order of the rows and of the arrow keys in a search.
func workspaceSidebarListedAssociatedWindows(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> [WorkspaceSidebarAssociatedWindowViewModel] {
    workspaceSidebarAssociatedWindowGroups(workspace).flatMap(\.windows)
}

/// The header of a card of windows opened from one window that isn't the tab's only row, as in a split:
/// that window's icon and title, and how many were opened from it.
struct WorkspaceSidebarAssociatedWindowsParentLabel: View {
    let parent: WorkspaceSidebarWindowViewModel?
    let count: Int
    var tint: Color? = nil
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            WorkspaceSidebarTabGroupHeaderLabel(isExpanded: true, tint: tint, count: count, drawsChevron: false) {
                if let parent {
                    WorkspaceSidebarTabIcon(bundleId: parent.appBundleId, bundlePath: parent.appBundlePath)
                } else {
                    Image(systemName: "macwindow").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.45))
                }
            } title: {
                WorkspaceSidebarTabGroupTitle(text: parent.map { $0.title ?? $0.appName } ?? "Opened from this tab", tint: tint)
            }
        }
        .buttonStyle(.plain)
        .help(parent.map { "Opened from \($0.title ?? $0.appName)" } ?? "Opened from this tab")
        .accessibilityLabel(parent.map { "\($0.title ?? $0.appName), \($0.appName), \(count) opened from it" }
            ?? "\(count) opened from this tab")
    }
}

/// A pin's count of windows opened from it, in the accent while one of them is in use.
struct WorkspaceSidebarAssociatedWindowsCountBadge: View {
    let count: Int
    let isInUse: Bool
    var compact = false

    var body: some View {
        Text("+\(count)")
            .font(.system(size: compact ? 8 : 9, weight: .semibold).monospacedDigit())
            .foregroundStyle(isInUse ? Color.white : Color.primary.opacity(0.7))
            .padding(.horizontal, compact ? 3 : 4)
            .padding(.vertical, compact ? 0 : 1)
            .background(Capsule().fill(isInUse ? Color.accentColor : Color.primary.opacity(0.12)))
    }
}

/// One accessibility action per window opened from a pin, which brings it forward.
struct WorkspaceSidebarAssociatedWindowActions: ViewModifier {
    let windows: [WorkspaceSidebarAssociatedWindowViewModel]
    let select: (UInt32) -> Void

    func body(content: Content) -> some View {
        windows.reduce(AnyView(content)) { view, child in
            AnyView(view.accessibilityAction(named: "Show “\(child.window.title ?? child.window.appName)”") {
                select(child.window.windowId)
            })
        }
    }
}

/// The context above windows of a tab whose parent isn't one of its own rows: a pin's window, lent to
/// another tab. It only names that window and where it is: it isn't the tab's, and it neither selects,
/// moves nor closes anything.
struct WorkspaceSidebarElsewhereParentRow: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    @Environment(\.workspaceSidebarTabIndent) private var indent

    private var title: String {
        workspace.lentWindow.map { $0.title?.takeIf { !$0.isEmpty } ?? $0.appName } ?? workspace.displayName
    }

    var body: some View {
        HStack(spacing: 9) {
            if let lent = workspace.lentWindow {
                WorkspaceSidebarTabIcon(bundleId: lent.appBundleId, bundlePath: lent.appBundlePath).saturation(0).opacity(0.5)
            } else {
                Image(systemName: "macwindow").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
            }
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text("In another tab")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.55))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        // It heads its card: the icon sits after the disclosure, as every group's header's does.
        .padding(.leading, indent.leadingPadding + workspaceSidebarTabIndentStep)
        .padding(.trailing, workspaceSidebarTabCloseSlotWidth)
        .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, maxHeight: workspaceSidebarTabRowHeight,
            alignment: .leading)
        .help("\(title) is in another tab and stays there. The window below was opened from it.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), in another tab")
    }
}
