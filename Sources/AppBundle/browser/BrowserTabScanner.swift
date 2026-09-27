import Foundation

struct BrowserTabAXStructure {
    let role: String
    let subrole: String
    var isTab: Bool { role == "AXRadioButton" && subrole == "AXTabButton" }
}

struct BrowserTabAXInfo {
    let title: String
    let selected: Bool
}

struct BrowserTabAXRecord<Node> {
    let structure: BrowserTabAXStructure
    let info: BrowserTabAXInfo
    let parent: Node
}

/// Small native boundary allows behavioral tests without reading live browsing data.
protocol BrowserTabAXNode: Equatable {
    func structure() -> BrowserTabAXStructure?
    func children() -> [Self]?
    func parent() -> Self?
    func window() -> Self?
    func tabInfo() -> BrowserTabAXInfo?
    func tabRecord() -> BrowserTabAXRecord<Self>?
    func press() -> Bool
}

extension BrowserTabAXNode {
    func tabRecord() -> BrowserTabAXRecord<Self>? {
        guard let structure = structure(), let info = tabInfo(), let parent = parent() else { return nil }
        return .init(structure: structure, info: info, parent: parent)
    }
}

/// Confined to the owning MacApp AX thread. No AX references escape in snapshots.
final class BrowserTabScanner<Node: BrowserTabAXNode> {
    let root: Node
    let adapter: BrowserTabAdapter
    let windowId: UInt32
    let pid: Int32
    let windowSession = UUID()
    private(set) var container: Node?
    private var lastDiscovery: TimeInterval = -.infinity
    private var handles: [(node: Node, id: UUID)] = []
    private let now: () -> TimeInterval
    private let isCancelled: () -> Bool
    private(set) var observedNodes: [Node] = []

    init(root: Node, adapter: BrowserTabAdapter, windowId: UInt32, pid: Int32,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         isCancelled: @escaping () -> Bool = { false }) {
        self.root = root
        self.adapter = adapter
        self.windowId = windowId
        self.pid = pid
        self.now = now
        self.isCancelled = isCancelled
        self.observedNodes = [root]
    }

    func scan(until budgetEnd: TimeInterval = .infinity, cancelled: () -> Bool = { false }) -> BrowserWindowTabs? {
        let started = now()
        guard started < budgetEnd, !isCancelled(), !cancelled() else { return nil }
        let discoveryDeadline = min(budgetEnd, started + 0.15)
        let candidate: Node
        var discovered = false
        if let container, started - lastDiscovery < 60, container.window() == root {
            candidate = container
        } else {
            container = nil
            guard let found = discover(deadline: discoveryDeadline, cancelled: cancelled) else { return nil }
            candidate = found
            discovered = true
            lastDiscovery = started
        }
        // A transient read or an unsupported native group doesn't invalidate the
        // container's ownership. Avoid rediscovering all browser chrome on retry.
        container = candidate
        if observedNodes.count < 2 || observedNodes[1] != candidate {
            observedNodes = [root, candidate]
        }
        guard let children = candidate.children(), !children.isEmpty, children.count <= 256 else {
            return nil
        }
        let deadline = min(budgetEnd, started + (discovered ? 0.15 : min(0.15, max(0.075, 0.05 + Double(children.count) * 0.001))))
        var next: [(node: Node, id: UUID)] = []
        var tabs: [BrowserTab] = []
        for child in children {
            guard !isCancelled(), !cancelled(), now() < deadline,
                  let record = child.tabRecord(), record.structure.isTab,
                  record.parent == candidate
            else {
                // A replaced container or a collapsed native tab group is not a
                // complete list. Don't retire identities or publish a partial scan.
                return nil
            }
            let id = handles.first { $0.node == child }?.id ?? UUID()
            next.append((child, id))
            tabs.append(.init(target: .init(windowId: windowId, pid: pid,
                windowSession: windowSession, tabId: id), title: browserTabDisplayTitle(record.info.title), isSelected: record.info.selected))
        }
        guard tabs.filter(\.isSelected).count == 1, now() < deadline, !isCancelled(), !cancelled() else { return nil }
        container = candidate
        handles = next
        // The selected control plus window/container notifications cover common
        // changes. Keep subscriptions bounded; polling reconciles background tabs.
        observedNodes = [root, candidate] + zip(next, tabs).filter { $0.1.isSelected }.map { $0.0.node }
        return .init(windowId: windowId, pid: pid, windowSession: windowSession, tabs: tabs)
    }

    func select(_ target: BrowserTabTarget, cancelled: () -> Bool = { false }) -> Bool {
        guard let (node, _) = validatedTab(target, until: now() + 0.2, cancelled: cancelled) else { return false }
        return node.press()
    }

    /// The full scan already established exactly one selection. Bookend the URL
    /// read with this exact control, without repeating every tab's IPC. Origin
    /// assignment still requires two complete, matching polls separated in time.
    func confirmsSelection(in snapshot: BrowserWindowTabs, until deadline: TimeInterval,
                           cancelled: () -> Bool = { false }) -> Bool {
        guard snapshot.tabs.filter(\.isSelected).count == 1, let selected = snapshot.tabs.first(where: \.isSelected),
              let (_, info) = validatedTab(selected.target, until: deadline, cancelled: cancelled)
        else { return false }
        return info.selected && browserTabDisplayTitle(info.title) == selected.title
    }

    private func validatedTab(_ target: BrowserTabTarget, until deadline: TimeInterval,
                              cancelled: () -> Bool) -> (Node, BrowserTabAXInfo)? {
        guard target.pid == pid, target.windowId == windowId, target.windowSession == windowSession,
              let handle = handles.first(where: { $0.id == target.tabId }), let container,
              !isCancelled(), !cancelled(), now() < deadline, container.window() == root, now() < deadline,
              let children = container.children(), children.contains(handle.node),
              !cancelled(), now() < deadline,
              let record = handle.node.tabRecord(), record.parent == container, record.structure.isTab,
              now() < deadline,
              handle.node.window() == root, now() < deadline, !isCancelled(), !cancelled()
        else { return nil }
        // Revalidate only this exact live control. A large tab strip must not make
        // an explicit selection depend on successfully rereading every other tab.
        return (handle.node, record.info)
    }

    private func discover(deadline: TimeInterval, cancelled: () -> Bool) -> Node? {
        var queue: [(Node, Int)] = [(root, 0)]
        var visited: [Node] = []
        var candidates: [Node] = []
        let excluded = Set(["AXWebArea", "AXHTMLContent", "AXSheet", "AXMenu", "AXMenuBar", "AXOutline"])
        while let (node, depth) = queue.popLast() {
            guard !isCancelled(), !cancelled(), now() < deadline, depth <= 14, visited.count < 400 else { return nil }
            if visited.contains(node) { continue }
            visited.append(node)
            guard let structure = node.structure() else { return nil }
            if excluded.contains(structure.role) { continue }
            if adapter == .chromium, structure.role == "AXTabGroup" {
                candidates.append(node)
                continue
            }
            if adapter == .safari, structure.isTab {
                guard let parent = node.parent() else { return nil }
                if !candidates.contains(parent) { candidates.append(parent) }
                continue
            }
            // Leaf controls cannot contain a tab strip. Never inspect web content
            // or tab descendants (including Safari's custom close action strings).
            guard ["AXWindow", "AXGroup", "AXOpaqueProviderGroup", "AXSplitGroup", "AXToolbar", "AXScrollArea", "AXTabGroup"]
                .contains(structure.role) else { continue }
            guard let children = node.children(), children.count <= 256 else { return nil }
            queue += children.map { ($0, depth + 1) }
        }
        guard candidates.count == 1, candidates[0].window() == root, now() < deadline else { return nil }
        return candidates[0]
    }
}
