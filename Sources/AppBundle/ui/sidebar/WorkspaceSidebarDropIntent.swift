import AppKit
import Common

/// The display temporary drop UI lists, as it was when the list opened. The list is a picture of
/// that display, so a drop on it goes there only if the same display is still where it was, with
/// no display change since. Another display now at the same place takes nothing.
struct WorkspaceSidebarDropDestinationIdentity: Equatable {
    let monitorScopeId: String
    let displayIdentity: MonitorDisplayIdentity?
    let topologyGeneration: UInt64

    @MainActor
    init?(monitorScopeId: String) {
        guard let monitor = workspaceSidebarMonitor(forScopeId: monitorScopeId),
              workspaceSidebarMonitorScopePoint(monitorScopeId) != nil else { return nil }
        self.monitorScopeId = monitorScopeId
        displayIdentity = monitor.displayIdentity
        topologyGeneration = MonitorConfigurationObserver.shared.topologyGeneration
    }

    init(monitorScopeId: String, displayIdentity: MonitorDisplayIdentity?, topologyGeneration: UInt64) {
        self.monitorScopeId = monitorScopeId
        self.displayIdentity = displayIdentity
        self.topologyGeneration = topologyGeneration
    }

    /// The display, if it's still the one the list showed.
    @MainActor
    func resolve() -> Monitor? {
        guard topologyGeneration == MonitorConfigurationObserver.shared.topologyGeneration,
              let monitor = workspaceSidebarMonitor(forScopeId: monitorScopeId),
              monitor.displayIdentity == displayIdentity else { return nil }
        return monitor
    }
}

/// What a release chose, captured then: the drop's session runs later, after other events, and
/// checks it again against the live state. Nothing in it depends on the drop UI still being open.
struct WorkspaceSidebarDropIntent {
    let surface: WorkspaceSidebarSurfaceRef?
    /// For a drop on temporary drop UI, the display it listed.
    let destination: WorkspaceSidebarDropDestinationIdentity?
    /// The list showed its project's pins from every display, as it did at the release.
    var listsSharedPins = false

    static let physical = WorkspaceSidebarDropIntent(surface: nil, destination: nil)

    /// The intent for a target found at release. A target on temporary drop UI whose list is gone
    /// has no intent: nothing may be dropped there.
    @MainActor
    static func captured(for target: WorkspaceSidebarDropTarget) -> WorkspaceSidebarDropIntent? {
        guard let surface = target.surface, surface.isTemporary else {
            return WorkspaceSidebarDropIntent(surface: target.surface, destination: nil)
        }
        guard let destination = WorkspaceSidebarTemporaryDropSurfaces.shared.destination(for: surface) else { return nil }
        return WorkspaceSidebarDropIntent(surface: surface, destination: destination,
            listsSharedPins: config.workspaceSidebar.sharesPinnedTabs)
    }

    /// Whether the drop may still go where it was aimed. Throws, before anything changes, when a
    /// listed display has gone or been replaced.
    @MainActor
    func checkDestination() throws {
        if let destination, destination.resolve() == nil { throw WorkspaceMutationError.displayUnavailable }
    }

    /// Whether `workspace` may still take a drop aimed at it. On temporary drop UI, the list must
    /// still be of the same display, and the tab still one it lists: that display's, or, with
    /// shared pins, one of its project's pins, which a window joins wherever that pin's tab is.
    @MainActor
    func accepts(_ workspace: Workspace) -> Bool {
        guard let destination else { return true }
        guard let monitor = destination.resolve() else { return false }
        if workspace.workspaceMonitor.rect == monitor.rect { return true }
        return listsSharedPins && workspace.projectId == activeWorkspaceProjectId(for: monitor)
            && workspaceSidebarOrganizationStore.state.workspaces[workspace.name]?.isFavorite == true
    }
}

extension WorkspaceSidebarTemporaryDropSurfaces {
    func destination(for surface: WorkspaceSidebarSurfaceRef) -> WorkspaceSidebarDropDestinationIdentity? {
        surfaces.first { $0.surfaceRef == surface && $0.dropDestination != nil }?.dropDestination
    }
}

/// The display a drop names, strictly: a display's scope that no longer resolves refuses the drop
/// rather than falling back to the window's or the pointer's display. Scopes that name no single
/// display keep their meaning, as `workspaceSidebarTargetMonitor` resolves them.
@MainActor
func workspaceSidebarDropTargetMonitor(scopeId: String, fallbackWindow: Window? = nil,
                                       fallbackPoint: CGPoint? = nil) -> Monitor? {
    guard workspaceSidebarMonitorScopePoint(scopeId) != nil else {
        return workspaceSidebarTargetMonitor(scopeId: scopeId, fallbackWindow: fallbackWindow, fallbackPoint: fallbackPoint)
    }
    return workspaceSidebarMonitor(forScopeId: scopeId)
}

/// Runs a drop's changes as one: if they throw or report failure, the tabs go back as they were.
/// The live state goes back first, which can't fail; then the pins and groups, only if they
/// changed. `body` must not suspend.
@MainActor
@discardableResult
func withWorkspaceSidebarDropTransaction(_ body: () throws -> Bool) throws -> Bool {
    let before = WorkspaceSidebarTabUndoSnapshot()
    let succeeded: Bool
    do { succeeded = try body() } catch {
        rollBackWorkspaceSidebarDrop(to: before)
        throw error
    }
    if !succeeded { rollBackWorkspaceSidebarDrop(to: before) }
    return succeeded
}

@MainActor
private func rollBackWorkspaceSidebarDrop(to before: WorkspaceSidebarTabUndoSnapshot) {
    let after = WorkspaceSidebarTabUndoSnapshot()
    guard !before.matches(after) else { return }
    before.restore(replacing: after)
    guard workspaceSidebarOrganizationStore.state != before.organization else { return }
    do { try workspaceSidebarOrganizationStore.update { $0 = before.organization } } catch {
        debugWorkspaceSidebarCrossDisplayDragLog("dropRollback organization restore failed: \(error)")
        showWorkspaceSidebarError("Couldn't restore the tab's pins or groups: \(error.localizedDescription)")
    }
}
