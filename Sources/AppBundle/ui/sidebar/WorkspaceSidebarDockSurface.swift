import SwiftUI

/// One clear glass shelf in Dock mode, independent of the original dark Sidebar chrome.
struct WorkspaceSidebarDockSurface<S: Shape>: View {
    let shape: S
    let configuration: WorkspaceSidebarConfiguration
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if configuration.chromeStyle == .solid {
                shape.fill(configuration.resolvedSolidChromeColor)
            } else if reduceTransparency {
                shape.fill(Color(white: 0.18))
            } else {
                if #available(macOS 26.0, *) {
                    // Clear preserves wallpaper color and the native refractive edge.
                    // Lowering regular glass opacity also fades that edge away.
                    Color.clear
                        .glassEffect(.clear.interactive(false), in: shape)
                        .overlay {
                            // The panel clips outside the shelf. Keep a fine inner rim
                            // visible there without stacking a second glass effect.
                            shape.stroke(LinearGradient(
                                colors: [Color.white.opacity(0.45), Color.white.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ), lineWidth: 1)
                        }
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
        }
        // The enclosing sidebarSurface clips the material and rim together.
    }
}
