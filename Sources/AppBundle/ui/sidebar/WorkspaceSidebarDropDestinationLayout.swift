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
let workspaceSidebarDropDestinationHintWidth: CGFloat = 128
/// A bottom Dock's row of hints narrows them this far before it scrolls.
let workspaceSidebarDropDestinationMinHintWidth: CGFloat = 72
let workspaceSidebarDropDestinationSingleHintHeight: CGFloat = 60
let workspaceSidebarDropDestinationHintHeight: CGFloat = 36
/// A short sidebar shrinks its hints this far before they scroll.
let workspaceSidebarDropDestinationMinHintHeight: CGFloat = 28
let workspaceSidebarDropDestinationHintSpacing: CGFloat = 4
let workspaceSidebarDropDestinationMinColumnWidth: CGFloat = 220
let workspaceSidebarDropDestinationMaxColumnWidth: CGFloat = 360
/// A list shorter than this isn't offered: only the hints show.
let workspaceSidebarDropDestinationMinColumnHeight: CGFloat = 240
/// Past this many other displays the hints scroll.
let workspaceSidebarDropDestinationMaxVisibleHints = 6

/// Where the hints and the other display's list go, in AppKit screen coordinates, on the display
/// the drag started on.
struct WorkspaceSidebarDropDestinationLayout: Equatable {
    /// One per hint, in order, where it is with the hints unscrolled. Hints past the end of
    /// `hintArea` are scrolled to; only the part inside it shows or takes the pointer.
    let hints: [CGRect]
    /// The hints' visible strip.
    let hintArea: CGRect
    /// The other display's list, when one is open.
    let column: CGRect?
    /// There was no room beside the sidebar, so the list covers part of it.
    let isInward: Bool
    /// There's room for a list at all. Without it only the hints show, and none opens.
    var columnFits = true

    /// The hints run past their strip, so it scrolls.
    var hintsOverflow: Bool { hints.contains { !hintArea.insetBy(dx: -0.5, dy: -0.5).contains($0) } }
}

/// Beside the source surface, on its inner side: to the right of a left sidebar, to the left of a
/// right Dock, above a bottom Dock. The list follows the hints. Without room for its narrowest width
/// there, it goes against the display's far edge, over the sidebar. Everything stays within
/// `visibleFrame`.
func workspaceSidebarDropDestinationLayout(
    sourceSurface: CGRect,
    visibleFrame: CGRect,
    position: WorkspaceDockPosition,
    hintCount: Int,
    preferredColumnWidth: CGFloat,
    opensColumn: Bool,
) -> WorkspaceSidebarDropDestinationLayout {
    let gap = workspaceSidebarDropDestinationGap
    let margin = workspaceSidebarDropDestinationMargin
    let spacing = workspaceSidebarDropDestinationHintSpacing
    let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
    let count = max(hintCount, 1)
    let shown = min(count, workspaceSidebarDropDestinationMaxVisibleHints)
    let columnWidth = min(max(preferredColumnWidth, workspaceSidebarDropDestinationMinColumnWidth),
        workspaceSidebarDropDestinationMaxColumnWidth)
    let minHeight = workspaceSidebarDropDestinationMinColumnHeight

    if position == .bottom {
        // Above the Dock: hints in a row, narrowed to fit and then scrolling, with the list above them.
        let fitted = (bounds.width - CGFloat(shown - 1) * spacing) / CGFloat(shown)
        let hintWidth = min(workspaceSidebarDropDestinationHintWidth, max(fitted, workspaceSidebarDropDestinationMinHintWidth))
        let rowWidth = min(CGFloat(shown) * hintWidth + CGFloat(shown - 1) * spacing, bounds.width)
        let area = CGRect(x: (sourceSurface.midX - rowWidth / 2).coerce(in: bounds.minX ... max(bounds.minX, bounds.maxX - rowWidth)),
            y: min(sourceSurface.maxY + gap, bounds.maxY - workspaceSidebarDropDestinationHintHeight),
            width: rowWidth, height: workspaceSidebarDropDestinationHintHeight)
        let hints = (0 ..< count).map { index in
            CGRect(x: area.minX + CGFloat(index) * (hintWidth + spacing), y: area.minY, width: hintWidth, height: area.height)
        }
        let height = max(min(bounds.maxY - (area.maxY + gap), 520), 0)
        let fits = height >= minHeight
        guard opensColumn, fits else {
            return .init(hints: hints, hintArea: area, column: nil, isInward: false, columnFits: fits)
        }
        let width = min(columnWidth, bounds.width)
        let column = CGRect(x: (area.midX - width / 2).coerce(in: bounds.minX ... max(bounds.minX, bounds.maxX - width)),
            y: area.maxY + gap, width: width, height: height)
        return .init(hints: hints, hintArea: area, column: column, isInward: false)
    }

    let isRight = position == .right
    let top = min(sourceSurface.maxY, bounds.maxY)
    let bottom = max(sourceSurface.minY, bounds.minY)
    let available = max(top - bottom, 0)
    // Six hints show at most; on a short sidebar they shrink before they scroll.
    let preferred = count == 1 ? workspaceSidebarDropDestinationSingleHintHeight : workspaceSidebarDropDestinationHintHeight
    let fitted = (available - CGFloat(shown - 1) * spacing) / CGFloat(shown)
    let hintHeight = min(preferred, max(fitted, workspaceSidebarDropDestinationMinHintHeight))
    let areaHeight = min(CGFloat(shown) * hintHeight + CGFloat(shown - 1) * spacing, available)
    let areaY = (sourceSurface.midY - areaHeight / 2).coerce(in: bottom ... max(bottom, top - areaHeight))
    // Beside the surface, or, without room, against the display's inner edge over it.
    let besideX = isRight ? sourceSurface.minX - gap - workspaceSidebarDropDestinationHintWidth : sourceSurface.maxX + gap
    let hintX = besideX.coerce(in: bounds.minX ... max(bounds.minX, bounds.maxX - workspaceSidebarDropDestinationHintWidth))
    let area = CGRect(x: hintX, y: areaY, width: workspaceSidebarDropDestinationHintWidth, height: areaHeight)
    let hints = (0 ..< count).map { index in
        let row = CGFloat(index)
        return CGRect(x: area.minX, y: area.maxY - (row + 1) * hintHeight - row * spacing, width: area.width, height: hintHeight)
    }
    let fits = available >= minHeight
    guard opensColumn, fits else { return .init(hints: hints, hintArea: area, column: nil, isInward: false, columnFits: fits) }

    let columnHeight = available
    let room = isRight ? area.minX - gap - bounds.minX : bounds.maxX - (area.maxX + gap)
    if room >= workspaceSidebarDropDestinationMinColumnWidth {
        let width = min(columnWidth, room)
        let x = isRight ? area.minX - gap - width : area.maxX + gap
        return .init(hints: hints, hintArea: area, column: CGRect(x: x, y: bottom, width: width, height: columnHeight),
            isInward: false)
    }
    // No room beside: over the sidebar, against the far edge, as wide as the display allows, with
    // the hints moved to the list's near side so neither covers the other.
    let width = min(columnWidth, bounds.width)
    let x = isRight ? bounds.minX : bounds.maxX - width
    let column = CGRect(x: x, y: bottom, width: width, height: columnHeight)
    let inwardHintX = (isRight ? column.maxX + gap : column.minX - gap - area.width)
        .coerce(in: bounds.minX ... max(bounds.minX, bounds.maxX - area.width))
    let shift = inwardHintX - area.minX
    return .init(hints: hints.map { $0.offsetBy(dx: shift, dy: 0) }, hintArea: area.offsetBy(dx: shift, dy: 0),
        column: column, isInward: true)
}

/// The hints' frames as they show, scrolled by `offset` along their strip, clipped to it. A hint
/// scrolled out of view takes no pointer.
func workspaceSidebarDropDestinationVisibleHints(_ layout: WorkspaceSidebarDropDestinationLayout, ids: [String],
                                                 offset: CGFloat, isRow: Bool) -> [(id: String, frame: CGRect)] {
    zip(ids, layout.hints).compactMap { id, frame in
        let scrolled = isRow ? frame.offsetBy(dx: -offset, dy: 0) : frame.offsetBy(dx: 0, dy: offset)
        let visible = scrolled.intersection(layout.hintArea)
        return visible.isNull || visible.width < 1 || visible.height < 1 ? nil : (id, visible)
    }
}

/// How far the hints can scroll along their strip.
func workspaceSidebarDropDestinationHintScrollRange(_ layout: WorkspaceSidebarDropDestinationLayout, isRow: Bool) -> CGFloat {
    guard let last = layout.hints.last else { return 0 }
    return isRow ? max(last.maxX - layout.hintArea.maxX, 0) : max(layout.hintArea.minY - last.minY, 0)
}
