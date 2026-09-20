import AppKit
import QuartzCore

enum WorkspaceSidebarAutoHideReason {
    case pointerExit
    case systemChrome
}

/// Move the backing layer, not the NSWindow or SwiftUI layout. The stationary,
/// clipped panel keeps the rail from sliding onto a neighbouring display.
@MainActor
final class WorkspaceSidebarSlideTransition {
    static let animationKey = "workspaceSidebarSlide"
    static let duration: TimeInterval = 0.20
    private(set) var isHidden = false
    private(set) var isAnimating = false
    private var generation = 0
    private var pendingCompletion: DispatchWorkItem?
    private var completion: (() -> Void)?
    let layer: CALayer

    init(layer: CALayer) { self.layer = layer }

    func setHidden(_ hidden: Bool, offset: CGPoint, animated: Bool, completion: @escaping () -> Void = {}) {
        // Refreshes during a hide may change its reason, but must not restart it.
        if hidden == isHidden, isAnimating, animated {
            self.completion = completion
            return
        }
        if hidden == isHidden, !isAnimating {
            completion()
            return
        }
        // A just-reset endpoint may not have reached the presentation tree yet.
        let from = (isAnimating ? layer.presentation()?.transform : nil) ?? layer.transform
        let to = hidden ? CATransform3DMakeTranslation(offset.x, offset.y, 0) : CATransform3DIdentity
        generation += 1
        let token = generation
        pendingCompletion?.cancel()
        self.completion = completion
        isHidden = hidden
        isAnimating = animated
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = false
        layer.transform = to
        layer.removeAnimation(forKey: Self.animationKey)
        if animated {
            let slide = CABasicAnimation(keyPath: "transform")
            slide.fromValue = NSValue(caTransform3D: from)
            slide.toValue = NSValue(caTransform3D: to)
            slide.duration = Self.duration
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(slide, forKey: Self.animationKey)
        }
        CATransaction.commit()
        if animated {
            let work = DispatchWorkItem { [weak self] in self?.finish(generation: token) }
            pendingCompletion = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
        } else {
            finish(generation: token)
        }
    }

    /// Establish a new endpoint while offscreen (initial reveal, resize or disable).
    func reset(hidden: Bool = false, offset: CGPoint = .zero) {
        generation += 1
        pendingCompletion?.cancel()
        pendingCompletion = nil
        completion = nil
        isHidden = hidden
        isAnimating = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.animationKey)
        layer.isHidden = hidden
        layer.transform = hidden ? CATransform3DMakeTranslation(offset.x, offset.y, 0) : CATransform3DIdentity
        CATransaction.commit()
    }

    private func finish(generation token: Int) {
        guard token == generation else { return }
        pendingCompletion = nil
        isAnimating = false
        // Keep subsequent zero-width layout/overflow updates invisible at rest.
        // The stationary NSPanel still receives global edge-hover rechecks.
        layer.isHidden = isHidden
        let action = completion
        completion = nil
        action?()
    }
}

/// Coordinates in the unflipped clipping view. Include protruding magnified icons
/// and the configured edge gap so the entire rail clears the physical screen edge.
func workspaceSidebarSlideOffset(content: CGRect, bounds: CGRect, position: WorkspaceDockPosition) -> CGPoint {
    switch position {
        case .left: CGPoint(x: min(bounds.minX - content.maxX, 0), y: 0)
        case .right: CGPoint(x: max(bounds.maxX - content.minX, 0), y: 0)
        case .bottom: CGPoint(x: 0, y: min(bounds.minY - content.maxY, 0))
    }
}

extension WorkspaceSidebarPanel {
    var sidebarAcceptsPointer: Bool { autoHideReason == nil && !slideTransition.isHidden }

    var sidebarCommandWouldClose: Bool {
        autoHideReason == nil && (inlineTextEditingActive ||
            (viewModel.isWorkspaceSidebarExpanded && !config.workspaceSidebar.alwaysExpanded))
    }

    var slideOffset: CGPoint {
        var surface = visibleSurfaceFrameInHostingView
        let settings = config.workspaceSidebar
        let compactWidth = workspaceSidebarHoverActivationWidth(settings)
        let width = max(viewModel.workspaceSidebarVisibleWidth, compactWidth)
        let progress = min(max((width - compactWidth) / max(CGFloat(settings.width) - compactWidth, 1), 0), 1)
        // Preferences can still describe the preceding hidden layout on this turn.
        // Include the destination geometry before showing the native layer.
        let expected = workspaceSidebarSurfaceFrame(availableSize: hostingView.bounds.size,
            visibleWidth: settings.showAppIcons && width <= compactWidth
                ? width * (fittedDockRestingWidth ?? compactWidth) / max(compactWidth, 1) : width,
            compactHeight: settings.effectiveDockPosition == .bottom ? surface.width : surface.height,
            expansionProgress: progress, fitsDockContent: settings.showAppIcons,
            compactLeftGap: CGFloat(settings.effectiveLeftGap), position: settings.effectiveDockPosition)
        // The retained cache may still describe a search view after it hid. Keep
        // its long axis for re-entry, not its old expanded thickness for this slide.
        if width <= compactWidth, !surface.isEmpty {
            if settings.effectiveDockPosition == .bottom {
                surface.origin.y = expected.origin.y
                surface.size.height = expected.height
            } else {
                surface.origin.x = expected.origin.x
                surface.size.width = expected.width
            }
        }
        let base = surface.isEmpty ? expected : surface.union(expected)
        let content = dockIconFrames.filter { !$0.isEmpty }.reduce(base) { $0.union($1) }
        let rect = hostingView.convert(content, to: clippingView)
        return workspaceSidebarSlideOffset(content: rect, bounds: clippingView.bounds,
            position: config.workspaceSidebar.effectiveDockPosition)
    }

    func hideSidebar(_ reason: WorkspaceSidebarAutoHideReason, animated: Bool = true) {
        // Cancelling command search calls closeWorkspaceSidebarFromCommand again.
        // That nested pointer close must not downgrade native suppression.
        guard autoHideReason != .systemChrome || reason == .systemChrome else { return }
        guard autoHideReason != reason else { return }
        autoHideReason = reason
        // Input is released at the start, while the outgoing pixels remain visible.
        dockPointerView?.reset(reason: .hidden)
        cancelInlineTextEditing()
        clearWorkspaceSidebarCommandInputState(self)
        cancelExpansionWork()
        ignoresMouseEvents = true
        let shouldAnimate = animated && isVisible && viewModel.workspaceSidebarVisibleWidth > 0
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        slideTransition.setHidden(true, offset: slideOffset, animated: shouldAnimate) { [weak self] in
            guard let self, self.autoHideReason != nil else { return }
            self.clearHiddenSidebarContent(preserveSurface: true)
            self.viewModel.isWorkspaceSidebarExpanded = false
            if self.autoHideReason == .systemChrome { self.orderOut(nil) }
        }
    }

    func revealSidebar(width: CGFloat) {
        let wasFullyHidden = viewModel.workspaceSidebarVisibleWidth == 0 ||
            (slideTransition.isHidden && !slideTransition.isAnimating)
        autoHideReason = nil
        // Prepare the real content size before revealing it. A hide never compresses
        // icons; reversing mid-flight uses the current presentation-layer transform.
        viewModel.workspaceSidebarVisibleWidth = width
        if width < CGFloat(config.workspaceSidebar.width) {
            viewModel.isWorkspaceSidebarExpanded = config.workspaceSidebar.alwaysExpanded
        }
        hostingView.layoutSubtreeIfNeeded()
        if wasFullyHidden { slideTransition.reset(hidden: true, offset: slideOffset) }
        slideTransition.setHidden(false, offset: .zero,
            animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { [weak self] in
                self?.updateMousePassthrough()
                self?.scheduleHoverRecheckSoon()
            }
        updateMousePassthrough()
    }
}
