import AppKit
import Common
import SwiftUI

/// One reversible sidebar edit. Closing windows is deliberately outside this history.
/// A later layout/organization edit invalidates the entry; focus and title updates do not.
@MainActor
final class WorkspaceSidebarTabUndo: ObservableObject {
    static let shared = WorkspaceSidebarTabUndo()
    @Published private(set) var title: String?
    private var entry: (before: WorkspaceSidebarTabUndoSnapshot, after: WorkspaceSidebarTabUndoSnapshot,
                        organizationOnly: WorkspaceSidebarOrganizationIdentityDelta?)?

    func record(_ title: String, before: WorkspaceSidebarTabUndoSnapshot) {
        let after = WorkspaceSidebarTabUndoSnapshot()
        guard before.canRestore(after) else { clear(); return }
        guard !before.matches(after) else { return }
        entry = (before, after, nil)
        self.title = "Undo \(title)"
    }

    /// An edit that changed only the organization and saved tab identities, with `before` and
    /// `after` taken right around it. Its Undo writes those back and touches nothing else: no
    /// layout, display or focus. Anything else changed alongside it clears the history instead.
    func recordOrganizationEdit(_ title: String, before: WorkspaceSidebarTabUndoSnapshot, after: WorkspaceSidebarTabUndoSnapshot,
                                identities: WorkspaceSidebarOrganizationIdentityDelta) {
        guard before.canRestore(after), before.matchesStructure(after) else { clear(); return }
        guard !before.matches(after) else { return }
        entry = (before, after, identities)
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
        if let identities = entry.organizationOnly { return try undoOrganizationEdit(entry.before, identities) }
        // Write the fallible organization store before making any live changes.
        try workspaceSidebarOrganizationStore.update { $0 = entry.before.organization }
        clear()
        entry.before.restore(replacing: entry.after)
        syncClosedWindowsCacheToCurrentWorld()
    }

    /// Organization first: if it can't be written, nothing has changed and Undo stays available.
    /// Then exactly the identities the edit added. If saving those fails, the groups stay removed
    /// and the identities stay saved, in memory as on disk, and the error says so.
    private func undoOrganizationEdit(_ before: WorkspaceSidebarTabUndoSnapshot,
                                      _ identities: WorkspaceSidebarOrganizationIdentityDelta) throws {
        try workspaceSidebarOrganizationStore.update { $0 = before.organization }
        clear()
        guard !identities.isEmpty else { return }
        let savedBefore = savedWorkspaceStore.file
        let runtimeBefore = SavedWorkspaceRuntimeIdentityState()
        for created in identities.created {
            if let removed = savedWorkspaceStore.remove(named: created.name) { clearSavedWorkspaceRuntimeState(removed) }
        }
        for name in identities.promoted { savedWorkspaceStore.update(named: name) { $0.keepWhenEmpty = false } }
        do {
            try savedWorkspaceStore.flushNowReportingFailure()
        } catch {
            savedWorkspaceStore.restoreForRollback(savedBefore)
            runtimeBefore.restore()
            throw NSError(domain: "WinMux.SidebarOrganization", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The groups were removed, but WinMux couldn't update its saved tabs, so they stay saved: \(error.localizedDescription)"])
        }
        for created in identities.created where created.workspace?.lifecycle == .durable {
            created.workspace?.lifecycle = created.lifecycle
        }
    }
}

/// What an organization-only edit changed in saved tab identities, so its Undo puts back exactly
/// that, and nothing a later edit did.
@MainActor
struct WorkspaceSidebarOrganizationIdentityDelta {
    struct Created {
        let name: String
        weak var workspace: Workspace?
        let lifecycle: WorkspaceLifecycle
    }

    /// Records the edit created, with each tab's lifecycle before.
    var created: [Created] = []
    /// Records whose keep-when-empty the edit turned back on.
    var promoted: [String] = []

    var isEmpty: Bool { created.isEmpty && promoted.isEmpty }
}

/// The session state `clearSavedWorkspaceRuntimeState` drops, to put back when a write fails.
@MainActor
struct SavedWorkspaceRuntimeIdentityState {
    private let vanishedSlots = savedWorkspaceRuntime.vanishedSlots
    private let visibleOnHome = savedWorkspaceRuntime.visibleOnHomeAtLastCheckpoint
    private let awaitingProject = savedWorkspaceRuntime.workspacesAwaitingProject
    private let pruneRetryAfter = savedWorkspaceRuntime.organizationPruneRetryAfter

    func restore() {
        savedWorkspaceRuntime.vanishedSlots = vanishedSlots
        savedWorkspaceRuntime.visibleOnHomeAtLastCheckpoint = visibleOnHome
        savedWorkspaceRuntime.workspacesAwaitingProject = awaitingProject
        savedWorkspaceRuntime.organizationPruneRetryAfter = pruneRetryAfter
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

    /// The same tabs, layouts, projects and displays, with the same tab on each: only the
    /// organization, saved identities and tab lifecycles may differ.
    func matchesStructure(_ other: Self) -> Bool {
        projects == other.projects && monitorRects == other.monitorRects &&
            viewports.mapValues(\.activeWorkspaceId) == other.viewports.mapValues(\.activeWorkspaceId) &&
            items.count == other.items.count && zip(items, other.items).allSatisfy { $0.matchesStructure($1) } &&
            focusedWindow === other.focusedWindow && focusedWorkspace === other.focusedWorkspace
    }

    private func undoIdentity(_ record: SavedWorkspaceRecord) -> SavedWorkspaceRecord {
        var record = record
        // Like the layout, the tab's apps are captured in the background after an edit.
        record.launchApps = nil
        record.layout = .init()
        record.lastVisibleSequence = nil
        return record
    }

    func restore(replacing after: Self) {
        let currentWindow = focus.windowOrNil
        let currentWorkspace = focus.workspace
        let currentViewports = winMuxWorkspaceState.monitorViewportsById
        // Switching project with a pin in All Projects kept on screen moves on too, though focus stays.
        let focusedViewport = MonitorViewportId(currentWorkspace.workspaceMonitor)
        let restoreOriginalFocus = (focusedWindow !== after.focusedWindow || focusedWorkspace !== after.focusedWorkspace) &&
            currentWindow === after.focusedWindow && currentWorkspace === after.focusedWorkspace &&
            currentViewports[focusedViewport]?.contextProjectId == after.viewports[focusedViewport]?.contextProjectId
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
        // Switching project with a pin in All Projects kept on screen is navigation too.
        for (id, viewport) in viewports where viewport.activeWorkspaceId != after.viewports[id]?.activeWorkspaceId {
            if currentViewports[id]?.activeWorkspaceId == after.viewports[id]?.activeWorkspaceId,
               currentViewports[id]?.contextProjectId == after.viewports[id]?.contextProjectId {
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
        func windowsByName(_ snapshot: Self) -> [String: Set<ObjectIdentifier>] {
            Dictionary(snapshot.items.map { ($0.workspace.name, Set($0.windows.map { ObjectIdentifier($0.window) })) },
                uniquingKeysWith: { first, _ in first })
        }
        let windowsBefore = windowsByName(self)
        let windowsAfter = windowsByName(after)
        for name in Set(beforeByName.keys).union(afterByName.keys) {
            guard beforeByName[name].map(undoIdentity) != afterByName[name].map(undoIdentity) else {
                // A tab whose windows the edit changed shows its apps as they were; captures since
                // recorded the edit's result. Other tabs keep what captures learned meanwhile.
                if windowsBefore[name] != windowsAfter[name], let before = beforeByName[name],
                   savedWorkspaceStore.record(named: name).map({ $0.launchApps != before.launchApps }) == true {
                    savedWorkspaceStore.update(named: name) { $0.launchApps = before.launchApps }
                }
                continue
            }
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
    let hasHadWindows: Bool
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
        hasHadWindows = workspace.hasHadWindows
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

    func matchesStructure(_ other: Self) -> Bool {
        workspace === other.workspace && projectId == other.projectId && namingStyle == other.namingStyle &&
            hasHadWindows == other.hasHadWindows && preferredMonitorPoint == other.preferredMonitorPoint &&
            retainsEmptyAfterProjectMove == other.retainsEmptyAfterProjectMove && tree == other.tree &&
            floating == other.floating && unconventional == other.unconventional
    }

    @MainActor func restore() {
        workspace.projectId = projectId
        workspace.restoreNamingStyle(namingStyle)
        workspace.lifecycle = lifecycle
        workspace.hasHadWindows = hasHadWindows
        workspace.preferredMonitorPoint = preferredMonitorPoint
        workspace.retainsEmptyAfterProjectMove = retainsEmptyAfterProjectMove
        let oldRoot = workspace.rootTilingContainer
        oldRoot.unbindFromParent()
        tree.restore(to: workspace)
        for window in floating { window.restore(to: workspace) }
        // Native minimized/fullscreen/hidden windows did not participate in the edit.
    }
}

/// Whether two weights are the same as far as a user can tell. Layout spreads its rounding over a
/// split, so a pass after a drop can move a weight by a few ulps: three thirds of 784 sum to
/// 784.0000000000001, and the next pass takes that back. That's no change, and mustn't make a
/// drop's Undo go away; a resize, of a point or more, is one.
private func workspaceSidebarUndoWeightsMatch(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1e-6 }

private indirect enum WorkspaceSidebarUndoTree: Equatable {
    case window(WorkspaceSidebarUndoWindow)
    case container(Orientation, Layout, CGFloat, [WorkspaceSidebarUndoTree])

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
            case (.window(let a), .window(let b)): a == b
            case (.container(let orientation, let layout, let weight, let children),
                  .container(let otherOrientation, let otherLayout, let otherWeight, let otherChildren)):
                orientation == otherOrientation && layout == otherLayout &&
                    workspaceSidebarUndoWeightsMatch(weight, otherWeight) && children == otherChildren
            default: false
        }
    }

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

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.window == rhs.window && lhs.originalParent == rhs.originalParent &&
            workspaceSidebarUndoWeightsMatch(lhs.weight, rhs.weight) && lhs.isFullscreen == rhs.isFullscreen &&
            lhs.noOuterGaps == rhs.noOuterGaps && lhs.layoutReason == rhs.layoutReason && lhs.floatingSize == rhs.floatingSize
    }

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
    var reducesMotion = false

    var body: some View {
        ZStack(alignment: .leading) {
            if let title = undo.title {
                Button { actions.send(.undoTabAction) } label: {
                    // The arrow sits on the tabs' icon column, the title on theirs.
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.uturn.backward").frame(width: workspaceSidebarTabIconSize)
                        Text(title).lineLimit(1).contentTransition(.opacity)
                    }
                    .font(.system(size: 12))
                    .padding(.leading, workspaceSidebarTabLeadingPadding).padding(.trailing, 12).padding(.vertical, 6)
                }
                .buttonStyle(.plain).help(title + " (⌘Z while Search Tabs has keyboard focus)")
                .background(.primary.opacity(0.07), in: Capsule())
                .padding(.horizontal, workspaceSidebarTabsListInset).padding(.vertical, 5)
                .transition(reducesMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reducesMotion ? WorkspaceSidebarTabMotion.feedback : WorkspaceSidebarTabMotion.disclosure, value: undo.title)
    }
}
