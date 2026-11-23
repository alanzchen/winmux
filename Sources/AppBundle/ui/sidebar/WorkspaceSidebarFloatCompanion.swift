import SwiftUI

/// A floating window accompanies a full-size tiled icon; only the full-size icon owns badges.
struct WorkspaceSidebarFloatCompanion: View {
    let window: WorkspaceSidebarWindowViewModel
    let mainIconSize: CGFloat
    var stackIndex = 0
    let onSelect: () -> Void
    nonisolated static let scale: CGFloat = 0.45
    nonisolated static let ringWidth: CGFloat = 1

    nonisolated static func offset(at index: Int, mainIconSize: CGFloat) -> CGSize {
        let offset = 2 - CGFloat(index) * mainIconSize * 0.2
        return CGSize(width: offset, height: offset)
    }

    static func windows(in windows: [WorkspaceSidebarWindowViewModel]) -> [WorkspaceSidebarWindowViewModel] {
        guard windows.contains(where: { $0.state != .floating }) else { return [] }
        return Array(windows.filter { $0.state == .floating }.prefix(2))
    }

    var body: some View {
        let size = mainIconSize * Self.scale
        Button(action: onSelect) {
            WorkspaceSidebarWindowIcon(window: window, size: size)
                .padding(Self.ringWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .mask(WorkspaceSidebarFloatCompanionCutout(mainIconSize: mainIconSize, count: stackIndex, companionIndex: stackIndex))
        .accessibilityLabel("\(window.appName), floating window")
    }
}

/// Remove the companion footprints from the main icon's surface so each thin ring reveals
/// the actual tile background. Path subtraction also keeps overlapping companions' rings clear.
struct WorkspaceSidebarFloatCompanionCutout: Shape {
    let mainIconSize: CGFloat
    let count: Int
    /// A rear companion also leaves room for the rings of companions drawn in front of it.
    var companionIndex: Int? = nil

    func path(in rect: CGRect) -> Path {
        var path = CGPath(rect: rect, transform: nil)
        let size = mainIconSize * WorkspaceSidebarFloatCompanion.scale
        let ring = WorkspaceSidebarFloatCompanion.ringWidth
        let origin: CGPoint
        if let companionIndex {
            let offset = WorkspaceSidebarFloatCompanion.offset(at: companionIndex, mainIconSize: mainIconSize)
            origin = CGPoint(x: rect.minX - offset.width, y: rect.minY - offset.height)
        } else {
            origin = CGPoint(x: rect.midX + mainIconSize / 2 - size - 2 * ring,
                y: rect.midY + mainIconSize / 2 - size - 2 * ring)
        }
        for index in 0..<count {
            let offset = WorkspaceSidebarFloatCompanion.offset(at: index, mainIconSize: mainIconSize)
            let footprint = CGRect(x: origin.x + offset.width, y: origin.y + offset.height,
                width: size + 2 * ring, height: size + 2 * ring)
            path = path.subtracting(CGPath(roundedRect: footprint, cornerWidth: size * 0.23 + ring,
                cornerHeight: size * 0.23 + ring, transform: nil))
        }
        return Path(path)
    }
}
