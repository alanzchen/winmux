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
    /// The title with its display name in full, when `title` shortens it.
    var fullTitle: String? = nil

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
    /// WinMux doesn't open apps with --read-only.
    var canOpenApps = true
    /// Tabs mode, where a workspace with several windows can be split back into tabs.
    var separatesIntoTabs = false
    /// Names the Customize item after the panel it opens settings for.
    var panelMode: WorkspaceSidebarMode = .dock
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
        canOpenApps: !serverArgs.isReadOnly,
        separatesIntoTabs: config.usesBrowserTabs,
        panelMode: config.workspaceSidebar.mode,
    )
}

/// A workspace's own menu items by group. The identity menu puts the appearance items between
/// `keep` and `panel`; the plain menu puts Rename there.
struct WorkspaceSidebarWorkspaceMenuSections: Equatable {
    /// Tabs mode: splitting a multi-window tab back into tabs.
    var layout: [WorkspaceSidebarWorkspaceMenuEntry] = []
    var keep: [WorkspaceSidebarWorkspaceMenuEntry] = []
    var panel: [WorkspaceSidebarWorkspaceMenuEntry] = []
    /// Last: forgetting what's saved and deleting.
    var remove: [WorkspaceSidebarWorkspaceMenuEntry] = []
}

func workspaceSidebarWorkspaceMenuSections(
    _ workspace: WorkspaceSidebarWorkspaceViewModel,
    context: WorkspaceSidebarWorkspaceMenuContext,
) -> WorkspaceSidebarWorkspaceMenuSections {
    let saved = workspace.savedState
    let tabs = context.separatesIntoTabs
    var sections = WorkspaceSidebarWorkspaceMenuSections()
    if tabs, workspaceSidebarTabWindowCount(workspace) > 1 {
        sections.layout.append(.init(title: "Separate into Tabs", command: .send(.separateWorkspaceIntoTabs(workspace.name))))
    }
    if saved == nil || saved?.keepWhenEmpty == false {
        let title = tabs ? "Keep Tab When Empty" : saved == nil ? "Save Workspace" : "Keep Workspace When Empty"
        sections.keep.append(.init(title: title, command: .send(.saveWorkspace(workspace.name))))
    }
    if let keepOn = workspaceSidebarKeepOnDisplayEntry(workspace, context: context) {
        sections.keep.append(keepOn)
    }
    if let saved, !saved.missingAppNames.isEmpty, context.canOpenApps {
        sections.keep.append(.init(
            title: "Open Missing Apps (\(saved.missingAppNames.count))",
            command: .send(.openSavedWorkspaceApps(workspace.name)),
        ))
    }
    if !tabs {
        sections.panel.append(.init(title: "Customize \(context.panelMode.settingsTitle)…", command: .customizeDock))
    }
    // Forgetting drops the saved name, layout, pin and group, so it isn't a checkbox beside Keep.
    if saved != nil && (!tabs || saved?.keepWhenEmpty == true) {
        sections.remove.append(.init(title: tabs ? "Stop Keeping Empty Tab" : "Forget Saved Workspace",
            command: .send(.forgetSavedWorkspace(workspace.name))))
    }
    if !tabs {
        sections.remove.append(.init(title: "Delete Workspace", isDestructive: true, command: .send(.deleteWorkspace(workspace.name))))
    }
    return sections
}

/// The plain menu, with Rename editing the name in place.
func workspaceSidebarWorkspaceMenuEntries(
    _ workspace: WorkspaceSidebarWorkspaceViewModel,
    context: WorkspaceSidebarWorkspaceMenuContext,
) -> [WorkspaceSidebarWorkspaceMenuEntry] {
    let sections = workspaceSidebarWorkspaceMenuSections(workspace, context: context)
    let rename = WorkspaceSidebarWorkspaceMenuEntry(title: context.separatesIntoTabs ? "Rename Tab" : "Rename Workspace",
        command: .rename)
    let groups = [sections.layout, sections.keep, [rename], sections.panel, sections.remove]
    return workspaceSidebarMenuWithoutStraySeparators(Array(groups.joined(separator: [.separator])))
}

/// Optional entries can leave separators next to each other or at an end; keep single ones.
func workspaceSidebarMenuWithoutStraySeparators(_ entries: [WorkspaceSidebarWorkspaceMenuEntry]) -> [WorkspaceSidebarWorkspaceMenuEntry] {
    var result: [WorkspaceSidebarWorkspaceMenuEntry] = []
    for entry in entries where !(entry.isSeparator && (result.last?.isSeparator ?? true)) {
        result.append(entry)
    }
    if result.last?.isSeparator == true { result.removeLast() }
    return result
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
    // Only the display's name is shortened; what's said about it stays whole.
    func keepOn(_ name: String?, fallback: String = "This Display", _ suffix: String = "", checked: Bool,
                enabled: Bool = true, command: WorkspaceSidebarWorkspaceMenuCommand? = nil) -> WorkspaceSidebarWorkspaceMenuEntry {
        let full = "Keep on " + (name.map { "“\($0)”" } ?? fallback) + suffix
        let title = "Keep on " + (name.map { "“\(workspaceSidebarMenuName($0))”" } ?? fallback) + suffix
        return .init(title: title, checked: checked, enabled: enabled, command: command, fullTitle: title == full ? nil : full)
    }
    if isForceAssigned {
        // workspace-to-monitor-force-assignment wins over the saved home. An older pin can
        // still be removed, so it doesn't come back when the config entry goes away.
        if isPinned {
            return keepOn(saved?.homeDisplayName, fallback: "Its Display", " (Overridden by Config)", checked: true,
                command: .send(.setSavedWorkspacePinned(workspace.name, false)))
        }
        return keepOn(displayName, " (Set in Config)", checked: true, enabled: false)
    }
    if !isPinned, !context.currentDisplayHasIdentity {
        return keepOn(displayName, " (Display Not Recognized)", checked: false, enabled: false)
    }
    let suffix = isPinned && saved?.isHomeConnected == false ? " (Disconnected)" : ""
    return keepOn(displayName, suffix, checked: isPinned, command: .send(.setSavedWorkspacePinned(workspace.name, !isPinned)))
}

@MainActor
func workspaceSidebarWorkspaceMenu(
    _ workspace: WorkspaceSidebarWorkspaceViewModel,
    rename: @escaping () -> Void,
    send: @escaping @MainActor (WorkspaceSidebarAction) -> Void,
) -> [WorkspaceSidebarAppMenuEntry] {
    let context = workspaceSidebarWorkspaceMenuContext(workspaceName: workspace.name)
    return workspaceSidebarWorkspaceMenuEntries(workspace, context: context).map {
        workspaceSidebarAppMenuEntry($0, rename: rename, send: send)
    }
}

@MainActor
func workspaceSidebarAppMenuEntry(
    _ entry: WorkspaceSidebarWorkspaceMenuEntry,
    rename: @escaping () -> Void = {},
    send: @escaping @MainActor (WorkspaceSidebarAction) -> Void,
) -> WorkspaceSidebarAppMenuEntry {
    WorkspaceSidebarAppMenuEntry(
        title: entry.title,
        checked: entry.checked,
        enabled: entry.enabled,
        isDestructive: entry.isDestructive,
        perform: entry.command.map { command in
            {
                switch command {
                    case .customizeDock: ShortcutSettingsModel.shared.requestPanelSettings()
                    case .rename: rename()
                    case .send(let action): send(action)
                }
            }
        },
        fullTitle: entry.fullTitle,
    )
}

func workspaceSidebarSavedWorkspaceDescription(_ saved: WorkspaceSidebarSavedState) -> String {
    var parts = [saved.keepWhenEmpty ? "Saved workspace" : "Closes when empty"]
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
