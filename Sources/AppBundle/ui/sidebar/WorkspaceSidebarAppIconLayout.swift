import CoreGraphics

struct WorkspaceSidebarAppIconLayout {
    static let iconSize: CGFloat = 14
    static let spacing: CGFloat = 3
    static let badgeHeight: CGFloat = 22

    let isInline: Bool
    let visibleAppCount: Int
    let overflowCount: Int
    let columns: Int
    let height: CGFloat

    init(appCount: Int, availableWidth: CGFloat) {
        let visibleCount = min(max(appCount, 0), 3)
        if visibleCount == 0 {
            self.init(isInline: true, visibleAppCount: 0, overflowCount: 0, columns: 1, height: 32)
            return
        }
        for count in stride(from: visibleCount, through: 1, by: -1) {
            let overflow = max(appCount - count, 0)
            let iconsWidth = CGFloat(count) * Self.iconSize + CGFloat(count - 1) * Self.spacing
            let overflowWidth = overflow == 0 ? 0 : CGFloat(String(overflow).count + 1) * 6 + Self.spacing
            if Self.badgeHeight + 6 + iconsWidth + overflowWidth <= availableWidth {
                self.init(isInline: true, visibleAppCount: count, overflowCount: overflow, columns: count, height: 32)
                return
            }
        }
        let overflow = max(appCount - visibleCount, 0)
        let itemCount = visibleCount + (overflow > 0 ? 1 : 0)
        let columns = min(itemCount, max(Int((availableWidth + Self.spacing) / (Self.iconSize + Self.spacing)), 1))
        let rows = (itemCount + columns - 1) / columns
        let height = Self.badgeHeight + 4 + CGFloat(rows) * Self.iconSize + CGFloat(rows - 1) * Self.spacing
        self.init(isInline: false, visibleAppCount: visibleCount, overflowCount: overflow, columns: columns, height: height)
    }

    private init(isInline: Bool, visibleAppCount: Int, overflowCount: Int, columns: Int, height: CGFloat) {
        self.isInline = isInline
        self.visibleAppCount = visibleAppCount
        self.overflowCount = overflowCount
        self.columns = columns
        self.height = height
    }
}
