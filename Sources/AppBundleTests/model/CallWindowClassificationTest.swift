@testable import AppBundle
import AppKit
import XCTest

/// How WinMux's existing classifier treats call-app windows, FaceTime's among them, from synthetic
/// AX records. These are NOT captures: what FaceTime's call, picture-in-picture or prompt windows
/// actually report on macOS 27 was not observed for this change. The cases pin the policy: AX role
/// and subrole decide; an elevated window level, missing minimize or zoom buttons, or a window level
/// that couldn't be read are each too weak alone to take a main window out of tiling, and FaceTime
/// gets no rule of its own.
final class CallWindowClassificationTest: XCTestCase {
    /// FaceTime isn't a known bundle: it goes through the general rules.
    private let faceTime: KnownBundleId? = KnownBundleId(rawValue: "com.apple.FaceTime")
    private let app = CallSyntheticAxElement(role: kAXApplicationRole)
    private let enabled = CallSyntheticAxElement(role: kAXButtonRole).put(Ax.enabledAttr, true)

    private func callWindow(_ id: UInt32, subrole: String = kAXStandardWindowSubrole, buttons: [String] = ["close", "minimize", "zoom", "fullscreen"]) -> CallSyntheticAxElement {
        let window = CallSyntheticAxElement(id: id, role: kAXWindowRole).put(Ax.parentAttr, app).put(Ax.subroleAttr, subrole)
        if buttons.contains("close") { window.put(Ax.closeButtonAttr, enabled) }
        if buttons.contains("minimize") { window.put(Ax.minimizeButtonAttr, enabled) }
        if buttons.contains("zoom") { window.put(Ax.zoomButtonAttr, enabled) }
        if buttons.contains("fullscreen") { window.put(Ax.fullscreenButtonAttr, enabled) }
        return window
    }

    func testTheMainCallWindowStaysAnOrdinaryTileableWindowUnderAmbiguousSignals() {
        XCTAssertNil(faceTime, "No FaceTime rule: a bundle-wide exclusion would take its main window out of splits")
        let main = callWindow(1)
        XCTAssertEqual(main.getWindowType(axApp: app, faceTime, .regular, .normalWindow), .window)
        // A window level above normal alone isn't proof of an overlay.
        XCTAssertEqual(main.getWindowType(axApp: app, faceTime, .regular, .alwaysOnTopWindow), .window)
        XCTAssertEqual(main.getWindowType(axApp: app, faceTime, .regular, .unknown(windowLevel: 1000)), .window)
        // The window server's level couldn't be joined to the AX window: not held back for that.
        XCTAssertEqual(main.getWindowType(axApp: app, faceTime, .regular, nil), .window)
        // Missing minimize and zoom buttons aren't proof of a dialog while it can go full screen.
        let fewButtons = callWindow(2, buttons: ["close", "fullscreen"])
        XCTAssertEqual(fewButtons.getWindowType(axApp: app, faceTime, .regular, .normalWindow), .window)
    }

    func testConfirmedOverlaysAndPromptsFloatAndAttachedSheetsAreNeverWindows() {
        // A floating panel, as picture-in-picture might be: floats, never tiled into the split.
        let panel = callWindow(3, subrole: kAXFloatingWindowSubrole, buttons: ["close"])
        XCTAssertEqual(panel.getWindowType(axApp: app, faceTime, .regular, .normalWindow), .dialog)
        XCTAssertEqual(panel.getWindowType(axApp: app, faceTime, .regular, .alwaysOnTopWindow), .dialog)
        // A standalone prompt: a dialog subrole, or a window that can't go full screen.
        XCTAssertEqual(callWindow(4, subrole: kAXDialogSubrole, buttons: ["close"])
            .getWindowType(axApp: app, faceTime, .regular, .normalWindow), .dialog)
        XCTAssertNotEqual(callWindow(5, subrole: kAXSystemDialogSubrole, buttons: [])
            .getWindowType(axApp: app, faceTime, .regular, .normalWindow), .window)
        XCTAssertEqual(callWindow(6, buttons: ["close"]).getWindowType(axApp: app, faceTime, .regular, .normalWindow), .dialog)
        // A prompt attached to the call window as a sheet isn't a window of its own.
        let main = callWindow(7)
        let sheet = CallSyntheticAxElement(id: 7, role: kAXSheetRole).put(Ax.parentAttr, main)
        XCTAssertEqual(sheet.getWindowType(axApp: app, faceTime, .regular, .normalWindow), .popup)
        XCTAssertTrue(sheet.isAttachedTransientHeuristic())
        // Unfocused chrome with no buttons and no standard subrole isn't a window either.
        let chrome = CallSyntheticAxElement(id: 8, role: kAXWindowRole).put(Ax.parentAttr, app)
            .put(Ax.subroleAttr, kAXUnknownSubrole).put(Ax.isFocused, false).put(Ax.isMainAttr, false)
        XCTAssertEqual(chrome.getWindowType(axApp: app, faceTime, .regular, .normalWindow), .popup)
    }
}

final class CallSyntheticAxElement: AxUiElementMock {
    private let id: UInt32?
    private var attributes: [String: Any] = [:]

    init(id: UInt32? = nil, role: String? = nil) {
        self.id = id
        attributes[Ax.roleAttr.key] = role
    }

    @discardableResult
    func put<Attr: ReadableAttr>(_ attr: Attr, _ value: Attr.T) -> Self {
        attributes[attr.key] = value
        return self
    }

    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T? { attributes[attr.key] as? Attr.T }
    func containingWindowId() -> CGWindowID? { id }
}
