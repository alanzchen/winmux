import CoreGraphics

struct WorkspaceSidebarAppIconLayout {
    static let iconSize: CGFloat = 32
    static let spacing: CGFloat = 6

    let itemSize: CGFloat
    let visibleAppCount: Int
    let overflowCount: Int
    let height: CGFloat

    init(appCount: Int, availableWidth: CGFloat) {
        itemSize = min(Self.iconSize, max(availableWidth, 1))
        visibleAppCount = min(max(appCount, 0), 3)
        overflowCount = max(appCount - visibleAppCount, 0)
        let itemCount = 1 + visibleAppCount + (overflowCount > 0 ? 1 : 0)
        height = CGFloat(itemCount) * itemSize + CGFloat(itemCount - 1) * Self.spacing
    }
}
