import Common

@MainActor
func windowDragSourcePreviewItem(window: Window, subject: WindowDragSubject, frame: Rect) -> WindowResizePreviewItem? {
    guard frame.width > 0, frame.height > 0 else { return nil }
    if subject == .group,
       let tabGroup = window.moveNode as? TilingContainer,
       tabGroup.usesWindowTabBehavior
    {
        return WindowResizePreviewItem(tabGroup: tabGroup, rect: frame, drawsFrameOnly: true)
    }
    return WindowResizePreviewItem(window: window, rect: frame)
}
