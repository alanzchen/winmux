import SwiftUI

/// The same app-level label mirrored by Dock mode, fitted to a tab's trailing accessory.
struct WorkspaceSidebarTabBadge: View {
    let appName: String
    let bundlePath: String?
    @ObservedObject var model: WorkspaceSidebarDockBadgeModel
    var compact = false

    var body: some View {
        if model.snapshot.showsAppBadges, let label = model.snapshot.label(forPath: bundlePath) {
            Text(compact ? "" : (label.count > 4 ? String(label.prefix(3)) + "…" : label))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, compact ? 0 : 4)
                .frame(minWidth: compact ? 6 : 16, maxWidth: compact ? 6 : 32,
                    minHeight: compact ? 6 : 16, maxHeight: compact ? 6 : 16)
                .fixedSize(horizontal: compact, vertical: false)
                .background(Color(red: 0.96, green: 0.20, blue: 0.23), in: Capsule())
                .accessibilityLabel("\(appName) badge: \(label)")
                .allowsHitTesting(false)
        }
    }
}
