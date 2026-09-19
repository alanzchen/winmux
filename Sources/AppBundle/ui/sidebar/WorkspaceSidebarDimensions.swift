import SwiftUI

@MainActor
func workspaceSidebarCompactSectionWidth(layout: WorkspaceSidebarConfiguration) -> CGFloat {
    let width = layout.expansionStartWidth - layout.compactHorizontalInset * 2
    return layout.showAppIcons ? max(width, 1) : max(
        width,
        workspaceSidebarBadgeWidth + (workspaceSidebarSectionInnerHorizontalInset * 2),
    )
}

@MainActor
func workspaceSidebarExpandedSectionWidth(layout: WorkspaceSidebarConfiguration) -> CGFloat {
    max(
        layout.expandedWidth -
            workspaceSidebarContentLeadingInset -
            workspaceSidebarContentTrailingInset,
        workspaceSidebarCompactSectionWidth(layout: layout),
    )
}

@MainActor
func workspaceSidebarSectionWidth(_ expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration) -> CGFloat {
    let compact = workspaceSidebarCompactSectionWidth(layout: layout)
    let expanded = workspaceSidebarExpandedSectionWidth(layout: layout)
    return compact + (expanded - compact) * expansionProgress
}

@MainActor
func workspaceSidebarContentWidth(_ expansionProgress: CGFloat, layout: WorkspaceSidebarConfiguration) -> CGFloat {
    max(
        workspaceSidebarSectionWidth(expansionProgress, layout: layout) -
            (workspaceSidebarSectionInnerHorizontalInset * 2) -
            workspaceSidebarBadgeWidth -
            workspaceSidebarHeaderSpacing,
        0,
    )
}
