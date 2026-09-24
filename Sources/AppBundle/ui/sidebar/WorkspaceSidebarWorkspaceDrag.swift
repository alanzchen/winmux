import AppKit
import SwiftUI
import UniformTypeIdentifiers

// A distinct type keeps whole-workspace moves out of window/tab-group drop handlers.
let workspaceSidebarWorkspaceDragType = "dev.winmux.sidebar-workspace"

struct WorkspaceSidebarWorkspaceDragPayload: Codable, Equatable, Sendable {
    let workspaceName: String
    private let kind: String

    init(workspaceName: String) {
        self.workspaceName = workspaceName
        kind = workspaceSidebarWorkspaceDragType
    }

    var pasteboardItem: NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(workspaceSidebarWorkspaceDragType))
        // SwiftUI's AppKit bridge drops unregistered custom types in SwiftPM executables.
        // The tagged data fallback is accepted only while our native workspace drag is active.
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.data.identifier))
        return item
    }

    var itemProvider: NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: workspaceSidebarWorkspaceDragType,
                                            visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func load(from provider: NSItemProvider, completion: @escaping @MainActor (Self) -> Void) {
        WorkspaceSidebarNativeDragItem.load(from: provider) { item in
            if case .workspace(let workspaceName) = item { completion(Self(workspaceName: workspaceName)) }
        }
    }
}

// Project column headers drag their project to reorder the columns.
let workspaceSidebarProjectDragType = "dev.winmux.sidebar-project"

struct WorkspaceSidebarProjectDragPayload: Codable, Equatable, Sendable {
    let projectId: String
    private let kind: String

    init(projectId: WorkspaceProjectId) {
        self.projectId = projectId.rawValue
        kind = workspaceSidebarProjectDragType
    }

    var pasteboardItem: NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(workspaceSidebarProjectDragType))
        // Accepted only while our native drag is active, like the workspace fallback.
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.data.identifier))
        return item
    }
}

/// A native sidebar drag, identified by its payload's kind tag.
enum WorkspaceSidebarNativeDragItem: Equatable, Sendable {
    case workspace(String)
    case project(WorkspaceProjectId)

    static let typeIdentifiers = [workspaceSidebarWorkspaceDragType, workspaceSidebarProjectDragType]

    static func decode(_ data: Data) -> Self? {
        struct Tagged: Decodable {
            let kind: String
            let workspaceName: String?
            let projectId: String?
        }
        guard let tagged = try? JSONDecoder().decode(Tagged.self, from: data) else { return nil }
        switch tagged.kind {
            case workspaceSidebarWorkspaceDragType:
                guard let name = tagged.workspaceName, !name.isEmpty else { return nil }
                return .workspace(name)
            case workspaceSidebarProjectDragType:
                guard let id = tagged.projectId, !id.isEmpty else { return nil }
                return .project(WorkspaceProjectId(id))
            default:
                return nil
        }
    }

    static func load(from provider: NSItemProvider, completion: @escaping @MainActor (Self) -> Void) {
        let type = typeIdentifiers.first { provider.hasItemConformingToTypeIdentifier($0) } ?? UTType.data.identifier
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let item = decode(data) else { return }
            Task { @MainActor in completion(item) }
        }
    }
}

struct WorkspaceSidebarProjectDropDelegate: DropDelegate {
    let projectId: WorkspaceProjectId
    let actions: WorkspaceSidebarActions
    @Binding var isTargeted: Bool
    var onWorkspaceDrop: @MainActor () -> Void = {}
    /// Side-by-side project columns of this width also reorder dragged project headers.
    var reorderWidth: CGFloat? = nil
    /// Whether a dragged project lands after this one; nil while no project is over it.
    var insertsProjectAfter: Binding<Bool?> = .constant(nil)

    func validateDrop(info: DropInfo) -> Bool {
        if let draggedProjectId = workspaceSidebarDraggedProjectId() {
            return reorderWidth != nil && draggedProjectId != projectId
        }
        return info.hasItemsConforming(to: [workspaceSidebarWorkspaceDragType]) ||
            (isWorkspaceSidebarNativeWorkspaceDragActive() && info.hasItemsConforming(to: [UTType.data]))
    }

    func dropEntered(info: DropInfo) {
        if workspaceSidebarDraggedProjectId() != nil {
            insertsProjectAfter.wrappedValue = insertsAfter(info: info)
        } else {
            isTargeted = true
        }
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        insertsProjectAfter.wrappedValue = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if workspaceSidebarDraggedProjectId() != nil {
            insertsProjectAfter.wrappedValue = insertsAfter(info: info)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let after = insertsAfter(info: info)
        dropExited(info: info)
        guard let provider = info.itemProviders(for: WorkspaceSidebarNativeDragItem.typeIdentifiers).first ??
            info.itemProviders(for: [UTType.data]).first else { return false }
        return performDrop(provider: provider, insertsProjectAfter: after)
    }

    func performDrop(provider: NSItemProvider, insertsProjectAfter after: Bool = false) -> Bool {
        guard WorkspaceSidebarNativeDragItem.typeIdentifiers.contains(where: provider.hasItemConformingToTypeIdentifier) ||
            (isWorkspaceSidebarNativeWorkspaceDragActive() && provider.hasItemConformingToTypeIdentifier(UTType.data.identifier))
        else { return false }
        let reorders = reorderWidth != nil
        WorkspaceSidebarNativeDragItem.load(from: provider) { item in
            switch item {
                case .workspace(let workspaceName):
                    onWorkspaceDrop()
                    actions.send(.moveWorkspace(workspaceName, toProject: projectId))
                case .project(let draggedProjectId):
                    guard reorders, draggedProjectId != projectId else { return }
                    actions.send(.moveProject(draggedProjectId, relativeTo: projectId, after: after))
            }
        }
        return true
    }

    private func insertsAfter(info: DropInfo) -> Bool {
        guard let reorderWidth else { return false }
        return info.location.x > reorderWidth / 2
    }
}

struct WorkspaceSidebarProjectDropModifier: ViewModifier {
    let projectId: WorkspaceProjectId
    let actions: WorkspaceSidebarActions
    var onWorkspaceDrop: @MainActor () -> Void = {}
    var reorderWidth: CGFloat? = nil
    @ObservedObject private var nativeDrag = WorkspaceSidebarNativeDragState.shared
    @State private var isTargeted = false
    @State private var insertsProjectAfter: Bool?

    func body(content: Content) -> some View {
        let delegate = WorkspaceSidebarProjectDropDelegate(projectId: projectId, actions: actions, isTargeted: $isTargeted,
            onWorkspaceDrop: onWorkspaceDrop, reorderWidth: reorderWidth, insertsProjectAfter: $insertsProjectAfter)
        return content
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(isTargeted ? 0.10 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(isTargeted ? 0.5 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: insertsProjectAfter == true ? .trailing : .leading) {
                // The insertion bar sits in the gap on the side where the dragged project lands.
                if let insertsProjectAfter {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 3)
                        .offset(x: (insertsProjectAfter ? 1 : -1) * (workspaceSidebarProjectColumnGap / 2 + 1.5))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.data], delegate: delegate)
            .overlay {
                // A workspace row's own drop target accepts windows only, and SwiftUI does not pass
                // other drags on to this one. While a workspace or project is dragged, cover the rows.
                if nativeDrag.isActive {
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrop(of: [UTType.data], delegate: delegate)
                        .onTapGesture { recoverStaleWorkspaceSidebarNativeWorkspaceDrag() }
                }
            }
            .onChange(of: nativeDrag.isActive) { isActive in
                // SwiftUI can deliver a last update after the drop; the ended drag clears it.
                guard !isActive else { return }
                isTargeted = false
                insertsProjectAfter = nil
            }
    }
}
