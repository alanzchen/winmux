import SwiftUI

// Tabs mode lines everything up on one grid. On each level, the leading glyph of every
// row (a tab's icon, the New Tab plus, the search glass, a group's chevron) centers on
// one column. A group's own icon and title, and its rows, start one step further in.

/// Space before a row's icon, from the list's edge.
let workspaceSidebarTabLeadingPadding: CGFloat = 10
/// How far a group's contents sit in from its header's chevron.
let workspaceSidebarTabIndentStep: CGFloat = 20
/// Padding inside a group's card.
let workspaceSidebarTabGroupInset: CGFloat = 4
/// A top-level card. Nested cards and the rows inside a card stay concentric with it.
let workspaceSidebarTabGroupCornerRadius: CGFloat = 14
/// The trailing column that holds counts, checkmarks, and a hovered row's close button.
let workspaceSidebarTabTrailingSlotWidth: CGFloat = workspaceSidebarTabCloseSlotWidth

/// Where a view sits on the grid: its level, and how far enclosing cards have moved its
/// leading edge in from the list's.
struct WorkspaceSidebarTabIndent: Equatable {
    var depth = 0
    var inset: CGFloat = 0

    /// Padding before the icon of a row at this level.
    var leadingPadding: CGFloat {
        workspaceSidebarTabLeadingPadding + CGFloat(depth) * workspaceSidebarTabIndentStep - inset
    }

    /// A card at this level: its header stays on the level, its rows go one step in.
    var header: WorkspaceSidebarTabIndent { .init(depth: depth, inset: inset + workspaceSidebarTabGroupInset) }
    var children: WorkspaceSidebarTabIndent { .init(depth: depth + 1, inset: inset + workspaceSidebarTabGroupInset) }

    var cardCornerRadius: CGFloat { max(6, workspaceSidebarTabGroupCornerRadius - inset) }
    /// Rows inside a card follow its corners; rows outside any card keep the tab radius.
    var rowCornerRadius: CGFloat { inset > 0 ? max(6, workspaceSidebarTabGroupCornerRadius - inset) : workspaceSidebarTabCornerRadius }
}

private struct WorkspaceSidebarTabIndentKey: EnvironmentKey {
    static let defaultValue = WorkspaceSidebarTabIndent()
}

private struct WorkspaceSidebarReducesMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var workspaceSidebarTabIndent: WorkspaceSidebarTabIndent {
        get { self[WorkspaceSidebarTabIndentKey.self] }
        set { self[WorkspaceSidebarTabIndentKey.self] = newValue }
    }

    /// The sidebar's Reduce Motion choice, so rows follow the same override the root view does.
    var workspaceSidebarReducesMotion: Bool {
        get { self[WorkspaceSidebarReducesMotionKey.self] }
        set { self[WorkspaceSidebarReducesMotionKey.self] = newValue }
    }
}

/// Tabs mode's motion. With Reduce Motion, nothing slides or resizes; hover and drop
/// feedback still fade, briefly.
enum WorkspaceSidebarTabMotion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let feedback = Animation.easeOut(duration: 0.14)
    static let disclosure = Animation.spring(response: 0.3, dampingFraction: 0.88)
    static let reorder = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let selection = Animation.easeOut(duration: 0.18)

    static func disclosure(reducesMotion: Bool) -> Animation? { reducesMotion ? nil : disclosure }
    static func reorder(reducesMotion: Bool) -> Animation? { reducesMotion ? nil : reorder }
    static func selection(reducesMotion: Bool) -> Animation? { reducesMotion ? nil : selection }
}

/// Rows a group reveals fade in just below its header, and fade out where they are.
extension AnyTransition {
    static var workspaceSidebarTabReveal: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity)
    }
}

/// A group's disclosure arrow, turning as the group opens.
struct WorkspaceSidebarTabDisclosureChevron: View {
    let isExpanded: Bool
    var tint: Color? = nil
    var isHighlighted = false
    var isEnabled = true

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle((tint ?? Color.primary).opacity(isEnabled ? (isHighlighted ? 0.95 : 0.6) : 0.3))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
    }
}

/// The count at the end of a group's header, in the column rows keep for their close button.
struct WorkspaceSidebarTabCountLabel: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.primary.opacity(0.4))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: workspaceSidebarTabTrailingSlotWidth)
            .contentTransition(.numericText())
    }
}

/// The label of any group's header: the chevron on this level's icon column, the group's
/// icon and title on its rows' columns, then optional accessories and the count.
struct WorkspaceSidebarTabGroupHeaderLabel<Icon: View, Title: View, Accessory: View>: View {
    let isExpanded: Bool
    var tint: Color? = nil
    var count: Int? = nil
    var canToggle = true
    var isHighlighted = false
    /// The chevron is drawn by the header's own disclosure button instead.
    var drawsChevron = true
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let title: () -> Title
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.workspaceSidebarTabIndent) private var indent

    var body: some View {
        HStack(spacing: 9) {
            icon().frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
            title()
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
            if let count { WorkspaceSidebarTabCountLabel(count: count) }
        }
        .padding(.leading, indent.leadingPadding + workspaceSidebarTabIndentStep)
        .padding(.trailing, count == nil ? workspaceSidebarTabTrailingSlotWidth : 0)
        .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, maxHeight: workspaceSidebarTabRowHeight,
            alignment: .leading)
        .overlay(alignment: .leading) {
            if drawsChevron {
                WorkspaceSidebarTabDisclosureChevron(isExpanded: isExpanded, tint: tint, isHighlighted: isHighlighted,
                    isEnabled: canToggle)
                    .padding(.leading, indent.leadingPadding)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

extension WorkspaceSidebarTabGroupHeaderLabel where Accessory == EmptyView {
    init(isExpanded: Bool, tint: Color? = nil, count: Int? = nil, canToggle: Bool = true, isHighlighted: Bool = false,
         drawsChevron: Bool = true, @ViewBuilder icon: @escaping () -> Icon, @ViewBuilder title: @escaping () -> Title) {
        self.init(isExpanded: isExpanded, tint: tint, count: count, canToggle: canToggle, isHighlighted: isHighlighted,
            drawsChevron: drawsChevron, icon: icon, title: title, accessory: { EmptyView() })
    }
}

/// A group's title: the group's color when it has one.
struct WorkspaceSidebarTabGroupTitle: View {
    let text: String
    var tint: Color? = nil
    var isActive = true

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint.map { $0.opacity(isActive ? 1 : 0.85) } ?? Color.primary.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// A disclosure button laid over a header's chevron, for headers whose label does something
/// else when clicked.
struct WorkspaceSidebarTabDisclosureButton: View {
    let isExpanded: Bool
    var tint: Color? = nil
    var canToggle = true
    let label: String
    let toggle: () -> Void
    @State private var isHovered = false
    @Environment(\.workspaceSidebarTabIndent) private var indent

    var body: some View {
        Button(action: toggle) {
            WorkspaceSidebarTabDisclosureChevron(isExpanded: isExpanded, tint: tint, isHighlighted: isHovered,
                isEnabled: canToggle)
                .frame(width: workspaceSidebarTabIconSize + 8, height: workspaceSidebarTabRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canToggle)
        .onHover { hovering in withAnimation(WorkspaceSidebarTabMotion.hover) { isHovered = hovering } }
        // Centered on the level's icon column; the extra width only widens the hit area.
        .padding(.leading, max(0, indent.leadingPadding - 4))
        .accessibilityLabel(label)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// Every kind of group in Tabs mode, whether one of your groups, a browser window's tabs,
/// or a workspace folder, uses this card: one shape, one fill, the same header and rows.
struct WorkspaceSidebarTabGroupCard<Header: View, Content: View>: View {
    /// The group's color; nil for a neutral card.
    let tint: Color?
    let isExpanded: Bool
    var isActive = false
    var isDropTarget = false
    /// A card flush inside another shape, such as a split's row, takes that shape's corners.
    var cornerRadius: CGFloat? = nil
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @Environment(\.workspaceSidebarTabIndent) private var indent
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? indent.cardCornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            header()
                .environment(\.workspaceSidebarTabIndent, indent.header)
            if isExpanded {
                content()
                    .environment(\.workspaceSidebarTabIndent, indent.children)
                    .transition(.workspaceSidebarTabReveal)
            }
        }
        .padding(workspaceSidebarTabGroupInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            shape.fill(fill)
                .overlay { shape.strokeBorder(stroke, lineWidth: 1) }
                .animation(WorkspaceSidebarTabMotion.feedback, value: isDropTarget)
        }
        // Rows revealed by opening the group stay inside the card while it grows.
        .clipShape(shape)
        .animation(WorkspaceSidebarTabMotion.disclosure(reducesMotion: reducesMotion), value: isExpanded)
    }

    // A drop target takes the accent every drop target in the list uses, whatever its color.
    private var fill: Color {
        if isDropTarget { return Color.accentColor.opacity(0.14) }
        guard let tint else { return Color.primary.opacity(isActive ? 0.06 : 0.04) }
        return tint.opacity(isActive ? 0.14 : 0.1)
    }

    private var stroke: Color {
        if isDropTarget { return Color.accentColor.opacity(0.65) }
        guard let tint else { return Color.primary.opacity(0.07) }
        return tint.opacity(0.18)
    }
}
