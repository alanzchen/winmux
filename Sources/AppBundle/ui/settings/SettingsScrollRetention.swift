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
    private var documentObservation: SettingsScrollObservation?
    private var userScrollObservation: SettingsScrollObservation?
    private var pendingRestoration: CGPoint?
    private var observedClipSize: CGSize?
    private var restorationGeometry: (document: CGSize, clip: CGSize)?
    private var applyingRestoration = false
    private var dismantled = false
    private let textEditor: Bool
    var revealingTarget: Bool {
        didSet { if revealingTarget { pendingRestoration = nil } }
    }
    init(page: String, revealingTarget: Bool = false, textEditor: Bool = false) {
        self.page = page; self.revealingTarget = revealingTarget; self.textEditor = textEditor; super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        attach()
        restoreAfterLayout()
    }

    private func attach() {
        guard !dismantled, scroll == nil, let scroll = textEditor ? editorScrollView() : enclosingScrollView else { return }
        self.scroll = scroll
        observedClipSize = scroll.contentView.bounds.size
        scroll.contentView.postsBoundsChangedNotifications = true
        pendingRestoration = revealingTarget ? nil : SettingsScrollMemory.shared.positions[page]
        observation = SettingsScrollObservation(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll = self.scroll else { return }
                    if self.observedClipSize != scroll.contentView.bounds.size {
                        self.observedClipSize = scroll.contentView.bounds.size
                        if self.pendingRestoration != nil { self.needsLayout = true }
                    }
                    // Keyboard, focus and accessibility scrolling need not be live scrolling.
                    // Once geometry is unchanged, an origin change outside our own restore
                    // is navigation. A layout clamp with changed geometry keeps the target.
                    if self.pendingRestoration != nil, !self.applyingRestoration,
                       let geometry = self.restorationGeometry,
                       geometry.document == scroll.documentView?.bounds.size,
                       geometry.clip == scroll.contentView.bounds.size {
                        self.pendingRestoration = nil
                    }
                    guard self.pendingRestoration == nil else { return }
                    SettingsScrollMemory.shared.positions[self.page] = scroll.contentView.bounds.origin
                }
            })
        // AppKit posts this after a user-initiated scroll, including devices without
        // a willStart/didEnd live-scroll pair. User intent supersedes a pending restore.
        userScrollObservation = SettingsScrollObservation(NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification,
            object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll = self.scroll else { return }
                    self.pendingRestoration = nil
                    SettingsScrollMemory.shared.positions[self.page] = scroll.contentView.bounds.origin
                }
            })
        if let document = scroll.documentView {
            document.postsFrameChangedNotifications = true
            documentObservation = SettingsScrollObservation(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                object: document, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.pendingRestoration != nil else { return }
                        self.needsLayout = true
                    }
                })
        }
    }
    /// The same scroll view now shows another page, such as another panel mode. Switch keys
    /// before its new content lays out, so that layout isn't recorded as the old page's offset.
    func show(_ next: String) {
        guard next != page else { return }
        page = next
        restorationGeometry = nil
        pendingRestoration = revealingTarget ? nil : (SettingsScrollMemory.shared.positions[next] ?? .zero)
        needsLayout = true
    }

    /// Layout, not a queued callback, owns restoration. Intermediate document sizes may clamp
    /// the requested position. Keep it until geometry can represent it or user intent supersedes
    /// it; only a document frame change schedules another attempt.
    private func restoreAfterLayout() {
        guard !dismantled, let point = pendingRestoration, let scroll, let document = scroll.documentView,
              document.bounds.width > 0, document.bounds.height > 0,
              scroll.contentView.bounds.width > 0, scroll.contentView.bounds.height > 0 else { return }
        let y = min(point.y, max(document.bounds.height - scroll.contentView.bounds.height, 0))
        let x = min(point.x, max(document.bounds.width - scroll.contentView.bounds.width, 0))
        restorationGeometry = (document.bounds.size, scroll.contentView.bounds.size)
        applyingRestoration = true
        scroll.contentView.scroll(to: CGPoint(x: max(x, 0), y: max(y, 0)))
        scroll.reflectScrolledClipView(scroll.contentView)
        applyingRestoration = false
        // Geometry decides completion; AppKit may round the applied origin to backing pixels.
        if max(x, 0) == max(point.x, 0), max(y, 0) == max(point.y, 0) { pendingRestoration = nil }
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
        documentObservation = nil
        userScrollObservation = nil
        pendingRestoration = nil
        observedClipSize = nil
        restorationGeometry = nil
        scroll = nil
    }
}
