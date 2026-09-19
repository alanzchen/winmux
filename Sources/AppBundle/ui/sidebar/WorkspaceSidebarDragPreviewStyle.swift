import SwiftUI

enum WorkspaceSidebarDragPreviewStyle: Equatable {
    case row
    case appIcon(size: CGFloat)
}

/// Shared by the cursor proxy and compact drop targets so an icon drag stays an icon.
struct WorkspaceSidebarDragIcon: View {
    let preview: WorkspaceSidebarDropPreviewViewModel
    let size: CGFloat

    var body: some View {
        AppIconView(bundleIdentifier: preview.appBundleIdentifier, bundlePath: preview.appBundlePath) { icon in
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                WorkspaceSidebarWorkspaceIconBackground(isActive: false)
                    .overlay {
                        Image(systemName: preview.isTabGroup ? "square.stack" : "app.dashed")
                            .font(.system(size: size * 0.5, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if preview.windowCount > 1 {
                Text("\(preview.windowCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(.black.opacity(0.75), in: Capsule())
            }
        }
        .accessibilityLabel(preview.appName)
        .allowsHitTesting(false)
    }
}
