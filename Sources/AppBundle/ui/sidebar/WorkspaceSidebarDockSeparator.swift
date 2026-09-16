import SwiftUI

struct WorkspaceSidebarDockSeparator: View, Animatable {
    nonisolated var expansionProgress: CGFloat
    let layout: WorkspaceSidebarConfiguration
    @Environment(\.displayScale) private var displayScale

    nonisolated var animatableData: CGFloat {
        get { expansionProgress }
        set { expansionProgress = newValue }
    }

    var body: some View {
        let compactWidth = max(layout.compactRailWidth - workspaceSidebarCompactRailHorizontalInset * 2, 1)
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(width: min(WorkspaceSidebarAppIconLayout.iconSize, compactWidth), height: 1 / max(displayScale, 1))
            .frame(width: compactWidth)
            .opacity(Double(1 - min(max(expansionProgress, 0), 1)))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
