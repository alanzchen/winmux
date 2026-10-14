@testable import AppBundle
import AppKit
import Common
import XCTest

/// What the window server and the system would say when a window appears: `order` front to back, every
/// window there `pid`'s, the last press at `input`, and whether the app is active.
@MainActor
func auxiliaryTestEnvironment(order: [UInt32]?, pid: Int32, input: TimeInterval?, active: Bool = true)
    -> AuxiliaryWindowOriginEnvironment
{
    AuxiliaryWindowOriginEnvironment(
        orderedWindows: { order.map { $0.map { AuxiliaryOrderedWindow(id: $0, pid: pid, layer: 0) } } },
        lastUserInput: { input },
        appIsActive: { _ in active })
}

/// A window of `app` whose context points to `opener`, placed as registration places it: the app active
/// since before, WinMux's focus on `opener` (focused here if it isn't) before a press just now, and the
/// new window in front with `opener` right below it. Its evidence is read when it's first seen, and
/// decided once its role is known.
@MainActor
func openAuxiliaryTestWindow(_ id: UInt32, app: TestApp, role: AuxiliaryWindowRole = .mailCompose, from opener: Window,
                             title: String, rect: Rect? = nil) async throws -> TestWindow {
    if focus.windowOrNil !== opener { XCTAssertTrue(opener.focusWindow()) }
    let since = auxiliaryFocusSpan.since
    noteAppActivatedForAuxiliaryWindows(pid: app.pid, at: since - 1)
    let evidence = captureAuxiliaryWindowOriginEvidence(newWindowId: id, pid: app.pid, observedAt: since + 0.2,
        environment: auxiliaryTestEnvironment(order: [id, opener.windowId], pid: app.pid, input: since + 0.1))
    let found = await auxiliaryWindowPlacement(evidence, type: role == .dialog ? .dialog : .window, role: { role })
    let placement = try XCTUnwrap(found, "With the context pointing to \(opener.windowId), it's placed under it")
    let window = TestWindow.new(id: id, parent: placement.workspace, rect: rect, app: app, title: title)
    recordAuxiliaryWindow(window, placement: placement, initialRect: rect)
    _ = try await restoreOrDetectNewWindow(window, isRegularWindow: false)
    return window
}
