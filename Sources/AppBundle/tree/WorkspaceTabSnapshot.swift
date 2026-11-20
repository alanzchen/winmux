import AppKit
import Common

/// `lentFromPin` is also persisted in saved slots. Renaming or persisting additional cases requires
/// a migration, version bump and ownership-safe encoding boundary; a version bump alone cannot
/// prevent older routers from interpreting a new role as a resident restoration claim.
enum WorkspaceTabMembership: String, Codable, Sendable {
    case resident, lentFromPin, awayFromComposition
}

struct WorkspaceTabAttachment {
    let role: AuxiliaryWindowRole
    let parentWindowId: UInt32?
    let hasLiveParent: Bool
    let listedUnderWindowId: UInt32?
}

struct WorkspaceTabLayoutWindow {
    let window: Window
    let weight: CGFloat
    let isMostRecentInParent: Bool
}

indirect enum WorkspaceTabLayoutNode {
    case window(WorkspaceTabLayoutWindow)
    case container(WorkspaceTabLayoutContainer)

    var windows: [Window] {
        switch self {
            case .window(let leaf): [leaf.window]
            case .container(let container): container.windows
        }
    }

    var representative: Window? {
        switch self {
            case .window(let leaf): leaf.window
            case .container(let container): container.tabRepresentative
        }
    }
}

struct WorkspaceTabLayoutContainer {
    /// Identity for commands and existing group IDs; membership comes from `children`.
    let source: TilingContainer
    let layout: Layout
    let orientation: Orientation
    let weight: CGFloat
    let hasTilingParent: Bool
    let isMostRecentInParent: Bool
    let children: [WorkspaceTabLayoutNode]
    let representative: Window?
    let tabRepresentative: Window?

    var windows: [Window] { children.flatMap(\.windows) }
    var tabRepresentatives: [Window] { children.compactMap(\.representative) }
    var containers: [WorkspaceTabLayoutContainer] {
        [self] + children.flatMap { node in
            if case .container(let container) = node { return container.containers }
            return []
        }
    }
}

/// One synchronous projection of tab content. No AX reads or cache: every consumer gets
/// the same roles, ownership and topology from the tree and the existing registries.
@MainActor
struct WorkspaceTabSnapshot {
    let workspace: Workspace
    let root: WorkspaceTabLayoutContainer
    let members: [WorkspaceTabMember]
    let isPinned: Bool
    private let membersById: [UInt32: WorkspaceTabMember]

    init(_ workspace: Workspace, composition: WorkspaceSidebarPinComposition? = nil) {
        self.workspace = workspace
        root = Self.layout(of: workspace.rootTilingContainer, weight: 1)
        var members: [WorkspaceTabMember] = []
        var seen: Set<UInt32> = []
        func add(_ windows: [Window], _ state: WorkspaceTabMemberState, membership: WorkspaceTabMembership = .resident, pinHomeName: String? = nil) {
            for window in windows where window.isBound && seen.insert(window.windowId).inserted {
                members.append(Self.member(window, state: state, membership: membership, pinHomeName: pinHomeName))
            }
        }
        _ = Self.visitResidentWindows(in: workspace, including: { _ in true }) { window, state in
            add([window], state)
            return false
        }

        // A pin lends a resource, not ownership: closing it must never close the borrower's window.
        let appearance = workspaceSidebarOrganizationStore.state.workspaces[workspace.name]
        isPinned = appearance?.isFavorite == true
        if config.usesBrowserTabs, appearance?.isFavorite == true {
            if !members.contains(where: \.isPinResource), let lent = appearance?.lentWindow?.live,
               lent.nodeWorkspace !== workspace {
                add([lent], Self.placement(of: lent), membership: .lentFromPin)
            }
            if let composition = composition ?? appearance?.composition {
                let homes = Dictionary(composition.away.map { ($0.window, $0.pinName) }, uniquingKeysWith: { first, _ in first })
                for reference in composition.away.map(\.window) + composition.layout.windows {
                    if let window = reference.live, window.nodeWorkspace !== workspace {
                        add([window], Self.placement(of: window), membership: .awayFromComposition, pinHomeName: homes[reference])
                    }
                }
            }
        }
        self.members = members
        membersById = Dictionary(uniqueKeysWithValues: members.map { ($0.window.windowId, $0) })
    }

    var residentMembers: [WorkspaceTabMember] { members.filter { $0.membership == .resident } }
    /// Actual tab ownership as Close and lifecycle have always used it. Absent windows retain
    /// slots, but do not make a visible tab or enter its close plan.
    var lifecycleMembers: [WorkspaceTabMember] { residentMembers.filter { $0.state != .notPresentable } }
    var treeMembers: [WorkspaceTabMember] { residentMembers.filter(\.isInWorkspaceTree) }
    var presentMembers: [WorkspaceTabMember] { residentMembers.filter { !$0.state.isOffscreen } }
    var floatingMembers: [WorkspaceTabMember] { residentMembers.filter { $0.state == .floating } }
    var pinResources: [WorkspaceTabMember] { members.filter(\.isPinResource) }
    var loanedMember: WorkspaceTabMember? { members.first { $0.membership == .lentFromPin } }
    var lentMember: WorkspaceTabMember? { loanedMember.flatMap { $0.state == .notPresentable ? nil : $0 } }

    func member(_ id: UInt32) -> WorkspaceTabMember? { membersById[id] }

    /// Global inventory also includes minimized windows whose previous tab no longer exists.
    static var minimizedMembers: [WorkspaceTabMember] {
        macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self).map {
            member($0, state: .minimized, membership: .resident)
        }
    }

    /// Hot visibility and bind paths need only membership, not topology or role metadata.
    static func hasPresentMembers(_ workspace: Workspace) -> Bool {
        visitResidentWindows(in: workspace, including: { !$0.isOffscreen }) { _, _ in true }
    }

    static func hasLifecycleMembers(_ workspace: Workspace) -> Bool {
        visitResidentWindows(in: workspace, including: { $0 != .notPresentable }) { _, _ in true }
    }

    /// Shared membership enumeration; returning true stops at the first matching resident.
    /// Read existing containers directly: asking whether a tab is empty must not create a root.
    private static func visitResidentWindows(in workspace: Workspace, including includes: (WorkspaceTabMemberState) -> Bool,
                                            visit: (Window, WorkspaceTabMemberState) -> Bool) -> Bool {
        func walk(_ node: TreeNode, state: WorkspaceTabMemberState) -> Bool {
            if let window = node as? Window { return window.isBound && visit(window, state) }
            return node.children.contains { walk($0, state: state) }
        }
        if includes(.laidOut), workspace.children.contains(where: { $0 is TilingContainer && walk($0, state: .laidOut) }) { return true }
        if includes(.floating), workspace.floatingWindows.contains(where: { walk($0, state: .floating) }) { return true }
        if includes(.hiddenWithApp), let hidden = workspace.existingMacOsNativeHiddenAppsWindowsContainer,
           walk(hidden, state: .hiddenWithApp) { return true }
        if includes(.nativeFullscreen), let fullscreen = workspace.existingMacOsNativeFullscreenWindowsContainer,
           walk(fullscreen, state: .nativeFullscreen) { return true }
        if includes(.minimized), workspaceOwnedMinimizedWindows(workspace).contains(where: { walk($0, state: .minimized) }) { return true }
        if includes(.notPresentable), workspaceOwnedNotPresentableWindows(workspace).contains(where: { walk($0, state: .notPresentable) }) { return true }
        return false
    }

    /// Undo alone requests MRU order; ordinary snapshots never traverse the MRU lists.
    static func windowsByRecency(in node: TreeNode) -> [Window] {
        if let window = node as? Window { return [window] }
        return node.childrenByMostRecentUse.flatMap { windowsByRecency(in: $0) }
    }

    /// The same topology capture serves callers operating on a subtree instead of a whole tab.
    static func layout(of container: TilingContainer, weight: CGFloat? = nil, isMostRecent: Bool = false) -> WorkspaceTabLayoutContainer {
        let recent = container.mostRecentChild
        let children: [WorkspaceTabLayoutNode] = container.children.compactMap { child in
            let weight = child.getWeight(container.orientation)
            switch child.nodeCases {
                case .window(let window):
                    return window.isBound ? .window(.init(window: window, weight: weight, isMostRecentInParent: recent === child)) : nil
                case .tilingContainer(let nested):
                    return .container(layout(of: nested, weight: weight, isMostRecent: recent === child))
                default: return nil
            }
        }
        return .init(source: container, layout: container.layout, orientation: container.orientation,
            weight: weight ?? (container.parent as? TilingContainer).map { container.getWeight($0.orientation) } ?? 1,
            hasTilingParent: container.parent is TilingContainer, isMostRecentInParent: isMostRecent, children: children,
            representative: container.tabActiveWindow ?? container.mostRecentWindowRecursive ?? children.compactMap(\.representative).first,
            tabRepresentative: container.tabRepresentativeWindow)
    }

    private static func member(_ window: Window, state: WorkspaceTabMemberState, membership: WorkspaceTabMembership, pinHomeName: String? = nil) -> WorkspaceTabMember {
        WorkspaceTabMember(window: window, state: state,
            tilingLayout: (window.parent as? TilingContainer).map { ($0.orientation, $0.layout) },
            membership: membership, attachment: attachment(of: window),
            parking: window.cornerParkingForDebug?.outcome, pinHomeName: pinHomeName)
    }

    static func attachment(of window: Window) -> WorkspaceTabAttachment? {
        let registry = AuxiliaryWindowRegistry.shared
        return registry.role(of: window).map { role in
            WorkspaceTabAttachment(role: role, parentWindowId: registry.parentWindowId(of: window),
                hasLiveParent: isAuxiliaryWindowOfOpenParent(window), listedUnderWindowId: auxiliaryWindowParent(of: window)?.windowId)
        }
    }

    static func auxiliaryChildren(of window: Window) -> [UInt32] {
        AuxiliaryWindowRegistry.shared.entries.filter {
            $0.value.parentWindowId == window.windowId && $0.value.pid == window.app.pid
        }.keys.sorted()
    }

    /// Command identity lookups need only the representatives, without allocating an entire snapshot.
    static func tabRepresentatives(of container: TilingContainer) -> [Window] {
        container.children.compactMap(\.tabRepresentativeWindow)
    }

    static func isEphemeral(_ window: Window) -> Bool {
        member(window, state: placement(of: window), membership: .resident).isEphemeral
    }

    private static func placement(of window: Window) -> WorkspaceTabMemberState {
        if window.isSetAsideAsNotPresentable { return .notPresentable }
        switch window.parent {
            case is TilingContainer: return .laidOut
            case is MacosHiddenAppsWindowsContainer: return .hiddenWithApp
            case is MacosFullscreenWindowsContainer: return .nativeFullscreen
            case is MacosMinimizedWindowsContainer: return .minimized
            case is Workspace: return .floating
            default: return .notPresentable
        }
    }
}

extension WorkspaceTabMember {
    var isInWorkspaceTree: Bool {
        membership == .resident && state != .minimized && state != .notPresentable
    }
    var isPinResource: Bool { isInWorkspaceTree && attachment?.hasLiveParent != true }
    var isEphemeral: Bool { state == .floating && attachment?.role.isEphemeral == true }
}
