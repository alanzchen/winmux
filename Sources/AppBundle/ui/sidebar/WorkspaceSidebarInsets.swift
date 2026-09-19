import SwiftUI

func workspaceSidebarOuterLeadingPadding(isCompact: Bool, layout: WorkspaceSidebarConfiguration? = nil) -> CGFloat {
    isCompact ? layout?.compactHorizontalInset ?? workspaceSidebarCompactRailHorizontalInset : workspaceSidebarContentLeadingInset
}

func workspaceSidebarOuterTrailingPadding(isCompact: Bool, layout: WorkspaceSidebarConfiguration? = nil) -> CGFloat {
    isCompact ? layout?.compactHorizontalInset ?? workspaceSidebarCompactRailHorizontalInset : workspaceSidebarContentTrailingInset
}

func workspaceSidebarStatusBottomPadding(isCompact: Bool, layout: WorkspaceSidebarConfiguration? = nil) -> CGFloat {
    workspaceSidebarOuterLeadingPadding(isCompact: isCompact, layout: layout)
}

func workspaceSidebarFooterBottomPadding(showsClock: Bool) -> CGFloat {
    showsClock ? 0 : 6
}

func workspaceSidebarHoverCueWidth(collapsedWidth: CGFloat, expandedWidth: CGFloat) -> CGFloat {
    min(collapsedWidth, expandedWidth)
}
