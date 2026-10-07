@testable import AppBundle
import AppKit
import Common
import SwiftUI
import XCTest

@MainActor
final class WinMuxToastTest: XCTestCase {
    override func tearDown() {
        MessageModel.shared.message = nil
        MessageModel.shared.detailMessage = nil
        WinMuxToastPanel.shared.dismiss()
        super.tearDown()
    }

    func testConfigFailureWithoutASidebarRequiresExplicitDetailsAndKeepsFullDiagnostic() async throws {
        let saved = config
        defer { config = saved }
        config.workspaceSidebar.enabled = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-invalid-\(UUID()).toml")
        let invalid = "config-version = 2\n[workspace-sidebar\n" + String(repeating: "# neutral diagnostic fixture\n", count: 80)
        try invalid.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var args = ReloadConfigCmdArgs(rawArgs: [])
        args.dryRun = true
        var output = ""
        let key = NSApp.keyWindow
        let request = MessageModel.shared.detailRequestId
        let succeeded = try await reloadConfig(args: args, forceConfigUrl: url, stdout: &output)
        XCTAssertFalse(succeeded)
        for _ in 0..<4 { await Task.yield() }
        let panel = WinMuxToastPanel.shared
        let diagnostic = try XCTUnwrap(panel.model.shown?.notice.details)
        XCTAssertEqual(diagnostic.body, output)
        XCTAssertEqual(diagnostic.description, "WinMux Config Error")
        XCTAssertTrue(panel.isVisible)
        XCTAssertNil(MessageModel.shared.detailMessage)
        XCTAssertEqual(MessageModel.shared.detailRequestId, request)
        XCTAssertTrue(NSApp.keyWindow === key, "Reporting a startup/config error never asks for key")
        panel.detailsPanel.button.performClick(nil)
        XCTAssertEqual(MessageModel.shared.detailMessage, diagnostic)
        XCTAssertEqual(MessageModel.shared.detailRequestId, request + 1)

        showWorkspaceSidebarError("A different operation failed")
        XCTAssertEqual(MessageModel.shared.detailMessage, diagnostic, "A later failure cannot rewrite opened details")
        panel.dismiss()
        args.noGui = true
        output = ""
        let quietResult = try await reloadConfig(args: args, forceConfigUrl: url, stdout: &output)
        XCTAssertFalse(quietResult)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNil(panel.model.shown, "--no-gui still only returns its diagnostic")
        XCTAssertEqual(output, diagnostic.body)
    }

    func testLongAndSimilarErrorsKeepTheirOwnOriginalDetailsAcrossReplacementAndDismissal() throws {
        var time = 0.0
        var opened: [WinMuxToastNotice] = []
        let panel = WinMuxToastPanel(model: .init(clock: { time }, announce: { _ in }), openDetails: { opened.append($0) })
        defer { panel.dismiss() }
        let full = String(repeating: "A complete diagnostic line\n", count: 500)
        let first = WinMuxToastNotice(title: "Config Error", body: full,
            details: Message(title: "Original title", description: "Original context", body: full))
        panel.show(first)
        XCTAssertLessThan(panel.frame.height, 200, "The preview is bounded, not the diagnostic")
        let originalAction = try XCTUnwrap(panel.detailsPanel.button.invoke)
        panel.show(first)
        XCTAssertEqual(panel.model.shown?.count, 2)
        let other = WinMuxToastNotice(title: first.title, body: full,
            details: Message(title: "Different title", description: "Different context", body: full + "last line"))
        panel.show(other)
        XCTAssertEqual(panel.model.shown?.count, 1, "Identical previews don't coalesce different diagnostics")
        originalAction()
        XCTAssertEqual(opened, [first], "The button's action captures the diagnostic, never reads the latest error")
        XCTAssertEqual(panel.model.shown?.notice, other, "A stale action does not dismiss a newer toast")
        time += WinMuxToastModel.lifetime
        panel.expire()
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.detailsPanel.isVisible)
        originalAction()
        XCTAssertEqual(opened.last?.diagnostic.body, full, "Already captured details survive expiration")
    }

    func testOnlyDetailsReceivesInputAndFocusedControlKeepsItsErrorUntilActivation() throws {
        var time = 0.0
        var opened: [WinMuxToastNotice] = []
        let panel = WinMuxToastPanel(model: .init(clock: { time }, announce: { _ in }), openDetails: { opened.append($0) })
        defer { panel.dismiss() }
        let first = WinMuxToastNotice(title: "First", body: "First error")
        let second = WinMuxToastNotice(title: "Second", body: "Second error")
        panel.show(first)
        let button = panel.detailsPanel.button
        XCTAssertTrue(panel.ignoresMouseEvents, "The body passes through at the window boundary")
        XCTAssertFalse(panel.detailsPanel.ignoresMouseEvents, "The control has its own receiving window")
        XCTAssertTrue(panel.frame.contains(panel.detailsPanel.frame))
        XCTAssertEqual(panel.detailsPanel.contentView, button)
        XCTAssertTrue(button.hitTest(CGPoint(x: 20, y: 12)) === button)
        XCTAssertNil(button.hitTest(CGPoint(x: -5, y: 12)))
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), "Details")
        XCTAssertTrue(button.acceptsFirstResponder)
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        button.setAccessibilityFocused(true)
        XCTAssertTrue(panel.model.isInteracting)
        time = 20
        panel.expire()
        panel.show(second)
        XCTAssertEqual(panel.model.shown?.notice, first, "An active control is never replaced underneath its user")
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(opened, [first])
        XCTAssertEqual(panel.model.shown?.notice, second, "The deferred error gets its own full lifetime")
        button.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.detailsPanel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49)))
        XCTAssertEqual(opened, [first, second], "The same native control supports keyboard activation")
        XCTAssertNil(panel.model.shown)
    }

    /// A toast shows its notice for a few seconds and is read out each time. The same notice again
    /// while it shows is counted on the one toast and stays up longer; another takes its place.
    func testAToastShowsForAFewSecondsCountsRepeatsAndIsReadOut() {
        var time = 100.0
        var announced: [String] = []
        let model = WinMuxToastModel(clock: { time }, announce: { announced.append($0) })
        let notice = WinMuxToastNotice(title: "Switch Tab", body: "Safari couldn't confirm switching to this tab.", monitorScopeId: "monitor:0,0")
        model.show(notice)
        XCTAssertEqual(model.shown, .init(notice: notice, count: 1, until: 100 + WinMuxToastModel.lifetime))
        XCTAssertTrue((3...5).contains(WinMuxToastModel.lifetime))
        time += 2
        model.show(notice)
        XCTAssertEqual(model.shown, .init(notice: notice, count: 2, until: 102 + WinMuxToastModel.lifetime), "One toast, counted, up longer")
        time += WinMuxToastModel.lifetime - 0.1
        model.expire()
        XCTAssertNotNil(model.shown)
        time += 0.1
        model.expire()
        XCTAssertNil(model.shown, "Gone on its own")

        model.show(notice)
        let other = WinMuxToastNotice(title: "Close Tab", body: "Safari didn't respond. Try again.")
        model.show(other)
        XCTAssertEqual(model.shown?.notice, other, "Another takes its place")
        XCTAssertEqual(model.shown?.count, 1)
        time += WinMuxToastModel.lifetime + 1
        model.show(notice)
        XCTAssertEqual(model.shown?.count, 1, "Once it's gone, the same notice starts over")
        XCTAssertEqual(announced, [notice.body, notice.body, notice.body, other.body, notice.body], "Each is read out")
    }

    /// The toast's window never takes focus or clicks: it can't become key or main, doesn't
    /// activate WinMux, and lets the mouse through. Its layer is below the sidebar's when that stays
    /// on top. It goes on its own.
    func testTheToastNeverTakesFocusOrClicksAndGoesOnItsOwn() {
        var time = 0.0
        let panel = WinMuxToastPanel(model: WinMuxToastModel(clock: { time }, announce: { _ in }))
        defer { panel.orderOut(nil) }
        let keyBefore = NSApp.keyWindow
        let activeBefore = NSApp.isActive
        panel.show(.init(title: "Close Window", body: "This window could not be closed."))
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(NSApp.keyWindow === keyBefore)
        XCTAssertEqual(NSApp.isActive, activeBefore)
        XCTAssertEqual(panel.level, WinMuxPanelLayer.overlay.level)
        XCTAssertLessThan(panel.level.rawValue, WinMuxPanelLayer.workspaceSidebar.level.rawValue)
        XCTAssertGreaterThan(panel.frame.width, 0)
        XCTAssertGreaterThan(panel.frame.height, 0)
        time += WinMuxToastModel.lifetime
        panel.expire()
        XCTAssertFalse(panel.isVisible)
    }

    /// The toast sits near the bottom of the display, beside the sidebar on the side with room,
    /// or centred with no sidebar, and never off the display.
    func testTheToastSitsBesideTheSidebarNearTheBottomOfItsDisplay() {
        let screen = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let size = CGSize(width: 300, height: 52)
        XCTAssertEqual(winMuxToastFrame(size: size, beside: CGRect(x: 0, y: 40, width: 260, height: 860), in: screen),
            CGRect(x: 272, y: 64, width: 300, height: 52), "Right of a left sidebar")
        XCTAssertEqual(winMuxToastFrame(size: size, beside: CGRect(x: 1180, y: 40, width: 260, height: 860), in: screen),
            CGRect(x: 868, y: 64, width: 300, height: 52), "Left of a right sidebar")
        XCTAssertEqual(winMuxToastFrame(size: size, beside: nil, in: screen), CGRect(x: 570, y: 64, width: 300, height: 52), "Centred")
        let wide = CGSize(width: 1500, height: 52)
        XCTAssertEqual(winMuxToastFrame(size: wide, beside: nil, in: screen).minX, 12, "Kept on the display")
    }

    /// A browser tab action that didn't go as asked is told in the toast, beside the sidebar that
    /// asked, and not in the message window.
    func testABrowserTabActionNoticeIsAToastNotTheMessageWindow() {
        let message = MessageModel.shared.message
        defer {
            MessageModel.shared.message = message
            WinMuxToastPanel.shared.dismiss()
        }
        MessageModel.shared.message = nil
        showBrowserTabActionNotice(.init(kind: .select, message: "Safari couldn't confirm switching to this tab.",
            monitorScopeId: "monitor:0,0"))
        XCTAssertEqual(WinMuxToastPanel.shared.model.shown?.notice, .init(title: "Switch Tab",
            body: "Safari couldn't confirm switching to this tab.", monitorScopeId: "monitor:0,0"))
        showBrowserTabActionNotice(.init(kind: .close, message: "Safari didn't respond. Try again."))
        XCTAssertEqual(WinMuxToastPanel.shared.model.shown?.notice, .init(title: "Close Tab", body: "Safari didn't respond. Try again."))
        XCTAssertNil(MessageModel.shared.message)
    }
}
