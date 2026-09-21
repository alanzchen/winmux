import CoreGraphics

/// The renderer, pointer targets and accessibility elements share these poses.
/// All distances used by the lens remain in the resting coordinate system.
struct WorkspaceSidebarNativeDockGeometry {
    let surface: CGRect
    let page: CGRect
    let leading: CGRect
    let trailing: CGRect
    let icons: [[CGRect]]
    let sections: [CGRect]
    let create: CGRect?
    let maximumScroll: CGFloat

    init(size: CGSize, configuration: WorkspaceSidebarConfiguration, visibleWidth: CGFloat,
         compactLength: CGFloat, leadingLength: CGFloat, trailingLength: CGFloat,
         appCounts: [Int], showsCreate: Bool, frame: WorkspaceSidebarDockMotionFrame,
         scrollOffset: CGFloat = 0, createLength: CGFloat = 32) {
        let horizontal = configuration.dockPosition == .bottom
        let inset = configuration.compactHorizontalInset
        let cross = max(configuration.compactRailWidth - 2 * inset, 1)
        let pagePadding: CGFloat = horizontal ? 10 : (leadingLength > 0 ? 0 : configuration.topPadding)
        let outerPadding: CGFloat = horizontal ? 6 : 0
        let resting = workspaceSidebarSurfaceFrame(availableSize: size, visibleWidth: visibleWidth,
            compactHeight: compactLength, expansionProgress: 0, fitsDockContent: true,
            compactLeftGap: configuration.compactLeftGap, position: configuration.dockPosition)
        let pointer = frame.pointer.map {
            (horizontal ? $0.x - resting.minX : $0.y - resting.minY)
                - outerPadding - leadingLength - pagePadding + scrollOffset
        }
        let column = WorkspaceSidebarDockColumnMagnification(appCounts: appCounts,
            itemSize: configuration.dockIconSize, amount: configuration.dockMagnificationAmount,
            pointerY: pointer, strength: frame.strength)
        // Fit the shelf to the current lens. Reserving maximum growth on entry
        // leaves empty space at both ends when the pointer is near a control or
        // the edge of the icon column, where actual magnification is smaller.
        let surfaceFrame = workspaceSidebarSurfaceFrame(availableSize: size, visibleWidth: visibleWidth,
            compactHeight: compactLength + column.growth, expansionProgress: 0, fitsDockContent: true,
            compactLeftGap: configuration.compactLeftGap, position: configuration.dockPosition)
        surface = surfaceFrame
        func rect(_ origin: CGFloat, _ length: CGFloat) -> CGRect {
            horizontal
                ? CGRect(x: surfaceFrame.minX + origin, y: surfaceFrame.minY, width: length, height: surfaceFrame.height)
                : CGRect(x: surfaceFrame.minX, y: surfaceFrame.minY + origin, width: surfaceFrame.width, height: length)
        }
        let length = horizontal ? surfaceFrame.width : surfaceFrame.height
        leading = rect(outerPadding, leadingLength)
        trailing = rect(max(outerPadding, length - outerPadding - trailingLength), trailingLength)
        let pageFrame = rect(outerPadding + leadingLength, max(0, length - 2 * outerPadding - leadingLength - trailingLength))
        page = pageFrame
        var origin = pagePadding
        var poses: [[CGRect]] = []
        var sectionPoses: [CGRect] = []
        for (index, count) in appCounts.enumerated() {
            let section = column.sections[index]
            let lens = WorkspaceSidebarDockMagnification(itemSize: configuration.dockIconSize,
                count: 1 + count, enabled: true, amount: configuration.dockMagnificationAmount * section.strength)
            let height = lens.renderedHeight(pointerY: section.pointerY)
            let localFrames = lens.frames(width: cross, pointerY: section.pointerY).map {
                workspaceSidebarDockOrientedFrame($0, crossAxis: cross, position: configuration.dockPosition)
            }
            poses.append(localFrames.map {
                $0.offsetBy(dx: pageFrame.minX + (horizontal ? origin + 3 : inset),
                    dy: pageFrame.minY + (horizontal ? inset : origin + 3))
            })
            sectionPoses.append(rect(outerPadding + leadingLength + origin, height + 6))
            origin += height + 12
        }
        if appCounts.isEmpty { origin = pagePadding }
        let createPose = showsCreate ? rect(outerPadding + leadingLength + origin, createLength) : nil
        let contentLength = origin - (appCounts.isEmpty || showsCreate ? 0 : 6) + (showsCreate ? createLength : 0) + 10
        maximumScroll = max(0, contentLength - (horizontal ? pageFrame.width : pageFrame.height))
        let offset = min(max(scrollOffset, 0), maximumScroll)
        let dx = horizontal ? -offset : 0
        let dy = horizontal ? 0 : -offset
        icons = poses.map { $0.map { $0.offsetBy(dx: dx, dy: dy) } }
        sections = sectionPoses.map { $0.offsetBy(dx: dx, dy: dy) }
        create = createPose?.offsetBy(dx: dx, dy: dy)
    }
}
