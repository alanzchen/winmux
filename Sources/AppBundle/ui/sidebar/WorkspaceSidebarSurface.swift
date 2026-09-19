import AppKit
import SwiftUI

/// Dark Liquid Glass over a stronger native blur, independent of the compact Dock.
struct WorkspaceSidebarSurface<S: Shape>: View {
    let shape: S
    let configuration: WorkspaceSidebarConfiguration
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let reduceTransparencyOverride: Bool?

    init(shape: S, configuration: WorkspaceSidebarConfiguration, reduceTransparencyOverride: Bool? = nil) {
        self.shape = shape
        self.configuration = configuration
        self.reduceTransparencyOverride = reduceTransparencyOverride
    }

    var body: some View {
        ZStack {
            if configuration.sidebarBlur && !(reduceTransparencyOverride ?? reduceTransparency) {
                WorkspaceSidebarBlurView()
                if #available(macOS 26.0, *) {
                    Color.clear
                        .glassEffect(.regular.interactive(false), in: shape)
                        .environment(\.colorScheme, .dark)
                }
                // Native black tint adapts to the backdrop and can lighten it. A scrim
                // gives the darkness control a predictable effect without fading content.
                shape.fill(Color.black.opacity(configuration.sidebarBackgroundOpacity))
            } else {
                shape.fill(Color(white: 0.08))
            }
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

/// AppKit supplies GPU-composited behind-window blur without capturing the screen.
/// Keep its appearance active while other apps have focus, including before search starts.
struct WorkspaceSidebarBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
