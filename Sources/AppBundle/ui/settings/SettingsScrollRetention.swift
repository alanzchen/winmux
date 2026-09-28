import AppKit
import SwiftUI

/// Remember each pane without publishing pointer-rate scroll offsets to SwiftUI.
@MainActor
final class SettingsScrollMemory {
    static let shared = SettingsScrollMemory()
    var positions: [String: CGPoint] = [:]
}

/// Token ownership also cleans up if AppKit destroys a host without dismantling it.
private final class SettingsScrollObservation {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

struct SettingsScrollRetention: NSViewRepresentable {
    let page: String
    var revealingTarget = false
    var textEditor = false
    func makeNSView(context: Context) -> SettingsScrollAnchor {
        SettingsScrollAnchor(page: page, revealingTarget: revealingTarget, textEditor: textEditor)
    }
    func updateNSView(_ view: SettingsScrollAnchor, context: Context) {
        view.revealingTarget = revealingTarget
        view.show(page)
    }
    static func dismantleNSView(_ view: SettingsScrollAnchor, coordinator: ()) { view.detach() }
}

@MainActor
final class SettingsScrollAnchor: NSView {
    private(set) var page: String
    private weak var scroll: NSScrollView?
    private var observation: SettingsScrollObservation?
    private var restored = false
    private var dismantled = false
    private let textEditor: Bool
    var revealingTarget: Bool
    init(page: String, revealingTarget: Bool = false, textEditor: Bool = false) {
        self.page = page; self.revealingTarget = revealingTarget; self.textEditor = textEditor; super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }
    private func attach() {
        guard !dismantled, scroll == nil, let scroll = textEditor ? editorScrollView() : enclosingScrollView else { return }
        self.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        restore(SettingsScrollMemory.shared.positions[page])
        observation = SettingsScrollObservation(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.restored, let scroll = self.scroll else { return }
                    SettingsScrollMemory.shared.positions[self.page] = scroll.contentView.bounds.origin
                }
            })
    }
    /// The same scroll view now shows another page, such as another panel mode. Switch keys
    /// before its new content lays out, so that layout isn't recorded as the old page's offset.
    func show(_ next: String) {
        guard next != page else { return }
        page = next
        guard scroll != nil else { return }
        restored = false
        restore(SettingsScrollMemory.shared.positions[next] ?? .zero)
    }

    private func restore(_ point: CGPoint?) {
        guard !revealingTarget, let point, let scroll else { restored = true; return }
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, !self.dismantled, let scroll else { return }
            if !self.revealingTarget {
                let y = min(point.y, max((scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height, 0))
                let x = min(point.x, max((scroll.documentView?.bounds.width ?? 0) - scroll.contentView.bounds.width, 0))
                scroll.contentView.scroll(to: CGPoint(x: max(x, 0), y: max(y, 0)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            self.restored = true
        }
    }

    private func editorScrollView() -> NSScrollView? {
        func find(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, let text = scroll.documentView as? NSTextView, text.isEditable { return scroll }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        var root: NSView = self
        while let parent = root.superview { root = parent }
        return find(in: root)
    }
    func detach() {
        dismantled = true
        observation = nil
        scroll = nil
    }
}
