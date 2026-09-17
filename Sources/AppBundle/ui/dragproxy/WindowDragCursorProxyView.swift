import SwiftUI

struct WindowDragCursorProxyView: View {
    let label: String
    let isGroup: Bool
    let preview: WorkspaceSidebarDropPreviewViewModel?
    let style: WorkspaceSidebarDragPreviewStyle

    init(label: String, isGroup: Bool) {
        self.label = label
        self.isGroup = isGroup
        self.preview = nil
        self.style = .row
    }

    init(preview: WorkspaceSidebarDropPreviewViewModel, style: WorkspaceSidebarDragPreviewStyle = .row) {
        self.label = preview.label
        self.isGroup = preview.isTabGroup
        self.preview = preview
        self.style = style
    }

    var body: some View {
        if case .appIcon(let size) = style, let preview {
            WorkspaceSidebarDragIcon(preview: preview, size: size)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                .padding(6)
        } else {
            rowPreview
        }
    }

    private var rowPreview: some View {
        HStack(spacing: 4) {
            if let preview, preview.isTabGroup {
                sidebarIconStack(preview)
            } else if let preview, let icon = appIconImage(bundleIdentifier: preview.appBundleIdentifier, bundlePath: preview.appBundlePath) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: workspaceSidebarAppIconSize, height: workspaceSidebarAppIconSize)
                    .cornerRadius(3)
            } else {
                Image(systemName: isGroup ? "square.stack" : "macwindow")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }
            Text(label)
                .font(.system(size: isGroup ? 12.5 : 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let preview, preview.windowCount > 1 {
                Text("\(preview.windowCount)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.54))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(WindowDragCursorProxyBackground(isGroup: isGroup))
        .allowsHitTesting(false)
    }

    private func sidebarIconStack(_ preview: WorkspaceSidebarDropPreviewViewModel) -> some View {
        HStack(spacing: -3) {
            ForEach(Array(preview.tabItems.prefix(4).enumerated()), id: \.offset) { _, tab in
                if let icon = appIconImage(bundleIdentifier: tab.appBundleIdentifier, bundlePath: tab.appBundlePath) {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: workspaceSidebarAppIconSize, height: workspaceSidebarAppIconSize)
                        .cornerRadius(3)
                }
            }
        }
    }
}
