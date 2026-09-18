import AppKit
import SwiftUI

struct WorkspaceSidebarAppIconHeader: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let availableWidth: CGFloat
    let isActive: Bool
    var morphTargets: Set<String> = []
    var morphsTitle: Bool = false
    var hidesTitleForMorph: Bool = true
    var magnificationEnabled: Bool = false
    var railWidth: CGFloat = 64
    var iconSize: CGFloat = WorkspaceSidebarAppIconLayout.iconSize
    var magnificationAmount: Double = 0.5
    var compactActions: WorkspaceSidebarDockCompactActions?

    var layout: WorkspaceSidebarAppIconLayout {
        WorkspaceSidebarAppIconLayout(appCount: workspace.apps.count, availableWidth: availableWidth, magnificationEnabled: magnificationEnabled, iconSize: iconSize, magnificationAmount: magnificationAmount)
    }

    var body: some View {
        // Construct artwork, menus and action closures from the workspace snapshot.
        // Only the small motion host/modifiers below read the changing lens pose.
        WorkspaceSidebarDockHeaderMotion(
            itemSize: layout.itemSize, count: 1 + layout.visibleAppCount,
            availableWidth: availableWidth, magnificationEnabled: magnificationEnabled,
            amount: magnificationAmount, reportsHitFrames: compactActions != nil
        ) {
            ZStack(alignment: .topLeading) {
                WorkspaceSidebarWorkspaceIcon(
                    identifier: workspaceSidebarAppSummaryIdentifier(workspace),
                    isActive: isActive, size: layout.itemSize, railWidth: railWidth,
                    restingSize: layout.itemSize, showsIndicator: false
                )
                .modifier(WorkspaceSidebarMorphAnchor(element: .compactTitle, isEnabled: morphsTitle, hidesContent: hidesTitleForMorph))
                .modifier(WorkspaceSidebarDockIconMotion(index: 0, itemSize: layout.itemSize))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                if isActive {
                    WorkspaceSidebarActiveWorkspaceIndicator()
                        .modifier(WorkspaceSidebarDockIndicatorMotion(itemSize: layout.itemSize, railWidth: railWidth))
                        .opacity(morphsTitle && hidesTitleForMorph ? 0 : 1)
                }
                ForEach(Array(workspace.apps.prefix(layout.visibleAppCount).enumerated()), id: \.element.id) { index, app in
                    appIcon(app, size: layout.itemSize)
                        .modifier(WorkspaceSidebarMorphAnchor(element: .compactApp(app.id), hidesContent: morphTargets.contains(app.id)))
                        .modifier(WorkspaceSidebarDockIconMotion(index: index + 1, itemSize: layout.itemSize))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if let compactActions {
                    Button(action: compactActions.onSelectWorkspace) {
                        Color.clear.frame(width: layout.itemSize, height: layout.itemSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Switch to workspace \(workspace.displayName)")
                    .modifier(WorkspaceSidebarDockIconMotion(index: 0, itemSize: layout.itemSize))
                    ForEach(Array(workspace.apps.prefix(layout.visibleAppCount).enumerated()), id: \.element.id) { index, app in
                        WorkspaceSidebarDockMovingAppButton(
                            app: app, workspaceName: workspace.name, workspaceDisplayName: workspace.displayName,
                            itemSize: layout.itemSize, index: index + 1, actions: compactActions.actions,
                            onSelect: { compactActions.onSelectApp(app) }
                        )
                        .modifier(WorkspaceSidebarDockIconMotion(index: index + 1, itemSize: layout.itemSize))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: compactActions == nil ? .ignore : .contain)
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
        .overlay { WorkspaceSidebarDockBadge(app: app) }
        .accessibilityHidden(true)
    }
}

/// Frame-dependent layout lives below the snapshot-built icon/button tree. This
/// prevents GeometryReader's moving origin from rebuilding that tree each frame.
struct WorkspaceSidebarDockHeaderMotion<Content: View>: View {
    let itemSize: CGFloat
    let count: Int
    let availableWidth: CGFloat
    let magnificationEnabled: Bool
    let amount: Double
    let reportsHitFrames: Bool
    let content: Content
    @Environment(\.workspaceSidebarDockPointer) private var pointer
    @Environment(\.workspaceSidebarDockSectionMagnification) private var section

    init(itemSize: CGFloat, count: Int, availableWidth: CGFloat, magnificationEnabled: Bool,
         amount: Double, reportsHitFrames: Bool, @ViewBuilder content: () -> Content) {
        self.itemSize = itemSize
        self.count = count
        self.availableWidth = availableWidth
        self.magnificationEnabled = magnificationEnabled
        self.amount = amount
        self.reportsHitFrames = reportsHitFrames
        self.content = content()
    }

    var body: some View {
        let layout = WorkspaceSidebarDockMagnification(itemSize: itemSize, count: count,
            enabled: magnificationEnabled, amount: amount * (section?.strength ?? 1))
        GeometryReader { geometry in
            let origin = geometry.frame(in: .named("workspaceSidebarContent")).origin
            let localPointer = section != nil ? section?.pointerY : pointer.map { $0.y - origin.y }
            let frames = layout.frames(width: availableWidth, pointerY: localPointer)
            content
                .environment(\.workspaceSidebarDockIconFrames, frames)
                .preference(key: WorkspaceSidebarDockIconFramesPreference.self,
                    value: reportsHitFrames ? frames.map { $0.offsetBy(dx: origin.x, dy: origin.y) } : [])
        }
        .frame(width: availableWidth, height: layout.renderedHeight(pointerY: section?.pointerY), alignment: .center)
    }
}

private struct WorkspaceSidebarDockIconFramesKey: EnvironmentKey {
    static let defaultValue: [CGRect] = []
}

extension EnvironmentValues {
    var workspaceSidebarDockIconFrames: [CGRect] {
        get { self[WorkspaceSidebarDockIconFramesKey.self] }
        set { self[WorkspaceSidebarDockIconFramesKey.self] = newValue }
    }
}

struct WorkspaceSidebarDockIconMotion: ViewModifier {
    let index: Int
    let itemSize: CGFloat
    @Environment(\.workspaceSidebarDockIconFrames) private var frames

    func body(content: Content) -> some View {
        let frame = frames.indices.contains(index) ? frames[index] : CGRect(x: 0, y: 0, width: itemSize, height: itemSize)
        content.scaleEffect(frame.width / itemSize, anchor: .topLeading)
            .offset(x: frame.minX, y: frame.minY)
    }
}

private struct WorkspaceSidebarDockIndicatorMotion: ViewModifier {
    let itemSize: CGFloat
    let railWidth: CGFloat
    @Environment(\.workspaceSidebarDockIconFrames) private var frames

    func body(content: Content) -> some View {
        let frame = frames.first ?? CGRect(x: 0, y: 0, width: itemSize, height: itemSize)
        content.offset(x: frame.minX + workspaceSidebarIndicatorLeadingOffset(tileSize: itemSize, railWidth: railWidth),
            y: frame.midY - 2)
    }
}

private struct WorkspaceSidebarDockMovingAppButton: View {
    let app: WorkspaceSidebarAppViewModel
    let workspaceName: String
    let workspaceDisplayName: String
    let itemSize: CGFloat
    let index: Int
    let actions: WorkspaceSidebarActions
    let onSelect: () -> Void
    @Environment(\.workspaceSidebarDockIconFrames) private var frames

    var body: some View {
        WorkspaceSidebarDockAppButton(app: app, workspaceName: workspaceName,
            workspaceDisplayName: workspaceDisplayName, size: CGSize(width: itemSize, height: itemSize),
            iconSize: frames.indices.contains(index) ? frames[index].width : itemSize,
            actions: actions, onSelect: onSelect)
    }
}

struct WorkspaceSidebarWorkspaceIcon: View {
    let identifier: String
    let isActive: Bool
    let size: CGFloat
    var railWidth: CGFloat = 64
    var restingSize: CGFloat? = nil
    var showsIndicator = true

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
                if isActive && showsIndicator {
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
