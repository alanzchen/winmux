import AppKit
import SwiftUI

/// An immutable diagnostic and its deliberately invoked original presentation. A custom
/// presenter is used only for errors whose original UI is outside MessageView (e.g. Sparkle).
@MainActor
final class WinMuxToastOriginalPresentation {
    let show: () -> Void
    init(_ show: @escaping () -> Void) { self.show = show }
}

struct WinMuxToastNotice: Equatable {
    let title: String
    let body: String
    let monitorScopeId: String?
    let details: Message?
    let original: WinMuxToastOriginalPresentation?

    init(title: String, body: String, monitorScopeId: String? = nil,
         details: Message? = nil, original: WinMuxToastOriginalPresentation? = nil) {
        self.title = title
        self.body = body
        self.monitorScopeId = monitorScopeId
        self.details = details
        self.original = original
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.body == rhs.body && lhs.monitorScopeId == rhs.monitorScopeId
            && lhs.details == rhs.details && lhs.original === rhs.original
    }

    var diagnostic: Message {
        details ?? Message(description: "\(title) Error", body: body)
    }
}

/// For framework-owned error UI: keep its exact presentation until Details is selected.
@MainActor
public func showWinMuxError(title: String, body: String, original: @escaping @MainActor () -> Void) {
    WinMuxToastPanel.shared.show(.init(title: title, body: body, original: .init(original)))
}

/// What the toast shows, and until when. The same notice again while it shows is counted, not
/// stacked, and stays up longer; another takes its place. Each is read out by VoiceOver.
@MainActor
final class WinMuxToastModel: ObservableObject {
    struct Shown: Equatable {
        let notice: WinMuxToastNotice
        var count: Int
        var until: TimeInterval
    }

    static let lifetime: TimeInterval = 4
    @Published private(set) var shown: Shown?
    private(set) var isInteracting = false
    private var pending: [WinMuxToastNotice] = []
    private let clock: () -> TimeInterval
    private let announce: @MainActor (String) -> Void

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         announce: @escaping @MainActor (String) -> Void = winMuxAnnounce) {
        self.clock = clock
        self.announce = announce
    }

    var now: TimeInterval { clock() }

    func show(_ notice: WinMuxToastNotice) {
        if isInteracting, shown?.notice != notice {
            if pending.last != notice { pending.append(notice) }
            return
        }
        let now = clock()
        if var shown, shown.notice == notice, now < shown.until {
            shown.count += 1
            shown.until = now + Self.lifetime
            self.shown = shown
        } else {
            shown = .init(notice: notice, count: 1, until: now + Self.lifetime)
        }
        announce(String(notice.body.prefix(600)))
    }

    /// Takes the toast down once its time is up.
    func expire() {
        guard !isInteracting else { return }
        if let shown, clock() >= shown.until { dismiss() }
    }

    func setInteracting(_ value: Bool) {
        guard value != isInteracting else { return }
        isInteracting = value
        if !value, var shown {
            shown.until = clock() + Self.lifetime
            self.shown = shown
        }
    }

    func dismiss() {
        shown = nil
        isInteracting = false
        if !pending.isEmpty { show(pending.removeFirst()) }
    }

    func reset() { pending = []; shown = nil; isInteracting = false }
}

/// Asks VoiceOver to read `text` out now, whatever has focus.
@MainActor
func winMuxAnnounce(_ text: String) {
    NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
        .announcement: text,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
    ])
}

/// The body stays entirely click-through. Only the small native Details button has a
/// receiving window, so a nil hitTest on an otherwise opaque panel cannot swallow clicks.
@MainActor
final class WinMuxToastPanel: NSPanelHud {
    static let shared = WinMuxToastPanel()
    let model: WinMuxToastModel
    private let hostingView: NSHostingView<WinMuxToastView>
    let detailsPanel = WinMuxToastDetailsPanel()
    private var timer: Timer?
    private let openDetails: (WinMuxToastNotice) -> Void

    init(model: WinMuxToastModel = WinMuxToastModel(),
         openDetails: @escaping (WinMuxToastNotice) -> Void = { notice in
             if let original = notice.original { original.show() }
             else { MessageModel.shared.openDetails(notice.diagnostic) }
         }) {
        self.model = model
        self.openDetails = openDetails
        hostingView = NSHostingView(rootView: WinMuxToastView(model: model))
        super.init()
        applyWinMuxLayer(.overlay)
        ignoresMouseEvents = true
        hasShadow = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = hostingView
        detailsPanel.button.interactionChanged = { [weak self] value in
            guard let self else { return }
            self.model.setInteracting(value)
            self.scheduleExpiration()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ notice: WinMuxToastNotice) {
        model.show(notice)
        displayCurrent()
    }

    private func displayCurrent() {
        guard let shown = model.shown else { hide(); return }
        // A focused/pressed control retains both its frame and its captured diagnostic.
        if !model.isInteracting {
            hostingView.rootView = WinMuxToastView(model: model)
            hostingView.layoutSubtreeIfNeeded()
            let place = winMuxToastPlace(monitorScopeId: shown.notice.monitorScopeId)
            setFrame(winMuxToastFrame(size: hostingView.fittingSize, beside: place.surface, in: place.screen), display: true)
            let notice = shown.notice
            detailsPanel.button.invoke = { [weak self] in
                guard let self else { return }
                // Dismiss this occurrence before showing the original UI; a later error is separate.
                self.detailsPanel.clearInteraction()
                if self.model.shown?.notice == notice { self.model.dismiss() }
                self.displayCurrent()
                self.openDetails(notice)
            }
            detailsPanel.button.setAccessibilityHelp("Show complete details for \(notice.title)")
            detailsPanel.setFrame(CGRect(x: frame.maxX - 66, y: frame.minY + 8, width: 54, height: 24), display: true)
        }
        orderFrontRegardless()
        detailsPanel.orderFrontRegardless()
        scheduleExpiration()
    }

    private func scheduleExpiration() {
        timer?.invalidate()
        timer = nil
        guard let shown = model.shown, !model.isInteracting else { return }
        timer = .scheduledTimer(withTimeInterval: max(0.05, shown.until - model.now), repeats: false) { _ in
            Task { @MainActor [weak self] in self?.expire() }
        }
    }

    func expire() {
        model.expire()
        displayCurrent()
    }

    func dismiss() {
        model.reset()
        hide()
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        detailsPanel.clearInteraction()
        detailsPanel.orderOut(nil)
        orderOut(nil)
    }
}

@MainActor
final class WinMuxToastDetailsPanel: NSPanelHud {
    let button = WinMuxToastDetailsButton(title: "Details", target: nil, action: nil)

    override init() {
        super.init()
        applyWinMuxLayer(.overlay)
        hasShadow = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.appearance = NSAppearance(named: .darkAqua)
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("Details")
        button.target = button
        button.action = #selector(WinMuxToastDetailsButton.showDetails)
        contentView = button
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func clearInteraction() {
        makeFirstResponder(nil)
        button.clearInteraction()
    }

    override func becomeKey() {
        super.becomeKey()
        button.updateInteraction()
    }

    override func resignKey() {
        super.resignKey()
        button.clearInteraction()
    }
}

@MainActor
final class WinMuxToastDetailsButton: NSButton {
    var invoke: (() -> Void)?
    var interactionChanged: ((Bool) -> Void)?
    private var pressed = false
    private var focused = false
    private var accessibilityFocused = false

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc func showDetails() { invoke?() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, invoke != nil else { return false }
        showDetails()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        updateInteraction()
        defer { pressed = false; updateInteraction() }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focused = true; updateInteraction() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focused = false; updateInteraction() }
        return accepted
    }

    override func setAccessibilityFocused(_ value: Bool) {
        super.setAccessibilityFocused(value)
        accessibilityFocused = value
        updateInteraction()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { showDetails() }
        else { super.keyDown(with: event) }
    }

    func clearInteraction() {
        pressed = false; focused = false; accessibilityFocused = false
        updateInteraction()
    }

    func updateInteraction() {
        interactionChanged?(pressed || (focused && window?.isKeyWindow == true) || accessibilityFocused)
    }
}

/// Where a toast about the sidebar `monitorScopeId`'s action goes: beside that sidebar while it
/// shows, otherwise on the pointer's display, beside the sidebar there if one shows.
@MainActor
func winMuxToastPlace(monitorScopeId: String?) -> (surface: CGRect?, screen: CGRect) {
    func surface(_ panel: WorkspaceSidebarPanel) -> CGRect {
        let surface = panel.visibleSurfaceFrameOnScreen
        return surface.isEmpty ? panel.frame : surface
    }
    if let monitorScopeId, let panel = WorkspaceSidebarPanel.panel(for: monitorScopeId), panel.isVisible,
       let screen = panel.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) {
        return (surface(panel), screen.visibleFrame)
    }
    let pointer = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else {
        return (nil, CGRect(x: 0, y: 0, width: 1000, height: 800))
    }
    let panel = WorkspaceSidebarPanel.visiblePanels.first { screen.frame.intersects($0.frame) }
    return (panel.map(surface), screen.visibleFrame)
}

/// The toast's frame: near the bottom of the display, beside the sidebar's surface on whichever
/// side has room, or centred when no sidebar shows; never off the display.
func winMuxToastFrame(size: CGSize, beside surface: CGRect?, in screen: CGRect) -> CGRect {
    let margin: CGFloat = 12
    var x: CGFloat
    if let surface {
        let right = surface.maxX + margin
        x = right + size.width <= screen.maxX - margin ? right : surface.minX - margin - size.width
    } else {
        x = screen.midX - size.width / 2
    }
    x = max(min(x, screen.maxX - margin - size.width), screen.minX + margin)
    return CGRect(x: x.rounded(), y: (screen.minY + 2 * margin).rounded(), width: size.width, height: size.height)
}

struct WinMuxToastView: View {
    @ObservedObject var model: WinMuxToastModel
    /// The sidebar's chrome when nil.
    var chromeStyle: ChromeStyle? = nil

    var body: some View {
        if let shown = model.shown {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.yellow.opacity(0.9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shown.notice.title).lineLimit(1)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(GlassToken.textPrimary))
                    Text(shown.notice.body.prefix(600))
                        .lineLimit(3)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(GlassToken.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: winMuxToastTextWidth(shown.notice), alignment: .leading)
                if shown.count > 1 {
                    Text("×\(shown.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(GlassToken.textTertiary))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .padding(.bottom, 29)
            .background {
                GlassSurface(shape: RoundedRectangle(cornerRadius: RadiusToken.card, style: .continuous),
                    style: chromeStyle ?? config.workspaceSidebar.chromeStyle, solidColor: config.workspaceSidebar.resolvedSolidChromeColor)
            }
            .clipShape(RoundedRectangle(cornerRadius: RadiusToken.card, style: .continuous))
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }
}

/// How wide the toast's text is: as wide as its longer line, up to 260 points, past which the
/// body wraps. A definite width, so the toast's height counts every wrapped line.
func winMuxToastTextWidth(_ notice: WinMuxToastNotice) -> CGFloat {
    let title = (notice.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
    let body = (notice.body as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
    return min(260, (max(title, body) + 2).rounded(.up))
}

/// A keyboard-only route to the same control from WinMux's status menu, without a global
/// shortcut or automatically focusing a toast over the user's current application.
struct WinMuxErrorDetailsMenuButton: View {
    @ObservedObject private var model = WinMuxToastPanel.shared.model

    var body: some View {
        if let notice = model.shown?.notice {
            Button("Show Error Details") {
                if let original = notice.original { original.show() }
                else { MessageModel.shared.openDetails(notice.diagnostic) }
                if model.shown?.notice == notice { WinMuxToastPanel.shared.dismiss() }
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
        }
    }
}
