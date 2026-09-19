import SwiftUI

/// Keep per-frame state below the sidebar's project filtering, menus, search and snapshots.
/// The content value is built only when those inputs change, not for each mouse event.
struct WorkspaceSidebarDockAnimationHost<Surface: Shape, Content: View>: View {
    let configuration: WorkspaceSidebarConfiguration
    let visibleWidth: CGFloat
    let compactHeight: CGFloat
    let expansionProgress: CGFloat
    let blockers: WorkspaceSidebarDockPointerBlockers
    private var allowsMagnification: Bool { blockers.isEmpty }
    let overflow: CGFloat
    let shape: Surface
    let hitRegions: WorkspaceSidebarDockHitRegions
    let motion: WorkspaceSidebarDockMotionController
    let growth: (CGPoint?, CGFloat, CGRect) -> CGFloat
    let content: Content
    @State private var frame = WorkspaceSidebarDockMotionFrame()
    @Environment(\.workspaceSidebarDockPointer) private var inheritedPointer

    var body: some View {
        GeometryReader { geometry in
            let resting = workspaceSidebarSurfaceFrame(availableSize: geometry.size,
                visibleWidth: visibleWidth, compactHeight: compactHeight,
                expansionProgress: expansionProgress, fitsDockContent: configuration.showAppIcons,
                compactLeftGap: configuration.compactLeftGap, position: configuration.dockPosition)
            // Native input is validated before entering the motion controller. Keep
            // its last valid point throughout exit, even as the icon under it shrinks.
            // Revalidating that point against shrinking bounds would snap to rest.
            let pointer: CGPoint? = if let inheritedPointer {
                acceptedPointer(inheritedPointer, in: hitRegions.surface ?? resting)
            } else {
                allowsMagnification ? frame.pointer : nil
            }
            let strength: CGFloat = inheritedPointer == nil ? frame.strength : 1
            let surface = workspaceSidebarSurfaceFrame(availableSize: geometry.size,
                visibleWidth: visibleWidth, compactHeight: compactHeight + growth(pointer, strength, resting),
                expansionProgress: expansionProgress, fitsDockContent: configuration.showAppIcons,
                compactLeftGap: configuration.compactLeftGap, position: configuration.dockPosition)
            content
                .environment(\.workspaceSidebarDockLayoutContext,
                    .init(restingSurface: resting, pointer: pointer, strength: strength))
                .coordinateSpace(name: "workspaceSidebarSurface")
                .frame(width: surface.width, height: surface.height, alignment: .leading)
                .background {
                    GeometryReader { surface in
                        Color.clear.preference(key: WorkspaceSidebarSurfaceFramePreferenceKey.self,
                            value: surface.frame(in: .named("workspaceSidebarContent")))
                    }
                }
                .modifier(WorkspaceSidebarDockOverflowFrame(surface: surface, overflow: overflow,
                    position: configuration.dockPosition))
        }
        .background {
            WorkspaceSidebarDockDisplayLink(controller: motion, blockers: blockers,
                horizontal: configuration.dockPosition == .bottom,
                containsPointer: { [shape, hitRegions] point in
                    let insideSurface = hitRegions.surface.map { surface in
                        surface.contains(point) && shape.path(in: surface).contains(point)
                    } ?? false
                    return insideSurface || hitRegions.icons.contains { $0.contains(point) }
                }, onFrame: { frame = $0 })
        }
    }

    private func acceptedPointer(_ point: CGPoint?, in surface: CGRect) -> CGPoint? {
        guard allowsMagnification, let point,
              shape.path(in: surface).contains(point) || hitRegions.icons.contains(where: { $0.contains(point) })
        else { return nil }
        return point
    }
}

private struct WorkspaceSidebarDockOverflowFrame: ViewModifier {
    let surface: CGRect
    let overflow: CGFloat
    let position: WorkspaceDockPosition

    func body(content: Content) -> some View {
        let horizontal = position == .bottom
        let alignment: Alignment = horizontal ? .bottom : position == .right ? .trailing : .leading
        let size = CGSize(width: surface.width + (horizontal ? 0 : overflow),
            height: surface.height + (horizontal ? overflow : 0))
        content.frame(width: size.width, height: size.height, alignment: alignment)
            .mask { Rectangle().frame(width: max(size.width, 0), height: max(size.height, 0)) }
            .position(x: surface.midX + (horizontal ? 0 : (position == .right ? -overflow : overflow) / 2),
                y: surface.midY - (horizontal ? overflow / 2 : 0))
    }
}
