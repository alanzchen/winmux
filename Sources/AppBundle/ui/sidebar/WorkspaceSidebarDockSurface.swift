import SwiftUI

/// One native regular glass shelf in Dock mode, independent of the original dark Sidebar chrome.
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
                    // Let the native material provide backdrop blur and edge highlights.
                    Color.clear
                        .glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
        }
        // The enclosing sidebarSurface clips the material to the shelf shape.
    }
}
