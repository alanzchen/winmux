import AppKit
import SwiftUI

// The hints and the other display's list, as a drag shows them. Both only ever take a drag's
// pointer: their panels ignore the mouse, and nothing in them selects, edits or watches anything.

/// The hints' state, published only when a hint's look changes.
struct WorkspaceSidebarDropDestinationHintsContent: Equatable {
    var hints: [WorkspaceSidebarDropDestinationHint] = []
    /// Each hint's frame in the strip, unscrolled, top-left origin.
    var frames: [CGRect] = []
    var armingId: String?
    var openId: String?
    /// With no room for a list, the hints say so and none opens.
    var columnFits = true
    var isRow = false
    var offset: CGFloat = 0
}

@MainActor
final class WorkspaceSidebarDropDestinationHintsModel: ObservableObject {
    @Published private(set) var content = WorkspaceSidebarDropDestinationHintsContent()

    func set(_ next: WorkspaceSidebarDropDestinationHintsContent) {
        if content != next { content = next }
    }
}

struct WorkspaceSidebarDropDestinationHintsView: View {
    @ObservedObject var model: WorkspaceSidebarDropDestinationHintsModel

    var body: some View {
        let content = model.content
        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(content.hints, content.frames)), id: \.0.id) { hint, frame in
                WorkspaceSidebarDropDestinationHintCard(hint: hint, isArming: content.armingId == hint.id,
                    isOpen: content.openId == hint.id, columnFits: content.columnFits)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX - (content.isRow ? content.offset : 0),
                        y: frame.minY - (content.isRow ? 0 : content.offset))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

struct WorkspaceSidebarDropDestinationHintCard: View {
    let hint: WorkspaceSidebarDropDestinationHint
    let isArming: Bool
    let isOpen: Bool
    let columnFits: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
        let isLit = isArming || isOpen
        HStack(spacing: 6) {
            Text(hint.direction.arrow).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(hint.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if !columnFits {
                    Text("Not enough room").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .foregroundStyle(isLit ? Color.accentColor : Color.primary.opacity(0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            shape.fill(.regularMaterial)
                .overlay { shape.fill(Color.accentColor.opacity(isOpen ? 0.18 : isArming ? 0.1 : 0)) }
        }
        .overlay {
            shape.strokeBorder(isLit ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.25),
                style: StrokeStyle(lineWidth: 1, dash: isLit ? [] : [4, 3]))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop on \(hint.name)")
    }
}

@MainActor
final class WorkspaceSidebarDropDestinationColumnModel: ObservableObject {
    @Published private(set) var snapshot: WorkspaceSidebarDropDestinationSnapshot?

    @discardableResult
    func set(_ next: WorkspaceSidebarDropDestinationSnapshot?) -> Bool {
        guard snapshot != next else { return false }
        snapshot = next
        return true
    }
}

/// The list's scroll position, apart from its content, so scrolling redraws only the scroll view.
@MainActor
final class WorkspaceSidebarDropDestinationScrollModel: ObservableObject {
    @Published var offset: CGFloat = 0
    /// Measured by the list, not published.
    private(set) var contentHeight: CGFloat = 0
    private(set) var viewportHeight: CGFloat = 0

    var maxOffset: CGFloat { max(contentHeight - viewportHeight, 0) }

    /// A list that got shorter, or a view that got taller, doesn't stay scrolled past its end.
    func measure(contentHeight: CGFloat? = nil, viewportHeight: CGFloat? = nil) {
        if let contentHeight { self.contentHeight = contentHeight }
        if let viewportHeight { self.viewportHeight = viewportHeight }
        if offset > maxOffset { offset = maxOffset }
    }
}

private struct WorkspaceSidebarDropDestinationContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

let workspaceSidebarDropDestinationHeaderHeight: CGFloat = 44

/// Another display's list: its tabs in Tabs mode, else its workspaces. The drop targets are the
/// sidebar's own, named for that display.
struct WorkspaceSidebarDropDestinationView: View {
    @ObservedObject var model: WorkspaceSidebarDropDestinationColumnModel
    let scroll: WorkspaceSidebarDropDestinationScrollModel
    /// The targets, with the surface of the list they were laid out for.
    let onTargets: @MainActor (WorkspaceSidebarSurfaceRef, [WorkspaceSidebarDropTargetFrame]) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 0) {
                    WorkspaceSidebarDropDestinationHeader(snapshot: snapshot)
                        .frame(height: workspaceSidebarDropDestinationHeaderHeight)
                    WorkspaceSidebarDropDestinationScrollView(scroll: scroll) {
                        if snapshot.usesTabsList {
                            WorkspaceSidebarDropDestinationTabsList(snapshot: snapshot)
                        } else {
                            WorkspaceSidebarDropDestinationWorkspaceList(snapshot: snapshot)
                        }
                    }
                }
                .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { [surface = snapshot.surface] in
                    onTargets(surface, $0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { shape.fill(.regularMaterial) }
        .overlay { shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 1) }
        .clipShape(shape)
        .coordinateSpace(name: "workspaceSidebarContent")
    }
}

struct WorkspaceSidebarDropDestinationHeader: View {
    let snapshot: WorkspaceSidebarDropDestinationSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Text(snapshot.hint.direction.arrow).font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.hint.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let project = snapshot.project {
                    Text([project.emoji, project.displayName].compactMap(\.self).joined(separator: " "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

/// A clipped view whose content moves by the scroll model's offset, not a `ScrollView`: the drop
/// targets' frames move with it exactly, and it scrolls only when the drag reaches its edges.
struct WorkspaceSidebarDropDestinationScrollView<Content: View>: View {
    @ObservedObject var scroll: WorkspaceSidebarDropDestinationScrollModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { viewport in
            content()
                .frame(width: viewport.size.width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { measured in
                        Color.clear.preference(key: WorkspaceSidebarDropDestinationContentHeightKey.self,
                            value: measured.size.height)
                    }
                }
                .offset(y: -scroll.offset)
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                .clipped()
                // Rows scrolled out of view take no drops.
                .transformPreference(WorkspaceSidebarDropTargetPreferenceKey.self) { targets in
                    targets = workspaceSidebarClippedDropTargets(targets,
                        to: viewport.frame(in: .named("workspaceSidebarContent")))
                }
                .onPreferenceChange(WorkspaceSidebarDropDestinationContentHeightKey.self) { height in
                    scroll.measure(contentHeight: height, viewportHeight: viewport.size.height)
                }
                .onAppear { scroll.measure(viewportHeight: viewport.size.height) }
                .onChange(of: viewport.size.height) { scroll.measure(viewportHeight: $0) }
        }
    }
}

/// Tabs mode: the display's pins, New Tab, its tabs and groups, and the space after them.
struct WorkspaceSidebarDropDestinationTabsList: View {
    let snapshot: WorkspaceSidebarDropDestinationSnapshot

    private var preview: WorkspaceSidebarDropPreviewViewModel? { snapshot.projection.dropPreview }
    private var scope: String { snapshot.monitorScopeId }
    private var projectId: WorkspaceProjectId { snapshot.projectId }

    var body: some View {
        let pins = snapshot.pins
        let sections = snapshot.tabSections
        let tailGap = workspaceSidebarTabsTailGap(sections: sections, lastPin: pins.last?.name)
        VStack(alignment: .leading, spacing: 0) {
            if pins.isEmpty {
                WorkspaceSidebarTabsPinDropZone(projectId: projectId, monitorScopeId: scope, hasPins: false,
                    isDropTarget: preview?.targetsPinned == true && preview?.targetProjectId == projectId)
                    .frame(height: 36)
                    .padding(.bottom, 6)
            } else {
                pinnedGrid(pins)
            }
            VStack(alignment: .leading, spacing: 2) {
                WorkspaceSidebarTabNewWorkspaceRow(projectId: projectId, monitorScopeId: scope,
                    isDropTarget: preview?.targetsNewWorkspace == true && preview?.targetProjectId == projectId,
                    onCreate: {})
                ForEach(sections) { section in
                    switch section {
                        case .tab(let workspace):
                            tabEntry(workspace, collectionId: nil)
                        case .collection(let group, let workspaces):
                            collection(group, workspaces: workspaces)
                    }
                }
            }
            if let tailGap {
                WorkspaceSidebarTabsTailDropZone(
                    target: .tabGap(projectId: projectId, monitorScopeId: scope, gap: tailGap.gap),
                    showsLine: tailGap.drawsOwnLine && preview?.targetGap == tailGap.gap && preview?.targetProjectId == projectId,
                    label: preview?.separatesFromTab == true ? "New Tab" : nil)
                    .frame(height: max(workspaceSidebarTabRowHeight * 2, 60))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func pinnedGrid(_ pins: [WorkspaceSidebarWorkspaceViewModel]) -> some View {
        let grid = WorkspaceSidebarPinnedGridLayout(workspaces: pins, width: snapshot.width - 16)
        return WorkspaceSidebarPinnedGrid(columns: grid.columns) {
            ForEach(pins) { workspace in
                WorkspaceSidebarPinnedTab(workspace: workspace, badgeModel: .shared, targetMonitorScopeId: scope,
                    insertionEdge: workspaceSidebarPinnedInsertionEdge(preview, workspaceName: workspace.name,
                        projectId: projectId, monitorScopeId: scope),
                    isDropTarget: preview?.targetWorkspaceName == workspace.name,
                    dropPlacement: preview?.targetPlacement, dropLabelSlot: preview?.targetLabelSlot) { _ in }
            }
        }
        .background {
            GeometryReader { content in
                Color.clear.preference(key: WorkspaceSidebarDropTargetPreferenceKey.self,
                    value: workspaceSidebarPinnedDropTargets(names: pins.map(\.name), projectId: projectId,
                        monitorScopeId: scope, frame: content.frame(in: .named("workspaceSidebarContent")),
                        columns: grid.columns))
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func tabEntry(_ workspace: WorkspaceSidebarWorkspaceViewModel, collectionId: String?) -> some View {
        let presentation = workspaceSidebarTabPresentation(workspace)
        let insertionEdge = workspaceSidebarTabInsertionEdge(preview, workspaceName: workspace.name,
            collectionId: collectionId, projectId: projectId)
        let insertionLabel = insertionEdge != nil && preview?.separatesFromTab == true ? "New Tab" : nil
        if presentation == .folder {
            WorkspaceSidebarDropDestinationFolderRow(workspace: workspace,
                isDropTarget: preview?.targetWorkspaceName == workspace.name, insertionEdge: insertionEdge,
                gapTarget: (projectId, scope), collectionId: collectionId)
        } else {
            WorkspaceSidebarTabCardView(
                workspace: workspace,
                presentation: presentation,
                isActive: workspaceSidebarTabIsActive(workspace, on: scope),
                isDropTarget: preview?.targetWorkspaceName == workspace.name,
                dragSourceWindowId: preview?.sourceWindowId,
                selectedSearchTarget: nil,
                activation: .init(allowsActivation: false, isInUseOnOtherDisplay: false, requestOverride: {}),
                isShowingOverride: false,
                overrideMinHeight: 0,
                actions: WorkspaceSidebarActions(),
                dropPlacement: preview?.targetPlacement,
                dropLabelSlot: preview?.targetLabelSlot,
                insertionEdge: insertionEdge,
                insertionLabel: insertionLabel,
                gapTarget: (projectId, scope),
                collectionId: collectionId,
                showsNowPlaying: false,
                onBeginRename: {},
                onCommitOverride: {},
                onCancelOverride: {},
            )
        }
    }

    private func collection(_ group: WorkspaceTabCollection, workspaces: [WorkspaceSidebarWorkspaceViewModel]) -> some View {
        let color = group.colorHex.flatMap(workspaceSidebarColor)
        // Collapsed as on the display, unless its tab on screen there keeps it open.
        let disclosure = WorkspaceSidebarTabCollectionDisclosure(group: group,
            containsActiveTab: workspaces.contains { $0.isVisible && $0.monitorScopeId == scope })
        let isDropTarget = preview?.targetCollectionId == group.id && workspaceSidebarDropPreview(preview, targetsList: scope)
        return WorkspaceSidebarTabGroupCard(tint: color, isExpanded: !disclosure.isCollapsed, isDropTarget: isDropTarget) {
            WorkspaceSidebarTabCollectionHeader(group: group, workspaces: workspaces, tint: color, disclosure: disclosure,
                badgeModel: .shared) {}
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: WorkspaceSidebarDropTargetPreferenceKey.self,
                            value: [.init(kind: .tabCollection(group.id, monitorScopeId: scope),
                                frame: geometry.frame(in: .named("workspaceSidebarContent")))])
                    }
                }
        } content: {
            if !disclosure.isCollapsed {
                ForEach(workspaces) { workspace in tabEntry(workspace, collectionId: group.id) }
            }
        }
    }
}

/// A tab shown as a folder, a stack or a tab with a group in it: one row that takes drops as a tab does.
struct WorkspaceSidebarDropDestinationFolderRow: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let isDropTarget: Bool
    let insertionEdge: VerticalEdge?
    let gapTarget: (projectId: WorkspaceProjectId, monitorScopeId: String)
    let collectionId: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
        HStack(spacing: 9) {
            Image(systemName: "folder").font(.system(size: 12)).frame(width: workspaceSidebarTabIconSize)
            Text(workspace.displayName).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Text("\(workspaceSidebarTabWindowCount(workspace))").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, workspaceSidebarTabLeadingPadding)
        .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, alignment: .leading)
        .background { shape.fill(Color.accentColor.opacity(isDropTarget ? 0.14 : 0)) }
        .overlay(alignment: insertionEdge == .bottom ? .bottom : .top) {
            if insertionEdge != nil { WorkspaceSidebarTabInsertionLine(edge: insertionEdge, label: nil) }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: WorkspaceSidebarDropTargetPreferenceKey.self,
                    value: workspaceSidebarTabDropTargets(workspaceName: workspace.name,
                        frame: geometry.frame(in: .named("workspaceSidebarContent")), gapTarget: gapTarget,
                        collectionId: collectionId))
            }
        }
    }
}

/// Sidebar and Dock: the display's workspaces, each taking a dropped window, then New Workspace.
struct WorkspaceSidebarDropDestinationWorkspaceList: View {
    let snapshot: WorkspaceSidebarDropDestinationSnapshot

    var body: some View {
        let preview = snapshot.projection.dropPreview
        VStack(alignment: .leading, spacing: 2) {
            ForEach(snapshot.workspaces) { workspace in
                WorkspaceSidebarDropDestinationWorkspaceRow(workspace: workspace,
                    isDropTarget: preview?.targetWorkspaceName == workspace.name && preview?.targetsNewWorkspace != true)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: WorkspaceSidebarDropTargetPreferenceKey.self,
                                value: [.init(kind: .workspace(workspace.name),
                                    frame: geometry.frame(in: .named("workspaceSidebarContent")))])
                        }
                    }
            }
            WorkspaceSidebarDropDestinationNewWorkspaceRow(projectId: snapshot.projectId,
                monitorScopeId: snapshot.monitorScopeId,
                isDropTarget: preview?.targetsNewWorkspace == true
                    && (preview?.targetProjectId == nil || preview?.targetProjectId == snapshot.projectId))
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

/// Sidebar and Dock: a dropped window gets a new workspace on that display.
struct WorkspaceSidebarDropDestinationNewWorkspaceRow: View {
    let projectId: WorkspaceProjectId
    let monitorScopeId: String
    let isDropTarget: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
            Text("New Workspace").font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.primary.opacity(isDropTarget ? 0.8 : 0.45))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, alignment: .leading)
        .background {
            shape.fill(isDropTarget ? Color.accentColor.opacity(0.14) : .clear)
                .overlay { shape.strokeBorder(Color.accentColor.opacity(isDropTarget ? 0.65 : 0), lineWidth: 1) }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: WorkspaceSidebarDropTargetPreferenceKey.self,
                    value: [.init(kind: .newWorkspace(projectId: projectId, monitorScopeId: monitorScopeId),
                        frame: geometry.frame(in: .named("workspaceSidebarContent")))])
            }
        }
        .accessibilityLabel("New Workspace")
    }
}

struct WorkspaceSidebarDropDestinationWorkspaceRow: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let isDropTarget: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(workspace.displayName).font(.system(size: 13, weight: workspace.isVisible ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            if !workspace.apps.isEmpty {
                HStack(spacing: 4) {
                    ForEach(workspace.apps.prefix(8)) { app in
                        WorkspaceSidebarTabIcon(bundleId: app.bundleId, bundlePath: app.bundlePath, size: 16)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(isDropTarget ? Color.accentColor.opacity(0.14) : Color.primary.opacity(workspace.isVisible ? 0.06 : 0))
                .overlay { shape.strokeBorder(Color.accentColor.opacity(isDropTarget ? 0.65 : 0), lineWidth: 1) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workspace.displayName)
    }
}
