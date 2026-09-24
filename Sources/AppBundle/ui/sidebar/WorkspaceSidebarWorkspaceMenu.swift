import SwiftUI

enum WorkspaceSidebarWorkspaceMenuCommand: Equatable {
    case customizeDock
    case rename
    case send(WorkspaceSidebarAction)
}

/// One description of the workspace menu feeds both the SwiftUI rail and the AppKit Dock.
struct WorkspaceSidebarWorkspaceMenuEntry: Equatable {
    var title: String = ""
    var checked = false
    var enabled = true
    var isDestructive = false
    var command: WorkspaceSidebarWorkspaceMenuCommand? = nil

    static var separator: Self { Self() }
    var isSeparator: Bool { title.isEmpty }
}

/// Live facts the menu needs that the snapshot doesn't carry.
struct WorkspaceSidebarWorkspaceMenuContext: Equatable {
    var monitorCount: Int
    /// The display the workspace is on, which Keep on pins it to.
    var currentDisplayName: String?
    var isForceAssignedByConfig = false
    /// Pinning needs a display WinMux can recognize again later.
    var currentDisplayHasIdentity = true
}

@MainActor
func workspaceSidebarWorkspaceMenuContext(workspaceName: String) -> WorkspaceSidebarWorkspaceMenuContext {
    let workspace = Workspace.existing(byName: workspaceName)
    let currentDisplay = workspace.map { $0.visibleMonitor ?? $0.workspaceMonitor }
    return WorkspaceSidebarWorkspaceMenuContext(
        monitorCount: monitors.count,
        currentDisplayName: currentDisplay?.name,
        isForceAssignedByConfig: resolvedForceAssignedMonitor(forWorkspaceName: workspaceName) != nil,
        currentDisplayHasIdentity: currentDisplay.map { SavedDisplayAffinity(monitor: $0) != nil } ?? false,
    )
}

func workspaceSidebarWorkspaceMenuEntries(
    _ workspace: WorkspaceSidebarWorkspaceViewModel,
    context: WorkspaceSidebarWorkspaceMenuContext,
) -> [WorkspaceSidebarWorkspaceMenuEntry] {
    let saved = workspace.savedState
    var entries: [WorkspaceSidebarWorkspaceMenuEntry] = [
        .init(title: "Customize Dock & Sidebar…", command: .customizeDock),
        .separator,
        .init(title: "Rename Workspace", command: .rename),
    ]
    if saved == nil {
        entries.append(.init(title: "Save Workspace", command: .send(.saveWorkspace(workspace.name))))
    }
    if let keepOn = workspaceSidebarKeepOnDisplayEntry(workspace, context: context) {
        entries.append(keepOn)
    }
    if let saved, !saved.missingAppNames.isEmpty {
        entries.append(.init(
            title: "Open Missing Apps (\(saved.missingAppNames.count))",
            command: .send(.openSavedWorkspaceApps(workspace.name)),
        ))
    }
    entries.append(.separator)
    if saved != nil {
        entries.append(.init(title: "Forget Saved Workspace", command: .send(.forgetSavedWorkspace(workspace.name))))
    }
    entries.append(.init(title: "Delete Workspace", isDestructive: true, command: .send(.deleteWorkspace(workspace.name))))
    return entries
}

/// Shown with more than one display, or while pinned so it can be unpinned. A pinned workspace
/// names its home; otherwise it names the display it is on, where pinning keeps it.
private func workspaceSidebarKeepOnDisplayEntry(
    _ workspace: WorkspaceSidebarWorkspaceViewModel,
    context: WorkspaceSidebarWorkspaceMenuContext,
) -> WorkspaceSidebarWorkspaceMenuEntry? {
    let saved = workspace.savedState
    let isPinned = saved?.isPinnedToDisplay == true
    guard context.monitorCount > 1 || isPinned else { return nil }
    let isForceAssigned = context.isForceAssignedByConfig || saved?.isForceAssignedByConfig == true
    let displayName = (isPinned && !isForceAssigned ? saved?.homeDisplayName : nil)
        ?? context.currentDisplayName
        ?? saved?.homeDisplayName
    let title = "Keep on " + (displayName.map { "“\($0)”" } ?? "This Display")
    if isForceAssigned {
        // workspace-to-monitor-force-assignment wins over the saved home. An older pin can
        // still be removed, so it doesn't come back when the config entry goes away.
        if isPinned, let home = saved?.homeDisplayName {
            return .init(
                title: "Keep on “\(home)” (Overridden by Config)",
                checked: true,
                command: .send(.setSavedWorkspacePinned(workspace.name, false)),
            )
        }
        return .init(title: title + " (Set in Config)", checked: true, enabled: false)
    }
    if !isPinned, !context.currentDisplayHasIdentity {
        return .init(title: title + " (Display Not Recognized)", enabled: false)
    }
    let suffix = isPinned && saved?.isHomeConnected == false ? " (Disconnected)" : ""
    return .init(
        title: title + suffix,
        checked: isPinned,
        command: .send(.setSavedWorkspacePinned(workspace.name, !isPinned)),
    )
}

@MainActor
func workspaceSidebarWorkspaceMenu(
    _ workspace: WorkspaceSidebarWorkspaceViewModel,
    rename: @escaping () -> Void,
    send: @escaping @MainActor (WorkspaceSidebarAction) -> Void,
) -> [WorkspaceSidebarAppMenuEntry] {
    let context = workspaceSidebarWorkspaceMenuContext(workspaceName: workspace.name)
    return workspaceSidebarWorkspaceMenuEntries(workspace, context: context).map { entry in
        WorkspaceSidebarAppMenuEntry(
            title: entry.title,
            checked: entry.checked,
            enabled: entry.enabled,
            isDestructive: entry.isDestructive,
            perform: entry.command.map { command in
                {
                    switch command {
                        case .customizeDock: ShortcutSettingsModel.shared.requestDockSettings()
                        case .rename: rename()
                        case .send(let action): send(action)
                    }
                }
            },
        )
    }
}

/// Builds the menu when it opens, not on every section body evaluation.
struct WorkspaceSidebarWorkspaceMenuContent: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let rename: () -> Void
    let send: @MainActor (WorkspaceSidebarAction) -> Void

    var body: some View {
        WorkspaceSidebarAppContextMenu(entries: workspaceSidebarWorkspaceMenu(workspace, rename: rename, send: send))
    }
}

func workspaceSidebarSavedWorkspaceDescription(_ saved: WorkspaceSidebarSavedState) -> String {
    var parts = ["Saved workspace"]
    // Config force-assignment, not the saved home, decides where it goes.
    if let home = saved.homeDisplayName, !saved.isForceAssignedByConfig {
        parts.append(saved.isPinnedToDisplay ? "Kept on “\(home)”" : "Returns to “\(home)”")
    }
    if !saved.missingAppNames.isEmpty {
        parts.append("Missing: \(saved.missingAppNames.joined(separator: ", "))")
    }
    return parts.joined(separator: " · ")
}

func workspaceSidebarWorkspaceTooltip(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> String {
    guard let saved = workspace.savedState else { return workspace.displayName }
    return "\(workspace.displayName)\n\(workspaceSidebarSavedWorkspaceDescription(saved))"
}
