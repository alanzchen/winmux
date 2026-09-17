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
                    Color.clear.glassEffect(.regular.interactive(false), in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
        }
        .clipShape(shape)
    }
}
