import AppKit
import SwiftUI

enum WorkspaceSidebarMorphElement: Hashable {
    case compactTitle
    case expandedTitle
    case compactApp(String)
    case expandedApp(String)
}

struct WorkspaceSidebarMorphPreference: PreferenceKey {
    static let defaultValue: [WorkspaceSidebarMorphElement: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [WorkspaceSidebarMorphElement: Anchor<CGRect>],
        nextValue: () -> [WorkspaceSidebarMorphElement: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { first, _ in first })
    }
}

struct WorkspaceSidebarMorphAnchor: ViewModifier {
    let element: WorkspaceSidebarMorphElement
    var isEnabled: Bool = true
    var hidesContent: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .anchorPreference(key: WorkspaceSidebarMorphPreference.self, value: .bounds) { [element: $0] }
                .opacity(hidesContent ? 0 : 1)
        } else {
            content
        }
    }
}

/// Both presentations stay mounted so their anchors describe the two morph endpoints.
struct WorkspaceSidebarMorphLayout: SwiftUI.Layout {
    var progress: CGFloat
    let compactWidth: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? compactWidth
        guard subviews.count == 2 else { return CGSize(width: width, height: 0) }
        let sizes = measuredSizes(subviews: subviews, expandedWidth: width)
        return CGSize(
            width: width,
            height: interpolate(sizes.compact.height, sizes.expanded.height, progress: progress)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let sizes = measuredSizes(subviews: subviews, expandedWidth: bounds.width)
        let origin = CGPoint(x: bounds.minX, y: bounds.minY)
        subviews[0].place(
            at: origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: compactWidth, height: sizes.compact.height)
        )
        subviews[1].place(
            at: origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: sizes.expanded.height)
        )
    }

    private func measuredSizes(subviews: Subviews, expandedWidth: CGFloat) -> (compact: CGSize, expanded: CGSize) {
        (
            subviews[0].sizeThatFits(ProposedViewSize(width: compactWidth, height: nil)),
            subviews[1].sizeThatFits(ProposedViewSize(width: expandedWidth, height: nil))
        )
    }
}

struct WorkspaceSidebarAppMorphTarget {
    let windowId: UInt32
    let opacity: Double
}

struct WorkspaceSidebarMorphOverlay: View {
    let anchors: [WorkspaceSidebarMorphElement: Anchor<CGRect>]
    let progress: CGFloat
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let targets: [String: WorkspaceSidebarAppMorphTarget]
    let isActive: Bool
    let morphsTitle: Bool
    var railWidth: CGFloat = 64

    var body: some View {
        GeometryReader { geometry in
            ForEach(workspace.apps) { app in
                if let target = targets[app.id],
                   let compactAnchor = anchors[.compactApp(app.id)],
                   let expandedAnchor = anchors[.expandedApp(app.id)]
                {
                    let rect = interpolatedRect(from: geometry[compactAnchor], to: geometry[expandedAnchor])
                    appIcon(app)
                        .frame(width: rect.width, height: rect.height)
                        .opacity(Double(interpolate(1, CGFloat(target.opacity), progress: progress)))
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            if morphsTitle,
               let compactAnchor = anchors[.compactTitle],
               let expandedAnchor = anchors[.expandedTitle]
            {
                let compactRect = geometry[compactAnchor]
                let rect = interpolatedRect(from: compactRect, to: geometry[expandedAnchor])
                let fontSize = interpolate(compactRect.height * 0.55, 15, progress: progress)
                let textScale = max(fontSize / 28.6, 0.001)
                let textWidth = max(rect.width - compactRect.width * 0.26 * (1 - clampedProgress), 1)
                ZStack {
                    WorkspaceSidebarWorkspaceIconBackground(isActive: isActive)
                        .opacity(Double((1 - clampedProgress) * (1 - clampedProgress)))
                    title(availableWidth: textWidth / textScale, fontSize: 28.6)
                        .font(.system(size: 28.6, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(Double(interpolate(0.98, isActive ? 1 : 0.85, progress: progress))))
                        .lineLimit(1)
                        .minimumScaleFactor(interpolate(0.25, 1, progress: progress))
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: textWidth / textScale, height: rect.height / textScale)
                        .scaleEffect(textScale)
                        .frame(width: textWidth, height: rect.height)
                }
                .frame(width: rect.width, height: rect.height)
                .overlay(alignment: .leading) {
                    if isActive {
                        WorkspaceSidebarActiveWorkspaceIndicator()
                            .offset(x: workspaceSidebarIndicatorLeadingOffset(tileSize: compactRect.width, railWidth: railWidth))
                            .opacity(Double(1 - clampedProgress))
                    }
                }
                .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func title(availableWidth: CGFloat, fontSize: CGFloat) -> some View {
        let compactTitle = workspaceSidebarAppSummaryIdentifier(workspace)
        if compactTitle == workspace.displayName {
            Text(compactTitle)
                .fixedSize()
                .scaleEffect(min(1, availableWidth / max(unconstrainedTitleWidth(compactTitle, fontSize: fontSize), 1)))
        } else {
            ZStack(alignment: .leading) {
                Text(compactTitle)
                    .opacity(Double(1 - clampedProgress))
                Text(workspace.displayName)
                    .opacity(Double(clampedProgress))
            }
        }
    }

    private func unconstrainedTitleWidth(_ title: String, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        return (title as NSString).size(withAttributes: [.font: font]).width
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
    }

    private var clampedProgress: CGFloat { min(max(progress, 0), 1) }

    private func interpolatedRect(from compact: CGRect, to expanded: CGRect) -> CGRect {
        workspaceSidebarInterpolatedMorphRect(from: compact, to: expanded, progress: progress)
    }
}

func workspaceSidebarInterpolatedMorphRect(from compact: CGRect, to expanded: CGRect, progress: CGFloat) -> CGRect {
    CGRect(
        x: interpolate(compact.minX, expanded.minX, progress: progress),
        y: interpolate(compact.minY, expanded.minY, progress: progress),
        width: interpolate(compact.width, expanded.width, progress: progress),
        height: interpolate(compact.height, expanded.height, progress: progress)
    )
}

private func interpolate(_ compact: CGFloat, _ expanded: CGFloat, progress: CGFloat) -> CGFloat {
    compact + (expanded - compact) * min(max(progress, 0), 1)
}
