import AppKit
import SwiftUI

/// Tabs mode: tabs chosen with Shift or Command, for acting on several at once. A plain click
/// goes back to one tab, as in a browser's tab strip.
@MainActor
final class WorkspaceSidebarTabSelection: ObservableObject {
    static let shared = WorkspaceSidebarTabSelection()
    @Published private(set) var names: [String] = []
    private var anchor: String?

    var isMultiple: Bool { names.count > 1 }
    func contains(_ name: String) -> Bool { names.contains(name) }

    /// Whether the click chose tabs instead of opening one. Shift selects the range from the
    /// last chosen tab, or the one on screen, in `order`: the tabs of the page clicked, as
    /// shown. Command adds or removes one tab. Tabs outside `order` leave the selection.
    func handleClick(on name: String, modifiers: NSEvent.ModifierFlags, order: [String], active: String?) -> Bool {
        let shown = Set(order)
        if modifiers.contains(.shift) {
            let from = anchor.flatMap { shown.contains($0) ? $0 : nil } ?? active.flatMap { shown.contains($0) ? $0 : nil } ?? name
            guard let start = order.firstIndex(of: from), let end = order.firstIndex(of: name) else {
                select([name], anchor: name)
                return true
            }
            select(Array(order[min(start, end)...max(start, end)]), anchor: from)
            return true
        }
        if modifiers.contains(.command) {
            var next = names.filter(shown.contains)
            if next.isEmpty, let active, active != name, shown.contains(active) { next = [active] }
            if let index = next.firstIndex(of: name) { next.remove(at: index) } else { next.append(name) }
            select(order.filter(next.contains), anchor: name)
            return true
        }
        clear()
        return false
    }

    func clear() {
        if !names.isEmpty { names = [] }
        anchor = nil
    }

    private func select(_ next: [String], anchor: String) {
        if names != next { names = next }
        self.anchor = anchor
    }
}

/// Whether a drag that started in the Tabs sidebar is under way, so drop places that only
/// appear during one, such as pinning into an empty pinned area, can show.
@MainActor
final class WorkspaceSidebarTabDragState: ObservableObject {
    static let shared = WorkspaceSidebarTabDragState()
    @Published private(set) var isDragging = false
    /// The pinned tab being dragged, which stays dimmed until the drag ends.
    @Published private(set) var draggedPinnedTab: String?

    func set(_ dragging: Bool, pinnedTab: String? = nil) {
        if isDragging != dragging { isDragging = dragging }
        let pinnedTab = dragging ? pinnedTab : nil
        if draggedPinnedTab != pinnedTab { draggedPinnedTab = pinnedTab }
    }
}

/// The menu for several chosen tabs: group, pin, or close them together.
@MainActor
func workspaceSidebarTabSelectionMenuEntries(_ names: [String], workspaces: [WorkspaceSidebarWorkspaceViewModel],
                                             collections: [WorkspaceTabCollection],
                                             send: @escaping @MainActor (WorkspaceSidebarAction) -> Void,
                                             clear: @escaping @MainActor () -> Void) -> [WorkspaceSidebarAppMenuEntry] {
    let tabs = names.compactMap { name in workspaces.first { $0.name == name } }
    guard tabs.count > 1, let projectId = tabs.first?.projectId else { return [] }
    let names = tabs.map(\.name)
    let act = { (action: WorkspaceSidebarAction) in { clear(); send(action) } }
    let groups = collections.filter { $0.projectId == projectId }
    var destinations: [WorkspaceSidebarAppMenuEntry] = groups.map { group in
        .named((group.emoji.map { $0 + " " } ?? "") + group.name,
            checked: names.allSatisfy(group.workspaceNames.contains),
            perform: act(.assignTabsToCollection(names, group.id)))
    }
    if collections.contains(where: { group in names.contains(where: group.workspaceNames.contains) }) {
        destinations += [.separator, .init(title: "Remove from Group", perform: act(.assignTabsToCollection(names, nil)))]
    }
    let allPinned = tabs.allSatisfy(\.appearance.isFavorite)
    let windowCount = tabs.reduce(0) { $0 + workspaceSidebarPinnedTabWindows($1).count }
    var entries: [WorkspaceSidebarAppMenuEntry] = [
        .header("\(tabs.count) Tabs"),
        .init(title: allPinned ? "Unpin \(tabs.count) Tabs" : "Pin \(tabs.count) Tabs",
            perform: act(.setTabsFavorite(names, !allPinned))),
        .init(title: "New Group with \(tabs.count) Tabs", perform: act(.createTabCollectionFromTabs(names))),
    ]
    if !destinations.isEmpty { entries.append(.init(title: "Add to Group", children: destinations)) }
    return entries + [
        .separator,
        .init(title: "Deselect Tabs", perform: { clear() }),
        .separator,
        // Asks first when that closes more windows than tabs.
        .init(title: windowCount > tabs.count ? "Close \(tabs.count) Tabs…" : "Close \(tabs.count) Tabs",
            isDestructive: true, perform: act(.closeTabs(names))),
    ]
}

/// The menu for several chosen tabs, when `name` is one of them.
@MainActor
func workspaceSidebarTabSelectionMenu(containing name: String) -> NSMenu? {
    let selection = WorkspaceSidebarTabSelection.shared
    guard config.usesBrowserTabs, selection.isMultiple, selection.contains(name) else { return nil }
    let entries = workspaceSidebarTabSelectionMenuEntries(selection.names,
        workspaces: TrayMenuModel.shared.workspaceSidebarWorkspaces,
        collections: workspaceSidebarOrganizationStore.state.collections,
        send: { handleWorkspaceSidebarAction($0) }, clear: { selection.clear() })
    return entries.isEmpty ? nil : workspaceSidebarNativeAppMenu(entries)
}

/// Closes every window of several tabs, asking first when that's more than one per tab.
@MainActor
@discardableResult
func closeWorkspaceSidebarTabs(_ names: [String], requestClose: @escaping @MainActor (Window) async -> Bool = { window in
    if let macWindow = window as? MacWindow { return await macWindow.requestCloseForProjectDeletion() }
    window.closeAxWindow()
    return true
}) -> Task<Void, Never>? {
    guard config.usesBrowserTabs, !serverArgs.isReadOnly else { return nil }
    let tabs = names.compactMap { Workspace.existing(byName: $0) }
    let windowCount = tabs.reduce(0) { $0 + $1.allLeafWindowsRecursive.count }
    if windowCount > tabs.count {
        let alert = NSAlert()
        alert.messageText = "Close \(tabs.count) tabs and their \(windowCount) windows?"
        alert.informativeText = "This closes the application windows. Each app may ask you to save changes."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Windows")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .popUpMenu
        guard alert.runModal() == .alertSecondButtonReturn else { return nil }
    }
    return runWorkspaceSidebarSession {
        // In order: a save prompt or a refused close stops the rest, and its window comes forward.
        for tab in tabs where winMuxWorkspaceState.workspaceById[tab.id] === tab {
            if tab.allLeafWindowsRecursive.isEmpty {
                try closeWorkspaceSidebarEmptyTab(tab)
                continue
            }
            let closed = await closeWorkspaceSidebarSplitWindows(tab.allLeafWindowsRecursive, in: tab, requestClose: requestClose)
            if !closed { return }
        }
        await updateWorkspaceSidebarModel()
    }
}

/// Closes an empty tab from the sidebar: a saved one is deleted, as its Close Tab does.
@MainActor
func closeWorkspaceSidebarEmptyTab(_ workspace: Workspace) throws {
    if config.usesBrowserTabs, workspace.isSaved, !workspace.isConfiguredPersistent, !workspaceHasLifecycleWindows(workspace) {
        try deleteWorkspace(workspace)
    } else { closeEmptyTab(workspace) }
}

/// Pins or unpins a tab. A pinned tab leaves its group, as pinning always has.
@MainActor
func setWorkspaceSidebarTabFavorite(_ workspace: Workspace, _ favorite: Bool) throws {
    try setWorkspaceSidebarTabsFavorite([workspace], favorite)
}

/// Several tabs at once, saved in one write.
@MainActor
func setWorkspaceSidebarTabsFavorite(_ workspaces: [Workspace], _ favorite: Bool) throws {
    if favorite { try saveWorkspaceSidebarIdentities(workspaces) }
    let names = Set(workspaces.map(\.name))
    try workspaceSidebarOrganizationStore.update { state in
        for name in names { state.workspaces[name, default: .init()].setFavorite(favorite) }
        if favorite {
            for index in state.collections.indices { state.collections[index].workspaceNames.removeAll(where: names.contains) }
        }
    }
}

/// Pins a tab dropped on the pinned tiles, or moves a pinned one there. `gap` puts it beside
/// another pin. Pinning and placing are one write, so a failure leaves neither behind.
@MainActor
func pinWorkspaceSidebarTab(_ workspace: Workspace, beside gap: WorkspaceSidebarTabGap?) throws {
    let wasPinned = workspaceSidebarOrganizationStore.state.workspaces[workspace.name]?.isFavorite == true
    if !wasPinned { try saveWorkspaceSidebarIdentities([workspace]) }
    let order = gap.flatMap { workspacePinnedTabOrder(moving: workspace, beside: $0) } ?? []
    try workspaceSidebarOrganizationStore.update { state in
        if !wasPinned {
            state.workspaces[workspace.name, default: .init()].setFavorite(true)
            for index in state.collections.indices { state.collections[index].workspaceNames.removeAll { $0 == workspace.name } }
        }
        for (index, name) in order.enumerated() { state.workspaces[name, default: .init()].pinOrder = index }
    }
}
