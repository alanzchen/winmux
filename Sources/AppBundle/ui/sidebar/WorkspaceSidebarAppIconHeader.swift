import AppKit
import SwiftUI

struct WorkspaceSidebarAppIconHeader: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let availableWidth: CGFloat
    let isActive: Bool
    var morphTargets: Set<String> = []
    var morphsTitle: Bool = false
    var magnificationEnabled: Bool = false
    var railWidth: CGFloat = 64
    var iconSize: CGFloat = WorkspaceSidebarAppIconLayout.iconSize
    var magnificationAmount: Double = 0.5
    @Environment(\.workspaceSidebarDockPointer) private var pointer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workspaceSidebarDockDrag) private var dockDrag

    var layout: WorkspaceSidebarAppIconLayout {
        WorkspaceSidebarAppIconLayout(appCount: workspace.apps.count, availableWidth: availableWidth, magnificationEnabled: magnificationEnabled, iconSize: iconSize, magnificationAmount: magnificationAmount)
    }

    var body: some View {
        GeometryReader { geometry in
            let count = 1 + layout.visibleAppCount
            let magnification = WorkspaceSidebarDockMagnification(itemSize: layout.itemSize, count: count, enabled: magnificationEnabled, amount: magnificationAmount)
            let origin = geometry.frame(in: .named("workspaceSidebarContent")).minY
            let frames = magnification.frames(width: availableWidth, pointerY: pointer.map { $0.y - origin })
            ZStack(alignment: .topLeading) {
                WorkspaceSidebarWorkspaceIcon(
                    identifier: workspaceSidebarAppSummaryIdentifier(workspace),
                    isActive: isActive,
                    size: frames[0].width,
                    railWidth: railWidth,
                    restingSize: layout.itemSize
                )
                .modifier(WorkspaceSidebarMorphAnchor(element: .compactTitle, isEnabled: morphsTitle))
                .position(x: frames[0].midX, y: frames[0].midY)
                ForEach(Array(workspace.apps.prefix(layout.visibleAppCount).enumerated()), id: \.element.id) { index, app in
                    let rect = frames[index + 1]
                    appIcon(app, size: rect.width)
                        .opacity(dockDrag?.hidesIcon(workspaceName: workspace.name, appId: app.id) == true ? 0 : 1)
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: availableWidth, height: layout.height, alignment: .center)
        .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.85), value: pointer)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dockDrag?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workspaceSidebarAppSummaryLabel(workspace))
    }

    private func appIcon(_ app: WorkspaceSidebarAppViewModel, size: CGFloat) -> some View {
        Group {
            if let icon = appIconImage(bundleIdentifier: app.bundleId, bundlePath: app.bundlePath) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                WorkspaceSidebarWorkspaceIconBackground(isActive: false)
                    .overlay {
                        Image(systemName: "app.dashed")
                            .font(.system(size: size * 0.50, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
            }
        }
        .frame(width: size, height: size)
        .modifier(WorkspaceSidebarMorphAnchor(element: .compactApp(app.id), hidesContent: morphTargets.contains(app.id)))
        .accessibilityHidden(true)
    }
}

struct WorkspaceSidebarWorkspaceIcon: View {
    let identifier: String
    let isActive: Bool
    let size: CGFloat
    var railWidth: CGFloat = 64
    var restingSize: CGFloat? = nil

    var body: some View {
        WorkspaceSidebarWorkspaceIconBackground(isActive: isActive)
            .overlay {
                Text(identifier)
                    // Keep glyph layout stable while the tile magnifies. Animating font
                    // sizes repeatedly re-lays out text as anchor geometry changes.
                    .font(.system(size: 28.6, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.98))
                    .lineLimit(1)
                    .minimumScaleFactor(0.25)
                    .padding(.horizontal, 6.76)
                    .frame(width: 52, height: 52)
                    .scaleEffect(size / 52)
            }
            .frame(width: size, height: size)
            .overlay(alignment: .leading) {
                if isActive {
                    WorkspaceSidebarActiveWorkspaceIndicator()
                        .offset(x: workspaceSidebarIndicatorLeadingOffset(tileSize: restingSize ?? size, railWidth: railWidth))
                }
            }
    }
}

struct WorkspaceSidebarActiveWorkspaceIndicator: View {
    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.82))
            .frame(width: 4, height: 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
