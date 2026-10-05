@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WinMuxToastTest: XCTestCase {
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
    /// activate WinMux, lets the mouse through, and sits below the sidebar. It goes on its own.
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
