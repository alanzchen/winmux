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
            guard let workspace = Workspace.existing(byName: $0), workspace.isVisible,
                  !config.usesBrowserTabs || workspaceTabIsShown(workspace) else { return false }
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

/// Which pins a pinned tab is among. A pin without one is its project's, as every pin was before
/// pins in All Projects; one in All Projects shows in every project's sidebar.
enum WorkspaceSidebarPinScope: String, Codable, Hashable {
    case allProjects
}

struct WorkspaceSidebarItemAppearance: Codable, Hashable {
    var colorHex: String? = nil
    var emoji: String? = nil
    var isFavorite = false
    /// A pin's place among its project's pins, once they've been rearranged. Pins without
    /// one follow the arranged pins, in tab order. A pin in All Projects has its place among those.
    var pinOrder: Int? = nil
    /// Optional, so files without it load, and files without pins in All Projects don't change.
    /// It means something only while pinned.
    var pinScope: WorkspaceSidebarPinScope? = nil
    /// Tabs mode, a pin with one window: that window, while it's in another tab's split. The pin
    /// shows grey, and a click brings the same window back. Means something only while pinned.
    var lentWindow: WorkspaceSidebarPinWindow? = nil
    /// Tabs mode, a pinned split, made from a split tab's menu: it as it was split, whatever windows
    /// it has now. Means something only while pinned.
    var composition: WorkspaceSidebarPinComposition? = nil
    /// Tabs mode, a pin made with Pin Document: the file its one window showed, which a click on the
    /// pin with no window opens again, in the same app. Means something only while pinned.
    var document: WorkspaceSidebarPinDocument? = nil
    /// Tabs mode, a pin made with Pin Page, Pin Message and the like, or New Link Pin: the address of
    /// a page or an app's item, which a click on the pin with no window opens again. Never set together
    /// with `document`. Means something only while pinned.
    var link: WorkspaceSidebarPinLink? = nil

    var isPinnedInAllProjects: Bool { isFavorite && pinScope == .allProjects }

    /// The pin's resource, whichever kind: what a click on it with no window opens. Setting it replaces
    /// the other kind.
    var resource: WorkspaceSidebarPinResource? {
        get { document.map(WorkspaceSidebarPinResource.file) ?? link.map(WorkspaceSidebarPinResource.link) }
        set {
            document = nil
            link = nil
            switch newValue {
                case .file(let file): document = file
                case .link(let address): link = address
                case nil: break
            }
        }
    }

    /// A new pin goes after the arranged pins, among its project's, and an unpinned tab forgets
    /// its place and its scope, the windows it lent or would bring back, and its resource.
    mutating func setFavorite(_ favorite: Bool) {
        if favorite != isFavorite { pinOrder = nil; pinScope = nil }
        if !favorite { lentWindow = nil; composition = nil; document = nil; link = nil }
        isFavorite = favorite
    }

    /// Pins it among `scope`'s pins, after those arranged there, unless it's there already.
    mutating func setPinScope(_ scope: WorkspaceSidebarPinScope?) {
        if !isFavorite || pinScope != scope { pinOrder = nil }
        isFavorite = true
        pinScope = scope
    }
}

/// One lifetime of a window: its number, its process, that process's app and launch, and the boot it
/// ran in. The same number and process seen in another boot, or in another launch, are another window.
struct WorkspaceSidebarPinWindow: Codable, Hashable {
    var windowId: UInt32
    var pid: Int32
    var bundleId: String? = nil
    var processLaunch: Date? = nil
    var boot: Date? = nil
}

/// A pinned document: the file, as a bookmark that follows it when it's renamed or moved on its disk,
/// the app that showed it, and its name for messages. `fileId` and `volume`, the file's number and
/// its volume's UUID when the file system has them, check that what the bookmark finds is that file.
struct WorkspaceSidebarPinDocument: Codable, Hashable {
    var bookmark: Data
    var bundleId: String
    var name: String
    var fileId: UInt64? = nil
    var volume: String? = nil
}

/// What a pin opens when it has no window: a file, or an address.
enum WorkspaceSidebarPinResource: Hashable {
    case file(WorkspaceSidebarPinDocument)
    case link(WorkspaceSidebarPinLink)

    /// Its mark in the corner of the pin's tile.
    var symbolName: String {
        switch self {
            case .file: "doc.fill"
            case .link(let link): link.url.lowercased().hasPrefix("http") ? "globe" : "link"
        }
    }

    var pinHelp: String {
        switch self {
            case .file(let document): "Pinned document: \(document.name)"
            case .link(let link): "Pinned link: \(link.title)"
        }
    }
}

/// A pinned address, kept exactly as it was taken or typed: a page in a browser, or an item in an
/// app, such as a message or a note. What the pin knows of a browser's window or tab is only for
/// this session and never kept here. A file written by a newer WinMux, with a newer `version`, is
/// read but not opened.
struct WorkspaceSidebarPinLink: Codable, Hashable {
    static let currentVersion = 1

    var version: Int = Self.currentVersion
    /// The full address, never shortened or cleaned of its query.
    var url: String
    /// What the pin calls it: the page's or item's title when taken, or the name typed for it.
    var title: String
    /// The adapter that took it, and opens it: `safari`, `chromium`, `mail`, `notes`, … or `link`.
    var adapter: String
    /// The app it was taken in, or that opens it; nil for the system's choice.
    var bundleId: String? = nil
    /// `window` when taken from a tab's window, `manual` when typed or pasted.
    var source: Source = .manual
    /// The integration that took it, by id, whose Open Item opens it; nil for the built-in ones.
    var integration: String? = nil

    enum Source: String, Codable, Hashable {
        case window
        case manual
    }

    init(url: String, title: String, adapter: String, bundleId: String? = nil, source: Source = .manual, integration: String? = nil) {
        self.url = url
        self.title = title
        self.adapter = adapter
        self.bundleId = bundleId
        self.source = source
        self.integration = integration
    }

    /// Never fails: a link a newer WinMux wrote, or a damaged one, must not keep the rest of the
    /// organization from loading. What it lacks makes it a link the pin won't open.
    init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        version = (try? values?.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        url = (try? values?.decodeIfPresent(String.self, forKey: .url)) ?? ""
        title = (try? values?.decodeIfPresent(String.self, forKey: .title)) ?? ""
        adapter = (try? values?.decodeIfPresent(String.self, forKey: .adapter)) ?? ""
        bundleId = try? values?.decodeIfPresent(String.self, forKey: .bundleId)
        source = (try? values?.decodeIfPresent(String.self, forKey: .source)).flatMap(Source.init(rawValue:)) ?? .manual
        integration = try? values?.decodeIfPresent(String.self, forKey: .integration)
    }

    /// Whether this WinMux can open it: a version it knows, and an address.
    var isReadable: Bool { version <= Self.currentVersion && !url.isEmpty }
}

/// A pinned split: its layout as it was split, and its windows away now, back alone in their own pins,
/// which a click on it brings back to their places.
struct WorkspaceSidebarPinComposition: Codable, Hashable {
    var layout: WorkspaceSidebarCompositionNode
    var away: [WorkspaceSidebarCompositionMember] = []
}

/// A pinned split's window that a click on its own pin took back there.
struct WorkspaceSidebarCompositionMember: Codable, Hashable {
    var window: WorkspaceSidebarPinWindow
    var pinName: String
}

/// A pinned split's layout: a window, or windows side by side or stacked, each with its length.
indirect enum WorkspaceSidebarCompositionNode: Codable, Hashable {
    case window(WorkspaceSidebarPinWindow, weight: CGFloat)
    case split(Orientation, weight: CGFloat, children: [WorkspaceSidebarCompositionNode])
}

struct WorkspaceSidebarOrganization: Codable, Equatable {
    var version = 1
    var collections: [WorkspaceTabCollection] = []
    var workspaces: [String: WorkspaceSidebarItemAppearance] = [:]
    /// Tabs mode: pinned splits from before they were recorded (`composition`) have been recorded,
    /// once. After that, only a split tab's menu Pin makes one.
    var pinnedSplitsRecorded: Bool? = nil
}

/// Atomic, explicit user edits. A failed or newer file stays untouched, and a failed
/// write doesn't publish a change that would disappear on relaunch.
@MainActor
final class WorkspaceSidebarOrganizationStore {
    private(set) var state: WorkspaceSidebarOrganization
    let url: URL?
    private(set) var readOnlyReason: String?
    /// Bumped for a workspace each time a write changes its appearance, Undo included, so work begun
    /// for one state of it can tell that state is gone. Not saved.
    private var appearanceRevisions: [String: UInt64] = [:]
    private var lastAppearanceRevision: UInt64 = 0

    func appearanceRevision(of name: String) -> UInt64 { appearanceRevisions[name] ?? 0 }

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
        let previous = state
        state = next
        var changed: Set<String> = []
        for name in Set(previous.workspaces.keys).union(next.workspaces.keys) where previous.workspaces[name] != next.workspaces[name] {
            lastAppearanceRevision &+= 1
            appearanceRevisions[name] = lastAppearanceRevision
            changed.insert(name)
        }
        if !changed.isEmpty { workspaceSidebarAppearancesDidChange(changed) }
    }

    func collection(containing name: String) -> WorkspaceTabCollection? {
        state.collections.first { $0.workspaceNames.contains(name) }
    }

    @discardableResult
    func create(projectId: WorkspaceProjectId, workspaceNames: [String]) throws -> WorkspaceTabCollection {
        var seen: Set<String> = []
        let collection = WorkspaceTabCollection(projectId: projectId, workspaceNames: workspaceNames.filter { seen.insert($0).inserted })
        try update { state in
            for name in workspaceNames { state.workspaces[name, default: .init()].setFavorite(false) }
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
            if collectionId != nil { state.workspaces[workspaceName, default: .init()].setFavorite(false) }
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
            if collectionId != nil { for name in workspaceNames { state.workspaces[name, default: .init()].setFavorite(false) } }
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

/// Tabs mode: a pin in All Projects, shown in every project's sidebar. It stays in its own
/// project, its home, which is where an older build, the Dock and the CLI list it. Pins exist only
/// in Tabs mode, so outside it this is every tab's own project, as before.
@MainActor
func workspaceIsPinnedInAllProjects(named name: String) -> Bool {
    config.usesBrowserTabs && workspaceSidebarOrganizationStore.state.workspaces[name]?.isPinnedInAllProjects == true
}

@MainActor
func workspaceIsPinnedInAllProjects(_ workspace: Workspace) -> Bool {
    workspaceIsPinnedInAllProjects(named: workspace.name)
}

/// Whether `projectId`'s tabs include `workspace`: its own project's do, and every project's
/// include a pin in All Projects.
@MainActor
func workspaceIsListed(_ workspace: Workspace, inProject projectId: WorkspaceProjectId) -> Bool {
    workspace.projectId == projectId || workspaceIsPinnedInAllProjects(workspace)
}

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
    // Windows of a process that's gone, or of another boot, aren't lent or brought back.
    forgetWorkspaceSidebarPinWindowsNoLongerOpen()
    // Pinned splits saved before they were recorded are recorded now, while their saved layout shows them.
    recordLegacyWorkspaceSidebarPinnedSplits()
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
