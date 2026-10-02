import AppKit
@testable import AppBundle
import SwiftUI

/// A bundle path no app is at. A window whose app is here draws the fallback glyph, which never
/// changes, rather than an installed app's icon, which is read again asynchronously and may be
/// replaced between two renders.
let workspaceSidebarTestMissingAppPath = "/nonexistent/WinMux Render Test.app"

/// The composed sidebar as `WorkspaceSidebarView` draws it, hosted without a window, with where
/// it laid out its drop targets, a tab's row among them. Two renders in one process draw the same
/// pixels for the same input, so what one draws that another doesn't shows where, and whether, the
/// view drew something, without reading text back from the image.
struct WorkspaceSidebarTestRender {
    let bitmap: NSBitmapImageRep
    let targets: [WorkspaceSidebarDropTargetFrame]
    let fittingSize: CGSize

    /// Where the view laid out `kind`'s target, in points from its top left.
    func frame(of kind: WorkspaceSidebarDropTargetKind) -> CGRect? {
        targets.first { $0.kind == kind }?.frame
    }

    /// How many of the pixels within `rect` are ink in light mode: well darker than the light
    /// sidebar behind them.
    func inkPixels(in rect: CGRect) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let area = rect.intersection(CGRect(origin: .zero, size: bitmap.size))
        guard !area.isNull else { return 0 }
        var count = 0
        for y in Int(area.minY * scale) ..< Int(area.maxY * scale) {
            for x in Int(area.minX * scale) ..< Int(area.maxX * scale) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent + color.greenComponent + color.blueComponent < 2.1 { count += 1 }
            }
        }
        return count
    }

    /// Where this render's pixels differ from `other`'s, in points from the top left, and how many
    /// pixels do, within `rect` if given. Nil where none does.
    func difference(from other: Self, in rect: CGRect? = nil) -> (pixels: Int, bounds: CGRect)? {
        precondition(bitmap.pixelsWide == other.bitmap.pixelsWide && bitmap.pixelsHigh == other.bitmap.pixelsHigh &&
            bitmap.bytesPerRow == other.bitmap.bytesPerRow && bitmap.bitsPerPixel == other.bitmap.bitsPerPixel)
        guard let mine = bitmap.bitmapData, let theirs = other.bitmap.bitmapData else { return nil }
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        let area = (rect ?? CGRect(origin: .zero, size: bitmap.size)).intersection(CGRect(origin: .zero, size: bitmap.size))
        guard !area.isNull else { return nil }
        var pixels = 0, minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        let columns = Int(area.minX * scale) ..< Int(area.maxX * scale)
        for y in Int(area.minY * scale) ..< Int(area.maxY * scale) {
            let row = y * bitmap.bytesPerRow + columns.lowerBound * bytesPerPixel
            // Most rows are the same: compare each whole, then look for its pixels only where it isn't.
            guard memcmp(mine + row, theirs + row, columns.count * bytesPerPixel) != 0 else { continue }
            for x in columns {
                let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
                guard (0 ..< bytesPerPixel).contains(where: { mine[offset + $0] != theirs[offset + $0] }) else { continue }
                pixels += 1
                (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
            }
        }
        guard pixels > 0 else { return nil }
        return (pixels, CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale))
    }
}

/// Renders the real sidebar view for `snapshot`, in light mode and without motion.
@MainActor
func renderWorkspaceSidebarForTest(_ snapshot: WorkspaceSidebarSnapshot, browserTabs: BrowserTabsModel,
                                   size: CGSize) throws -> WorkspaceSidebarTestRender {
    var targets: [WorkspaceSidebarDropTargetFrame] = []
    let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: snapshot, actions: .init(setDropTargets: { targets = $0 }),
        reduceMotionOverride: true, reduceTransparencyOverride: true, browserTabsModel: browserTabs)
        .frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw NSError(domain: "WorkspaceSidebarTestRender", code: 1)
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return .init(bitmap: bitmap, targets: targets, fittingSize: host.fittingSize)
}
