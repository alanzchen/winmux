import AppKit

/// First line of defence against lock screen
///
/// When you lock the screen, all accessibility API becomes unobservable (all attributes become empty, window id
/// becomes nil, etc.) which tricks WinMux into thinking that all windows were closed.
/// That's why every time a window dies WinMux caches the "entire world" (unless window is already presented in the cache)
/// so that once the screen is unlocked, WinMux could restore windows to where they were
@MainActor private var closedWindowsCache = FrozenWorld(workspaces: [], monitors: [], windowIds: [])

struct FrozenMonitor: Codable, Sendable {
    let topLeftCorner: CGPoint
    let visibleWorkspace: String
    /// The project the display was in, which a pin in All Projects shown there isn't from. Older
    /// snapshots have none.
    var contextProjectId: WorkspaceProjectId? = nil

    @MainActor init(_ monitor: Monitor) {
        topLeftCorner = monitor.rect.topLeftCorner
        visibleWorkspace = monitor.activeWorkspace.name
        contextProjectId = winMuxWorkspaceState.activeProjectId(for: monitor)
    }
}

struct FrozenWorkspace: Codable, Sendable {
    let name: String
    let projectId: WorkspaceProjectId
    let namingStyle: WorkspaceNamingStyle
    let monitor: FrozenMonitor // todo drop this property, once monitor to workspace assignment migrates to TreeNode
    let rootTilingNode: FrozenContainer
    let floatingWindows: [FrozenWindow]
    let macosUnconventionalWindows: [FrozenWindow]

    private enum CodingKeys: String, CodingKey {
        case name
        case projectId
        case namingStyle
        case monitor
        case rootTilingNode
        case floatingWindows
        case macosUnconventionalWindows
    }

    @MainActor init(_ workspace: Workspace) {
        name = workspace.name
        projectId = workspace.projectId
        namingStyle = workspace.namingStyle
        monitor = FrozenMonitor(workspace.workspaceMonitor)
        rootTilingNode = FrozenContainer(workspace.rootTilingContainer)
        floatingWindows = workspace.floatingWindows.map(FrozenWindow.init)
        macosUnconventionalWindows =
            workspaceOwnedMinimizedWindows(workspace).map(FrozenWindow.init) +
            (workspace.existingMacOsNativeHiddenAppsWindowsContainer?.children.filterIsInstance(of: Window.self).map(FrozenWindow.init) ?? []) +
            (workspace.existingMacOsNativeFullscreenWindowsContainer?.children.filterIsInstance(of: Window.self).map(FrozenWindow.init) ?? [])
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        projectId = try container.decodeIfPresent(WorkspaceProjectId.self, forKey: .projectId) ?? workspaceProjectDefaultId
        namingStyle = try container.decodeIfPresent(WorkspaceNamingStyle.self, forKey: .namingStyle) ?? .explicit
        monitor = try container.decode(FrozenMonitor.self, forKey: .monitor)
        rootTilingNode = try container.decode(FrozenContainer.self, forKey: .rootTilingNode)
        floatingWindows = try container.decode([FrozenWindow].self, forKey: .floatingWindows)
        macosUnconventionalWindows = try container.decode([FrozenWindow].self, forKey: .macosUnconventionalWindows)
    }
}

@MainActor func cacheClosedWindowIfNeeded() {
    let frozenWorld = snapshotCurrentFrozenWorld()
    if frozenWorld.windowIds.isSubset(of: closedWindowsCache.windowIds) {
        return // already cached
    }
    closedWindowsCache = frozenWorld
}

@MainActor
func replaceClosedWindowsCache(_ frozenWorld: FrozenWorld) {
    closedWindowsCache = frozenWorld
}

@MainActor
func syncClosedWindowsCacheToCurrentWorld() {
    closedWindowsCache = snapshotCurrentFrozenWorld()
    scheduleSavedWorkspaceCheckpoint()
}

@MainActor func restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: Window) async throws -> Bool {
    try await restoreFrozenWorldIfNeeded(closedWindowsCache, newlyDetectedWindow: newlyDetectedWindow)
}

/// The cache once the user put `window` in `workspace` on purpose. See `FrozenWorld.superseding`.
@MainActor
func supersedeClosedWindowsCache(placementOf window: Window, in workspace: Workspace) {
    closedWindowsCache = closedWindowsCache.superseding(placementOf: window, in: workspace)
}

/// Frozen-world restores under way. Each works from its own snapshot across its AX waits, so it
/// leaves a reopened window that's claimed for a tab alone, and the reopen is finished only once
/// none is left. See `finishNewWindowIntentPlacement`.
@MainActor private(set) var activeFrozenRestoreCount = 0

@MainActor
func beginFrozenRestore() {
    activeFrozenRestoreCount += 1
}

/// On every way out of a restore: returning, throwing, or cancelled.
@MainActor
func endFrozenRestore() {
    activeFrozenRestoreCount -= 1
    if activeFrozenRestoreCount == 0 { finishDeferredReopenPlacements() }
}

@MainActor
func resetFrozenRestoresForTests() {
    activeFrozenRestoreCount = 0
}

/// A reopened window claimed for a tab and not finished yet: whatever an older snapshot remembers,
/// a restore neither moves it nor changes its state. Checked at each step, after every wait.
@MainActor
private func restoreLeavesAlone(_ window: Window) -> Bool {
    NewWindowIntentRegistry.shared.holdsReopenClaim(on: window)
}

@MainActor
func restoreFrozenWorldIfNeeded(_ frozenWorld: FrozenWorld, newlyDetectedWindow: Window) async throws -> Bool {
    if !frozenWorld.windowIds.contains(newlyDetectedWindow.windowId) {
        return false
    }
    guard frozenWorld.workspaces.contains(where: { collectFrozenWindows($0)[newlyDetectedWindow.windowId] != nil }) else {
        return false
    }
    beginFrozenRestore()
    defer { endFrozenRestore() }
    let monitors = monitors
    let topLeftCornerToMonitor = monitors.grouped { $0.rect.topLeftCorner }
    let restoredWorkspaceNames = Set(frozenWorld.workspaces.map(\.name))

    for frozenWorkspace in frozenWorld.workspaces {
        let workspace = Workspace.get(byName: frozenWorkspace.name)
        workspace.assignProject(frozenWorkspace.projectId)
        workspace.restoreNamingStyle(frozenWorkspace.namingStyle)
        let frozenWindowById = collectFrozenWindows(frozenWorkspace)
        _ = topLeftCornerToMonitor[frozenWorkspace.monitor.topLeftCorner]?
            .singleOrNil()?
            .setActiveWorkspace(workspace)
        for frozenWindow in frozenWorkspace.floatingWindows {
            if let window = Window.get(byId: frozenWindow.id), !restoreLeavesAlone(window) {
                applyFrozenWindowState(window, frozenWindow)
                window.bindAsFloatingWindow(to: workspace)
            }
        }
        for frozenWindow in frozenWorkspace.macosUnconventionalWindows {
            if let window = Window.get(byId: frozenWindow.id), !restoreLeavesAlone(window) {
                try await restoreFrozenUnconventionalWindow(window, frozenWindow, on: workspace)
            }
        }
        let prevRoot = workspace.rootTilingContainer // Save prevRoot into a variable to avoid it being garbage collected earlier than needed
        let potentialOrphans = prevRoot.allLeafWindowsRecursive
        prevRoot.unbindFromParent()
        restoreTreeRecursive(frozenContainer: frozenWorkspace.rootTilingNode, parent: workspace, index: INDEX_BIND_LAST)
        // A reopened window claimed for this tab stays in it, before any wait below could let the
        // user move it, or a failure strand it in the replaced root.
        for window in potentialOrphans where restoreLeavesAlone(window) && window.isBound && window.nodeWorkspace == nil {
            // Beside a restored stack, never in it.
            let binding = workspaceAppendBindingData(targetWorkspace: workspace, index: INDEX_BIND_LAST)
            window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        }
        for window in (potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive) {
            if restoreLeavesAlone(window) { continue }
            if let frozenWindow = frozenWindowById[window.windowId] {
                if case .macos = frozenWindow.layoutReason {
                    try await restoreFrozenUnconventionalWindow(window, frozenWindow, on: workspace)
                    continue
                }
                applyFrozenWindowState(window, frozenWindow)
            }
            try await window.relayoutWindow(on: workspace, forceTile: true)
        }
    }

    for monitor in frozenWorld.monitors {
        guard let targetMonitor = topLeftCornerToMonitor[monitor.topLeftCorner]?.singleOrNil() else { continue }
        let targetWorkspace: Workspace
        if let existingVisibleWorkspace = Workspace.existing(byName: monitor.visibleWorkspace),
           restoredWorkspaceNames.contains(existingVisibleWorkspace.name)
        {
            targetWorkspace = existingVisibleWorkspace
        } else {
            targetWorkspace = getOrCreateMonitorViewportFallbackWorkspace(for: targetMonitor)
        }
        // A pin in All Projects shows again in the project the display was in.
        _ = targetMonitor.setActiveWorkspace(targetWorkspace,
            contextProjectId: monitor.contextProjectId.flatMap { winMuxWorkspaceState.projectsById[$0] != nil ? $0 : nil })
    }
    return true
}

@discardableResult
@MainActor
private func restoreTreeRecursive(frozenContainer: FrozenContainer, parent: NonLeafTreeNodeObject, index: Int) -> Bool {
    let container = TilingContainer(
        parent: parent,
        adaptiveWeight: frozenContainer.weight,
        frozenContainer.orientation,
        frozenContainer.layout,
        index: index,
    )

    var index = 0
    for child in frozenContainer.children {
        switch child {
            case .window(let w):
                // Stop the loop if can't find the window, because otherwise all the subsequent windows will have incorrect index
                guard let window = Window.get(byId: w.id) else { return false }
                // A reopened window claimed for a tab stays there; the rest of its old stack doesn't wait for it.
                if restoreLeavesAlone(window) { continue }
                applyFrozenWindowState(window, w)
                window.bind(to: container, adaptiveWeight: w.weight, index: index)
            case .container(let c):
                // There is no reason to continue
                if !restoreTreeRecursive(frozenContainer: c, parent: container, index: index) { return false }
        }
        index += 1
    }
    return true
}

@MainActor
private func applyFrozenWindowState(_ window: Window, _ frozenWindow: FrozenWindow) {
    window.isFullscreen = frozenWindow.isFullscreen
    window.noOuterGapsInFullscreen = frozenWindow.noOuterGapsInFullscreen
    window.layoutReason = frozenWindow.layoutReason
}

@MainActor
private func restoreFrozenUnconventionalWindow(
    _ window: Window,
    _ frozenWindow: FrozenWindow,
    on workspace: Workspace,
) async throws {
    let isMacosFullscreen = try await window.isMacosFullscreen
    let isMacosMinimized = try await (!isMacosFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized }
    let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
        !config.automaticallyUnhideMacosHiddenApps && (window.app as? MacApp)?.nsApp.isHidden == true
    // A popup promoted and claimed for a tab while the AX reads waited.
    if restoreLeavesAlone(window) { return }
    applyFrozenWindowState(window, frozenWindow)

    switch true {
        case isMacosFullscreen:
            window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        case isMacosMinimized:
            window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        case isMacosWindowOfHiddenApp:
            window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        default:
            switch frozenWindow.layoutReason {
                case .macos(let prevParentKind, let prevWorkspaceName):
                    do {
                        // A popup promoted and claimed for a tab while the relayout classified it.
                        try await exitMacOsNativeUnconventionalState(
                            window: window,
                            prevParentKind: prevParentKind,
                            prevWorkspaceName: prevWorkspaceName,
                            workspace: workspace,
                            abandonIf: { restoreLeavesAlone($0) },
                        )
                    } catch is WindowRelayoutAbandoned {}
                case .standard:
                    window.bindAsFloatingWindow(to: workspace)
            }
    }
}

private func collectFrozenWindows(_ frozenWorkspace: FrozenWorkspace) -> [UInt32: FrozenWindow] {
    var result = [UInt32: FrozenWindow]()
    for frozenWindow in frozenWorkspace.floatingWindows {
        result[frozenWindow.id] = frozenWindow
    }
    for frozenWindow in frozenWorkspace.macosUnconventionalWindows {
        result[frozenWindow.id] = frozenWindow
    }
    collectFrozenWindowsRecursive(frozenWorkspace.rootTilingNode, result: &result)
    return result
}

private func collectFrozenWindowsRecursive(_ frozenContainer: FrozenContainer, result: inout [UInt32: FrozenWindow]) {
    for child in frozenContainer.children {
        switch child {
            case .window(let frozenWindow):
                result[frozenWindow.id] = frozenWindow
            case .container(let container):
                collectFrozenWindowsRecursive(container, result: &result)
        }
    }
}

// Consider the following case:
// 1. Close window
// 2. The previous step lead to caching the whole world
// 3. Change something in the layout
// 4. Lock the screen
// 5. The cache won't be updated because all alive windows are already cached
// 6. Unlock the screen
// 7. The wrong cache is used
//
// That's why we have to refresh the cache every time layout or visible workspace assignment changes. Those changes can
// be caused by running commands and with mouse manipulations.
@MainActor func resetClosedWindowsCache() {
    closedWindowsCache = FrozenWorld(workspaces: [], monitors: [], windowIds: [])
}

/// Whether a detected window will be put back from the closed-windows cache.
@MainActor
func closedWindowsCacheContains(windowId: UInt32) -> Bool {
    closedWindowsCache.windowIds.contains(windowId)
}
