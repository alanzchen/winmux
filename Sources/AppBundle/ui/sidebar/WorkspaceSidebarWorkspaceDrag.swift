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
        let type = provider.hasItemConformingToTypeIdentifier(workspaceSidebarWorkspaceDragType)
            ? workspaceSidebarWorkspaceDragType : UTType.data.identifier
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let payload = try? JSONDecoder().decode(Self.self, from: data),
                  payload.kind == workspaceSidebarWorkspaceDragType, !payload.workspaceName.isEmpty else { return }
            Task { @MainActor in completion(payload) }
        }
    }
}

struct WorkspaceSidebarProjectDropDelegate: DropDelegate {
    let projectId: WorkspaceProjectId
    let actions: WorkspaceSidebarActions
    @Binding var isTargeted: Bool
    var onWorkspaceDrop: @MainActor () -> Void = {}

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [workspaceSidebarWorkspaceDragType]) ||
            (isWorkspaceSidebarNativeWorkspaceDragActive() && info.hasItemsConforming(to: [UTType.data]))
    }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let provider = info.itemProviders(for: [workspaceSidebarWorkspaceDragType]).first ??
            info.itemProviders(for: [UTType.data]).first else { return false }
        return performDrop(provider: provider)
    }

    func performDrop(provider: NSItemProvider) -> Bool {
        guard provider.hasItemConformingToTypeIdentifier(workspaceSidebarWorkspaceDragType) ||
            (isWorkspaceSidebarNativeWorkspaceDragActive() && provider.hasItemConformingToTypeIdentifier(UTType.data.identifier))
        else { return false }
        WorkspaceSidebarWorkspaceDragPayload.load(from: provider) { payload in
            onWorkspaceDrop()
            actions.send(.moveWorkspace(payload.workspaceName, toProject: projectId))
        }
        return true
    }
}

struct WorkspaceSidebarProjectDropModifier: ViewModifier {
    let projectId: WorkspaceProjectId
    let actions: WorkspaceSidebarActions
    var onWorkspaceDrop: @MainActor () -> Void = {}
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
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
            .onDrop(of: [UTType.data], delegate: WorkspaceSidebarProjectDropDelegate(
                projectId: projectId, actions: actions, isTargeted: $isTargeted, onWorkspaceDrop: onWorkspaceDrop))
    }
}
