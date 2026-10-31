import Foundation
import Common

/// Tabs mode: a shortcut to a resource, among the pins. It only goes to its resource, a file or an
/// address: it holds no window, lends none, and is never part of a pinned split. The tab whose window
/// it was taken from stays as it was. A shortcut a newer WinMux wrote, or a damaged one, is kept but
/// not opened.
struct WorkspaceSidebarResourceShortcut: Codable, Hashable, Identifiable {
    static let currentVersion = 1

    var id: String = UUID().uuidString
    var version: Int = Self.currentVersion
    /// The project whose pins it's among. With `pinScope` `.allProjects`, it's among every project's.
    var projectId: WorkspaceProjectId
    var pinScope: WorkspaceSidebarPinScope? = nil
    /// Its resource, one of the two, as a pin keeps it.
    var document: WorkspaceSidebarPinDocument? = nil
    var link: WorkspaceSidebarPinLink? = nil

    init(projectId: WorkspaceProjectId, resource: WorkspaceSidebarPinResource, pinScope: WorkspaceSidebarPinScope? = nil) {
        self.projectId = projectId
        self.pinScope = pinScope
        self.resource = resource
    }

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

    /// What it's called, always its resource's name.
    var name: String { document?.name ?? link?.title ?? "" }

    /// Whether this WinMux can go to it: a version it knows, and a resource it can open.
    var isReadable: Bool {
        version <= Self.currentVersion && (document != nil || link?.isReadable == true)
    }

    var isInAllProjects: Bool { pinScope == .allProjects }

    private enum CodingKeys: String, CodingKey {
        case id, version, projectId, pinScope, document, link
    }

    /// Never fails: one shortcut must not keep the rest of the organization from loading.
    init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? values?.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        version = (try? values?.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        projectId = (try? values?.decodeIfPresent(WorkspaceProjectId.self, forKey: .projectId)) ?? workspaceProjectDefaultId
        pinScope = (try? values?.decodeIfPresent(WorkspaceSidebarPinScope.self, forKey: .pinScope)) ?? nil
        document = (try? values?.decodeIfPresent(WorkspaceSidebarPinDocument.self, forKey: .document)) ?? nil
        link = (try? values?.decodeIfPresent(WorkspaceSidebarPinLink.self, forKey: .link)) ?? nil
    }
}

extension WorkspaceSidebarOrganization {
    /// The shortcuts among a project's pins, in the order they were added: those in All Projects, then
    /// the project's own.
    func resourceShortcuts(projectId: WorkspaceProjectId) -> (allProjects: [WorkspaceSidebarResourceShortcut],
                                                            project: [WorkspaceSidebarResourceShortcut]) {
        let shortcuts = resourceShortcuts ?? []
        return (shortcuts.filter(\.isInAllProjects),
            shortcuts.filter { !$0.isInAllProjects && $0.projectId == projectId })
    }
}
