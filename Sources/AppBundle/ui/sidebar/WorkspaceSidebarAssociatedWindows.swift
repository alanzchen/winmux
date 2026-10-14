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

/// The auxiliary windows of a tab card: one level under its rows, each selecting and closing only
/// itself. Folded, they're one row saying how many there are; a search shows the matching ones.
struct WorkspaceSidebarAssociatedWindowsView: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let isActive: Bool
    let isSearching: Bool
    let selectedSearchTarget: WorkspaceSidebarSearchSelection?
    let dragSourceWindowId: UInt32?
    let allowsDrag: Bool
    let activation: WorkspaceSidebarTabActivation
    let actions: WorkspaceSidebarActions
    let badgeModel: WorkspaceSidebarDockBadgeModel
    @ObservedObject private var disclosure = WorkspaceSidebarAssociatedWindowsDisclosure.shared
    @Environment(\.workspaceSidebarTabIndent) private var indent
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion

    init(workspace: WorkspaceSidebarWorkspaceViewModel, isActive: Bool, isSearching: Bool,
         selectedSearchTarget: WorkspaceSidebarSearchSelection?, dragSourceWindowId: UInt32?, allowsDrag: Bool,
         activation: WorkspaceSidebarTabActivation, actions: WorkspaceSidebarActions,
         badgeModel: WorkspaceSidebarDockBadgeModel = .shared) {
        self.workspace = workspace
        self.isActive = isActive
        self.isSearching = isSearching
        self.selectedSearchTarget = selectedSearchTarget
        self.dragSourceWindowId = dragSourceWindowId
        self.allowsDrag = allowsDrag
        self.activation = activation
        self.actions = actions
        self.badgeModel = badgeModel
    }

    private var windows: [WorkspaceSidebarAssociatedWindowViewModel] { workspace.associatedWindows }
    private var isCollapsed: Bool { !isSearching && disclosure.isCollapsed(workspace.name) }

    var body: some View {
        VStack(spacing: 2) {
            if isCollapsed {
                summaryRow.transition(.workspaceSidebarTabReveal)
            } else {
                ForEach(windows) { child in
                    childRow(child).transition(.workspaceSidebarTabReveal)
                }
            }
        }
        .animation(WorkspaceSidebarTabMotion.disclosure(reducesMotion: reducesMotion), value: isCollapsed)
    }

    private func toggle() {
        withAnimation(WorkspaceSidebarTabMotion.disclosure(reducesMotion: reducesMotion)) { disclosure.toggle(workspace.name) }
    }

    private func parentTitle(_ child: WorkspaceSidebarAssociatedWindowViewModel) -> String? {
        workspaceSidebarPinnedTabWindows(workspace).first { $0.windowId == child.parentWindowId }
            .map { $0.title ?? $0.appName }
    }

    private func childRow(_ child: WorkspaceSidebarAssociatedWindowViewModel) -> some View {
        WorkspaceSidebarTabRowView(
            window: child.window,
            indent: workspaceSidebarTabIndentStep,
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
        .overlay(alignment: .leading) {
            if child.id == windows.first?.id {
                WorkspaceSidebarTabDisclosureButton(isExpanded: true, canToggle: !isSearching,
                    label: "Fold \(workspaceSidebarAssociatedWindowsCountText(windows.count)) into one row", toggle: toggle)
            }
        }
        .id("window:\(child.window.windowId)")
    }

    private var summaryRow: some View {
        let focusedChild = windows.first(where: \.window.isFocused)
        let isShown = isActive && focusedChild != nil
        let count = workspaceSidebarAssociatedWindowsCountText(windows.count)
        return Button(action: toggle) {
            HStack(spacing: 9) {
                ZStack {
                    ForEach(Array(windows.prefix(2).enumerated()), id: \.offset) { index, child in
                        WorkspaceSidebarTabIcon(bundleId: child.window.appBundleId, bundlePath: child.window.appBundlePath,
                            size: windows.count > 1 ? 11 : workspaceSidebarTabIconSize)
                            .offset(x: windows.count > 1 ? (index == 0 ? -3 : 3) : 0, y: windows.count > 1 ? (index == 0 ? -3 : 3) : 0)
                    }
                }
                .frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
                Text(count)
                    .font(.system(size: 13, weight: isShown ? .medium : .regular))
                    .foregroundStyle(Color.primary.opacity(isShown ? 0.95 : 0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, indent.leadingPadding + workspaceSidebarTabIndentStep)
            .padding(.trailing, workspaceSidebarTabCloseSlotWidth)
            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, maxHeight: workspaceSidebarTabRowHeight,
                alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            WorkspaceSidebarTabDisclosureChevron(isExpanded: false)
                .padding(.leading, indent.leadingPadding)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background {
            // The window in use is one of those folded here: this row stands for it.
            RoundedRectangle(cornerRadius: indent.rowCornerRadius, style: .continuous)
                .fill(isShown ? Color(nsColor: .controlBackgroundColor) : .clear)
                .shadow(color: isShown ? Color.black.opacity(0.22) : .clear, radius: 3, y: 1)
        }
        .help("\(count) opened from this tab, folded. Click to list them.\n"
            + windows.map { $0.window.title ?? $0.window.appName }.joined(separator: "\n"))
        .accessibilityLabel("\(count) opened from this tab")
        .accessibilityValue(isShown ? "Folded, one of them in use" : "Folded")
        .accessibilityHint("Lists them")
        .modifier(WorkspaceSidebarNativeContextMenu {
            windows.map { child in
                WorkspaceSidebarAppMenuEntry.named(child.window.title ?? child.window.appName, { "Show “\($0)”" },
                    perform: { activation.select(.selectWindow(child.window.windowId), send: actions.send) })
            }
        })
        .id("associated:\(workspace.name)")
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
        .padding(.leading, indent.leadingPadding)
        .padding(.trailing, workspaceSidebarTabCloseSlotWidth)
        .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, maxHeight: workspaceSidebarTabRowHeight,
            alignment: .leading)
        .help("\(title) is in another tab and stays there. The window below was opened from it.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), in another tab")
    }
}
