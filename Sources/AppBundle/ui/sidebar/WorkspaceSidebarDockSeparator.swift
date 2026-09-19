import SwiftUI

struct WorkspaceSidebarDockSeparator: View, Animatable {
    nonisolated var expansionProgress: CGFloat
    let layout: WorkspaceSidebarConfiguration

    nonisolated var animatableData: CGFloat {
        get { expansionProgress }
        set { expansionProgress = newValue }
    }

    var body: some View {
        let compactWidth = max(layout.compactRailWidth - layout.compactHorizontalInset * 2, 1)
        Rectangle()
            .fill(Color.primary.opacity(0.20))
            .frame(width: min(20 * layout.compactDockScale, compactWidth), height: 1)
            .frame(width: compactWidth)
            .opacity(Double(1 - min(max(expansionProgress, 0), 1)))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
