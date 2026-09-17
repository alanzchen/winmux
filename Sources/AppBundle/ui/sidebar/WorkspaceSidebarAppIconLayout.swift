import CoreGraphics

struct WorkspaceSidebarAppIconLayout {
    static let iconSize: CGFloat = CGFloat(WorkspaceSidebarConfig.defaultDockIconSize)
    // With the default 48-point canvas, a 52-point pitch matches the reference's
    // icon-center spacing relative to the fixed 64-point shelf.
    static let spacing: CGFloat = 4

    let itemSize: CGFloat
    let visibleAppCount: Int
    let height: CGFloat

    init(appCount: Int, availableWidth: CGFloat, magnificationEnabled: Bool = false, iconSize: CGFloat = Self.iconSize, magnificationAmount: Double = 0.5) {
        itemSize = min(iconSize, max(availableWidth, 1))
        visibleAppCount = max(appCount, 0)
        let itemCount = 1 + visibleAppCount
        height = WorkspaceSidebarDockMagnification(itemSize: itemSize, count: itemCount, enabled: magnificationEnabled, amount: magnificationAmount).height
    }
}
