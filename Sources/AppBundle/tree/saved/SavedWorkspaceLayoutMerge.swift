import AppKit
import Common

/// The container normalizations WinMux applies to live trees (see normalizeContainers.swift).
struct SavedLayoutNormalization: Equatable, Sendable {
    var flatten: Bool
    var oppositeOrientation: Bool

    @MainActor
    static var current: SavedLayoutNormalization {
        SavedLayoutNormalization(
            flatten: config.enableNormalizationFlattenContainers,
            oppositeOrientation: config.enableNormalizationOppositeOrientationForNestedContainers,
        )
    }
}

struct SavedLayoutMergeContext {
    /// Slots whose windows are in this workspace's tiling tree.
    var liveTiled: Set<String>
    /// Slots whose windows float in this workspace.
    var liveFloating: Set<String>
    /// Whether a slot whose window is not in the workspace keeps waiting for it.
    var keep: (SavedWindowSlot) -> Bool
    var normalization: SavedLayoutNormalization
}

/// Folds the live layout into the saved one without losing the positions of windows the
/// workspace is waiting for (their app quit, the Mac restarted, ...).
///
/// - No waiting slots: the live layout is the saved layout.
/// - The live tree is what the saved tree looks like without its waiting slots (after the same
///   normalizations WinMux applies): nothing was restructured, so the saved tree stays as it is,
///   nested containers and tab groups included, and only picks up live titles and sizes.
/// - Otherwise the user restructured the workspace: the live tree wins and each waiting unit
///   goes back next to the sibling it followed (or preceded) before.
func mergeSavedLayout(
    previous: SavedWorkspaceLayout,
    live: SavedWorkspaceLayout,
    context: SavedLayoutMergeContext,
) -> SavedWorkspaceLayout {
    let liveSlotById = Dictionary(live.allSlots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let isLive = { (slot: SavedWindowSlot) in context.liveTiled.contains(slot.id) || context.liveFloating.contains(slot.id) }

    // 1. The saved tree minus slots that moved to the floating layer or stopped waiting.
    let kept = pruneEmptyContainers(filterSlots(previous.root) { slot in
        if context.liveFloating.contains(slot.id) { return false }
        return context.liveTiled.contains(slot.id) || context.keep(slot)
    }, isRoot: true) ?? SavedLayoutContainer(layout: previous.root.layout, orientation: previous.root.orientation)
    let waiting = Set(kept.allSlots.map(\.id).filter { !context.liveTiled.contains($0) })

    let root: SavedLayoutContainer
    if waiting.isEmpty {
        root = live.root
    } else {
        let projection = pruneEmptyContainers(filterSlots(kept) { !waiting.contains($0.id) }, isRoot: true)
            ?? SavedLayoutContainer(layout: kept.layout, orientation: kept.orientation)
        let normalizedProjection = normalizeSavedLayout(projection, context.normalization)
        let normalizedLive = normalizeSavedLayout(live.root, context.normalization)
        if savedLayoutShapeEqual(.container(normalizedProjection), .container(normalizedLive)) {
            root = copyLiveWeights(copyLiveSlotData(kept, liveSlotById), liveBySlotSet: containersBySlotSet(live.root), waiting: waiting)
        } else {
            root = reinsertWaitingUnits(kept: kept, live: live.root, waiting: waiting)
        }
    }

    // Floating windows: kept order, then new ones.
    var floating = previous.floating.compactMap { slot -> SavedWindowSlot? in
        if context.liveTiled.contains(slot.id) { return nil }
        if context.liveFloating.contains(slot.id) { return liveSlotById[slot.id] ?? slot }
        return context.keep(slot) ? slot : nil
    }
    let floatingIds = Set(floating.map(\.id))
    floating += live.floating.filter { !floatingIds.contains($0.id) }

    var result = SavedWorkspaceLayout(root: root, floating: floating)
    let slotCount = result.allSlots.count
    if slotCount > savedWorkspaceMaxSlotsPerWorkspace {
        let excess = slotCount - savedWorkspaceMaxSlotsPerWorkspace
        let droppable = result.allSlots.reversed().filter { !isLive($0) }.prefix(excess).map(\.id).toSet()
        result.root = pruneEmptyContainers(filterSlots(result.root) { !droppable.contains($0.id) }, isRoot: true) ?? result.root
        result.floating = result.floating.filter { !droppable.contains($0.id) }
    }
    return result
}

// MARK: - Tree helpers

func filterSlots(_ container: SavedLayoutContainer, _ keep: (SavedWindowSlot) -> Bool) -> SavedLayoutContainer {
    var result = container
    result.children = container.children.compactMap { child in
        switch child {
            case .slot(let slot): keep(slot) ? child : nil
            case .container(let nested): .container(filterSlots(nested, keep))
        }
    }
    return result
}

/// Removes empty non-root containers. Returns nil when the container itself is empty and not
/// the root.
func pruneEmptyContainers(_ container: SavedLayoutContainer, isRoot: Bool) -> SavedLayoutContainer? {
    var result = container
    result.children = container.children.compactMap { child in
        switch child {
            case .slot: child
            case .container(let nested): pruneEmptyContainers(nested, isRoot: false).map(SavedLayoutNode.container)
        }
    }
    return result.children.isEmpty && !isRoot ? nil : result
}

/// Emulates `unbindEmptyAndAutoFlatten` and `normalizeOppositeOrientationForNestedContainers`.
func normalizeSavedLayout(_ root: SavedLayoutContainer, _ normalization: SavedLayoutNormalization) -> SavedLayoutContainer {
    var current = root
    for _ in 0 ..< 16 {
        var next = flattenSavedRoot(current, flatten: normalization.flatten)
        if normalization.oppositeOrientation {
            next = normalizeSavedOrientation(next, parentOrientation: nil)
        }
        if next == current { break }
        current = next
    }
    return current
}

private func flattenSavedRoot(_ root: SavedLayoutContainer, flatten: Bool) -> SavedLayoutContainer {
    // A root with a single container child is replaced by that child.
    if flatten, root.children.count == 1, case .container(let child) = root.children[0] {
        var promoted = child
        promoted.weight = root.weight
        return flattenSavedRoot(promoted, flatten: flatten)
    }
    var result = root
    result.children = root.children.compactMap { flattenSavedNode($0, flatten: flatten) }
    return result
}

private func flattenSavedNode(_ node: SavedLayoutNode, flatten: Bool) -> SavedLayoutNode? {
    guard case .container(let container) = node else { return node }
    var result = container
    result.children = container.children.compactMap { flattenSavedNode($0, flatten: flatten) }
    if result.children.isEmpty { return nil }
    if flatten, result.children.count == 1 {
        return result.children[0].withWeight(container.weight)
    }
    return .container(result)
}

private func normalizeSavedOrientation(_ container: SavedLayoutContainer, parentOrientation: Orientation?) -> SavedLayoutContainer {
    var result = container
    if result.orientation == parentOrientation {
        result.orientation = result.orientation.opposite
    }
    result.children = container.children.map { child in
        guard case .container(let nested) = child else { return child }
        return .container(normalizeSavedOrientation(nested, parentOrientation: result.orientation))
    }
    return result
}

/// Structural equality: layouts, orientations, child order and slot ids. Weights are ignored.
func savedLayoutShapeEqual(_ lhs: SavedLayoutNode, _ rhs: SavedLayoutNode) -> Bool {
    switch (lhs, rhs) {
        case (.slot(let a), .slot(let b)):
            return a.id == b.id
        case (.container(let a), .container(let b)):
            guard a.layout == b.layout, a.orientation == b.orientation, a.children.count == b.children.count else { return false }
            return zip(a.children, b.children).allSatisfy { savedLayoutShapeEqual($0, $1) }
        default:
            return false
    }
}

private func slotIds(_ node: SavedLayoutNode, excluding: Set<String> = []) -> Set<String> {
    node.allSlots.map(\.id).filter { !excluding.contains($0) }.toSet()
}

/// Copies titles and window identities of live slots. Weights are handled separately because a
/// live slot's weight is relative to its live parent, which may be a different container.
private func copyLiveSlotData(_ container: SavedLayoutContainer, _ liveSlotById: [String: SavedWindowSlot]) -> SavedLayoutContainer {
    var result = container
    result.children = container.children.map { child in
        switch child {
            case .slot(let slot):
                guard var live = liveSlotById[slot.id] else { return child }
                live.weight = slot.weight
                return .slot(live)
            case .container(let nested):
                return .container(copyLiveSlotData(nested, liveSlotById))
        }
    }
    return result
}

private func containersBySlotSet(_ root: SavedLayoutContainer) -> [Set<String>: SavedLayoutContainer] {
    var result: [Set<String>: SavedLayoutContainer] = [:]
    func visit(_ container: SavedLayoutContainer) {
        let ids = slotIds(.container(container))
        if !ids.isEmpty, result[ids] == nil {
            result[ids] = container
        }
        for case .container(let nested) in container.children {
            visit(nested)
        }
    }
    visit(root)
    return result
}

/// A saved container whose live windows form exactly one live container takes that container's
/// child weights. Containers flattened away in the live tree keep their saved weights.
private func copyLiveWeights(
    _ container: SavedLayoutContainer,
    liveBySlotSet: [Set<String>: SavedLayoutContainer],
    waiting: Set<String>,
) -> SavedLayoutContainer {
    var result = container
    let liveIds = slotIds(.container(container), excluding: waiting)
    if !liveIds.isEmpty, let liveContainer = liveBySlotSet[liveIds] {
        var liveChildBySlotSet: [Set<String>: SavedLayoutNode] = [:]
        for child in liveContainer.children {
            liveChildBySlotSet[slotIds(child)] = child
        }
        let hasLiveMostRecent = liveContainer.children.contains(where: \.isMostRecentInParent)
        result.children = result.children.map { child in
            let ids = slotIds(child, excluding: waiting)
            guard !ids.isEmpty, let liveChild = liveChildBySlotSet[ids] else {
                return hasLiveMostRecent ? child.withMostRecentInParent(false) : child
            }
            return child.withWeight(liveChild.weight).withMostRecentInParent(liveChild.isMostRecentInParent)
        }
    }
    result.children = result.children.map { child in
        guard case .container(let nested) = child else { return child }
        return .container(copyLiveWeights(nested, liveBySlotSet: liveBySlotSet, waiting: waiting))
    }
    return result
}

// MARK: - Reinsertion after a restructure

private final class SavedMergeNode {
    var slot: SavedWindowSlot?
    var layout: Layout = .tiles
    var orientation: Orientation = .h
    var weight: CGFloat = 1
    var isMostRecentInParent = false
    var children: [SavedMergeNode] = []
    weak var parent: SavedMergeNode?

    init(_ node: SavedLayoutNode) {
        switch node {
            case .slot(let slot):
                self.slot = slot
                weight = slot.weight
            case .container(let container):
                layout = container.layout
                orientation = container.orientation
                weight = container.weight
                isMostRecentInParent = container.isMostRecentInParent
                children = container.children.map(SavedMergeNode.init)
                for child in children { child.parent = self }
        }
    }

    func insert(_ child: SavedMergeNode, at index: Int) {
        child.parent = self
        children.insert(child, at: min(max(index, 0), children.count))
    }

    var ownIndex: Int? { parent?.children.firstIndex { $0 === self } }

    var ancestorsWithSelf: [SavedMergeNode] {
        var result: [SavedMergeNode] = []
        var current: SavedMergeNode? = self
        while let node = current {
            result.append(node)
            current = node.parent
        }
        return result
    }

    func slotNodesById() -> [String: SavedMergeNode] {
        var result: [String: SavedMergeNode] = [:]
        func visit(_ node: SavedMergeNode) {
            if let slot = node.slot { result[slot.id] = node }
            node.children.forEach(visit)
        }
        visit(self)
        return result
    }

    var asContainer: SavedLayoutContainer {
        SavedLayoutContainer(
            layout: layout,
            orientation: orientation,
            weight: weight,
            isMostRecentInParent: isMostRecentInParent,
            children: children.map(\.asNode),
        )
    }

    var asNode: SavedLayoutNode {
        if var slot {
            slot.weight = weight
            return .slot(slot)
        }
        return .container(asContainer)
    }
}

/// The lowest node containing all the given nodes.
private func lowestCommonAncestor(_ nodes: [SavedMergeNode]) -> SavedMergeNode? {
    guard let first = nodes.first else { return nil }
    var common = first.ancestorsWithSelf
    for node in nodes.dropFirst() {
        let ancestors = node.ancestorsWithSelf
        common = common.filter { candidate in ancestors.contains { $0 === candidate } }
    }
    return common.first
}

private func reinsertWaitingUnits(kept: SavedLayoutContainer, live: SavedLayoutContainer, waiting: Set<String>) -> SavedLayoutContainer {
    let result = SavedMergeNode(.container(live))
    let liveSlotNodes = result.slotNodesById()
    var insertedByPath: [[Int]: SavedMergeNode] = [:]

    /// Where a saved sibling sits in the result: the lowest node holding its live windows, or
    /// the node of a waiting unit reinserted earlier.
    func anchorNode(_ node: SavedLayoutNode, path: [Int]) -> SavedMergeNode? {
        if let inserted = insertedByPath[path] { return inserted }
        let nodes = node.allSlots.compactMap { waiting.contains($0.id) ? nil : liveSlotNodes[$0.id] }
        return lowestCommonAncestor(nodes)
    }

    func visit(_ container: SavedLayoutContainer, path: [Int]) {
        for (index, child) in container.children.enumerated() {
            let childPath = path + [index]
            let childIds = slotIds(child)
            let isWaitingUnit = !childIds.isEmpty && childIds.isSubset(of: waiting)
            guard isWaitingUnit else {
                if case .container(let nested) = child { visit(nested, path: childPath) }
                continue
            }
            let unit = SavedMergeNode(child)
            let siblings = container.children.enumerated()
            let left = siblings.filter { $0.offset < index }.reversed().lazy
                .compactMap { anchorNode($0.element, path: path + [$0.offset]) }.first
            let right = siblings.filter { $0.offset > index }.lazy
                .compactMap { anchorNode($0.element, path: path + [$0.offset]) }.first
            if let left {
                if let parent = left.parent, let leftIndex = left.ownIndex {
                    parent.insert(unit, at: leftIndex + 1)
                } else {
                    result.insert(unit, at: result.children.count)
                }
            } else if let right {
                if let parent = right.parent, let rightIndex = right.ownIndex {
                    parent.insert(unit, at: rightIndex)
                } else {
                    result.insert(unit, at: 0)
                }
            } else {
                result.insert(unit, at: result.children.count)
            }
            insertedByPath[childPath] = unit
        }
    }
    visit(kept, path: [])
    return result.asContainer
}
