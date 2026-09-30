import AppKit
import SwiftUI

/// A speaker on a tab whose window is playing sound, or a muted one on a window with a muted
/// browser tab. Core Audio reports sound per app; a browser's tabs say which window it comes
/// from, and without them every window of the app shows it.
struct WorkspaceSidebarTabAudioIndicator: View {
    let window: WorkspaceSidebarWindowViewModel
    var size: CGFloat = 10
    @ObservedObject var model: AudioActivityModel = .shared
    @Environment(\.workspaceSidebarBrowserWindows) private var browserWindows

    var body: some View {
        if let audio = browserWindows.audio(windowId: window.windowId, bundleId: window.appBundleId,
            appIsPlaying: model.isPlaying(bundleId: window.appBundleId)) {
            let label = audio == .muted ? "Muted" : "Playing sound"
            Image(systemName: audio == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.55))
                .help(label)
                .accessibilityLabel(label)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// Whether a tab shows Music's now playing under its row.
func workspaceSidebarShowsNowPlaying(_ window: WorkspaceSidebarWindowViewModel) -> Bool {
    window.appBundleId == appleMusicBundleId
}

/// Where clicking the player at the bottom of the sidebar goes: Music's window, brought to this
/// display like its tab, or focused on the display already showing it. Nil when no Music window
/// is listed, so Music is opened instead.
func workspaceSidebarBottomMusicPlayerAction(
    _ workspaces: [WorkspaceSidebarWorkspaceViewModel],
    targetMonitorScopeId: String,
) -> WorkspaceSidebarAction? {
    // A window on screen here first, then one on screen elsewhere, then the first listed.
    func rank(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> Int {
        workspaceSidebarTabIsActive(workspace, on: targetMonitorScopeId) ? 0 : workspace.isVisible ? 1 : 2
    }
    let target = workspaces.flatMap { workspace in
        workspaceSidebarPinnedTabWindows(workspace).filter(workspaceSidebarShowsNowPlaying).map { (workspace, $0) }
    }.min { rank($0.0) < rank($1.0) }
    guard let (workspace, window) = target else { return nil }
    return workspaceSidebarWorkspaceIsInUseOnOtherDisplay(workspace, selectedScopeId: targetMonitorScopeId)
        ? .focusWindowInPlace(window.windowId) : .selectWindow(window.windowId)
}

func workspaceSidebarNowPlayingTime(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

/// Music's tab: the track playing, its artwork and progress, and playback controls.
struct WorkspaceSidebarMusicNowPlayingView: View {
    let onSelect: () -> Void
    @ObservedObject var model: AppleMusicNowPlayingModel = .shared
    @ObservedObject var audio: AudioActivityModel = .shared
    @Environment(\.workspaceSidebarTabIndent) private var indent

    private var track: AppleMusicNowPlaying? {
        model.nowPlaying.flatMap { $0.state != .stopped && !$0.title.isEmpty ? $0 : nil }
    }

    /// Until Music has said what it's playing, whether it's making sound.
    private var isPlaying: Bool {
        model.nowPlaying.map { $0.state == .playing } ?? audio.isPlaying(bundleId: appleMusicBundleId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkspaceSidebarNowPlayingHeaderLayout {
                Button(action: onSelect) {
                    HStack(spacing: 9) {
                        artwork
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track?.title ?? (isPlaying ? "Playing" : "Not Playing"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(track == nil ? 0.6 : 0.92))
                            if let subtitle {
                                Text(subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.primary.opacity(0.6))
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(track.map { [$0.title, subtitle].compactMap(\.self).joined(separator: " — ") } ?? "Music")
                .accessibilityLabel(track.map { "Now playing: \($0.title)" + (subtitle.map { ", \($0)" } ?? "") }
                    ?? (isPlaying ? "Music: playing" : "Music: not playing"))
                controls
            }
            if let track, let duration = track.duration, track.position != nil {
                // Counts on only while playing, so a paused track doesn't redraw every second.
                if track.state == .playing {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        WorkspaceSidebarNowPlayingProgress(elapsed: track.elapsed(at: context.date) ?? 0, duration: duration)
                    }
                } else {
                    WorkspaceSidebarNowPlayingProgress(elapsed: track.elapsed(at: track.positionDate) ?? 0, duration: duration)
                }
            }
            if model.needsAutomationPermission {
                Button("Allow WinMux to control Music in System Settings…") { model.openAutomationSettings() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                    .lineLimit(2)
            }
        }
        .padding(.leading, indent.leadingPadding)
        .padding(.trailing, 8)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .animation(WorkspaceSidebarTabMotion.feedback, value: track?.trackKey)
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String? {
        guard let track else { return nil }
        let parts = [track.artist, track.album].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Group {
            if let image = model.artwork, track != nil {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(red: 0.98, green: 0.36, blue: 0.45), Color(red: 0.98, green: 0.23, blue: 0.32)],
                    startPoint: .top, endPoint: .bottom)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: workspaceSidebarNowPlayingArtworkSize, height: workspaceSidebarNowPlayingArtworkSize)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            control("backward.fill", label: "Previous", size: 12) { model.send(.previous) }
            control(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play", size: 16) {
                model.send(.playPause)
            }
            control("forward.fill", label: "Next", size: 12) { model.send(.next) }
        }
    }

    private func control(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceSidebarNowPlayingControlStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

let workspaceSidebarNowPlayingArtworkSize: CGFloat = 40
/// The least of the track's title the player shows beside its controls.
let workspaceSidebarNowPlayingMinimumTitleWidth: CGFloat = 56

/// The track, then the playback controls: side by side while the title keeps room to be read,
/// otherwise the controls go under the track, centered, so a narrow sidebar never cuts them off.
struct WorkspaceSidebarNowPlayingHeaderLayout: SwiftUI.Layout {
    private let spacing: CGFloat = 9
    private let stackedSpacing: CGFloat = 4

    static func placesControlsBeside(width: CGFloat, controlsWidth: CGFloat) -> Bool {
        width >= workspaceSidebarNowPlayingArtworkSize + 9 + workspaceSidebarNowPlayingMinimumTitleWidth + 9 + controlsWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let controls = subviews[1].sizeThatFits(.unspecified)
        guard let width = proposal.width, width.isFinite else {
            let track = subviews[0].sizeThatFits(.unspecified)
            return CGSize(width: track.width + spacing + controls.width, height: max(track.height, controls.height))
        }
        if Self.placesControlsBeside(width: width, controlsWidth: controls.width) {
            let track = subviews[0].sizeThatFits(ProposedViewSize(width: width - spacing - controls.width, height: nil))
            return CGSize(width: width, height: max(track.height, controls.height))
        }
        let track = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: track.height + stackedSpacing + controls.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let controls = subviews[1].sizeThatFits(.unspecified)
        if Self.placesControlsBeside(width: bounds.width, controlsWidth: controls.width) {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: bounds.width - spacing - controls.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
            return
        }
        let track = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.minY + track.height + stackedSpacing), anchor: .top,
            proposal: .unspecified)
    }
}

/// Music's player at the bottom of the expanded Tabs sidebar, while Music is open: whichever
/// tab or project is showing, and even when Music has no window.
struct WorkspaceSidebarBottomMusicPlayer: View {
    let onSelect: () -> Void
    @ObservedObject var model: AppleMusicNowPlayingModel = .shared
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion

    var body: some View {
        ZStack {
            if model.isRunning {
                WorkspaceSidebarMusicNowPlayingView(onSelect: onSelect, model: model)
                    // The player's own top padding follows a tab's row; here it starts the card.
                    .padding(.top, 6)
                    .background {
                        RoundedRectangle(cornerRadius: workspaceSidebarTabCornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    }
                    .padding(.horizontal, workspaceSidebarTabsListInset).padding(.top, 6)
                    .transition(reducesMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reducesMotion ? WorkspaceSidebarTabMotion.feedback : WorkspaceSidebarTabMotion.disclosure,
            value: model.isRunning)
    }
}

private struct WorkspaceSidebarNowPlayingControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkspaceSidebarNowPlayingControl(configuration: configuration)
    }
}

private struct WorkspaceSidebarNowPlayingControl: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : isHovered ? 0.07 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .onHover { isHovered = $0 }
    }
}

struct WorkspaceSidebarNowPlayingProgress: View {
    let elapsed: TimeInterval
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 6) {
            Text(workspaceSidebarNowPlayingTime(elapsed)).fixedSize()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(Color.primary.opacity(0.12))
                    Capsule(style: .continuous).fill(Color.primary.opacity(0.5))
                        .frame(width: geometry.size.width * CGFloat(duration > 0 ? min(1, elapsed / duration) : 0))
                }
            }
            .frame(height: 3)
            Text("-" + workspaceSidebarNowPlayingTime(max(0, duration - elapsed))).fixedSize()
        }
        .font(.system(size: 9, weight: .medium).monospacedDigit())
        .foregroundStyle(Color.primary.opacity(0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(workspaceSidebarNowPlayingTime(elapsed)) of \(workspaceSidebarNowPlayingTime(duration))")
    }
}
