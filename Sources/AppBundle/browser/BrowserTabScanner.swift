import Foundation

struct BrowserTabAXStructure {
    let role: String
    let subrole: String
    /// Safari's own name for a control, the same in every language.
    var identifier: String? = nil
    /// Whether reading the identifier failed, rather than finding there's none.
    var identifierUnreadable = false
    var title: String? = nil
    var description: String? = nil
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
    /// A Safari tab's own controls, read with it.
    var children: [Node]? = nil
}

/// The selector in Safari's "Name:…\nTarget:…\nSelector:…" close action. Names are localized;
/// the selector isn't.
let browserTabCloseSelector = "Selector:_closeButtonClicked:"

/// The speaker in Safari's address field. It shows while the tab it's in plays sound or is muted,
/// and also while another tab plays, to mute that one.
let safariAudioIndicatorIdentifier = "UnifiedField._audioIndicator"

/// What a control on a Safari tab says about its sound: a tab playing sound shows a mute button,
/// and a muted one an unmute button. The words are localized, so a muted tab shows as playing in
/// another language. A close button, should one show under the pointer, is told apart by its
/// subrole or by the name of the tab's close action, `closeName`; without that name, only
/// English words can say a button is the sound.
func safariTabControlAudio(_ control: BrowserTabAXStructure, closeName: String?) -> BrowserTabAudio? {
    guard control.role == "AXButton", control.subrole != "AXCloseButton" else { return nil }
    let words = [control.title, control.description].compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
    guard !words.isEmpty, !words.contains(where: { $0.contains("close") }) else { return nil }
    if let closeName {
        guard !words.contains(closeName.lowercased()) else { return nil }
    } else {
        guard words.contains(where: { $0.contains("mute") }) else { return nil }
    }
    return words.contains { $0.contains("unmute") } ? .muted : .playing
}

/// What the address field's speaker says about its own tab. Only its English words tell "this
/// tab" from the others it can mute, so in another language it says nothing.
func safariAddressFieldAudio(_ control: BrowserTabAXStructure) -> BrowserTabAudio? {
    let words = [control.title, control.description].compactMap { $0?.lowercased() }
    guard words.contains(where: { $0.contains("mute this tab") }) else { return nil }
    return words.contains { $0.contains("unmute this tab") } ? .muted : .playing
}

/// The localized name of a Safari tab's close action, from its "Name:…\nTarget:…\nSelector:…" action.
func safariCloseActionName(_ actions: [String]) -> String? {
    actions.first { $0.contains(browserTabCloseSelector) }.flatMap { action in
        action.split(separator: "\n").first.flatMap { $0.hasPrefix("Name:") ? String($0.dropFirst(5)) : nil }
    }
}

/// Small native boundary allows behavioral tests without reading live browsing data.
protocol BrowserTabAXNode: Equatable {
    func structure() -> BrowserTabAXStructure?
    func children() -> [Self]?
    func parent() -> Self?
    func window() -> Self?
    func tabInfo() -> BrowserTabAXInfo?
    func tabRecord(withChildren: Bool) -> BrowserTabAXRecord<Self>?
    /// Presses the element, if it offers that, and says whether it was called and what it answered.
    func press() -> BrowserTabAXCall
    /// The element's actions, including an app's own named ("Name:…") actions.
    func actionNames() -> [String]
    func perform(_ action: String) -> BrowserTabAXCall
    /// The element's own title, read from a window.
    func windowTitle() -> String?
    /// Whether the app says the element no longer exists.
    func isGone() -> Bool
}

extension BrowserTabAXNode {
    func tabRecord(withChildren: Bool) -> BrowserTabAXRecord<Self>? {
        guard let structure = structure(), let info = tabInfo() else { return nil }
        return .init(structure: structure, info: info, parent: parent().map { .element($0) } ?? .unreadable,
            window: window().map { .element($0) } ?? .unreadable, children: withChildren ? children() : nil)
    }

    func tabRecord() -> BrowserTabAXRecord<Self>? { tabRecord(withChildren: false) }

    func actionNames() -> [String] { [] }
    func perform(_ action: String) -> BrowserTabAXCall { .unavailable }
    func windowTitle() -> String? { nil }
    func isGone() -> Bool { false }

    /// Closes this tab with its own control, found without localized text. Safari's tabs offer
    /// a named action for the method their close button calls, even while the button is hidden
    /// (it appears only under the pointer). Otherwise the tab's close button, or its only button.
    func pressCloseControl() -> BrowserTabAXCall {
        if let action = actionNames().first(where: { $0.contains(browserTabCloseSelector) }) { return perform(action) }
        guard let buttons = children()?.filter({ $0.structure()?.role == "AXButton" }) else { return .unavailable }
        let close = buttons.first { $0.structure()?.subrole == "AXCloseButton" } ?? (buttons.count == 1 ? buttons[0] : nil)
        return close?.press() ?? .unavailable
    }

    /// Closes this Safari tab only by that named action, found by its unlocalized selector
    /// (`safariIsCloseAction`). Nothing else is pressed: a tab's only other button may be its
    /// sound's, and a close button isn't guessed at. A Safari topic's own button offers no such
    /// action, and nothing that is or may be one (`SafariTabCluster`) is ever closed: that could
    /// close the topic's tabs. `structure`: this element's, as just read.
    func pressSafariCloseAction(_ structure: BrowserTabAXStructure) -> BrowserTabAXCall {
        guard SafariTabCluster(structure).isPage, let action = actionNames().first(where: safariIsCloseAction) else { return .unavailable }
        return perform(action)
    }

    /// Whether this Safari control offers a tab's close action: what a tab whose identifier says
    /// nothing of topics must show to be taken for one where topics can show. Every tab does, even
    /// while its close button is hidden; a topic's own button doesn't.
    func closesAsSafariTab() -> Bool {
        actionNames().contains(where: safariIsCloseAction)
    }
}

/// Whether a Safari "Name:…\nTarget:…\nSelector:…" action is a tab's close action: its one
/// selector line is exactly the close button's.
func safariIsCloseAction(_ action: String) -> Bool {
    action.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix("Selector:") } == [Substring(browserTabCloseSelector)]
}

/// How a tab bar, read again, shows a tab's Safari topic.
enum SafariOwnTopic: Equatable, Sendable {
    /// Its one button, open, and as many of its tabs as it says it has.
    case shown
    /// Its button says it's closed.
    case closed
    /// Not as it says: no button, two, a count that's off, or a control that may be one of its own.
    case unaccounted
    /// The tab bar couldn't be read in time.
    case unread
}

/// How long a window found to have no tab strip, whose title stays the same, has only its title
/// read before it is walked again: less while its browser plays sound.
let browserLoneTabRediscovery: TimeInterval = 30
let browserLoneTabRediscoveryWhilePlaying: TimeInterval = 5

/// Confined to the owning MacApp AX thread. No AX references escape in snapshots.
final class BrowserTabScanner<Node: BrowserTabAXNode> {
    let root: Node
    let adapter: BrowserTabAdapter
    let windowId: UInt32
    let pid: Int32
    let windowSession = UUID()
    private(set) var container: Node?
    private var lastDiscovery: TimeInterval = -.infinity
    /// The listed tabs, each with what its identifier said of Safari's topics. A tab is known by its
    /// element: were Safari to reuse one for another page, saying the same of topics, that couldn't
    /// be told. A tab whose identifier says something else of topics than when it was listed isn't
    /// acted on until a scan lists it again, keeping its id, as it then says.
    private var handles: [(node: Node, id: UUID, cluster: SafariTabCluster)] = []
    /// Whether the tab bar, when its tabs were last all read, accounted for every tab of its
    /// Safari topics (`safariTabClustersAccountedFor`), even if that scan then failed, as when no
    /// tab it listed was selected (`actionable`).
    private var tabsComplete = true
    /// Whether this Safari can show topics (`safariShowsTopics`). That says only whether a topic's
    /// own button can be among the tabs, not which control is a tab: before Safari 27, a tab button
    /// whose identifier says nothing of topics is a tab, as it always was; from then on, it must
    /// also show it closes as one (`closesAsSafariTab`).
    let showsTopics: Bool
    /// The tab bar's controls whose identifiers say nothing of topics that showed they close as
    /// tabs, while it lists them so, across reads that ran out of time before listing every tab:
    /// so a large tab bar's tabs are each asked once. Nothing else is kept as such.
    private var closeProven: [Node] = []
    /// The selected tab of the last complete scan, which named its container.
    private var anchor: Node?
    private let now: () -> TimeInterval
    private let isCancelled: () -> Bool
    /// Pauses this thread while an action's effect is awaited (`browserTabActionConfirmationPauses`).
    private let wait: (TimeInterval) -> Void
    /// Where each select or close says what it did (`BrowserTabActionTrace`).
    private let log: (String) -> Void
    private(set) var observedNodes: [Node] = []
    /// Whether the last discovery read the whole window and found no tab at all, as in Safari's
    /// Settings or a window whose one tab hides the tab bar. A failed or partial read never says so.
    private(set) var foundNoTabStrip = false
    /// When a discovery last found no tab strip, until one finds a strip or fails.
    private var foundNoTabStripAt: TimeInterval?
    /// The one tab of a window without a tab strip, while it stays that way.
    private var loneTabId = UUID()
    /// Whether the last discovery's window, if it has no tab strip, plays sound or is muted.
    private var loneTabAudio: BrowserTabAudio?
    /// The window's title since its last walk found no tab strip. A new title may be a new tab.
    private var walkedTitle: String?
    /// How many controls a Safari tab has with nothing playing: its icon, while tabs show website
    /// icons, and its title. Learned once per walk.
    private var quietTabControls: Int?
    /// The WinMux Tabs extension's toolbar button's identifier in Safari, which names the extension
    /// and its team, when WinMux has the extension. Its title says which extension window this is.
    /// A new identifier has the next read walk the window, to find that button.
    var markerIdentifier: String? {
        didSet {
            guard markerIdentifier != oldValue else { return }
            markerNode = nil
            walkedMarker = nil
            lastDiscovery = -.infinity
        }
    }
    /// That button, as the last complete walk found it, and what it said then.
    private var markerNode: Node?
    private var walkedMarker: SafariExtensionMarker?

    init(root: Node, adapter: BrowserTabAdapter, windowId: UInt32, pid: Int32, markerIdentifier: String? = nil, showsTopics: Bool = true,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         isCancelled: @escaping () -> Bool = { false },
         wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         log: @escaping (String) -> Void = { browserTabActionLog.debug("\($0, privacy: .public)") }) {
        self.root = root
        self.adapter = adapter
        self.showsTopics = showsTopics
        self.windowId = windowId
        self.pid = pid
        self.markerIdentifier = markerIdentifier
        self.now = now
        self.isCancelled = isCancelled
        self.wait = wait
        self.log = log
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
            walkedTitle = nil
            quietTabControls = nil
            guard let found = discover(deadline: discoveryDeadline, cancelled: cancelled) else {
                foundNoTabStripAt = foundNoTabStrip ? started : nil
                return nil
            }
            if foundNoTabStripAt != nil {
                foundNoTabStripAt = nil
                loneTabId = UUID()
            }
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
        var listed: [(node: Node, record: BrowserTabAXRecord<Node>)] = []
        for child in children {
            guard !isCancelled(), !cancelled(), now() < deadline,
                  let record = child.tabRecord(withChildren: adapter == .safari), isTab(record, of: candidate)
            else {
                // A replaced container or a collapsed native tab group is not a
                // complete list. Don't retire identities or publish a partial scan.
                return nil
            }
            listed.append((child, record))
        }
        // A Safari topic's own button is listed with the tabs, as one, but it's no page. Where one
        // can show, a control that says nothing of topics is a tab only if it closes as one, which
        // it may have shown before: a tab piled up in a crowded tab bar offers no close for now.
        var clusters = listed.map { cluster(of: $0.record) }
        if adapter == .safari, showsTopics {
            closeProven = listed.indices.filter { clusters[$0] == .unknown && closeProven.contains(listed[$0].node) }.map { listed[$0].node }
            for index in listed.indices where clusters[index] == .unknown && !closeProven.contains(listed[index].node) {
                guard now() < deadline, !isCancelled(), !cancelled() else { return nil }
                if listed[index].node.closesAsSafariTab() { closeProven.append(listed[index].node) } else { clusters[index] = .malformed }
            }
        }
        let complete = safariTabClustersAccountedFor(clusters)
        tabsComplete = complete
        var next: [(node: Node, id: UUID, cluster: SafariTabCluster)] = []
        var tabs: [BrowserTab] = []
        var records: [(node: Node, record: BrowserTabAXRecord<Node>)] = []
        for ((child, record), cluster) in zip(listed, clusters) where cluster.isPage {
            let id = handles.first { $0.node == child }?.id ?? UUID()
            next.append((child, id, cluster))
            let label = browserTabLabel(record.info.title, adapter: adapter)
            tabs.append(.init(target: .init(windowId: windowId, pid: pid, windowSession: windowSession, tabId: id),
                title: label.title, isSelected: record.info.selected, audio: label.audio))
            records.append((child, record))
        }
        guard tabs.filter(\.isSelected).count == 1, now() < deadline, !isCancelled(), !cancelled() else { return nil }
        var quietControls = quietTabControls
        if adapter == .safari {
            guard let sound = safariTabAudio(records, until: deadline, cancelled: cancelled),
                  now() < deadline, !isCancelled(), !cancelled() else { return nil }
            for index in tabs.indices { tabs[index].audio = sound.audio[index] }
            quietControls = sound.quietControls
        }
        container = candidate
        handles = next
        quietTabControls = quietControls
        anchor = zip(next, tabs).first { $0.1.isSelected }?.0.node
        // The selected control plus window/container notifications cover common
        // changes. Keep subscriptions bounded; polling reconciles background tabs.
        observedNodes = [root, candidate] + zip(next, tabs).filter { $0.1.isSelected }.map { $0.0.node }
        return .init(windowId: windowId, pid: pid, windowSession: windowSession, tabs: tabs, isComplete: complete,
            marker: marker(walked: discovered, until: deadline, cancelled: cancelled))
    }

    /// What the extension's toolbar button says now: read with the walk, or on its own, in one
    /// round trip, after. A button the walk didn't find, that's gone, or that a read ran out of
    /// time for, says nothing; the next walk looks again.
    private func marker(walked: Bool, until deadline: TimeInterval, cancelled: () -> Bool) -> SafariExtensionMarker? {
        guard adapter == .safari, let markerIdentifier, let markerNode else { return nil }
        if walked { return walkedMarker }
        guard now() < deadline, !isCancelled(), !cancelled() else { return nil }
        guard let structure = markerNode.structure(), structure.identifier == markerIdentifier else {
            self.markerNode = nil
            return nil
        }
        return SafariExtensionMarker(structure.description)
    }

    func select(_ target: BrowserTabTarget, cancelled: () -> Bool = { false }) -> BrowserTabActionResult {
        run(.select, on: target, cancelled: cancelled) { node, _ in node.press() }
    }

    /// Closes exactly the tab the sidebar listed; a tab that has since moved or changed
    /// identity is left alone.
    func close(_ target: BrowserTabTarget, cancelled: () -> Bool = { false }) -> BrowserTabActionResult {
        run(.close, on: target, cancelled: cancelled) { node, record in
            adapter == .safari ? node.pressSafariCloseAction(record.structure) : node.pressCloseControl()
        }
    }

    private func run(_ kind: BrowserTabActionKind, on target: BrowserTabTarget, cancelled: () -> Bool,
                     _ dispatch: (Node, BrowserTabAXRecord<Node>) -> BrowserTabAXCall) -> BrowserTabActionResult {
        let started = now()
        var trace = BrowserTabActionTrace(kind: kind)
        let result = act(kind, on: target, cancelled: cancelled, trace: &trace, dispatch)
        log(trace.line(result, elapsed: now() - started))
        return result
    }

    /// Presses or closes the listed tab, once. Safari accepts both on a tab scrolled out of its
    /// crowded tab bar, one that names no parent, yet does neither; and a tab piled up with others
    /// offers neither. Either is scrolled into view, checked again as if just listed, and acted on
    /// only if it then names its tab bar; that's the one second try, only ever for an action that
    /// wasn't sent. One that was is never sent again: its tab is read for its effect
    /// (`confirmEffect`), and what it did is told as it was seen.
    private func act(_ kind: BrowserTabActionKind, on target: BrowserTabTarget, cancelled: () -> Bool, trace: inout BrowserTabActionTrace,
                     _ dispatch: (Node, BrowserTabAXRecord<Node>) -> BrowserTabAXCall) -> BrowserTabActionResult {
        let first: (node: Node, record: BrowserTabAXRecord<Node>)
        switch actionable(target, cancelled: cancelled) {
            case .failure(let refusal): return .notDispatched(refusal)
            case .success(let tab): first = tab
        }
        trace.describe(first.record, tabClass: tabClass(first.record))
        if first.record.parent != .none {
            trace.stage = "dispatch"
            let call = dispatch(first.node, first.record)
            trace.call = call
            if call != .unavailable { return confirmEffect(kind, of: first.node, after: call, cancelled: cancelled, trace: &trace) }
        }
        trace.stage = "reveal"
        guard !isCancelled(), !cancelled() else { return .notDispatched(.cancelled) }
        guard reveal(first.node) else { return .notDispatched(first.record.parent == .none ? .outOfView : .noAction) }
        let shown: (node: Node, record: BrowserTabAXRecord<Node>)
        switch actionable(target, cancelled: cancelled) {
            case .failure(let refusal): return .notDispatched(refusal)
            case .success(let tab): shown = tab
        }
        trace.describe(shown.record, tabClass: tabClass(shown.record))
        guard shown.record.parent != .none else { return .notDispatched(.outOfView) }
        trace.stage = "dispatch"
        let call = dispatch(shown.node, shown.record)
        trace.call = call
        guard call != .unavailable else { return .notDispatched(.noAction) }
        return confirmEffect(kind, of: shown.node, after: call, cancelled: cancelled, trace: &trace)
    }

    /// What a dispatched action did, as its tab then says: read at once, then after each of
    /// `browserTabActionConfirmationPauses`, all within one deadline,
    /// `browserTabActionConfirmationBudget` after the action returned, that counts the reads as well
    /// as the pauses. A pause takes only what's left of it, and no read starts after it. So the
    /// app's Accessibility thread is held at most the budget plus one read's tail: a select's read
    /// is one round trip, a close's two (`isClosed`), each with a 50 ms messaging timeout, so at
    /// most 0.30 s for a select and 0.35 s for a close. A select is done once the tab says it's
    /// selected, a close once the tab or its window is gone. Otherwise what it did isn't known, or
    /// it failed if the browser answered with an error. Nothing is sent again, and nothing sent is
    /// ever told as not sent.
    private func confirmEffect(_ kind: BrowserTabActionKind, of node: Node, after call: BrowserTabAXCall, cancelled: () -> Bool,
                               trace: inout BrowserTabActionTrace) -> BrowserTabActionResult {
        trace.stage = "confirm"
        trace.dispatchAttempted = true
        let deadline = now() + browserTabActionConfirmationBudget
        func inTime() -> Bool { now() < deadline && !isCancelled() && !cancelled() }
        var confirmed = kind == .select ? node.tabInfo()?.selected == true : isClosed(node, while: inTime)
        for pause in browserTabActionConfirmationPauses where !confirmed {
            guard inTime() else { break }
            wait(min(pause, deadline - now()))
            guard inTime() else { break }
            confirmed = kind == .select ? node.tabInfo()?.selected == true : isClosed(node, while: inTime)
        }
        trace.postcondition = confirmed ? .confirmed : .unknown
        if confirmed { return .dispatched(.confirmed) }
        if case .failed(let failure) = call { return .failed(failure) }
        return .dispatched(.unknown)
    }

    /// Whether a closed tab is gone: its element, or the window it was in, says it no longer
    /// exists. A tab that left its tab bar, or a tab bar that went or lists nothing, may still be
    /// open, moved to another window or hidden, so that says nothing. The window is read only
    /// while `inTime`.
    private func isClosed(_ node: Node, while inTime: () -> Bool) -> Bool {
        node.isGone() || inTime() && root.isGone()
    }

    /// The listed tab, checked again as if just listed, if it may be acted on. A tab that says
    /// it's in no topic may; one in a topic, only if the tab bar, read again now, still shows that
    /// topic open with all its tabs (`ownTopic`), as a topic can close or change at any time;
    /// any other, only if the tab bar did when last read in full.
    private func actionable(_ target: BrowserTabTarget, cancelled: () -> Bool) -> Result<(node: Node, record: BrowserTabAXRecord<Node>), BrowserTabActionRefusal> {
        let deadline = now() + 0.2
        let checked = validatedTab(target, until: deadline, cancelled: cancelled)
        guard case .success(let tab) = checked else { return checked }
        switch cluster(of: tab.record) {
            case .plain: return checked
            // The tab could have changed while the tab bar was read: what's acted on is the tab as
            // checked after that.
            case .member(let id):
                let topic = ownTopic(id, until: deadline, cancelled: cancelled)
                switch topic.state {
                    case .shown:
                        guard let proof = topic.proof else { return .failure(.unaccounted) }
                        let final = validatedTab(target, until: deadline, cancelled: cancelled)
                        guard case .success = final else { return final }
                        if let refusal = ownTopicHolds(id, proof, until: deadline, cancelled: cancelled) { return .failure(refusal) }
                        return final
                    case .closed: return .failure(.collapsedTopic)
                    case .unaccounted: return .failure(.unaccounted)
                    case .unread: return .failure(isCancelled() || cancelled() ? .cancelled : .noResponse)
                }
            default: return tabsComplete ? checked : .failure(.unaccounted)
        }
    }

    /// How the tab bar, read again, shows the Safari topic `id`. Only that topic counts: other
    /// topics, open or closed, don't say anything about this one's tabs (Phase A, 2026-10-04,
    /// narrowing F4's check from the whole tab bar to the tab's own topic). Every control is still
    /// read: one that can't be read, isn't a tab, or says nothing reliable of topics could be this
    /// topic's button or one of its tabs.
    private func ownTopic(_ id: String, until deadline: TimeInterval, cancelled: () -> Bool)
        -> (state: SafariOwnTopic, proof: (header: Node, tabCount: Int, children: [Node])?) {
        guard let container, now() < deadline, let children = container.children(), children.count <= 256 else { return (.unread, nil) }
        var headers: [(node: Node, isExpanded: Bool, tabCount: Int)] = []
        var members = 0
        for child in children {
            guard now() < deadline, !isCancelled(), !cancelled(), let structure = child.structure() else { return (.unread, nil) }
            guard structure.isTab else { return (.unaccounted, nil) }
            switch SafariTabCluster(structure) {
                case .header(id, let isExpanded, let tabCount): headers.append((child, isExpanded, tabCount))
                case .member(id): members += 1
                case .malformed, .unknown: return (.unaccounted, nil)
                case .header, .member, .plain: break
            }
        }
        guard now() < deadline else { return (.unread, nil) }
        guard headers.count == 1, let header = headers.first else { return (.unaccounted, nil) }
        guard header.isExpanded else { return (.closed, nil) }
        return members == header.tabCount ? (.shown, (header.node, header.tabCount, children)) : (.unaccounted, nil)
    }

    /// Whether the topic `ownTopic` showed still stands, read once more after the tab itself was
    /// checked, within the same deadline: the tab bar lists the same controls, and the topic's own
    /// button, the one read before, still says it's that topic's, open, with as many tabs. Nil when
    /// it does; otherwise why not. Accessibility can't check and act at once, so this only closes
    /// the gap the reads before the action left; a change after it still lands.
    private func ownTopicHolds(_ id: String, _ proof: (header: Node, tabCount: Int, children: [Node]), until deadline: TimeInterval,
                               cancelled: () -> Bool) -> BrowserTabActionRefusal? {
        func stop() -> BrowserTabActionRefusal? { isCancelled() || cancelled() ? .cancelled : now() < deadline ? nil : .noResponse }
        if let stop = stop() { return stop }
        guard let container, let children = container.children() else { return stop() ?? .noResponse }
        guard sameControls(children, proof.children) else { return .unaccounted }
        if let stop = stop() { return stop }
        guard let structure = proof.header.structure() else { return stop() ?? .noResponse }
        if let stop = stop() { return stop }
        switch SafariTabCluster(structure) {
            case .header(id, true, proof.tabCount) where structure.isTab: return nil
            case .header(id, false, _) where structure.isTab: return .collapsedTopic
            default: return .unaccounted
        }
    }

    /// Whether two lists of a tab bar's controls name the same controls, each once, in any order. A
    /// list naming one control twice is never the same as another, even one as long whose every
    /// control it names: the topic's button listed again in place of one of its tabs isn't the topic.
    private func sameControls(_ listed: [Node], _ other: [Node]) -> Bool {
        func unique(_ nodes: [Node]) -> Bool { nodes.indices.allSatisfy { !nodes[..<$0].contains(nodes[$0]) } }
        return listed.count == other.count && unique(listed) && unique(other) && listed.allSatisfy(other.contains)
    }

    /// Scrolls a tab into its tab bar's view. Safari offers neither press nor close on a tab piled
    /// up with others in a crowded tab bar until then.
    private func reveal(_ node: Node) -> Bool {
        let scroll = "AXScrollToVisible"
        return node.actionNames().contains(scroll) && node.perform(scroll) == .succeeded
    }

    /// The full scan already established exactly one selection. Bookend the URL
    /// read with this exact control, without repeating every tab's IPC. Origin
    /// assignment still requires two complete, matching polls separated in time.
    func confirmsSelection(in snapshot: BrowserWindowTabs, until deadline: TimeInterval,
                           cancelled: () -> Bool = { false }) -> Bool {
        guard snapshot.tabs.filter(\.isSelected).count == 1, let selected = snapshot.tabs.first(where: \.isSelected),
              case .success(let tab) = validatedTab(selected.target, until: deadline, cancelled: cancelled)
        else { return false }
        return tab.record.info.selected && browserTabLabel(tab.record.info.title, adapter: adapter).title == selected.title
    }

    /// A Safari window whose one tab hides the tab bar, as that tab, named by the window's title:
    /// what the Safari extension can pair it by. After a full scan found no tab strip, only the
    /// title is read, so a window that stays that way isn't walked at every read. A new tab
    /// changes the title, and a new title, or `interval`, has the window walked again: nil asks
    /// for the full scan. `afterWalk`: called right after `scan()` walked the window and found no
    /// tab strip, in the same read, so the extension's button the walk just read isn't read again.
    func loneTab(until budgetEnd: TimeInterval = .infinity, rediscoverAfter interval: TimeInterval = browserLoneTabRediscovery,
                 afterWalk: Bool = false, cancelled: () -> Bool = { false }) -> BrowserWindowTabs? {
        guard adapter == .safari, let found = foundNoTabStripAt, now() - found < interval,
              now() < budgetEnd, !isCancelled(), !cancelled(), let title = root.windowTitle(),
              now() < budgetEnd, !isCancelled(), !cancelled(), walkedTitle.map({ $0 == title }) ?? true else { return nil }
        walkedTitle = title
        return .init(windowId: windowId, pid: pid, windowSession: windowSession, tabs: [
            .init(target: .init(windowId: windowId, pid: pid, windowSession: windowSession, tabId: loneTabId),
                title: browserTabLabel(title, adapter: adapter).title, isSelected: true, audio: loneTabAudio),
        ], marker: marker(walked: afterWalk && foundNoTabStrip, until: budgetEnd, cancelled: cancelled))
    }

    /// A Safari tab playing sound shows a mute button after its icon and title, and keeps it, to
    /// unmute, while muted; a pinned tab shows only its icon, and without website icons a tab
    /// shows only its title. So only a tab with more controls than a quiet one has its extra ones
    /// read: a strip with nothing playing costs no more than its tabs. How many a quiet tab has is
    /// learned once per walk from the last control of the unpinned tab with the most, which is
    /// shown in full (tabs piled up in a crowded tab bar show fewer): a button there is one more
    /// than a quiet tab's, as when every tab is playing. It's returned to keep only with a
    /// complete scan. Nil when a read failed or ran out of time, as a partial scan says nothing.
    private func safariTabAudio(_ records: [(node: Node, record: BrowserTabAXRecord<Node>)], until deadline: TimeInterval,
                                cancelled: () -> Bool) -> (audio: [BrowserTabAudio?], quietControls: Int?)? {
        let pinned = records.map { $0.record.structure.identifier?.contains("isPinned=true") == true }
        let counts = records.map { $0.record.children?.count ?? 0 }
        var quiet = quietTabControls
        if quiet == nil, let widest = records.indices.filter({ !pinned[$0] }).max(by: { counts[$0] < counts[$1] }), counts[widest] > 0 {
            guard now() < deadline, !isCancelled(), !cancelled(),
                  let last = records[widest].record.children?.last?.structure() else { return nil }
            quiet = last.role == "AXButton" ? counts[widest] - 1 : counts[widest]
        }
        let usualCount = (pinned: min(1, records.indices.filter { pinned[$0] }.map { counts[$0] }.min() ?? 1),
                          unpinned: quiet ?? 2)
        var audio: [BrowserTabAudio?] = []
        for (index, (node, record)) in records.enumerated() {
            let usual = pinned[index] ? usualCount.pinned : usualCount.unpinned
            guard let children = record.children, children.count > usual else {
                audio.append(nil)
                continue
            }
            guard now() < deadline, !isCancelled(), !cancelled() else { return nil }
            let closeName = safariCloseActionName(node.actionNames())
            var found: BrowserTabAudio?
            for control in children.suffix(children.count - usual).reversed() where found == nil {
                guard now() < deadline, !isCancelled(), !cancelled(), let structure = control.structure() else { return nil }
                found = safariTabControlAudio(structure, closeName: closeName)
            }
            audio.append(found)
        }
        return (audio, quiet)
    }

    /// The listed tab as it is now, or why it can't be taken for the one listed. Revalidates only
    /// this exact live control: a large tab strip must not make an explicit selection depend on
    /// successfully rereading every other tab.
    private func validatedTab(_ target: BrowserTabTarget, until deadline: TimeInterval,
                              cancelled: () -> Bool) -> Result<(node: Node, record: BrowserTabAXRecord<Node>), BrowserTabActionRefusal> {
        guard target.pid == pid, target.windowId == windowId, target.windowSession == windowSession,
              let handle = handles.first(where: { $0.id == target.tabId }), let container else { return .failure(.changed) }
        /// Why to stop here, if anything says so: a cancel, or no time left.
        func stop() -> BrowserTabActionRefusal? { isCancelled() || cancelled() ? .cancelled : now() < deadline ? nil : .noResponse }
        if let stop = stop() { return .failure(stop) }
        guard let window = container.window() else { return .failure(stop() ?? .noResponse) }
        guard window == root else { return .failure(.changed) }
        if let stop = stop() { return .failure(stop) }
        guard let children = container.children() else { return .failure(stop() ?? .noResponse) }
        guard children.contains(handle.node) else { return .failure(.changed) }
        if let stop = stop() { return .failure(stop) }
        guard let record = handle.node.tabRecord(), record.parent != .unreadable else { return .failure(stop() ?? .noResponse) }
        // Still the same page, in the same topic: never a topic's own button.
        guard isTab(record, of: container), cluster(of: record) == handle.cluster,
              record.window == .element(root) || record.parent == .none else { return .failure(.changed) }
        if let stop = stop() { return .failure(stop) }
        // A tab out of view is taken on its tab bar's word, so the bar must still hold the tab
        // that was selected, which named it.
        guard record.parent != .none || anchorHolds(in: container, children: children) else { return .failure(.outOfView) }
        if let stop = stop() { return .failure(stop) }
        return .success((handle.node, record))
    }

    /// What kind of tab a listed control is, for the debug log.
    private func tabClass(_ record: BrowserTabAXRecord<Node>) -> String {
        switch cluster(of: record) {
            case .unknown: adapter == .safari ? "unknown" : "\(adapter)"
            case .plain: "plain"
            case .member: "member"
            case .header: "header"
            case .malformed: "malformed"
        }
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

    /// What a listed control's identifier says of Safari's topics. Other browsers have none.
    private func cluster(of record: BrowserTabAXRecord<Node>) -> SafariTabCluster {
        adapter == .safari ? SafariTabCluster(record.structure) : .unknown
    }

    private func anchorHolds(in container: Node, children: [Node]) -> Bool {
        guard let anchor, children.contains(anchor) else { return false }
        return anchor.tabRecord()?.parent == .element(container)
    }

    private func discover(deadline: TimeInterval, cancelled: () -> Bool) -> Node? {
        foundNoTabStrip = false
        var audio: BrowserTabAudio?
        var marker: (node: Node, value: SafariExtensionMarker?)?
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
            // Read with the walk: the speaker for a window without a tab strip's one tab, and the
            // extension's button.
            if adapter == .safari, structure.identifier == safariAudioIndicatorIdentifier {
                audio = safariAddressFieldAudio(structure)
                continue
            }
            if adapter == .safari, let markerIdentifier, structure.identifier == markerIdentifier {
                marker = (node, SafariExtensionMarker(structure.description))
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
        loneTabAudio = foundNoTabStrip ? audio : nil
        markerNode = marker?.node
        walkedMarker = marker?.value
        guard candidates.count == 1, candidates[0].window() == root, now() < deadline else { return nil }
        return candidates[0]
    }
}
