import SwiftUI

@MainActor
func workspaceSidebarInUseOverrideMinHeight(sectionWidth: CGFloat) -> CGFloat {
    let cancelWidth = ("Cancel" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).width
    let overrideWidth = ("Override" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold)]).width + 28
    let actionsWidth = ceil(cancelWidth + overrideWidth + 12)
    return sectionWidth < actionsWidth
        ? workspaceSidebarInUseOverrideEmptySectionMinHeight + 24
        : workspaceSidebarInUseOverrideEmptySectionMinHeight
}

struct WorkspaceSidebarInUseOverrideOverlay: View {
    let text: String
    let onOverride: () -> Void
    let onCancel: () -> Void
    @State private var isOverrideHovered = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: workspaceSidebarSectionCornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            Color.clear
                .background(.ultraThinMaterial)
                .overlay {
                    shape.fill(Color(nsColor: .systemRed).opacity(0.14))
                }
                .clipShape(shape)

            shape.strokeBorder(Color(nsColor: .systemRed).opacity(0.45), lineWidth: 0.8)

            VStack(spacing: 8) {
                Text(text)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        cancelButton
                        overrideButton
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(spacing: 6) {
                        overrideButton
                        cancelButton
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .contentShape(Rectangle())
    }

    private var cancelButton: some View {
        Button("Cancel", action: onCancel)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.8))
            .buttonStyle(.plain)
            .fixedSize()
    }

    private var overrideButton: some View {
        Button(action: onOverride) {
            Text("Override")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .systemRed).opacity(isOverrideHovered ? 1 : 0.88))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.white.opacity(isOverrideHovered ? 0.28 : 0), lineWidth: 0.6)
        }
        .onHover { hovering in
            isOverrideHovered = hovering
        }
    }
}
