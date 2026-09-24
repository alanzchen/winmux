import AppKit
import Common

let savedWorkspacesFileVersion = 1
let savedWorkspaceMaxSlotsPerWorkspace = 64
let savedWorkspaceMaxTitleLength = 256

/// On-disk form of every saved workspace. Records are kept in presentation order.
///
/// Every field except the identities decodes with a default, so adding a field never needs a
/// version bump. Bump `savedWorkspacesFileVersion` only for changes an older build would misread.
struct SavedWorkspacesFile: Codable, Equatable, Sendable {
    var version: Int = savedWorkspacesFileVersion
    var nextVisibilitySequence: Int = 1
    var workspaces: [SavedWorkspaceRecord] = []

    init(version: Int = savedWorkspacesFileVersion, nextVisibilitySequence: Int = 1, workspaces: [SavedWorkspaceRecord] = []) {
        self.version = version
        self.nextVisibilitySequence = nextVisibilitySequence
        self.workspaces = workspaces
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case nextVisibilitySequence
        case workspaces
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? savedWorkspacesFileVersion
        nextVisibilitySequence = try container.decodeIfPresent(Int.self, forKey: .nextVisibilitySequence) ?? 1
        workspaces = try container.decodeIfPresent([SavedWorkspaceRecord].self, forKey: .workspaces) ?? []
    }
}

struct SavedWorkspaceRecord: Codable, Equatable, Sendable {
    /// Permanent identity, never reused.
    let id: String
    /// The internal `Workspace.name`. It is immutable and stays reserved while the record exists.
    let workspaceName: String
    /// Fallback for the TOML `workspace-labels` entry. nil means the automatic "Workspace N" name.
    var displayName: String?
    var projectId: WorkspaceProjectId
    var namingStyle: WorkspaceNamingStyle
    /// The soft home display. nil until the workspace is seen on a display with an identity.
    var display: SavedDisplayAffinity?
    var isPinnedToDisplay: Bool = false
    /// Bumped each time the workspace becomes visible on its home display.
    var lastVisibleSequence: Int?
    var layout: SavedWorkspaceLayout = .init()

    init(
        id: String = newSavedWorkspaceRecordId(),
        workspaceName: String,
        displayName: String? = nil,
        projectId: WorkspaceProjectId = workspaceProjectDefaultId,
        namingStyle: WorkspaceNamingStyle = .explicit,
        display: SavedDisplayAffinity? = nil,
        isPinnedToDisplay: Bool = false,
        lastVisibleSequence: Int? = nil,
        layout: SavedWorkspaceLayout = .init(),
    ) {
        self.id = id
        self.workspaceName = workspaceName
        self.displayName = displayName
        self.projectId = projectId
        self.namingStyle = namingStyle
        self.display = display
        self.isPinnedToDisplay = isPinnedToDisplay
        self.lastVisibleSequence = lastVisibleSequence
        self.layout = layout
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceName
        case displayName
        case projectId
        case namingStyle
        case display
        case isPinnedToDisplay
        case lastVisibleSequence
        case layout
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        workspaceName = try container.decode(String.self, forKey: .workspaceName)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        projectId = try container.decodeIfPresent(WorkspaceProjectId.self, forKey: .projectId) ?? workspaceProjectDefaultId
        namingStyle = try container.decodeIfPresent(WorkspaceNamingStyle.self, forKey: .namingStyle) ?? .explicit
        display = try container.decodeIfPresent(SavedDisplayAffinity.self, forKey: .display)
        isPinnedToDisplay = try container.decodeIfPresent(Bool.self, forKey: .isPinnedToDisplay) ?? false
        lastVisibleSequence = try container.decodeIfPresent(Int.self, forKey: .lastVisibleSequence)
        layout = try container.decodeIfPresent(SavedWorkspaceLayout.self, forKey: .layout) ?? .init()
    }
}

struct SavedDisplayAffinity: Codable, Equatable, Sendable {
    var uuid: String?
    var vendor: UInt32?
    var model: UInt32?
    var serial: UInt32?
    var isBuiltin: Bool = false
    /// localizedName, shown in menus.
    var name: String
    /// Tie-break between identical displays.
    var lastTopLeft: CGPoint

    init(uuid: String?, vendor: UInt32?, model: UInt32?, serial: UInt32?, isBuiltin: Bool, name: String, lastTopLeft: CGPoint) {
        self.uuid = uuid
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.isBuiltin = isBuiltin
        self.name = name
        self.lastTopLeft = lastTopLeft
    }

    private enum CodingKeys: String, CodingKey {
        case uuid
        case vendor
        case model
        case serial
        case isBuiltin
        case name
        case lastTopLeft
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        vendor = try container.decodeIfPresent(UInt32.self, forKey: .vendor)
        model = try container.decodeIfPresent(UInt32.self, forKey: .model)
        serial = try container.decodeIfPresent(UInt32.self, forKey: .serial)
        isBuiltin = try container.decodeIfPresent(Bool.self, forKey: .isBuiltin) ?? false
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        lastTopLeft = try container.decodeIfPresent(CGPoint.self, forKey: .lastTopLeft) ?? .zero
    }
}

struct SavedWorkspaceLayout: Codable, Equatable, Sendable {
    var root: SavedLayoutContainer = .init()
    var floating: [SavedWindowSlot] = []

    init(root: SavedLayoutContainer = .init(), floating: [SavedWindowSlot] = []) {
        self.root = root
        self.floating = floating
    }

    private enum CodingKeys: String, CodingKey {
        case root
        case floating
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decodeIfPresent(SavedLayoutContainer.self, forKey: .root) ?? .init()
        floating = try container.decodeIfPresent([SavedWindowSlot].self, forKey: .floating) ?? []
    }

    var allSlots: [SavedWindowSlot] { root.allSlots + floating }
}

struct SavedLayoutContainer: Codable, Equatable, Sendable {
    var layout: Layout = .tiles
    var orientation: Orientation = .h
    var weight: CGFloat = 1
    var isMostRecentInParent: Bool = false
    var children: [SavedLayoutNode] = []

    init(layout: Layout = .tiles, orientation: Orientation = .h, weight: CGFloat = 1, isMostRecentInParent: Bool = false, children: [SavedLayoutNode] = []) {
        self.layout = layout
        self.orientation = orientation
        self.weight = weight
        self.isMostRecentInParent = isMostRecentInParent
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case layout
        case orientation
        case weight
        case isMostRecentInParent
        case children
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decodeIfPresent(Layout.self, forKey: .layout) ?? .tiles
        orientation = try container.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .h
        weight = try container.decodeIfPresent(CGFloat.self, forKey: .weight) ?? 1
        isMostRecentInParent = try container.decodeIfPresent(Bool.self, forKey: .isMostRecentInParent) ?? false
        children = try container.decodeIfPresent([SavedLayoutNode].self, forKey: .children) ?? []
    }

    /// Slots in depth-first order.
    var allSlots: [SavedWindowSlot] {
        children.flatMap { child -> [SavedWindowSlot] in
            switch child {
                case .slot(let slot): [slot]
                case .container(let container): container.allSlots
            }
        }
    }
}

enum SavedLayoutNode: Codable, Equatable, Sendable {
    case container(SavedLayoutContainer)
    case slot(SavedWindowSlot)

    private enum CodingKeys: String, CodingKey {
        case kind
        case container
        case slot
    }

    private enum Kind: String, Codable {
        case container
        case slot
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
            case .container:
                self = .container(try container.decode(SavedLayoutContainer.self, forKey: .container))
            case .slot:
                self = .slot(try container.decode(SavedWindowSlot.self, forKey: .slot))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case .container(let savedContainer):
                try container.encode(Kind.container, forKey: .kind)
                try container.encode(savedContainer, forKey: .container)
            case .slot(let slot):
                try container.encode(Kind.slot, forKey: .kind)
                try container.encode(slot, forKey: .slot)
        }
    }

    var weight: CGFloat {
        switch self {
            case .container(let container): container.weight
            case .slot(let slot): slot.weight
        }
    }

    var isMostRecentInParent: Bool {
        switch self {
            case .container(let container): container.isMostRecentInParent
            case .slot(let slot): slot.isMostRecentInParent
        }
    }

    func withMostRecentInParent(_ value: Bool) -> SavedLayoutNode {
        switch self {
            case .container(var container):
                container.isMostRecentInParent = value
                return .container(container)
            case .slot(var slot):
                slot.isMostRecentInParent = value
                return .slot(slot)
        }
    }

    func withWeight(_ weight: CGFloat) -> SavedLayoutNode {
        switch self {
            case .container(var container):
                container.weight = weight
                return .container(container)
            case .slot(var slot):
                slot.weight = weight
                return .slot(slot)
        }
    }

    var allSlots: [SavedWindowSlot] {
        switch self {
            case .container(let container): container.allSlots
            case .slot(let slot): [slot]
        }
    }
}

/// One window position in a saved layout. The app fingerprint matches windows after an app or
/// Mac relaunch; `lastWindowId` + `lastPid` match the same window after a WinMux relaunch.
struct SavedWindowSlot: Codable, Equatable, Sendable {
    let id: String
    var bundleId: String
    var appName: String?
    var bundlePath: String?
    var title: String?
    var weight: CGFloat = 1
    /// WinMux fullscreen, not macOS native fullscreen.
    var isFullscreen: Bool = false
    var isMostRecentInParent: Bool = false
    var lastWindowId: UInt32?
    var lastPid: Int32?

    init(
        id: String = newSavedWindowSlotId(),
        bundleId: String,
        appName: String? = nil,
        bundlePath: String? = nil,
        title: String? = nil,
        weight: CGFloat = 1,
        isFullscreen: Bool = false,
        isMostRecentInParent: Bool = false,
        lastWindowId: UInt32? = nil,
        lastPid: Int32? = nil,
    ) {
        self.id = id
        self.bundleId = bundleId
        self.appName = appName
        self.bundlePath = bundlePath
        self.title = title
        self.weight = weight
        self.isFullscreen = isFullscreen
        self.isMostRecentInParent = isMostRecentInParent
        self.lastWindowId = lastWindowId
        self.lastPid = lastPid
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bundleId
        case appName
        case bundlePath
        case title
        case weight
        case isFullscreen
        case isMostRecentInParent
        case lastWindowId
        case lastPid
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        bundleId = try container.decode(String.self, forKey: .bundleId)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        bundlePath = try container.decodeIfPresent(String.self, forKey: .bundlePath)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        weight = try container.decodeIfPresent(CGFloat.self, forKey: .weight) ?? 1
        isFullscreen = try container.decodeIfPresent(Bool.self, forKey: .isFullscreen) ?? false
        isMostRecentInParent = try container.decodeIfPresent(Bool.self, forKey: .isMostRecentInParent) ?? false
        lastWindowId = try container.decodeIfPresent(UInt32.self, forKey: .lastWindowId)
        lastPid = try container.decodeIfPresent(Int32.self, forKey: .lastPid)
    }
}

func newSavedWorkspaceRecordId() -> String {
    "saved-\(UUID().uuidString.lowercased())"
}

func newSavedWindowSlotId() -> String {
    "slot-\(UUID().uuidString.lowercased())"
}

func normalizedSavedWindowTitle(_ title: String?) -> String? {
    guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(savedWorkspaceMaxTitleLength))
}
