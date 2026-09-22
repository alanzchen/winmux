import AppKit
import SwiftUI

/// AppKit supplies a reliable end callback for both drops and cancelled drags.
struct WorkspaceSidebarWorkspaceDragSource: NSViewRepresentable {
    let workspaceName: String
    let displayName: String
    let onActivate: @MainActor () -> Void

    func makeNSView(context: Context) -> WorkspaceSidebarWorkspaceDragSourceView {
        WorkspaceSidebarWorkspaceDragSourceView()
    }

    func updateNSView(_ view: WorkspaceSidebarWorkspaceDragSourceView, context: Context) {
        view.workspaceName = workspaceName
        view.displayName = displayName
        view.onActivate = onActivate
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(displayName)
    }

    static func dismantleNSView(_ view: WorkspaceSidebarWorkspaceDragSourceView, coordinator: ()) {
        // An AppKit session can outlive this row. Its end callback or source
        // deallocation releases the claim, keeping the destination available.
        view.cancelPendingActivation()
    }
}

final class WorkspaceSidebarWorkspaceDragSourceView: NSView, NSDraggingSource {
    var workspaceName = ""
    var displayName = ""
    var onActivate: @MainActor () -> Void = {}
    private var mouseDownPoint: CGPoint?
    private var mouseDownEvent: NSEvent?
    private var dragClaim: WorkspaceSidebarNativeDragClaim?
    private(set) var isDraggingWorkspace = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            mouseDownPoint = nil
            mouseDownEvent = nil
            rightMouseDown(with: event)
            return
        }
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint, let mouseDownEvent, !isDraggingWorkspace else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) >= 4,
              let pasteboard = WorkspaceSidebarWorkspaceDragPayload(workspaceName: workspaceName).pasteboardItem
        else { return }
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let preview = dragPreview()
        let previewOrigin = CGPoint(x: origin.x - 10, y: origin.y - preview.size.height / 2)
        item.setDraggingFrame(CGRect(origin: previewOrigin, size: preview.size), contents: preview)
        beginDrag()
        beginDraggingSession(with: [item], event: mouseDownEvent, source: self)
            .animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        let shouldActivate = mouseDownPoint != nil && !isDraggingWorkspace &&
            bounds.contains(convert(event.locationInWindow, from: nil))
        mouseDownPoint = nil
        mouseDownEvent = nil
        if shouldActivate { onActivate() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard !isDraggingWorkspace else { return false }
        onActivate()
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag()
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func beginDrag() {
        guard !isDraggingWorkspace else { return }
        isDraggingWorkspace = true
        dragClaim = WorkspaceSidebarNativeDragClaim()
    }

    func cancelPendingActivation() {
        mouseDownPoint = nil
        mouseDownEvent = nil
    }

    func finishDrag() {
        cancelPendingActivation()
        guard isDraggingWorkspace else { return }
        isDraggingWorkspace = false
        dragClaim = nil
    }

    private func dragPreview() -> NSImage {
        let title = NSAttributedString(string: displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let size = CGSize(width: min(title.size().width + 20, 320), height: 36)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.16, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            title.draw(in: rect.insetBy(dx: 10, dy: 9))
            return true
        }
    }
}

@MainActor
private final class WorkspaceSidebarNativeDragClaim {
    init() { beginWorkspaceSidebarNativeWorkspaceDrag() }

    isolated deinit {
        endWorkspaceSidebarNativeWorkspaceDrag()
        WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
    }
}
