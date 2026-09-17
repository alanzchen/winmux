import SwiftUI

private struct WorkspaceSidebarDockPointerKey: EnvironmentKey {
    static let defaultValue: CGPoint? = nil
}

extension EnvironmentValues {
    var workspaceSidebarDockPointer: CGPoint? {
        get { self[WorkspaceSidebarDockPointerKey.self] }
        set { self[WorkspaceSidebarDockPointerKey.self] = newValue }
    }
}

/// Always evaluate distance against resting positions, never the magnified icon under the mouse.
/// A two-pitch cosine envelope has at most two icon sizes of total weight, so the
/// fixed reserve accommodates every pointer position without changing the rail height.
struct WorkspaceSidebarDockMagnification {
    let itemSize: CGFloat
    let count: Int
    let enabled: Bool

    var pitch: CGFloat { itemSize + WorkspaceSidebarAppIconLayout.spacing }
    var maximumGrowth: CGFloat { max(min(itemSize * 0.5, 52 - itemSize), 0) }
    var reserve: CGFloat { enabled ? min(CGFloat(count), 2) * maximumGrowth : 0 }
    var height: CGFloat { CGFloat(count) * itemSize + CGFloat(max(count - 1, 0)) * WorkspaceSidebarAppIconLayout.spacing + reserve }

    func restingCenter(_ index: Int) -> CGFloat { reserve / 2 + itemSize / 2 + CGFloat(index) * pitch }

    func frames(width: CGFloat, pointerY: CGFloat?) -> [CGRect] {
        let sizes = (0..<count).map { index -> CGFloat in
            guard enabled, let pointerY else { return itemSize }
            let distance = abs(pointerY - restingCenter(index))
            let weight = distance < 2 * pitch ? (1 + cos(.pi * distance / (2 * pitch))) / 2 : 0
            return itemSize + maximumGrowth * weight
        }
        let growth = sizes.reduce(0, +) - CGFloat(count) * itemSize
        var y = (reserve - growth) / 2
        return sizes.map { side in
            defer { y += side + WorkspaceSidebarAppIconLayout.spacing }
            return CGRect(x: (width - side) / 2, y: y, width: side, height: side)
        }
    }
}

func workspaceSidebarIndicatorLeadingOffset(tileSize: CGFloat, railWidth: CGFloat) -> CGFloat {
    // Leading alignment places the dot's left edge at zero; subtract its radius too.
    -max(railWidth - tileSize, 0) / 4 - 2
}
