import AppKit
import Common
import SwiftUI

/// One reversible sidebar edit. Closing windows is deliberately outside this history.
/// A later layout/organization edit invalidates the entry; focus and title updates do not.
@MainActor
final class WorkspaceSidebarTabUndo: ObservableObject {
    static let shared = WorkspaceSidebarTabUndo()
    @Published private(set) var title: String?
    private var entry: (before: WorkspaceSidebarTabUndoSnapshot, after: WorkspaceSidebarTabUndoSnapshot)?

    func record(_ title: String, before: WorkspaceSidebarTabUndoSnapshot) {
        let after = WorkspaceSidebarTabUndoSnapshot()
        guard before.canRestore(after) else { clear(); return }
        guard !before.matches(after) else { return }
        entry = (before, after)
        self.title = "Undo \(title)"
    }

    func clear() { entry = nil; title = nil }

    func invalidateIfChanged() {
        guard let entry else { return }
        if !config.usesBrowserTabs || !entry.after.matches(WorkspaceSidebarTabUndoSnapshot()) { clear() }
    }

    func undo() throws {
        guard !serverArgs.isReadOnly, config.usesBrowserTabs, let entry else { return }
        guard entry.after.matches(WorkspaceSidebarTabUndoSnapshot()),
              entry.before.canRestore(entry.after),
              entry.before.windows.allSatisfy({ Window.get(byId: $0.window.windowId) === $0.window }),
              !savedWorkspaceStore.isReadOnly else {
            clear()
            return
        }
        // Write the fallible organization store before making any live changes.
        try workspaceSidebarOrganizationStore.update { $0 = entry.before.organization }
        clear()
        entry.before.restore(replacing: entry.after)
        syncClosedWindowsCacheToCurrentWorld()
    }
}

@MainActor
struct WorkspaceSidebarTabUndoSnapshot {
    let organization = workspaceSidebarOrganizationStore.state
    private let items = Workspace.all.map { WorkspaceSidebarUndoWorkspace($0) }
    private let projects = winMuxWorkspaceState.projectsById
    private let viewports = winMuxWorkspaceState.monitorViewportsById
    private let monitorRects = monitors.map(\.rect)
    private let saved = savedWorkspaceStore.records
    private let recentWindows = Workspace.all.flatMap { workspaceSidebarUndoWindowRecency($0) }
    private let focusedWindow = focus.windowOrNil
    private let focusedWorkspace = focus.workspace

    var windows: [WorkspaceSidebarUndoWindow] { items.flatMap { $0.windows } }

    func canRestore(_ other: Self) -> Bool {
        Set(windows.map { ObjectIdentifier($0.window) }) == Set(other.windows.map { ObjectIdentifier($0.window) }) &&
            items.flatMap(\.unconventional) == other.items.flatMap(\.unconventional)
    }

    func matches(_ other: Self) -> Bool {
        organization == other.organization && projects == other.projects && monitorRects == other.monitorRects &&
            items == other.items && saved.map(undoIdentity) == other.saved.map(undoIdentity)
    }

    private func undoIdentity(_ record: SavedWorkspaceRecord) -> SavedWorkspaceRecord {
        var record = record
        record.layout = .init()
        record.lastVisibleSequence = nil
        return record
    }

    func restore(replacing after: Self) {
        let currentWindow = focus.windowOrNil
        let currentWorkspace = focus.workspace
        let currentViewports = winMuxWorkspaceState.monitorViewportsById
        let restoreOriginalFocus = (focusedWindow !== after.focusedWindow || focusedWorkspace !== after.focusedWorkspace) &&
            currentWindow === after.focusedWindow && currentWorkspace === after.focusedWorkspace
        // Keep the actual Workspace objects, including an empty source pruned after a split.
        for item in items { winMuxWorkspaceState.registerWorkspace(item.workspace) }
        let retainedIds = Set(items.map { $0.workspace.id })
        for item in items { item.restore() }
        for workspace in Workspace.all where !retainedIds.contains(workspace.id) {
            // Never unregister a workspace with a live window, even if an unexpected
            // native container transition escaped the snapshot checks.
            if workspace.allLeafWindowsRecursive.isEmpty { _ = winMuxWorkspaceState.removeWorkspace(workspace) }
        }
        winMuxWorkspaceState.projectsById = projects
        // Restore only a viewport selection made by this edit, and only if it has
        // not been superseded by navigation. An appearance Undo must never switch
        // an unrelated display back to an older tab.
        var restoredViewports = currentViewports
        for (id, viewport) in viewports where viewport.activeWorkspaceId != after.viewports[id]?.activeWorkspaceId {
            if currentViewports[id]?.activeWorkspaceId == after.viewports[id]?.activeWorkspaceId {
                restoredViewports[id] = viewport
            }
        }
        // A previously selected tab may now be in use on a display the edit did
        // not switch. Keep that later placement; simultaneous Undo swaps remain valid.
        var rejectedSelection: Bool
        repeat {
            rejectedSelection = false
            for (id, viewport) in restoredViewports {
                guard let active = viewport.activeWorkspaceId, active != currentViewports[id]?.activeWorkspaceId else { continue }
                if currentViewports.contains(where: { otherId, current in
                    otherId != id && current.activeWorkspaceId == active && restoredViewports[otherId]?.activeWorkspaceId == active
                }) {
                    restoredViewports[id] = currentViewports[id]
                    rejectedSelection = true
                }
            }
        } while rejectedSelection
        winMuxWorkspaceState.monitorViewportsById = restoredViewports
        winMuxWorkspaceState.pruneProjectWorkspaceIndexes()
        for (id, viewport) in winMuxWorkspaceState.monitorViewportsById {
            if let active = viewport.activeWorkspaceId.flatMap({ winMuxWorkspaceState.workspaceById[$0] }) {
                _ = winMuxWorkspaceState.setActiveWorkspace(active, on: id)
            }
        }
        // Rebuilding containers must not change which split member an inactive tab
        // will focus the next time it is selected.
        for window in recentWindows.reversed() { window.markAsMostRecentChild() }
        let beforeByName = Dictionary(uniqueKeysWithValues: saved.map { ($0.workspaceName, $0) })
        let afterByName = Dictionary(uniqueKeysWithValues: after.saved.map { ($0.workspaceName, $0) })
        for name in Set(beforeByName.keys).union(afterByName.keys) {
            guard beforeByName[name].map(undoIdentity) != afterByName[name].map(undoIdentity) else { continue }
            if var record = beforeByName[name] {
                if let current = savedWorkspaceStore.record(named: name) {
                    record.layout = current.layout
                    record.lastVisibleSequence = current.lastVisibleSequence
                    savedWorkspaceStore.update(named: name) { $0 = record }
                } else { savedWorkspaceStore.insert(record) }
            } else if let removed = savedWorkspaceStore.remove(named: name) {
                clearSavedWorkspaceRuntimeState(removed)
            }
        }
        savedWorkspaceStore.reorder(workspaceNamesInOrder: saved.map(\.workspaceName))
        savedWorkspaceStore.flushNow()
        let selectedWindow = restoreOriginalFocus ? focusedWindow : currentWindow
        let selectedWorkspace = restoreOriginalFocus ? focusedWorkspace : currentWorkspace
        if let selectedWindow { _ = selectedWindow.focusWindow() }
        else if Workspace.existing(byName: selectedWorkspace.name) === selectedWorkspace { _ = selectedWorkspace.focusWorkspace() }
        checkWorkspaceHierarchyInvariants()
    }
}

@MainActor
private func workspaceSidebarUndoWindowRecency(_ node: TreeNode) -> [Window] {
    if let window = node as? Window { return [window] }
    return node.childrenByMostRecentUse.flatMap { workspaceSidebarUndoWindowRecency($0) }
}

private struct WorkspaceSidebarUndoWorkspace: Equatable {
    let workspace: Workspace
    let projectId: WorkspaceProjectId
    let namingStyle: WorkspaceNamingStyle
    let lifecycle: WorkspaceLifecycle
    let preferredMonitorPoint: CGPoint?
    let retainsEmptyAfterProjectMove: Bool
    let tree: WorkspaceSidebarUndoTree
    let floating: [WorkspaceSidebarUndoWindow]
    let unconventional: [WorkspaceSidebarUndoWindow]

    @MainActor init(_ workspace: Workspace) {
        self.workspace = workspace
        projectId = workspace.projectId
        namingStyle = workspace.namingStyle
        lifecycle = workspace.lifecycle
        preferredMonitorPoint = workspace.preferredMonitorPoint
        retainsEmptyAfterProjectMove = workspace.retainsEmptyAfterProjectMove
        tree = .init(workspace.rootTilingContainer)
        floating = workspace.floatingWindows.map { WorkspaceSidebarUndoWindow($0) }
        unconventional = (workspaceOwnedMinimizedWindows(workspace) +
            (workspace.existingMacOsNativeHiddenAppsWindowsContainer?.allLeafWindowsRecursive ?? []) +
            (workspace.existingMacOsNativeFullscreenWindowsContainer?.allLeafWindowsRecursive ?? []))
            .map { WorkspaceSidebarUndoWindow($0) }
    }

    var windows: [WorkspaceSidebarUndoWindow] { tree.windows + floating + unconventional }

    @MainActor func restore() {
        workspace.projectId = projectId
        workspace.restoreNamingStyle(namingStyle)
        workspace.lifecycle = lifecycle
        workspace.preferredMonitorPoint = preferredMonitorPoint
        workspace.retainsEmptyAfterProjectMove = retainsEmptyAfterProjectMove
        let oldRoot = workspace.rootTilingContainer
        oldRoot.unbindFromParent()
        tree.restore(to: workspace)
        for window in floating { window.restore(to: workspace) }
        // Native minimized/fullscreen/hidden windows did not participate in the edit.
    }
}

private indirect enum WorkspaceSidebarUndoTree: Equatable {
    case window(WorkspaceSidebarUndoWindow)
    case container(Orientation, Layout, CGFloat, [WorkspaceSidebarUndoTree])

    @MainActor init(_ node: TreeNode) {
        if let window = node as? Window { self = .window(.init(window)) }
        else if let container = node as? TilingContainer {
            self = .container(container.orientation, container.layout,
                (container.parent as? TilingContainer).map { container.getWeight($0.orientation) } ?? 1,
                container.children.map { Self($0) })
        } else { preconditionFailure("A tab layout contains only windows and tiling containers") }
    }

    var windows: [WorkspaceSidebarUndoWindow] {
        switch self {
            case .window(let window): [window]
            case .container(_, _, _, let children): children.flatMap(\.windows)
        }
    }

    @MainActor func restore(to parent: NonLeafTreeNodeObject) {
        switch self {
            case .window(let window): window.restore(to: parent)
            case .container(let orientation, let layout, let weight, let children):
                let container = TilingContainer(parent: parent, adaptiveWeight: weight, orientation, layout, index: INDEX_BIND_LAST)
                for child in children { child.restore(to: container) }
        }
    }
}

struct WorkspaceSidebarUndoWindow: Equatable {
    let window: Window
    let originalParent: TreeNode?
    let weight: CGFloat
    let isFullscreen: Bool
    let noOuterGaps: Bool
    let layoutReason: LayoutReason
    let floatingSize: CGSize?

    @MainActor init(_ window: Window) {
        self.window = window
        originalParent = window.parent
        weight = (window.parent as? TilingContainer).map { window.getWeight($0.orientation) } ?? 1
        isFullscreen = window.isFullscreen
        noOuterGaps = window.noOuterGapsInFullscreen
        layoutReason = window.layoutReason
        floatingSize = window.lastFloatingSize
    }

    @MainActor func restore(to parent: NonLeafTreeNodeObject) {
        window.isFullscreen = isFullscreen
        window.noOuterGapsInFullscreen = noOuterGaps
        window.layoutReason = layoutReason
        window.lastFloatingSize = floatingSize
        window.bind(to: parent, adaptiveWeight: weight, index: INDEX_BIND_LAST)
    }
}

struct WorkspaceSidebarTabUndoButton: View {
    @ObservedObject var undo: WorkspaceSidebarTabUndo = .shared
    let actions: WorkspaceSidebarActions

    var body: some View {
        if let title = undo.title {
            Button { actions.send(.undoTabAction) } label: {
                Label(title, systemImage: "arrow.uturn.backward").font(.system(size: 12))
                    .lineLimit(1).padding(.horizontal, 10).padding(.vertical, 6)
            }
            .buttonStyle(.plain).help(title + " (⌘Z while Search Tabs has keyboard focus)")
            .background(.primary.opacity(0.07), in: Capsule()).padding(.horizontal, 12).padding(.vertical, 5)
        }
    }
}
