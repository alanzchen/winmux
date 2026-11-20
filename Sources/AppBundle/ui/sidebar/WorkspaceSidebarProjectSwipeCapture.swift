import AppKit
import Common
import SwiftUI

struct WorkspaceSidebarProjectSwipeScrollCapture: NSViewRepresentable {
    let isEnabled: Bool
    let onChanged: (CGFloat, CGFloat) -> Void
    let onCancelled: () -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
        if isEnabled {
            context.coordinator.installMonitor()
        } else {
            context.coordinator.removeMonitor()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var isEnabled = false
        var onChanged: ((CGFloat, CGFloat) -> Void)?
        var onCancelled: (() -> Void)?
        var onEnded: ((CGFloat, CGFloat) -> Void)?
        var monitor: Any?
        var horizontalTranslation: CGFloat = 0
        var verticalTranslation: CGFloat = 0
        var hasLockedHorizontalIntent = false
        var endWorkItem: DispatchWorkItem?

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            resetAccumulatedScroll()
        }

        func resetAccumulatedScroll() {
            endWorkItem?.cancel()
            endWorkItem = nil
            horizontalTranslation = 0
            verticalTranslation = 0
            hasLockedHorizontalIntent = false
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled,
                  !isWorkspaceSidebarDragInProgress(),
                  event.hasPreciseScrollingDeltas,
                  event.momentumPhase.isEmpty,
                  let view,
                  let window = view.window,
                  event.window === window
            else {
                resetIfNeededForExternalEvent(event)
                return event
            }
            let point = view.convert(event.locationInWindow, from: nil)
            let panel = window as? WorkspaceSidebarPanel
            guard hasLockedHorizontalIntent || (view.bounds.contains(point)
                && panel?.isEventInsideVisibleRegion(event) != false
                && panel?.isScreenPointInsideExpandedSurface(window.convertPoint(toScreen: event.locationInWindow)) != true) else {
                resetIfNeededForExternalEvent(event)
                return event
            }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                resetAccumulatedScroll()
            }
            horizontalTranslation = workspaceSidebarProjectSwipeTranslationAfterScroll(
                currentTranslation: horizontalTranslation,
                scrollingDeltaX: event.scrollingDeltaX,
            )
            verticalTranslation += event.scrollingDeltaY

            if !hasLockedHorizontalIntent {
                guard workspaceSidebarProjectSwipeDirection(
                    horizontalTranslation: horizontalTranslation,
                    verticalTranslation: verticalTranslation,
                ) != nil else {
                    if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                        resetAccumulatedScroll()
                    }
                    return event
                }
                hasLockedHorizontalIntent = true
            }

            onChanged?(horizontalTranslation, verticalTranslation)
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                finishLockedSwipe(cancelled: event.phase.contains(.cancelled))
            } else {
                scheduleEndTimer()
            }
            return nil
        }

        func resetIfNeededForExternalEvent(_ event: NSEvent) {
            guard hasLockedHorizontalIntent,
                  event.phase.contains(.ended) || event.phase.contains(.cancelled)
            else {
                return
            }
            finishLockedSwipe(cancelled: event.phase.contains(.cancelled))
        }

        func scheduleEndTimer() {
            endWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.finishLockedSwipe()
            }
            endWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        func finishLockedSwipe(cancelled: Bool = false) {
            guard hasLockedHorizontalIntent else {
                resetAccumulatedScroll()
                return
            }
            let finalHorizontalTranslation = horizontalTranslation
            let finalVerticalTranslation = verticalTranslation
            resetAccumulatedScroll()
            if cancelled {
                onCancelled?()
            } else {
                onEnded?(finalHorizontalTranslation, finalVerticalTranslation)
            }
        }
    }
}
