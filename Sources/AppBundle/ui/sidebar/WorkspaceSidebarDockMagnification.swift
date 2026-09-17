import SwiftUI

let workspaceSidebarDockPointerExitedNotification = Notification.Name("workspaceSidebarDockPointerExited")

private struct WorkspaceSidebarDockPointerKey: EnvironmentKey {
    static let defaultValue: CGPoint? = nil
}

extension EnvironmentValues {
    var workspaceSidebarDockPointer: CGPoint? {
        get { self[WorkspaceSidebarDockPointerKey.self] }
        set { self[WorkspaceSidebarDockPointerKey.self] = newValue }
    }
}

/// Edge displacement based on the sine mapping described in US7434177B1, Fig. 8.
/// Both size and position come from the same monotonic map of resting coordinates.
/// This is an independent implementation, not a claim of exact current macOS geometry.
struct WorkspaceSidebarDockMagnification {
    let itemSize: CGFloat
    let count: Int
    let enabled: Bool
    var amount: Double = 0.5

    var pitch: CGFloat { itemSize + WorkspaceSidebarAppIconLayout.spacing }
    var maximumGrowth: CGFloat {
        // Like the native Dock, icons may grow past the fixed-width glass background.
        itemSize * CGFloat(min(max(amount, 0), 1))
    }
    var height: CGFloat { CGFloat(count) * itemSize + CGFloat(max(count - 1, 0)) * WorkspaceSidebarAppIconLayout.spacing }

    func restingCenter(_ index: Int) -> CGFloat { itemSize / 2 + CGFloat(index) * pitch }

    func mappedEdge(_ y: CGFloat, pointerY: CGFloat?) -> CGFloat {
        guard enabled, let pointerY, itemSize > 0 else { return y }
        let radius = 2 * pitch
        let amplitude = maximumGrowth / (2 * sin(.pi * itemSize / (4 * radius)))
        let distance = min(max((y - pointerY) / radius, -1), 1)
        return y + amplitude * sin(.pi * distance / 2)
    }

    func renderedHeight(pointerY: CGFloat?) -> CGFloat {
        mappedEdge(height, pointerY: pointerY) - mappedEdge(0, pointerY: pointerY)
    }

    func frames(width: CGFloat, pointerY: CGFloat?) -> [CGRect] {
        let origin = mappedEdge(0, pointerY: pointerY)
        return (0..<max(count, 0)).map { index in
            let lower = mappedEdge(CGFloat(index) * pitch, pointerY: pointerY)
            let upper = mappedEdge(CGFloat(index) * pitch + itemSize, pointerY: pointerY)
            let side = upper - lower
            // Vertical Dock: the left baseline stays fixed; icons grow rightward.
            return CGRect(x: (width - itemSize) / 2, y: lower - origin, width: side, height: side)
        }
    }
}

struct WorkspaceSidebarDockSectionMagnification {
    let pointerY: CGFloat?
    var strength: CGFloat = 1
}

private struct WorkspaceSidebarDockSectionMagnificationKey: EnvironmentKey {
    static let defaultValue: WorkspaceSidebarDockSectionMagnification? = nil
}

extension EnvironmentValues {
    var workspaceSidebarDockSectionMagnification: WorkspaceSidebarDockSectionMagnification? {
        get { self[WorkspaceSidebarDockSectionMagnificationKey.self] }
        set { self[WorkspaceSidebarDockSectionMagnificationKey.self] = newValue }
    }
}

/// A shared resting coordinate system spans every workspace. Section growth never changes
/// the pointer distance used by the next workspace, and separators keep their normal spacing.
struct WorkspaceSidebarDockColumnMagnification {
    let sections: [WorkspaceSidebarDockSectionMagnification]
    let growth: CGFloat

    init(appCounts: [Int], itemSize: CGFloat, amount: Double, pointerY: CGFloat?, strength: CGFloat = 1) {
        var origin: CGFloat = 3 // Section's vertical padding.
        var sections: [WorkspaceSidebarDockSectionMagnification] = []
        var growth: CGFloat = 0
        for count in appCounts {
            let localPointer = pointerY.map { $0 - origin }
            let layout = WorkspaceSidebarDockMagnification(itemSize: itemSize, count: 1 + count, enabled: true, amount: amount * strength)
            sections.append(.init(pointerY: localPointer, strength: strength))
            growth += layout.renderedHeight(pointerY: localPointer) - layout.height
            origin += layout.height + 12 // Section padding (6) + inter-section spacing (6).
        }
        self.sections = sections
        self.growth = max(growth, 0)
    }
}

struct WorkspaceSidebarDockColumnOriginPreference: PreferenceKey {
    static let defaultValue: [WorkspaceProjectId: CGFloat] = [:]
    static func reduce(value: inout [WorkspaceProjectId: CGFloat], nextValue: () -> [WorkspaceProjectId: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { first, _ in first })
    }
}

/// Hit geometry is an input cache, not UI state: measurements must not invalidate the
/// view tree which just produced them on every pointer sample.
@MainActor
final class WorkspaceSidebarDockHitRegions {
    var surface: CGRect?
    var icons: [CGRect] = []
}

struct WorkspaceSidebarDockLayoutContext {
    var restingSurface: CGRect = .zero
    var pointer: CGPoint?
    var strength: CGFloat = 1
}

private struct WorkspaceSidebarDockLayoutContextKey: EnvironmentKey {
    static let defaultValue = WorkspaceSidebarDockLayoutContext()
}

extension EnvironmentValues {
    var workspaceSidebarDockLayoutContext: WorkspaceSidebarDockLayoutContext {
        get { self[WorkspaceSidebarDockLayoutContextKey.self] }
        set { self[WorkspaceSidebarDockLayoutContextKey.self] = newValue }
    }
}

struct WorkspaceSidebarDockContextReader<Content: View>: View {
    @Environment(\.workspaceSidebarDockLayoutContext) private var context
    @ViewBuilder let content: (WorkspaceSidebarDockLayoutContext) -> Content
    var body: some View { content(context) }
}

func workspaceSidebarIndicatorLeadingOffset(tileSize: CGFloat, railWidth: CGFloat) -> CGFloat {
    // Leading alignment places the dot's left edge at zero; subtract its radius too.
    -max(railWidth - tileSize, 0) / 4 - 2
}

/// The widened scroll viewport and outer mask own clipping during magnification.
/// Inner section and pager clips must not crop icons at the glass rail's right edge.
struct WorkspaceSidebarTrailingOverflowModifier<Base: Shape>: ViewModifier {
    let base: Base
    let overflow: CGFloat

    func body(content: Content) -> some View {
        if overflow > 0 {
            content
        } else {
            content.clipShape(base)
        }
    }
}

struct WorkspaceSidebarDockIconFramesPreference: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

struct WorkspaceSidebarDockIconFrameReporter: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(key: WorkspaceSidebarDockIconFramesPreference.self,
                    value: [geometry.frame(in: .named("workspaceSidebarContent"))])
            }
        }
    }
}

extension WorkspaceSidebarConfiguration {
    var dockMagnificationOverflow: CGFloat {
        guard showAppIcons, dockMagnification else { return 0 }
        let growth = WorkspaceSidebarDockMagnification(itemSize: dockIconSize, count: 1,
            enabled: true, amount: dockMagnificationAmount).maximumGrowth
        return max(growth - (compactRailWidth - dockIconSize) / 2, 0)
    }
}

struct WorkspaceSidebarWorkspaceStack<Content: View>: View {
    let isLazy: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        if isLazy {
            LazyVStack(alignment: .leading, spacing: 6, content: content)
        } else {
            VStack(alignment: .leading, spacing: 6, content: content)
        }
    }
}
