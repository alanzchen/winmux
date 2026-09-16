import AppKit
import SwiftUI

struct WorkspaceSidebarAppIconHeader: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let availableWidth: CGFloat
    let isActive: Bool
    var morphTargets: Set<String> = []
    var morphsTitle: Bool = false

    var layout: WorkspaceSidebarAppIconLayout {
        WorkspaceSidebarAppIconLayout(appCount: workspace.apps.count, availableWidth: availableWidth)
    }

    var body: some View {
        VStack(spacing: WorkspaceSidebarAppIconLayout.spacing) {
            WorkspaceSidebarWorkspaceIcon(
                identifier: workspaceSidebarAppSummaryIdentifier(workspace),
                isActive: isActive,
                size: layout.itemSize
            )
            .modifier(WorkspaceSidebarMorphAnchor(element: .compactTitle, isEnabled: morphsTitle))
            ForEach(workspace.apps.prefix(layout.visibleAppCount)) { app in
                appIcon(app)
            }
            if layout.overflowCount > 0 {
                WorkspaceSidebarWorkspaceIcon(identifier: "+\(layout.overflowCount)", isActive: false, size: layout.itemSize)
            }
        }
        .frame(width: availableWidth, height: layout.height, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workspaceSidebarAppSummaryLabel(workspace))
    }

    private func appIcon(_ app: WorkspaceSidebarAppViewModel) -> some View {
        Group {
            if let icon = appIconImage(bundleIdentifier: app.bundleId, bundlePath: app.bundlePath) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                WorkspaceSidebarWorkspaceIconBackground(isActive: false)
                    .overlay {
                        Image(systemName: "app.dashed")
                            .font(.system(size: layout.itemSize * 0.50, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
            }
        }
        .frame(width: layout.itemSize, height: layout.itemSize)
        .modifier(WorkspaceSidebarMorphAnchor(element: .compactApp(app.id), isEnabled: morphTargets.contains(app.id)))
        .accessibilityHidden(true)
    }
}

struct WorkspaceSidebarWorkspaceIcon: View {
    let identifier: String
    let isActive: Bool
    let size: CGFloat

    var body: some View {
        WorkspaceSidebarWorkspaceIconBackground(isActive: isActive)
            .overlay {
                Text(identifier)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.98))
                    .lineLimit(1)
                    .minimumScaleFactor(0.25)
                    .padding(.horizontal, size * 0.13)
            }
            .frame(width: size, height: size)
    }
}

/// A standard app-icon silhouette; the numeral has the same footprint as its apps.
struct WorkspaceSidebarWorkspaceIconBackground: View {
    let isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                .fill(LinearGradient(
                    colors: isActive
                        ? [Color(red: 0.37, green: 0.64, blue: 0.96), Color(red: 0.16, green: 0.38, blue: 0.78)]
                        : [Color(red: 0.47, green: 0.51, blue: 0.57), Color(red: 0.26, green: 0.29, blue: 0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                        .strokeBorder(LinearGradient(
                            colors: [Color.white.opacity(0.38), Color.white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ), lineWidth: 0.5)
                }
                .padding(side * 0.07)
        }
    }
}
