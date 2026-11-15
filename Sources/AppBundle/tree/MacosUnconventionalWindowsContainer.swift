import Common

final class MacosFullscreenWindowsContainer: TreeNode, NonLeafTreeNodeObject {
    @MainActor
    init(parent: Workspace) {
        super.init(parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }
}

/// The container for macOS windows of hidden apps
final class MacosHiddenAppsWindowsContainer: TreeNode, NonLeafTreeNodeObject {
    @MainActor
    init(parent: Workspace) {
        super.init(parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }
}

@MainActor let macosMinimizedWindowsContainer = MacosMinimizedWindowsContainer()
// WINMUX-HOOK-BEGIN(notPresentableWindows)
/// Windows that exist but can't be shown (`Window.isNotPresentable`): out of every tab, its layout and the sidebar,
/// remembered where they were (`setAsideNotPresentableWindow`). Of the minimized container's kind, so the tree treats
/// them as it treats minimized windows; not that container, so nothing takes them for minimized windows of a tab
/// (`workspaceOwnedMinimizedWindows`).
@MainActor let macosNotPresentableWindowsContainer = MacosMinimizedWindowsContainer()
// WINMUX-HOOK-END(notPresentableWindows)
final class MacosMinimizedWindowsContainer: TreeNode, NonLeafTreeNodeObject {
    @MainActor
    fileprivate init() {
        super.init(parent: NilTreeNode.instance, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }
}

@MainActor let macosPopupWindowsContainer = MacosPopupWindowsContainer()
/// The container for macOS objects that are windows from AX perspective but from human perspective they are not even
/// dialogs. E.g. Sonoma (macOS 14) keyboard layout switch
final class MacosPopupWindowsContainer: TreeNode, NonLeafTreeNodeObject {
    @MainActor
    fileprivate init() {
        super.init(parent: NilTreeNode.instance, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }
}
