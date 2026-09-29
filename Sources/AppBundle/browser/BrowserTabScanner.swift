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

/// What a control says about an element it belongs to, its parent or its window.
enum BrowserTabAXLink<Node> {
    case element(Node)
    /// It says there's none (kAXErrorNoValue), as Safari's tabs scrolled out of a crowded tab
    /// bar say of their parent.
    case none
    /// The read failed some other way.
    case unreadable
}

extension BrowserTabAXLink: Equatable where Node: Equatable {}

extension BrowserTabAXLink {
    var element: Node? { if case .element(let node) = self { node } else { nil } }
}

struct BrowserTabAXRecord<Node> {
    let structure: BrowserTabAXStructure
    let info: BrowserTabAXInfo
    let parent: BrowserTabAXLink<Node>
    let window: BrowserTabAXLink<Node>
}

/// The selector in Safari's "Name:…\nTarget:…\nSelector:…" close action. Names are localized;
/// the selector isn't.
let browserTabCloseSelector = "Selector:_closeButtonClicked:"

/// Small native boundary allows behavioral tests without reading live browsing data.
protocol BrowserTabAXNode: Equatable {
    func structure() -> BrowserTabAXStructure?
    func children() -> [Self]?
    func parent() -> Self?
    func window() -> Self?
    func tabInfo() -> BrowserTabAXInfo?
    func tabRecord() -> BrowserTabAXRecord<Self>?
    func press() -> Bool
    /// The element's actions, including an app's own named ("Name:…") actions.
    func actionNames() -> [String]
    func perform(_ action: String) -> Bool
}

extension BrowserTabAXNode {
    func tabRecord() -> BrowserTabAXRecord<Self>? {
        guard let structure = structure(), let info = tabInfo() else { return nil }
        return .init(structure: structure, info: info, parent: parent().map { .element($0) } ?? .unreadable,
            window: window().map { .element($0) } ?? .unreadable)
    }

    func actionNames() -> [String] { [] }
    func perform(_ action: String) -> Bool { false }

    /// Closes this tab with its own control, found without localized text. Safari's tabs offer
    /// a named action for the method their close button calls, even while the button is hidden
    /// (it appears only under the pointer). Otherwise the tab's close button, or its only button.
    func pressCloseControl() -> Bool {
        if let action = actionNames().first(where: { $0.contains(browserTabCloseSelector) }) { return perform(action) }
        guard let buttons = children()?.filter({ $0.structure()?.role == "AXButton" }) else { return false }
        let close = buttons.first { $0.structure()?.subrole == "AXCloseButton" } ?? (buttons.count == 1 ? buttons[0] : nil)
        return close?.press() ?? false
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
    /// The selected tab of the last complete scan, which named its container.
    private var anchor: Node?
    private let now: () -> TimeInterval
    private let isCancelled: () -> Bool
    private(set) var observedNodes: [Node] = []
    /// Whether the last discovery read the whole window and found no tab at all, as in Safari's
    /// Settings or a window whose one tab hides the tab bar. A failed or partial read never says so.
    private(set) var foundNoTabStrip = false

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
        // Only this scan's own full discovery may say the window has no tab strip.
        foundNoTabStrip = false
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
                  let record = child.tabRecord(), isTab(record, of: candidate)
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
        anchor = zip(next, tabs).first { $0.1.isSelected }?.0.node
        // The selected control plus window/container notifications cover common
        // changes. Keep subscriptions bounded; polling reconciles background tabs.
        observedNodes = [root, candidate] + zip(next, tabs).filter { $0.1.isSelected }.map { $0.0.node }
        return .init(windowId: windowId, pid: pid, windowSession: windowSession, tabs: tabs)
    }

    func select(_ target: BrowserTabTarget, cancelled: () -> Bool = { false }) -> Bool {
        act(on: target, cancelled: cancelled) { $0.press() }
    }

    /// Closes exactly the tab the sidebar listed; a tab that has since moved or changed
    /// identity is left alone.
    func close(_ target: BrowserTabTarget, cancelled: () -> Bool = { false }) -> Bool {
        act(on: target, cancelled: cancelled) { $0.pressCloseControl() }
    }

    /// Presses or closes the listed tab. Safari accepts both on a tab scrolled out of its crowded
    /// tab bar, one that names no parent, yet does neither; and a tab piled up with others offers
    /// neither. Either is scrolled into view, checked again as if just listed, and acted on only
    /// if it then names its tab bar. Otherwise it's left, and the action says it wasn't done.
    private func act(on target: BrowserTabTarget, cancelled: () -> Bool, _ action: (Node) -> Bool) -> Bool {
        guard let (node, record) = validatedTab(target, until: now() + 0.2, cancelled: cancelled) else { return false }
        if record.parent != .none, action(node) { return true }
        guard !isCancelled(), !cancelled(), reveal(node), let (shown, record) = validatedTab(target, until: now() + 0.2, cancelled: cancelled),
              record.parent != .none else { return false }
        return action(shown)
    }

    /// Scrolls a tab into its tab bar's view. Safari offers neither press nor close on a tab piled
    /// up with others in a crowded tab bar until then.
    private func reveal(_ node: Node) -> Bool {
        let scroll = "AXScrollToVisible"
        return node.actionNames().contains(scroll) && node.perform(scroll)
    }

    /// The full scan already established exactly one selection. Bookend the URL
    /// read with this exact control, without repeating every tab's IPC. Origin
    /// assignment still requires two complete, matching polls separated in time.
    func confirmsSelection(in snapshot: BrowserWindowTabs, until deadline: TimeInterval,
                           cancelled: () -> Bool = { false }) -> Bool {
        guard snapshot.tabs.filter(\.isSelected).count == 1, let selected = snapshot.tabs.first(where: \.isSelected),
              let (_, record) = validatedTab(selected.target, until: deadline, cancelled: cancelled)
        else { return false }
        return record.info.selected && browserTabDisplayTitle(record.info.title) == selected.title
    }

    private func validatedTab(_ target: BrowserTabTarget, until deadline: TimeInterval,
                              cancelled: () -> Bool) -> (Node, BrowserTabAXRecord<Node>)? {
        guard target.pid == pid, target.windowId == windowId, target.windowSession == windowSession,
              let handle = handles.first(where: { $0.id == target.tabId }), let container,
              !isCancelled(), !cancelled(), now() < deadline, container.window() == root, now() < deadline,
              let children = container.children(), children.contains(handle.node),
              !cancelled(), now() < deadline,
              let record = handle.node.tabRecord(), isTab(record, of: container),
              record.window == .element(root) || record.parent == .none, now() < deadline,
              // A tab out of view is taken on its tab bar's word, so the bar must still hold the
              // tab that was selected, which named it.
              record.parent != .none || anchorHolds(in: container, children: children),
              now() < deadline, !isCancelled(), !cancelled()
        else { return nil }
        // Revalidate only this exact live control. A large tab strip must not make
        // an explicit selection depend on successfully rereading every other tab.
        return (handle.node, record)
    }

    /// Whether a control its container lists is one of that container's tabs. Safari's tabs
    /// scrolled out of a crowded tab bar say they have no parent, so they're taken on the
    /// container's word, unless they name another window or their window can't be read. The
    /// selected tab always shows, so it must name its container.
    private func isTab(_ record: BrowserTabAXRecord<Node>, of container: Node) -> Bool {
        guard record.structure.isTab else { return false }
        switch record.parent {
        case .element(let parent): return parent == container
        case .none: return !record.info.selected && (record.window == .element(root) || record.window == .none)
        case .unreadable: return false
        }
    }

    private func anchorHolds(in container: Node, children: [Node]) -> Bool {
        guard let anchor, children.contains(anchor) else { return false }
        return anchor.tabRecord()?.parent == .element(container)
    }

    private func discover(deadline: TimeInterval, cancelled: () -> Bool) -> Node? {
        foundNoTabStrip = false
        // Each node with the one whose children listed it.
        var queue: [(node: Node, depth: Int, lister: Node?)] = [(root, 0, nil)]
        var visited: [Node] = []
        var candidates: [Node] = []
        let excluded = Set(["AXWebArea", "AXHTMLContent", "AXSheet", "AXMenu", "AXMenuBar", "AXOutline"])
        while let (node, depth, lister) = queue.popLast() {
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
                guard let named = node.tabRecord()?.parent, let parent = named == .none ? lister : named.element else { return nil }
                if !candidates.contains(parent) { candidates.append(parent) }
                continue
            }
            // Leaf controls cannot contain a tab strip. Never inspect web content
            // or tab descendants (including Safari's custom close action strings).
            guard ["AXWindow", "AXGroup", "AXOpaqueProviderGroup", "AXSplitGroup", "AXToolbar", "AXScrollArea", "AXTabGroup"]
                .contains(structure.role) else { continue }
            guard let children = node.children(), children.count <= 256 else { return nil }
            queue += children.map { ($0, depth + 1, node) }
        }
        foundNoTabStrip = candidates.isEmpty
        guard candidates.count == 1, candidates[0].window() == root, now() < deadline else { return nil }
        return candidates[0]
    }
}
