import SwiftUI

struct WorkspaceSidebarAppReminder: Identifiable, Equatable {
    struct ID: Hashable {
        let workspace: String
        let app: String
    }
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let app: WorkspaceSidebarAppViewModel
    var id: ID { ID(workspace: workspace.name, app: app.id) }
}

/// A Dock badge belongs to the application, not to an individual window. Keep
/// workspace destinations distinct instead of guessing which window is unread.
func workspaceSidebarAppReminders(
    workspaces: [WorkspaceSidebarWorkspaceViewModel],
    displayedWorkspaceNames: Set<String>,
    badges: WorkspaceSidebarDockBadgeSnapshot,
    enabled: Bool
) -> [WorkspaceSidebarAppReminder] {
    guard enabled else { return [] }
    return workspaces.filter { !displayedWorkspaceNames.contains($0.name) && !$0.isVisible }.flatMap { workspace in
        workspace.apps.filter { badges.label(forPath: $0.bundlePath) != nil }
            .map { WorkspaceSidebarAppReminder(workspace: workspace, app: $0) }
    }
}

/// Bound the footer to three icons; more reminders remain reachable by scrolling.
func workspaceSidebarReminderLength(count: Int, iconSize: CGFloat) -> CGFloat {
    count > 0 ? 8 + CGFloat(min(count, 3)) * (iconSize + 8) : 0
}

extension WorkspaceSidebarView {
    var hiddenWorkspaceAppReminders: [WorkspaceSidebarAppReminder] {
        guard snapshot.configuration.showAppIcons, snapshot.configuration.showHiddenWorkspaceAppReminders else { return [] }
        guard !dockBadgePresence.paths.isEmpty else { return [] }
        return workspaceSidebarAppReminders(workspaces: snapshot.workspaces,
            displayedWorkspaceNames: Set(currentFilteredProjectWorkspaces().map(\.name)),
            badges: dockBadgeModel.snapshot,
            enabled: true)
    }

    @ViewBuilder
    func hiddenWorkspaceReminderSection(layout: WorkspaceSidebarConfiguration) -> some View {
        let reminders = hiddenWorkspaceAppReminders
        if !reminders.isEmpty {
            let horizontal = layout.dockPosition == .bottom
            let length = workspaceSidebarReminderLength(count: reminders.count, iconSize: layout.dockIconSize)
            let stack = horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
            ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
                stack {
                    ForEach(reminders) { reminder in
                        WorkspaceSidebarAppReminderButton(reminder: reminder, layout: layout, actions: actions, model: dockBadgeModel)
                    }
                }
                .padding(horizontal ? .horizontal : .vertical, 4)
                .frame(minWidth: horizontal ? nil : layout.compactRailWidth,
                    minHeight: horizontal ? layout.compactRailWidth : nil)
            }
            .frame(width: horizontal ? length - 8 : layout.compactRailWidth,
                height: horizontal ? layout.compactRailWidth : length - 8)
            .padding(horizontal ? .leading : .top, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Hidden workspace app reminders")
        }
    }

}

/// Observe counts at the button, including its accessibility value, without
/// invalidating the Dock geometry that only observes badge presence.
struct WorkspaceSidebarAppReminderButton: View {
    let reminder: WorkspaceSidebarAppReminder
    let layout: WorkspaceSidebarConfiguration
    let actions: WorkspaceSidebarActions
    @ObservedObject var model: WorkspaceSidebarDockBadgeModel

    var body: some View {
        let size = layout.dockIconSize
        let description = workspaceSidebarAppContextDescription(reminder.app, workspaceDisplayName: reminder.workspace.displayName)
        return Button {
            guard !isWorkspaceSidebarDragInProgress() else { return }
            actions.send(.selectApp(workspaceName: reminder.workspace.name, appId: reminder.app.id))
        } label: {
            AppIconView(bundleIdentifier: reminder.app.bundleId, bundlePath: reminder.app.bundlePath) { icon in
                if let icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: size, height: size)
            .overlay {
                WorkspaceSidebarIdentityLabel(label: String(reminder.workspace.displayName.prefix(4)), size: size)
            }
            .overlay { WorkspaceSidebarDockBadge(app: reminder.app, isReminder: true, model: model) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Focus \(description)")
        .accessibilityValue(model.snapshot.label(forPath: reminder.app.bundlePath).map { "Badge: \($0)" } ?? "")
        .modifier(WorkspaceSidebarIconTooltip(text: description, kind: .app))
        // Native Dock footer is hosted separately from the root SwiftUI environment.
        .environment(\.workspaceSidebarTooltipVisibility, WorkspaceSidebarTooltipVisibility(
            workspace: layout.showWorkspaceTooltips, app: layout.showAppTooltips))
        .contextMenu {
            WorkspaceSidebarAppMenuContent(workspaceName: reminder.workspace.name, app: reminder.app)
        }
    }
}
