import AppKit

// A sidebar drag with more than one display offers, beside the sidebar it started in, a hint for
// each other display. Pausing on one opens that display's list next to it, on this display, so a
// tab can be dropped there without the pointer crossing to the other screen.

/// Which way another display lies from this one, for its hint's arrow.
enum WorkspaceSidebarDisplayDirection: Equatable {
    case left, right, up, down, upLeft, upRight, downLeft, downRight

    var arrow: String {
        switch self {
            case .left: "←"
            case .right: "→"
            case .up: "↑"
            case .down: "↓"
            case .upLeft: "↖"
            case .upRight: "↗"
            case .downLeft: "↙"
            case .downRight: "↘"
        }
    }
}

/// From one display's centre to another's, in top-left-origin coordinates. A display mostly to one
/// side is that side; one about as far across as down is diagonal.
func workspaceSidebarDisplayDirection(from source: Rect, to destination: Rect) -> WorkspaceSidebarDisplayDirection {
    let dx = destination.center.x - source.center.x
    let dy = destination.center.y - source.center.y
    if abs(dx) >= 2 * abs(dy) { return dx < 0 ? .left : .right }
    if abs(dy) >= 2 * abs(dx) { return dy < 0 ? .up : .down }
    switch (dx < 0, dy < 0) {
        case (true, true): return .upLeft
        case (false, true): return .upRight
        case (true, false): return .downLeft
        case (false, false): return .downRight
    }
}

/// Another display a drag can reach from the current one.
struct WorkspaceSidebarDropDestinationHint: Equatable, Identifiable {
    /// The display's scope, "monitor:x,y".
    let id: String
    /// As the display menu names it: identical displays are numbered.
    let name: String
    let direction: WorkspaceSidebarDisplayDirection
}

/// The other displays, in their real arrangement: left to right, then top to bottom.
func workspaceSidebarDropDestinationHints(source: Monitor, monitors: [Monitor]) -> [WorkspaceSidebarDropDestinationHint] {
    monitors.filter { $0.rect.topLeftCorner != source.rect.topLeftCorner }.map { monitor in
        WorkspaceSidebarDropDestinationHint(id: workspaceSidebarMonitorScopeId(for: monitor),
            name: workspaceSidebarMonitorDisplayName(monitor, among: monitors),
            direction: workspaceSidebarDisplayDirection(from: source.rect, to: monitor.rect))
    }
}

let workspaceSidebarDropDestinationGap: CGFloat = 6
let workspaceSidebarDropDestinationMargin: CGFloat = 8
/// Each other display's rail, beside the sidebar: as tall as the sidebar, this wide.
let workspaceSidebarDropDestinationRailWidth: CGFloat = 30
/// Short of room beside the sidebar, rails narrow this far before they move over its inner edge.
let workspaceSidebarDropDestinationMinRailWidth: CGFloat = 20
let workspaceSidebarDropDestinationRailSpacing: CGFloat = 2
/// A bottom Dock's rails are one strip above it, this tall, in segments at least this wide.
let workspaceSidebarDropDestinationRailThickness: CGFloat = 30
let workspaceSidebarDropDestinationMinSegmentWidth: CGFloat = 100
let workspaceSidebarDropDestinationMinColumnWidth: CGFloat = 220
let workspaceSidebarDropDestinationMaxColumnWidth: CGFloat = 360
/// A list shorter than this isn't offered: only the rails show.
let workspaceSidebarDropDestinationMinColumnHeight: CGFloat = 240

/// Where the rails and the other display's list go, in AppKit screen coordinates, on the display
/// the drag started on.
struct WorkspaceSidebarDropDestinationLayout: Equatable {
    /// One rail per other display, in order, side by side: each the whole height of the sidebar
    /// beside it, or, above a bottom Dock, a segment of the strip along it.
    let hints: [CGRect]
    /// All the rails together.
    let hintArea: CGRect
    /// The other display's list, when one is open.
    let column: CGRect?
    /// There was no room beside the sidebar, so the list covers part of it.
    let isInward: Bool
    /// There's room for a list at all. Without it only the rails show, and none opens.
    var columnFits = true
}

/// Beside the source surface, on its inner side: to the right of a left sidebar, to the left of a
/// right one, above a bottom Dock. The rails run the sidebar's whole visible height, side by side,
/// and the list follows them. The rails, the gap and the list are fitted together, so they never
/// overlap: the list narrows first, then the rails. Without room beside the sidebar, the list goes
/// against the display's far edge, over the sidebar, with the rails beside it. The rails are where
/// they'd be with the list open, so opening it never moves them from under the pointer. A short
/// sidebar still gets a usable list, taller than it. Everything stays within `visibleFrame`.
func workspaceSidebarDropDestinationLayout(
    sourceSurface: CGRect,
    visibleFrame: CGRect,
    position: WorkspaceDockPosition,
    hintCount: Int,
    preferredColumnWidth: CGFloat,
    opensColumn: Bool,
) -> WorkspaceSidebarDropDestinationLayout {
    if position == .right {
        // A right sidebar is a left one seen in a mirror; the rails keep the displays' order.
        func mirror(_ rect: CGRect) -> CGRect {
            CGRect(x: visibleFrame.minX + visibleFrame.maxX - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
        }
        let mirrored = workspaceSidebarDropDestinationLayout(sourceSurface: mirror(sourceSurface), visibleFrame: visibleFrame,
            position: .left, hintCount: hintCount, preferredColumnWidth: preferredColumnWidth, opensColumn: opensColumn)
        let area = mirror(mirrored.hintArea)
        return .init(hints: workspaceSidebarDropDestinationRails(in: area, count: hintCount), hintArea: area,
            column: mirrored.column.map(mirror), isInward: mirrored.isInward, columnFits: mirrored.columnFits)
    }
    let gap = workspaceSidebarDropDestinationGap
    let bounds = visibleFrame.insetBy(dx: workspaceSidebarDropDestinationMargin, dy: workspaceSidebarDropDestinationMargin)
    let count = max(hintCount, 1)
    let totalSpacing = CGFloat(count - 1) * workspaceSidebarDropDestinationRailSpacing
    let columnWidth = min(max(preferredColumnWidth, workspaceSidebarDropDestinationMinColumnWidth),
        workspaceSidebarDropDestinationMaxColumnWidth)
    let minColumnWidth = workspaceSidebarDropDestinationMinColumnWidth
    let minHeight = workspaceSidebarDropDestinationMinColumnHeight

    if position == .bottom {
        // Above the Dock: one strip along it, in segments wide enough to read, with the list above.
        let thickness = workspaceSidebarDropDestinationRailThickness
        let width = min(max(sourceSurface.width, CGFloat(count) * workspaceSidebarDropDestinationMinSegmentWidth + totalSpacing),
            visibleFrame.width)
        let area = CGRect(x: (sourceSurface.midX - width / 2).coerce(in: visibleFrame.minX ... max(visibleFrame.minX, visibleFrame.maxX - width)),
            y: min(sourceSurface.maxY + gap, visibleFrame.maxY - thickness), width: width, height: thickness)
        let height = max(min(bounds.maxY - (area.maxY + gap), 520), 0)
        let fits = height >= minHeight
        let rails = workspaceSidebarDropDestinationRails(in: area, count: count)
        guard opensColumn, fits else { return .init(hints: rails, hintArea: area, column: nil, isInward: false, columnFits: fits) }
        let listWidth = min(columnWidth, bounds.width)
        let column = CGRect(x: (area.midX - listWidth / 2).coerce(in: bounds.minX ... max(bounds.minX, bounds.maxX - listWidth)),
            y: area.maxY + gap, width: listWidth, height: height)
        return .init(hints: rails, hintArea: area, column: column, isInward: false)
    }

    // The rails are exactly the sidebar's visible height.
    let railBottom = max(sourceSurface.minY, visibleFrame.minY)
    let railHeight = max(min(sourceSurface.maxY, visibleFrame.maxY) - railBottom, 0)
    // The list spans the sidebar's height, or, beside a short one, a usable height centred on it.
    let spanBottom = max(sourceSurface.minY, bounds.minY)
    let span = max(min(sourceSurface.maxY, bounds.maxY) - spanBottom, 0)
    let listHeight = min(max(span, minHeight), bounds.height)
    let listY = span >= minHeight ? spanBottom
        : (sourceSurface.midY - listHeight / 2).coerce(in: bounds.minY ... max(bounds.minY, bounds.maxY - listHeight))
    let fits = listHeight >= minHeight

    let preferredRails = CGFloat(count) * workspaceSidebarDropDestinationRailWidth + totalSpacing
    let narrowestRails = CGFloat(count) * workspaceSidebarDropDestinationMinRailWidth + totalSpacing
    /// Rails and list widths sharing `room`: the list narrows first, then the rails; nil if even
    /// their narrowest don't fit.
    func allocate(_ room: CGFloat) -> (rails: CGFloat, list: CGFloat)? {
        let list = min(columnWidth, max(room - gap - preferredRails, minColumnWidth))
        let rails = min(preferredRails, room - gap - list)
        return rails >= narrowestRails - 0.01 ? (rails, list) : nil
    }
    let edge = sourceSurface.maxX + gap
    func railsArea(x: CGFloat, width: CGFloat) -> CGRect { CGRect(x: x, y: railBottom, width: width, height: railHeight) }

    if fits, let beside = allocate(bounds.maxX - edge) {
        // Beside the sidebar: the rails, then the list.
        let area = railsArea(x: edge, width: beside.rails)
        let column = CGRect(x: area.maxX + gap, y: listY, width: beside.list, height: listHeight)
        return .init(hints: workspaceSidebarDropDestinationRails(in: area, count: count), hintArea: area,
            column: opensColumn ? column : nil, isInward: false)
    }
    if fits, let inward = allocate(bounds.maxX - visibleFrame.minX) {
        // Over the sidebar: the list against the far edge, the rails just before it.
        let column = CGRect(x: bounds.maxX - inward.list, y: listY, width: inward.list, height: listHeight)
        let area = railsArea(x: column.minX - gap - inward.rails, width: inward.rails)
        return .init(hints: workspaceSidebarDropDestinationRails(in: area, count: count), hintArea: area,
            column: opensColumn ? column : nil, isInward: opensColumn)
    }
    // No room for a list: every rail still shows, beside the sidebar as far as the display allows,
    // narrower than usual if it must be.
    let width = min(max(min(preferredRails, visibleFrame.maxX - edge), narrowestRails), visibleFrame.width)
    let area = railsArea(x: edge.coerce(in: visibleFrame.minX ... max(visibleFrame.minX, visibleFrame.maxX - width)), width: width)
    return .init(hints: workspaceSidebarDropDestinationRails(in: area, count: count), hintArea: area, column: nil,
        isInward: false, columnFits: false)
}

/// `count` rails side by side across `area`, in order, the same width each.
func workspaceSidebarDropDestinationRails(in area: CGRect, count: Int) -> [CGRect] {
    let count = max(count, 1)
    let spacing = workspaceSidebarDropDestinationRailSpacing
    let width = max((area.width - CGFloat(count - 1) * spacing) / CGFloat(count), 0)
    return (0 ..< count).map { index in
        CGRect(x: area.minX + CGFloat(index) * (width + spacing), y: area.minY, width: width, height: area.height)
    }
}
