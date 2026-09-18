import AppKit
@testable import AppBundle
import MASShortcut
import SwiftUI
import XCTest

@MainActor
final class ShortcutSettingsLayoutTest: XCTestCase {
    func testWindowCanResizeAndReopeningPreservesItsFrame() {
        let window = makeWindow(.shortcuts)
        defer { window.close() }
        let initialChromeHeight = (window.contentView?.frame.height ?? 0) - window.contentLayoutRect.height
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height - initialChromeHeight, shortcutSettingsMinimumSize.height,
                                    "The first layout must protect the usable height before any re-presentation")
        // Reproduce the fixed AppKit limits installed by older versions.
        window.styleMask.remove(.resizable)
        window.minSize = shortcutSettingsDefaultSize
        window.maxSize = shortcutSettingsDefaultSize
        configureShortcutSettingsWindow(window)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        let chromeHeight = (window.contentView?.frame.height ?? 0) - window.contentLayoutRect.height
        XCTAssertEqual(window.contentMinSize.width, shortcutSettingsMinimumSize.width)
        XCTAssertEqual(window.contentMinSize.height - chromeHeight, shortcutSettingsMinimumSize.height)
        XCTAssertGreaterThan(window.contentMaxSize.width, 1320)
        XCTAssertGreaterThan(window.contentMaxSize.height, 900)

        for size in [CGSize(width: 1320, height: 900), shortcutSettingsMinimumSize, shortcutSettingsDefaultSize] {
            resize(window, to: size)
            XCTAssertEqual(window.contentLayoutRect.size, size)
            let frame = window.frame
            configureShortcutSettingsWindow(window)
            XCTAssertEqual(window.frame, frame, "Reopening must preserve the user's size and position")
        }
    }

    func testPanesFillTheResizedWindowWithoutHorizontalScroll() throws {
        for pane: SettingsSidebarItem in [.shortcuts, .workspaces, .behavior, .appearance, .reference] {
            let window = makeWindow(pane)
            defer { window.close() }
            for size in [shortcutSettingsMinimumSize, CGSize(width: 1320, height: 900), shortcutSettingsDefaultSize] {
                resize(window, to: size)
                let content = try XCTUnwrap(window.contentView)
                XCTAssertEqual(window.contentLayoutRect.size, size)
                let scrollViews = descendants(content).compactMap { $0 as? NSScrollView }
                XCTAssertFalse(scrollViews.isEmpty)
                for scroll in scrollViews where !scroll.isHiddenOrHasHiddenAncestor {
                    guard let document = scroll.documentView else { continue }
                    XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 1,
                                             "\(pane): content must fit horizontally at \(size)")
                }
            }
        }
    }

    func testResizePreservesEditorDraftAndFirstResponder() throws {
        let window = makeWindow(.configuration)
        defer { window.close() }
        settle(window)
        let content = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        let draft = "# Unsaved resize regression draft\nstart-at-login = false\n"
        editor.string = draft
        editor.didChangeText()
        window.makeFirstResponder(editor)
        let initialWidth = editor.enclosingScrollView?.frame.width ?? 0
        resize(window, to: CGSize(width: 1200, height: 800))
        XCTAssertEqual(editor.string, draft)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertGreaterThan(editor.enclosingScrollView?.frame.width ?? 0, initialWidth)
        resize(window, to: shortcutSettingsMinimumSize)
        XCTAssertEqual(editor.string, draft)
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testDirectionalPadsReflowFromStackedToSideBySide() throws {
        let window = makeWindow(.shortcuts)
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        func padOrigins() throws -> (CGPoint, CGPoint) {
            let recorders = descendants(content).compactMap { $0 as? MASShortcutView }
            XCTAssertGreaterThanOrEqual(recorders.count, 8)
            guard recorders.count >= 8 else { throw XCTSkip("Native recorder views are missing") }
            return (recorders[0].convert(.zero, to: content), recorders[4].convert(.zero, to: content))
        }
        resize(window, to: shortcutSettingsMinimumSize)
        let originalRecorders = Array(descendants(content).compactMap { $0 as? MASShortcutView }.prefix(8))
        let narrow = try padOrigins()
        XCTAssertEqual(narrow.0.x, narrow.1.x, accuracy: 1)
        XCTAssertGreaterThan(abs(narrow.0.y - narrow.1.y), 100)
        resize(window, to: CGSize(width: 1320, height: 900))
        let wide = try padOrigins()
        XCTAssertEqual(wide.0.y, wide.1.y, accuracy: 1)
        XCTAssertGreaterThan(abs(wide.0.x - wide.1.x), 400)
        let resizedRecorders = Array(descendants(content).compactMap { $0 as? MASShortcutView }.prefix(8))
        XCTAssertEqual(resizedRecorders.map(ObjectIdentifier.init), originalRecorders.map(ObjectIdentifier.init),
                       "Changing layout must preserve the native shortcut recorders")
    }

    func testAppearanceResizeRetainsScrollPosition() throws {
        let window = makeWindow(.appearance)
        defer { window.close() }
        resize(window, to: shortcutSettingsMinimumSize)
        let content = try XCTUnwrap(window.contentView)
        let scroll = try XCTUnwrap(descendants(content).compactMap { $0 as? NSScrollView }.max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 240))
        scroll.reflectScrolledClipView(scroll.contentView)
        resize(window, to: CGSize(width: 900, height: 480))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 100, "Resizing must not reset the pane to the top")
    }

    func testWideNavigationColumnKeepsMinimumDetailWidth() throws {
        let window = makeWindow(.shortcuts)
        defer { window.close() }
        resize(window, to: CGSize(width: 1100, height: 620))
        let split = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSSplitView }.first)
        split.setPosition(280, ofDividerAt: 0)
        resize(window, to: shortcutSettingsMinimumSize)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(split.arrangedSubviews.last).frame.width, 460)
    }

    private func makeWindow(_ pane: SettingsSidebarItem) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: shortcutSettingsDefaultSize),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "WinMux Settings Resize Proof"
        window.contentView = NSHostingView(rootView: ShortcutSettingsView(model: .shared, selectedItem: pane)
            .background(Color(nsColor: .windowBackgroundColor)))
        configureShortcutSettingsWindow(window)
        settle(window)
        return window
    }

    private func resize(_ window: NSWindow, to usableSize: CGSize) {
        // NavigationSplitView installs a native toolbar. Its height belongs to the
        // content frame but not the usable layout rect; test the actual pane area.
        let toolbarHeight = (window.contentView?.frame.height ?? 0) - window.contentLayoutRect.height
        window.setContentSize(CGSize(width: usableSize.width, height: usableSize.height + toolbarHeight))
        settle(window)
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

}
