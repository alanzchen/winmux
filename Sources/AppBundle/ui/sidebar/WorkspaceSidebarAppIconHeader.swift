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
        Group {
            if layout.isInline {
                HStack(spacing: 6) {
                    badge
                    if layout.visibleAppCount > 0 {
                        HStack(spacing: WorkspaceSidebarAppIconLayout.spacing) {
                            ForEach(workspace.apps.prefix(layout.visibleAppCount)) { app in
                                appIcon(app)
                            }
                            if layout.overflowCount > 0 { overflow }
                        }
                    }
                }
            } else {
                VStack(spacing: 4) {
                    badge
                    VStack(spacing: WorkspaceSidebarAppIconLayout.spacing) {
                        ForEach(0 ..< gridRowCount, id: \.self) { row in
                            HStack(spacing: WorkspaceSidebarAppIconLayout.spacing) {
                                ForEach(gridIndices(for: row), id: \.self) { index in
                                    if index < layout.visibleAppCount {
                                        appIcon(workspace.apps[index])
                                    } else {
                                        overflow
                                            .frame(width: min(WorkspaceSidebarAppIconLayout.iconSize, availableWidth))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: availableWidth, height: layout.height, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workspaceSidebarAppSummaryLabel(workspace))
    }

    private var badge: some View {
        Text(workspaceSidebarAppSummaryIdentifier(workspace))
            .font(.system(size: 18, weight: isActive ? .bold : .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(isActive ? 1 : 0.70))
            .lineLimit(1)
            .minimumScaleFactor(0.35)
            .frame(width: min(WorkspaceSidebarAppIconLayout.badgeHeight, availableWidth), height: WorkspaceSidebarAppIconLayout.badgeHeight)
            .modifier(WorkspaceSidebarMorphAnchor(element: .compactTitle, isEnabled: morphsTitle))
    }

    private func appIcon(_ app: WorkspaceSidebarAppViewModel) -> some View {
        Group {
            if let icon = appIconImage(bundleIdentifier: app.bundleId, bundlePath: app.bundlePath) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.white.opacity(0.75))
            }
        }
        .frame(width: min(WorkspaceSidebarAppIconLayout.iconSize, availableWidth), height: WorkspaceSidebarAppIconLayout.iconSize)
        .modifier(WorkspaceSidebarMorphAnchor(element: .compactApp(app.id), isEnabled: morphTargets.contains(app.id)))
        .accessibilityHidden(true)
    }

    private var overflow: some View {
        Text("+\(layout.overflowCount)")
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.65))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(height: WorkspaceSidebarAppIconLayout.iconSize)
    }

    private var gridItemCount: Int {
        layout.visibleAppCount + (layout.overflowCount > 0 ? 1 : 0)
    }

    private var gridRowCount: Int {
        (gridItemCount + layout.columns - 1) / layout.columns
    }

    private func gridIndices(for row: Int) -> Range<Int> {
        let start = row * layout.columns
        return start ..< min(start + layout.columns, gridItemCount)
    }
}
