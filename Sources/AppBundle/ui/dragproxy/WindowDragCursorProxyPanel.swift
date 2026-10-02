import AppKit
import Common
import SwiftUI

@MainActor
final class WindowDragCursorProxyPanel: NSPanelHud {
    static let shared = WindowDragCursorProxyPanel()

    let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    var currentContent: WindowDragCursorProxyContent?
    var proxySize: CGSize = .zero
    /// Where the pointer sits in the proxy, from its bottom-left corner; nil centers the proxy on it.
    var proxyPointer: CGPoint?
    /// Chosen tabs dragged as an icon, whose count moves beside the icon near the screen's top.
    var batchProxy: (preview: WorkspaceSidebarDropPreviewViewModel, style: WorkspaceSidebarDragPreviewStyle)?

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
        proxyPointer = nil
        batchProxy = nil
        updateFrame(mouseScreenPoint: mouseScreenPoint)
        startFollowingMouseIfNeeded()
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func show(preview: WorkspaceSidebarDropPreviewViewModel, mouseScreenPoint: CGPoint, style: WorkspaceSidebarDragPreviewStyle = .row) {
        if case .appIcon = style, preview.batchTabCount != nil {
            batchProxy = (preview, style)
            layOutBatchProxy(mouseScreenPoint: mouseScreenPoint, force: true)
        } else {
            batchProxy = nil
            updateContent(preview: preview, style: style)
            proxySize = windowDragCursorProxySize(preview: preview, style: style)
            proxyPointer = nil
        }
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
        batchProxy = nil
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
    var batchLabelPlacement: WindowDragCursorProxyBatchLabelPlacement = .above

    init(label: String, isGroup: Bool, preview: WorkspaceSidebarDropPreviewViewModel? = nil, style: WorkspaceSidebarDragPreviewStyle = .row,
         batchLabelPlacement: WindowDragCursorProxyBatchLabelPlacement = .above) {
        self.label = label
        self.isGroup = isGroup
        self.preview = preview
        self.style = style
        self.batchLabelPlacement = batchLabelPlacement
    }
}

extension WindowDragCursorProxyPanel {
    func updateContent(label: String, isGroup: Bool) {
        let nextContent = WindowDragCursorProxyContent(label: label, isGroup: isGroup)
        guard currentContent != nextContent else { return }
        hostingView.rootView = AnyView(WindowDragCursorProxyView(label: label, isGroup: isGroup))
        currentContent = nextContent
    }

    func updateContent(preview: WorkspaceSidebarDropPreviewViewModel, style: WorkspaceSidebarDragPreviewStyle = .row,
                       batchLabelPlacement: WindowDragCursorProxyBatchLabelPlacement = .above) {
        let nextContent = WindowDragCursorProxyContent(
            label: preview.label,
            isGroup: preview.isTabGroup,
            preview: preview,
            style: style,
            batchLabelPlacement: batchLabelPlacement,
        )
        guard currentContent != nextContent else { return }
        hostingView.rootView = AnyView(WindowDragCursorProxyView(preview: preview, style: style,
            batchLabelPlacement: batchLabelPlacement))
        currentContent = nextContent
    }

    /// The batch's count goes above its icon, or, too near the screen's top for that, before it.
    func layOutBatchProxy(mouseScreenPoint: CGPoint, force: Bool = false) {
        guard let (preview, style) = batchProxy else { return }
        let placement = windowDragCursorProxyBatchLabelPlacement(mouseScreenPoint: mouseScreenPoint,
            icon: windowDragCursorProxySize(label: preview.label, style: style),
            labelWidth: workspaceSidebarTabDropLabelWidth(preview.label),
            screenFrame: windowDragCursorProxyScreenFrame(containing: mouseScreenPoint))
        guard force || currentContent?.batchLabelPlacement != placement else { return }
        updateContent(preview: preview, style: style, batchLabelPlacement: placement)
        proxySize = windowDragCursorProxySize(preview: preview, style: style, batchLabelPlacement: placement)
        proxyPointer = windowDragCursorProxyPointer(preview: preview, style: style, batchLabelPlacement: placement)
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

/// Where an icon drag of several chosen tabs shows their count.
enum WindowDragCursorProxyBatchLabelPlacement: Equatable {
    case above
    /// Before the icon, at the pointer's height: too near the screen's top for above.
    case leading
    /// After the icon: too near the top for above, and the left edge for before.
    case trailing
}

/// Above the icon, which the pointer sits on, so the pointer, covering what's below and right of
/// its tip, leaves the count clear. Where the screen's top leaves no room above, before it; where
/// the left edge leaves none there either, after it, past the pointer's width.
func windowDragCursorProxyBatchLabelPlacement(mouseScreenPoint: CGPoint, icon: CGSize, labelWidth: CGFloat,
                                              screenFrame: CGRect) -> WindowDragCursorProxyBatchLabelPlacement {
    let above = icon.height / 2 + windowDragCursorProxyBatchLabelSpacing + windowDragCursorProxyBatchLabelHeight
    if screenFrame.maxY - mouseScreenPoint.y >= above { return .above }
    let before = icon.width / 2 + windowDragCursorProxyBatchLabelSpacing + labelWidth
    return mouseScreenPoint.x - screenFrame.minX >= before ? .leading : .trailing
}

/// The proxy for `preview`: an icon drag of several chosen tabs has their count beside the icon.
@MainActor
func windowDragCursorProxySize(preview: WorkspaceSidebarDropPreviewViewModel, style: WorkspaceSidebarDragPreviewStyle,
                               batchLabelPlacement: WindowDragCursorProxyBatchLabelPlacement = .above) -> CGSize {
    let size = windowDragCursorProxySize(label: preview.label, style: style)
    guard case .appIcon = style, preview.batchTabCount != nil else { return size }
    let label = workspaceSidebarTabDropLabelWidth(preview.label)
    return switch batchLabelPlacement {
        case .above: CGSize(width: max(size.width, label + 8),
            height: size.height + windowDragCursorProxyBatchLabelSpacing + windowDragCursorProxyBatchLabelHeight)
        case .leading, .trailing: CGSize(width: label + windowDragCursorProxyBatchLabelSpacing + size.width, height: size.height)
    }
}

/// Where the pointer sits in that proxy, from its bottom-left corner: on the icon. Nil: centered,
/// as for every other drag.
@MainActor
func windowDragCursorProxyPointer(preview: WorkspaceSidebarDropPreviewViewModel, style: WorkspaceSidebarDragPreviewStyle,
                                  batchLabelPlacement: WindowDragCursorProxyBatchLabelPlacement = .above) -> CGPoint? {
    guard case .appIcon = style, preview.batchTabCount != nil else { return nil }
    let icon = windowDragCursorProxySize(label: preview.label, style: style)
    let size = windowDragCursorProxySize(preview: preview, style: style, batchLabelPlacement: batchLabelPlacement)
    return switch batchLabelPlacement {
        case .above: CGPoint(x: size.width / 2, y: icon.height / 2)
        case .leading: CGPoint(x: size.width - icon.width / 2, y: icon.height / 2)
        case .trailing: CGPoint(x: icon.width / 2, y: icon.height / 2)
    }
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
        layOutBatchProxy(mouseScreenPoint: mouseScreenPoint)
        guard proxySize.width > 0, proxySize.height > 0 else { return }
        let targetFrame = windowDragCursorProxyFrame(
            mouseScreenPoint: mouseScreenPoint,
            proxySize: proxySize,
            pointer: proxyPointer,
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
