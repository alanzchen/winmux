import SwiftUI

/// Keep per-frame state below the sidebar's project filtering, menus, search and snapshots.
/// The content value is built only when those inputs change, not for each mouse event.
struct WorkspaceSidebarDockAnimationHost<Surface: Shape, Content: View>: View {
    let configuration: WorkspaceSidebarConfiguration
    let visibleWidth: CGFloat
    let compactHeight: CGFloat
    let expansionProgress: CGFloat
    let allowsMagnification: Bool
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
                expansionProgress: expansionProgress, fitsDockContent: configuration.showAppIcons)
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
                expansionProgress: expansionProgress, fitsDockContent: configuration.showAppIcons)
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
                .frame(width: surface.width + overflow, alignment: .leading)
                .mask(alignment: .leading) { Rectangle().frame(width: max(visibleWidth, 0) + overflow) }
                .onContinuousHover(coordinateSpace: .named("workspaceSidebarContent")) { phase in
                    switch phase {
                        case .active(let point):
                            motion.receive(isWorkspaceSidebarDragInProgress() ? nil : acceptedPointer(point, in: surface))
                        case .ended: motion.receive(nil)
                    }
                }
                .position(x: surface.midX + overflow / 2, y: surface.midY)
        }
        .background { WorkspaceSidebarDockDisplayLink(controller: motion, onFrame: { frame = $0 }) }
    }

    private func acceptedPointer(_ point: CGPoint?, in surface: CGRect) -> CGPoint? {
        guard allowsMagnification, let point,
              shape.path(in: surface).contains(point) || hitRegions.icons.contains(where: { $0.contains(point) })
        else { return nil }
        return point
    }
}
