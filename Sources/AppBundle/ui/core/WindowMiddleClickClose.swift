import AppKit
import Common
import SwiftUI

let windowMiddleMouseButtonNumber = 2
/// How long a hidden window may take to close before WinMux reveals it, so a save
/// or confirmation sheet attached to a parked window becomes visible.
let windowMiddleClickRevealDelay: Duration = .milliseconds(400)

/// Only middle-button events reach the catcher. Left and right clicks, drags, and
/// scrolling fall through to the SwiftUI control underneath.
func windowMiddleClickCapturesEvent(_ type: NSEvent.EventType?) -> Bool {
    switch type {
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp: true
        default: false
    }
}

/// A window closes when the middle button is pressed and released over its row or tab,
/// like a browser tab.
func shouldCloseWindowOnMouseUp(buttonNumber: Int, pressedButtonNumber: Int?, isInside: Bool, enabled: Bool) -> Bool {
    enabled && buttonNumber == windowMiddleMouseButtonNumber && pressedButtonNumber == buttonNumber && isInside
}

/// Overlay for a SwiftUI tab or row that represents one window.
struct WindowMiddleClickCatcher: NSViewRepresentable {
    let onMiddleClick: @MainActor () -> Void

    func makeNSView(context: Context) -> WindowMiddleClickView {
        let view = WindowMiddleClickView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ view: WindowMiddleClickView, context: Context) {
        view.onMiddleClick = onMiddleClick
    }
}

final class WindowMiddleClickView: NSView {
    var onMiddleClick: (@MainActor () -> Void)?
    private var pressedButtonNumber: Int?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard windowMiddleClickCapturesEvent(NSApp.currentEvent?.type) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func otherMouseDown(with event: NSEvent) {
        pressButton(event.buttonNumber)
    }

    override func otherMouseUp(with event: NSEvent) {
        releaseButton(event.buttonNumber, at: convert(event.locationInWindow, from: nil))
    }

    func pressButton(_ buttonNumber: Int) {
        pressedButtonNumber = buttonNumber
    }

    func releaseButton(_ buttonNumber: Int, at point: CGPoint) {
        defer { pressedButtonNumber = nil }
        guard shouldCloseWindowOnMouseUp(
            buttonNumber: buttonNumber,
            pressedButtonNumber: pressedButtonNumber,
            isInside: bounds.contains(point),
            enabled: config.middleClickClosesWindows,
        ) else { return }
        onMiddleClick?()
    }
}

/// A window the user cannot currently see: a background tab, or one on a workspace
/// that is not showing. A prompt it raises while closing would appear off screen.
@MainActor
func windowIsHiddenFromView(_ window: Window) -> Bool {
    if window.nodeWorkspace?.isVisible != true { return true }
    guard let tabGroup = window.nearestWindowTabGroup, tabGroup.usesWindowTabBehavior else { return false }
    return tabGroup.tabActiveWindow !== window
}

/// Presses the window's close button, as Command-W would once the window is focused.
/// A hidden window closes in place. If it is still open shortly afterwards, usually
/// because the app is asking to save changes, `reveal` brings it into view so the prompt shows.
@MainActor
func closeWindowFromMiddleClick(_ windowId: UInt32, reveal: @escaping @MainActor () -> Void) {
    guard !serverArgs.isReadOnly, let token: RunSessionGuard = .isServerEnabled else { return }
    Task { @MainActor in
        var closedHiddenWindow = false
        do {
            try await runLightSession(.menuBarButton, token) {
                guard let macWindow = Window.get(byId: windowId) as? MacWindow else { return }
                let isHidden = windowIsHiddenFromView(macWindow)
                guard try await macWindow.macApp.pressCloseButton(windowId) else {
                    showWindowCloseError("This window could not be closed.")
                    return
                }
                closedHiddenWindow = isHidden
            }
        } catch {
            showWindowCloseError(error.localizedDescription)
            return
        }
        guard closedHiddenWindow else { return }
        try? await Task.sleep(for: windowMiddleClickRevealDelay)
        guard let macWindow = Window.get(byId: windowId) as? MacWindow,
              (try? await macWindow.macApp.containsAxWindow(windowId)) == true else { return }
        reveal()
    }
}

@MainActor
private func showWindowCloseError(_ body: String) {
    MessageModel.shared.message = Message(description: "Close Window Error", body: body)
}
