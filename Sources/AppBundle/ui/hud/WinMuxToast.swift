import AppKit
import SwiftUI

/// A short line about an action the user just took that didn't go as asked, such as a sidebar
/// tab switch Safari didn't confirm. It shows for a few seconds beside the sidebar the action came
/// from, or on the pointer's display, never takes focus or clicks, and VoiceOver reads it out.
/// Anything the user must act on, such as a config error or a data-loss notice, stays in the
/// message window (`MessageModel`).
struct WinMuxToastNotice: Equatable {
    let title: String
    let body: String
    /// The sidebar the action came from; nil for the pointer's display.
    var monitorScopeId: String? = nil
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
    private let clock: () -> TimeInterval
    private let announce: @MainActor (String) -> Void

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         announce: @escaping @MainActor (String) -> Void = winMuxAnnounce) {
        self.clock = clock
        self.announce = announce
    }

    var now: TimeInterval { clock() }

    func show(_ notice: WinMuxToastNotice) {
        let now = clock()
        if var shown, shown.notice == notice, now < shown.until {
            shown.count += 1
            shown.until = now + Self.lifetime
            self.shown = shown
        } else {
            shown = .init(notice: notice, count: 1, until: now + Self.lifetime)
        }
        announce(notice.body)
    }

    /// Takes the toast down once its time is up.
    func expire() {
        if let shown, clock() >= shown.until { self.shown = nil }
    }

    func dismiss() { shown = nil }
}

/// Asks VoiceOver to read `text` out now, whatever has focus.
@MainActor
func winMuxAnnounce(_ text: String) {
    NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
        .announcement: text,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
    ])
}

/// The toast's window: a non-activating panel that never becomes key or main and lets every
/// click through, at the overlay layer, below the sidebar, so it sits beside it.
@MainActor
final class WinMuxToastPanel: NSPanelHud {
    static let shared = WinMuxToastPanel()
    let model: WinMuxToastModel
    private let hostingView: NSHostingView<WinMuxToastView>
    private var timer: Timer?

    init(model: WinMuxToastModel = WinMuxToastModel()) {
        self.model = model
        hostingView = NSHostingView(rootView: WinMuxToastView(model: model))
        super.init()
        applyWinMuxLayer(.overlay)
        ignoresMouseEvents = true
        hasShadow = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ notice: WinMuxToastNotice) {
        model.show(notice)
        guard let shown = model.shown else { return }
        hostingView.rootView = WinMuxToastView(model: model)
        hostingView.layoutSubtreeIfNeeded()
        let place = winMuxToastPlace(monitorScopeId: notice.monitorScopeId)
        setFrame(winMuxToastFrame(size: hostingView.fittingSize, beside: place.surface, in: place.screen), display: true)
        orderFrontRegardless()
        timer?.invalidate()
        timer = .scheduledTimer(withTimeInterval: max(0.05, shown.until - model.now), repeats: false) { _ in
            Task { @MainActor [weak self] in self?.expire() }
        }
    }

    /// Takes the toast down if its time is up, or waits for the rest of it.
    func expire() {
        model.expire()
        if let shown = model.shown {
            timer = .scheduledTimer(withTimeInterval: max(0.05, shown.until - model.now), repeats: false) { _ in
                Task { @MainActor [weak self] in self?.expire() }
            }
        } else {
            hide()
        }
    }

    /// Takes the toast down now.
    func dismiss() {
        model.dismiss()
        hide()
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
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
                    Text(shown.notice.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(GlassToken.textPrimary))
                    Text(shown.notice.body)
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
