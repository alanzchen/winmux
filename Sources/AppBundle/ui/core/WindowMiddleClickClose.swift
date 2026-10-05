import AppKit
import Common
import SwiftUI

let windowMiddleMouseButtonNumber = 2
/// After a hidden window's close button is pressed, WinMux watches this long for a sheet,
/// such as a prompt to save, that would otherwise stay out of view with the window.
let windowMiddleClickSheetPollInterval: Duration = .milliseconds(150)
let windowMiddleClickSheetPollCount = 10

/// Only middle-button events reach the catcher, and only while the setting is on. Left and
/// right clicks, other buttons, drags, and scrolling fall through to the SwiftUI control.
func windowMiddleClickCapturesEvent(_ type: NSEvent.EventType?, buttonNumber: Int?, enabled: Bool) -> Bool {
    guard enabled, buttonNumber == windowMiddleMouseButtonNumber else { return false }
    switch type {
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp: return true
        default: return false
    }
}

/// A window closes when the middle button is pressed and released over its row or tab,
/// like a browser tab.
func shouldCloseWindowOnMouseUp(buttonNumber: Int, pressedButtonNumber: Int?, isInside: Bool, enabled: Bool) -> Bool {
    enabled && buttonNumber == windowMiddleMouseButtonNumber && pressedButtonNumber == buttonNumber && isInside
}

/// Overlay for a SwiftUI tab or row that represents one window, or one browser tab.
struct WindowMiddleClickCatcher: NSViewRepresentable {
    let identity: AnyHashable
    let onMiddleClick: @MainActor () -> Void

    init(windowId: UInt32, onMiddleClick: @escaping @MainActor () -> Void) {
        identity = AnyHashable(windowId)
        self.onMiddleClick = onMiddleClick
    }

    /// A browser tab: its own identity, so a press on one tab never closes its neighbor.
    init(browserTab target: BrowserTabTarget, onMiddleClick: @escaping @MainActor () -> Void) {
        identity = AnyHashable(target)
        self.onMiddleClick = onMiddleClick
    }

    func makeNSView(context: Context) -> WindowMiddleClickView {
        let view = WindowMiddleClickView()
        view.update(identity: identity, onMiddleClick: onMiddleClick)
        return view
    }

    func updateNSView(_ view: WindowMiddleClickView, context: Context) {
        view.update(identity: identity, onMiddleClick: onMiddleClick)
    }
}

final class WindowMiddleClickView: NSView {
    private var identity: AnyHashable?
    private var onMiddleClick: (@MainActor () -> Void)?
    private var pressedButtonNumber: Int?
    private var pressedIdentity: AnyHashable?

    func update(windowId nextWindowId: UInt32, onMiddleClick nextAction: @escaping @MainActor () -> Void) {
        update(identity: AnyHashable(nextWindowId), onMiddleClick: nextAction)
    }

    /// SwiftUI can hand this view to another tab or row while the button is down; a
    /// release then belongs to no window.
    func update(identity nextIdentity: AnyHashable, onMiddleClick nextAction: @escaping @MainActor () -> Void) {
        if identity != nextIdentity {
            pressedButtonNumber = nil
            pressedIdentity = nil
        }
        identity = nextIdentity
        onMiddleClick = nextAction
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let event = NSApp.currentEvent
        guard windowMiddleClickCapturesEvent(event?.type, buttonNumber: event?.buttonNumber,
            enabled: config.middleClickClosesWindows) else { return nil }
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
        pressedIdentity = identity
    }

    func releaseButton(_ buttonNumber: Int, at point: CGPoint) {
        defer {
            pressedButtonNumber = nil
            pressedIdentity = nil
        }
        guard pressedIdentity != nil, pressedIdentity == identity, shouldCloseWindowOnMouseUp(
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
/// A hidden window closes in place. If it shows a sheet while closing, usually a prompt to
/// save changes, `reveal` brings it into view so the prompt can be answered. A window that
/// couldn't be closed says so beside the sidebar `monitorScopeId`, or on the pointer's display.
@MainActor
func closeWindowFromMiddleClick(_ windowId: UInt32, monitorScopeId: String? = nil, reveal: @escaping @MainActor () -> Void) {
    guard !serverArgs.isReadOnly, let token: RunSessionGuard = .isServerEnabled else { return }
    Task { @MainActor in
        var closedHiddenWindow: MacWindow?
        do {
            try await runLightSession(.menuBarButton, token) {
                guard let macWindow = Window.get(byId: windowId) as? MacWindow else { return }
                let isHidden = windowIsHiddenFromView(macWindow)
                guard try await macWindow.macApp.pressCloseButton(windowId) else {
                    showWindowCloseError("This window could not be closed.", monitorScopeId: monitorScopeId)
                    return
                }
                if isHidden { closedHiddenWindow = macWindow }
            }
        } catch {
            showWindowCloseError("This window could not be closed. \(error.localizedDescription)", monitorScopeId: monitorScopeId)
            return
        }
        guard let macWindow = closedHiddenWindow else { return }
        // A window that is merely slow to close is never revealed; only one waiting on a sheet.
        for _ in 0..<windowMiddleClickSheetPollCount {
            do { try await Task.sleep(for: windowMiddleClickSheetPollInterval) } catch { return }
            guard Window.get(byId: windowId) === macWindow,
                  (try? await macWindow.macApp.containsAxWindow(windowId)) == true else { return }
            if (try? await macWindow.macApp.windowShowsSheet(windowId)) == true {
                reveal()
                return
            }
        }
    }
}

/// A toast, as nothing needs the user to act: the window stays as it was.
@MainActor
private func showWindowCloseError(_ body: String, monitorScopeId: String?) {
    WinMuxToastPanel.shared.show(.init(title: "Close Window", body: body, monitorScopeId: monitorScopeId))
}
