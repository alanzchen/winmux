import CoreGraphics

struct WorkspaceSidebarAppIconLayout {
    static let iconSize: CGFloat = 40
    static let spacing: CGFloat = 6

    let itemSize: CGFloat
    let visibleAppCount: Int
    let height: CGFloat

    init(appCount: Int, availableWidth: CGFloat, magnificationEnabled: Bool = false, iconSize: CGFloat = Self.iconSize) {
        itemSize = min(iconSize, max(availableWidth, 1))
        visibleAppCount = max(appCount, 0)
        let itemCount = 1 + visibleAppCount
        height = WorkspaceSidebarDockMagnification(itemSize: itemSize, count: itemCount, enabled: magnificationEnabled).height
    }
}
