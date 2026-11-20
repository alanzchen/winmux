import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class SettingsScrollLayoutOwnershipTest: XCTestCase {
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    private func queueBarrier() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func verifyRestoration(beforeLayoutHeight: CGFloat, layOutEmptyDocument: Bool) async throws {
        let saved = SettingsScrollMemory.shared.positions
        defer { SettingsScrollMemory.shared.positions = saved }
        SettingsScrollMemory.shared.positions = [:]
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 520, height: 480))
        let document = Document(frame: CGRect(x: 0, y: 0, width: 520, height: 2000))
        let anchor = SettingsScrollAnchor(page: "test.dock")
        document.addSubview(anchor)
        scroll.documentView = document
        defer { anchor.detach() }
        await queueBarrier()
        anchor.layout()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.minY, 400)
        XCTAssertEqual(SettingsScrollMemory.shared.positions["test.dock"]?.y, 400, "Initial capture is proven separately")

        anchor.show("test.sidebar")
        anchor.layout()
        await queueBarrier()
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
        document.setFrameSize(CGSize(width: 520, height: beforeLayoutHeight))
        anchor.show("test.dock")
        if layOutEmptyDocument { anchor.layout() }
        // Drain queued work while the previous page's short geometry is still installed.
        // A dispatch callback cannot decide that the requested page has finished layout.
        await queueBarrier()
        document.setFrameSize(CGSize(width: 520, height: 2000))
        anchor.layout()
        XCTAssertNil(scroll.window)
        XCTAssertEqual(scroll.contentView.bounds.minY, 400, "Restore only against the new page's committed geometry")
        XCTAssertEqual(SettingsScrollMemory.shared.positions["test.dock"]?.y, 400)
    }

    func testQueuedCallbackCannotRestoreAgainstPreviousPagesShortGeometry() async throws {
        try await verifyRestoration(beforeLayoutHeight: 480, layOutEmptyDocument: false)
    }

    func testZeroGeometryDoesNotConsumePendingRestoration() async throws {
        try await verifyRestoration(beforeLayoutHeight: 0, layOutEmptyDocument: true)
    }

    func testShortIntermediateLayoutDoesNotConsumePendingRestoration() async throws {
        try await verifyRestoration(beforeLayoutHeight: 480, layOutEmptyDocument: true)
    }

    private func verifyUserTakeover(postsLiveScroll: Bool) {
        let saved = SettingsScrollMemory.shared.positions
        defer { SettingsScrollMemory.shared.positions = saved }
        SettingsScrollMemory.shared.positions = ["test.dock": CGPoint(x: 0, y: 800)]
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 520, height: 480))
        let document = Document(frame: CGRect(x: 0, y: 0, width: 520, height: 700))
        let anchor = SettingsScrollAnchor(page: "test.dock")
        document.addSubview(anchor)
        scroll.documentView = document
        defer { anchor.detach() }
        anchor.layout()
        XCTAssertLessThan(scroll.contentView.bounds.minY, 800)
        XCTAssertEqual(SettingsScrollMemory.shared.positions["test.dock"]?.y, 800)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 100))
        if postsLiveScroll { NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll) }
        XCTAssertEqual(SettingsScrollMemory.shared.positions["test.dock"]?.y, 100)
        document.setFrameSize(CGSize(width: 520, height: 2000))
        anchor.layout()
        XCTAssertEqual(scroll.contentView.bounds.minY, 100)
        XCTAssertEqual(SettingsScrollMemory.shared.positions["test.dock"]?.y, 100)
    }

    func testUserScrollSupersedesAnUnrepresentableSavedPosition() {
        verifyUserTakeover(postsLiveScroll: true)
    }

    func testNonLiveNavigationSupersedesAnUnrepresentableSavedPosition() {
        verifyUserTakeover(postsLiveScroll: false)
    }
}
