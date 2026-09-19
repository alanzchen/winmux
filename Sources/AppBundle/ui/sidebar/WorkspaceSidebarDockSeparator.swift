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
        let horizontal = layout.dockPosition == .bottom && expansionProgress == 0
        let length = min(20 * layout.compactDockScale, compactWidth)
        Rectangle()
            .fill(Color.primary.opacity(0.20))
            .frame(width: horizontal ? 1 : length, height: horizontal ? length : 1)
            .frame(width: horizontal ? 1 : compactWidth, height: horizontal ? compactWidth : 1)
            .opacity(Double(1 - min(max(expansionProgress, 0), 1)))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
