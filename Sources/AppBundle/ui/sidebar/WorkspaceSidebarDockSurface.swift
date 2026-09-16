import SwiftUI

/// Compact Dock material. Keep this independent of the darker expanded sidebar chrome.
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
                    Color.clear.glassEffect(.clear.interactive(false), in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
                shape.fill(Color(white: 37 / 255).opacity(0.74))
            }
        }
        .overlay {
            if configuration.chromeStyle == .liquidGlass {
                shape.stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.16), location: 0),
                            .init(color: .white.opacity(0.12), location: 0.28),
                            .init(color: .white.opacity(0.04), location: 0.76),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
        }
        .clipShape(shape)
    }
}
