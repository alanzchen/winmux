import Foundation
import Common

/// A sidebar collection is organization only. Its members are workspace tabs, each of
/// which may contain a split. It never owns windows or participates in the tiling tree.
struct WorkspaceTabCollection: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var projectId: WorkspaceProjectId
    var name: String = "New Group"
    var colorHex: String? = nil
    var emoji: String? = nil
    var workspaceNames: [String] = []
    var isCollapsed = false

    @MainActor
    func containsVisibleWorkspace(on scopeId: String? = nil) -> Bool {
        workspaceNames.contains {
            guard let workspace = Workspace.existing(byName: $0), workspace.isVisible else { return false }
            guard let scopeId, !workspaceSidebarMonitorScopeIsSentinel(scopeId) else { return true }
            return workspaceSidebarMonitorScopeId(for: workspace.workspaceMonitor) == scopeId
        }
    }
}

/// A saved collapsed preference yields to an active tab or search. Both the rows and
/// disclosure controls use this effective state, so an open group never points sideways.
struct WorkspaceSidebarTabCollectionDisclosure {
    let isCollapsed: Bool
    let canToggle: Bool

    init(group: WorkspaceTabCollection, containsActiveTab: Bool, isSearching: Bool = false) {
        canToggle = !containsActiveTab && !isSearching
        isCollapsed = group.isCollapsed && canToggle
    }
}

@MainActor
func toggleWorkspaceSidebarTabCollection(_ id: String, monitorScopeId: String? = nil) throws {
    let store = workspaceSidebarOrganizationStore
    guard let group = store.state.collections.first(where: { $0.id == id }),
          !group.containsVisibleWorkspace(on: monitorScopeId) else { return }
    try store.edit(id) { $0.isCollapsed.toggle() }
}

struct WorkspaceSidebarItemAppearance: Codable, Hashable {
    var colorHex: String? = nil
    var emoji: String? = nil
    var isFavorite = false
}

struct WorkspaceSidebarOrganization: Codable, Equatable {
    var version = 1
    var collections: [WorkspaceTabCollection] = []
    var workspaces: [String: WorkspaceSidebarItemAppearance] = [:]
}

/// Atomic, explicit user edits. A failed or newer file stays untouched, and a failed
/// write doesn't publish a change that would disappear on relaunch.
@MainActor
final class WorkspaceSidebarOrganizationStore {
    private(set) var state: WorkspaceSidebarOrganization
    let url: URL?
    private(set) var readOnlyReason: String?

    init(state: WorkspaceSidebarOrganization = .init(), url: URL? = nil, readOnlyReason: String? = nil) {
        self.state = state
        self.url = url
        self.readOnlyReason = readOnlyReason
    }

    static func load(url: URL, readOnly: Bool = false) -> WorkspaceSidebarOrganizationStore {
        let reason = readOnly ? "WinMux is running with --read-only." : nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .init(url: url, readOnlyReason: reason)
        }
        do {
            let data = try Data(contentsOf: url)
            struct Version: Decodable { let version: Int }
            guard try JSONDecoder().decode(Version.self, from: data).version == 1 else {
                return .init(url: url, readOnlyReason: "Sidebar organization was saved by a different version of WinMux.")
            }
            var state = try JSONDecoder().decode(WorkspaceSidebarOrganization.self, from: data)
            var ids: Set<String> = []
            var members: Set<String> = []
            state.collections = state.collections.filter { ids.insert($0.id).inserted }
            for index in state.collections.indices {
                state.collections[index].workspaceNames = state.collections[index].workspaceNames.filter { members.insert($0).inserted }
            }
            return .init(state: state, url: url, readOnlyReason: reason)
        } catch {
            return .init(url: url, readOnlyReason: "Sidebar organization could not be read: \(error.localizedDescription)")
        }
    }

    func update(_ change: (inout WorkspaceSidebarOrganization) -> Void) throws {
        if let readOnlyReason { throw error(readOnlyReason) }
        var next = state
        change(&next)
        guard next != state else { return }
        if let url {
            let data = try JSONEncoder.winMuxDefault.encode(next)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        state = next
    }

    func collection(containing name: String) -> WorkspaceTabCollection? {
        state.collections.first { $0.workspaceNames.contains(name) }
    }

    @discardableResult
    func create(projectId: WorkspaceProjectId, workspaceNames: [String]) throws -> WorkspaceTabCollection {
        var seen: Set<String> = []
        let collection = WorkspaceTabCollection(projectId: projectId, workspaceNames: workspaceNames.filter { seen.insert($0).inserted })
        try update { state in
            for name in workspaceNames { state.workspaces[name, default: .init()].isFavorite = false }
            for index in state.collections.indices {
                state.collections[index].workspaceNames.removeAll { workspaceNames.contains($0) }
            }
            state.collections.append(collection)
        }
        return collection
    }

    func edit(_ id: String, _ change: (inout WorkspaceTabCollection) -> Void) throws {
        guard let index = state.collections.firstIndex(where: { $0.id == id }) else { return }
        try update { change(&$0.collections[index]) }
    }

    func assign(_ workspaceName: String, projectId: WorkspaceProjectId, to collectionId: String?) throws {
        if let collectionId, !state.collections.contains(where: { $0.id == collectionId && $0.projectId == projectId }) {
            throw error("Choose a group in the same project as this tab.")
        }
        try update { state in
            if collectionId != nil { state.workspaces[workspaceName, default: .init()].isFavorite = false }
            for index in state.collections.indices {
                state.collections[index].workspaceNames.removeAll { $0 == workspaceName }
                if state.collections[index].id == collectionId { state.collections[index].workspaceNames.append(workspaceName) }
            }
        }
    }

    /// Several tabs of one project at once, in one write.
    func assign(_ workspaceNames: [String], projectId: WorkspaceProjectId, to collectionId: String?) throws {
        if let collectionId, !state.collections.contains(where: { $0.id == collectionId && $0.projectId == projectId }) {
            throw error("Choose a group in the same project as these tabs.")
        }
        let names = Set(workspaceNames)
        try update { state in
            if collectionId != nil { for name in workspaceNames { state.workspaces[name, default: .init()].isFavorite = false } }
            for index in state.collections.indices {
                state.collections[index].workspaceNames.removeAll(where: names.contains)
                if state.collections[index].id == collectionId { state.collections[index].workspaceNames += workspaceNames }
            }
        }
    }

    func removeWorkspace(_ name: String) throws {
        try update { state in
            state.workspaces.removeValue(forKey: name)
            for index in state.collections.indices { state.collections[index].workspaceNames.removeAll { $0 == name } }
        }
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "WinMux.SidebarOrganization", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor var workspaceSidebarOrganizationStore = WorkspaceSidebarOrganizationStore()

/// Customizing a tab gives it a persistent identity. Reuse saved-workspace restoration
/// so a generated name cannot be recycled for an unrelated window after relaunch.
@MainActor
func saveWorkspaceSidebarIdentity(_ workspace: Workspace, keepWhenEmpty: Bool = true, flush: Bool = true) throws {
    if let reason = workspaceSidebarOrganizationStore.readOnlyReason {
        throw NSError(domain: "WinMux.SidebarOrganization", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }
    try ensureSavedWorkspaceRecord(workspace, flush: flush, keepWhenEmpty: keepWhenEmpty)
}

/// Saves several tabs' identities with one write of the saved-workspace file.
@MainActor
func saveWorkspaceSidebarIdentities(_ workspaces: [Workspace]) throws {
    defer { savedWorkspaceStore.flushNow() }
    for workspace in workspaces { try saveWorkspaceSidebarIdentity(workspace, flush: false) }
}

@MainActor
func assignWorkspaceToSidebarCollection(_ workspace: Workspace, collectionId: String?, keepWhenEmpty: Bool = true) throws {
    if let collectionId {
        guard workspaceSidebarOrganizationStore.state.collections.contains(where: {
            $0.id == collectionId && $0.projectId == workspace.projectId
        }) else { throw WorkspaceMutationError.projectNotFound(workspace.projectId.rawValue) }
        try saveWorkspaceSidebarIdentity(workspace, keepWhenEmpty: keepWhenEmpty)
    }
    try workspaceSidebarOrganizationStore.assign(workspace.name, projectId: workspace.projectId, to: collectionId)
}

@MainActor
func newTabInSidebarCollection(_ id: String, monitor: Monitor) throws -> WorkspaceLauncherNewTab? {
    guard let group = workspaceSidebarOrganizationStore.state.collections.first(where: { $0.id == id }) else { return nil }
    let previous = monitor.activeWorkspace
    let anchor = orderedWorkspaces(in: group.projectId).last { group.workspaceNames.contains($0.name) }
    // An explicit new member is always fresh, even if the current tab is empty.
    let workspace = createWorkspace(after: anchor, projectId: group.projectId, monitor: monitor)
    do { try assignWorkspaceToSidebarCollection(workspace, collectionId: id) }
    catch { removeWorkspaceFromRegistry(workspace, reason: .deleted); throw error }
    return WorkspaceLauncherNewTab(workspace: workspace, previous: previous, discardsSavedPlaceholderOnCancel: true)
}

@MainActor
func moveWorkspaceSidebarCollection(_ id: String, to projectId: WorkspaceProjectId) throws {
    guard let group = workspaceSidebarOrganizationStore.state.collections.first(where: { $0.id == id }),
          group.projectId != projectId else { return }
    guard winMuxWorkspaceState.projectsById[projectId] != nil else {
        throw WorkspaceMutationError.projectNotFound(projectId.rawValue)
    }
    let workspaces = group.workspaceNames.compactMap { Workspace.existing(byName: $0) }
        .filter { !$0.isArchived && $0.projectId == group.projectId }
    // Persist first. The following synchronous moves preserve each workspace's tree,
    // and see the group's new project so they don't detach its members.
    try workspaceSidebarOrganizationStore.edit(id) { $0.projectId = projectId }
    for workspace in workspaces { moveWorkspaceToProject(workspaceName: workspace.name, projectId: projectId) }
}

@MainActor
func loadWorkspaceSidebarOrganization() {
    guard !isUnitTest, let savedURL = try? savedWorkspacesFileUrl() else { return }
    workspaceSidebarOrganizationStore = .load(
        url: savedURL.deletingLastPathComponent().appendingPathComponent("sidebar-organization.json"),
        readOnly: serverArgs.isReadOnly)
    if let reason = workspaceSidebarOrganizationStore.readOnlyReason {
        MessageModel.shared.message = Message(description: "Sidebar Organization", body: reason)
    }
}

enum WorkspaceSidebarTabSection: Equatable, Identifiable {
    case tab(WorkspaceSidebarWorkspaceViewModel)
    case collection(WorkspaceTabCollection, [WorkspaceSidebarWorkspaceViewModel])

    var id: String {
        switch self {
            case .tab(let workspace): "tab:\(workspace.name)"
            case .collection(let group, _): "collection:\(group.id)"
        }
    }
}

/// Collections occupy their first member's position; ordinary tabs remain ordinary rows.
/// Missing members are retained on disk for windows restored later during startup.
func workspaceSidebarTabSections(workspaces: [WorkspaceSidebarWorkspaceViewModel],
                                 collections: [WorkspaceTabCollection], projectId: WorkspaceProjectId) -> [WorkspaceSidebarTabSection] {
    let groups = collections.filter { $0.projectId == projectId }
    var emitted: Set<String> = []
    var result: [WorkspaceSidebarTabSection] = []
    for workspace in workspaces {
        if let group = groups.first(where: { $0.workspaceNames.contains(workspace.name) }) {
            if emitted.insert(group.id).inserted {
                result.append(.collection(group, workspaces.filter { group.workspaceNames.contains($0.name) }))
            }
        } else { result.append(.tab(workspace)) }
    }
    for group in groups where group.workspaceNames.isEmpty && emitted.insert(group.id).inserted {
        result.append(.collection(group, []))
    }
    return result
}
