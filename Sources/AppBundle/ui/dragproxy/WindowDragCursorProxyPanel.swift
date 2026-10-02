import AppKit
import Common
import SwiftUI

@MainActor
final class WindowDragCursorProxyPanel: NSPanelHud {
    static let shared = WindowDragCursorProxyPanel()

    let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    var currentContent: WindowDragCursorProxyContent?
    var proxySize: CGSize = .zero
    /// How far above the proxy's bottom the pointer sits; nil centers the proxy on it.
    var proxyPointerFromBottom: CGFloat?

    override private init() {
        super.init()
        identifier = NSUserInterfaceItemIdentifier(windowDragCursorProxyPanelId)
        hasShadow = false
        isFloatingPanel = true
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        ignoresMouseEvents = true
        backgroundColor = .clear
        applyWinMuxLayer(.dragCursorProxy)
        level = NSWindow.Level(rawValue: WinMuxPanelLayer.workspaceSidebar.level.rawValue + 1)
        contentView = hostingView
        hostingView.frame = contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
    }

    func show(label: String, isGroup: Bool, mouseScreenPoint: CGPoint) {
        updateContent(label: label, isGroup: isGroup)
        proxySize = windowDragCursorProxySize(label: label)
        proxyPointerFromBottom = nil
        updateFrame(mouseScreenPoint: mouseScreenPoint)
        startFollowingMouseIfNeeded()
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func show(preview: WorkspaceSidebarDropPreviewViewModel, mouseScreenPoint: CGPoint, style: WorkspaceSidebarDragPreviewStyle = .row) {
        updateContent(preview: preview, style: style)
        proxySize = windowDragCursorProxySize(preview: preview, style: style)
        proxyPointerFromBottom = windowDragCursorProxyPointerFromBottom(preview: preview, style: style)
        updateFrame(mouseScreenPoint: mouseScreenPoint)
        startFollowingMouseIfNeeded()
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func hide() {
        guard currentContent != nil || isVisible else { return }
        stopFollowingMouse()
        currentContent = nil
        // Drop icon consumers and preview captures when the gesture finishes.
        hostingView.rootView = AnyView(EmptyView())
        // Hidden hosts can defer SwiftUI teardown; finish it before ordering out.
        hostingView.layoutSubtreeIfNeeded()
        if isVisible {
            orderOut(nil)
        }
    }
}
struct WindowDragCursorProxyContent: Equatable {
    let label: String
    let isGroup: Bool
    let preview: WorkspaceSidebarDropPreviewViewModel?
    let style: WorkspaceSidebarDragPreviewStyle

    init(label: String, isGroup: Bool, preview: WorkspaceSidebarDropPreviewViewModel? = nil, style: WorkspaceSidebarDragPreviewStyle = .row) {
        self.label = label
        self.isGroup = isGroup
        self.preview = preview
        self.style = style
    }
}

extension WindowDragCursorProxyPanel {
    func updateContent(label: String, isGroup: Bool) {
        let nextContent = WindowDragCursorProxyContent(label: label, isGroup: isGroup)
        guard currentContent != nextContent else { return }
        hostingView.rootView = AnyView(WindowDragCursorProxyView(label: label, isGroup: isGroup))
        currentContent = nextContent
    }

    func updateContent(preview: WorkspaceSidebarDropPreviewViewModel, style: WorkspaceSidebarDragPreviewStyle = .row) {
        let nextContent = WindowDragCursorProxyContent(
            label: preview.label,
            isGroup: preview.isTabGroup,
            preview: preview,
            style: style,
        )
        guard currentContent != nextContent else { return }
        hostingView.rootView = AnyView(WindowDragCursorProxyView(preview: preview, style: style))
        currentContent = nextContent
    }
}

func windowDragCursorProxySize(label: String, style: WorkspaceSidebarDragPreviewStyle = .row) -> CGSize {
    switch style {
        case .row: CGSize(width: min(max(CGFloat(label.count) * 7 + 42, 96), 224), height: 28)
        case .appIcon(let size): CGSize(width: size + 12, height: size + 12)
    }
}

let windowDragCursorProxyBatchLabelHeight: CGFloat = 16
let windowDragCursorProxyBatchLabelSpacing: CGFloat = 2

/// The proxy for `preview`: an icon drag of several chosen tabs has their count above the icon.
@MainActor
func windowDragCursorProxySize(preview: WorkspaceSidebarDropPreviewViewModel, style: WorkspaceSidebarDragPreviewStyle) -> CGSize {
    let size = windowDragCursorProxySize(label: preview.label, style: style)
    guard case .appIcon = style, preview.batchTabCount != nil else { return size }
    return CGSize(width: max(size.width, workspaceSidebarTabDropLabelWidth(preview.label) + 8),
        height: size.height + windowDragCursorProxyBatchLabelSpacing + windowDragCursorProxyBatchLabelHeight)
}

/// Where the pointer sits in that proxy, from its bottom: on the icon, so the count above it stays
/// clear of the pointer, which covers what's below and right of its tip. Nil: centered, as always.
@MainActor
func windowDragCursorProxyPointerFromBottom(preview: WorkspaceSidebarDropPreviewViewModel,
                                            style: WorkspaceSidebarDragPreviewStyle) -> CGFloat? {
    guard case .appIcon = style, preview.batchTabCount != nil else { return nil }
    return windowDragCursorProxySize(label: preview.label, style: style).height / 2
}
extension WindowDragCursorProxyPanel {
    func startFollowingMouseIfNeeded() {
        DisplayRefreshDriver.shared.add(owner: self) { [weak self] _ in
            self?.updateFrameWhileDragging(mouseScreenPoint: NSEvent.mouseLocation)
        }
    }

    func stopFollowingMouse() {
        DisplayRefreshDriver.shared.remove(owner: self)
    }

    func updateFrame(mouseScreenPoint: CGPoint) {
        guard proxySize.width > 0, proxySize.height > 0 else { return }
        let targetFrame = windowDragCursorProxyFrame(
            mouseScreenPoint: mouseScreenPoint,
            proxySize: proxySize,
            pointerFromBottom: proxyPointerFromBottom,
        )
        if frame.size == targetFrame.size {
            setFrameOrigin(targetFrame.origin)
        } else {
            setFrame(targetFrame, display: false, animate: false)
        }
    }

    private func updateFrameWhileDragging(mouseScreenPoint: CGPoint) {
        guard isLeftMouseButtonDown else {
            hide()
            return
        }
        updateFrame(mouseScreenPoint: mouseScreenPoint)
    }
}
