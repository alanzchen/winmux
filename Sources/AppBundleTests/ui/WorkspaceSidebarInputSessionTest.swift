@testable import AppBundle
import XCTest

final class WorkspaceSidebarInputSessionTest: XCTestCase {
    func testOnlyIntentionalNonpersistentHoverStartsSearch() {
        for pinned in [false, true] {
            XCTAssertFalse(WorkspaceSidebarExpansionReason.passive.startsSearch(
                alwaysExpanded: pinned, isDragging: false, isTrackingMenu: false
            ))
        }
        XCTAssertTrue(WorkspaceSidebarExpansionReason.hover.startsSearch(
            alwaysExpanded: false, isDragging: false, isTrackingMenu: false
        ))
        XCTAssertFalse(WorkspaceSidebarExpansionReason.hover.startsSearch(
            alwaysExpanded: true, isDragging: false, isTrackingMenu: false
        ))
        XCTAssertFalse(WorkspaceSidebarExpansionReason.hover.startsSearch(
            alwaysExpanded: false, isDragging: true, isTrackingMenu: false
        ))
        XCTAssertFalse(WorkspaceSidebarExpansionReason.hover.startsSearch(
            alwaysExpanded: false, isDragging: false, isTrackingMenu: true
        ))
    }

    @MainActor
    func testMovingInputBetweenPanelsCancelsPreviousOwner() {
        let session = WorkspaceSidebarInputSession()
        let first = InputOwner()
        let second = InputOwner()
        session.acquire(first)
        XCTAssertTrue(session.handle(.text("first")))
        session.acquire(second)
        XCTAssertEqual(first.cancellations, 1)
        XCTAssertTrue(session.handle(.text("second")))
        XCTAssertEqual(first.text, "first")
        XCTAssertEqual(second.text, "second")
        // A disappearing old editor must not release its replacement.
        session.release(first)
        XCTAssertTrue(session.owner === second)
        session.release(second)
        XCTAssertFalse(session.handle(.text("outside")))
    }

    @MainActor
    func testReacquiringSamePanelPreservesBufferedInput() {
        let session = WorkspaceSidebarInputSession()
        let owner = InputOwner()
        session.acquire(owner)
        XCTAssertTrue(session.handle(.text("a")))
        session.acquire(owner)
        XCTAssertTrue(session.handle(.text("b")))
        XCTAssertEqual(owner.cancellations, 0)
        XCTAssertEqual(owner.text, "ab")
    }

    @MainActor
    func testInactiveAndUnhandledEventsPassThrough() {
        let session = WorkspaceSidebarInputSession()
        let owner = InputOwner()
        session.acquire(owner)
        XCTAssertFalse(session.handle(.ignored))
        owner.canCaptureSidebarInput = false
        XCTAssertFalse(session.handle(.text("outside")))
        XCTAssertFalse(session.handle(.commit))
        XCTAssertEqual(owner.text, "")
        owner.canCaptureSidebarInput = true
        owner.handlesKeys = false
        XCTAssertFalse(session.handle(.text("unhandled")))
    }

    @MainActor
    func testDestroyedPanelCannotRetainKeyboardCapture() {
        let session = WorkspaceSidebarInputSession()
        var owner: InputOwner? = InputOwner()
        session.acquire(owner!)
        owner = nil
        XCTAssertNil(session.owner)
        XCTAssertFalse(session.handle(.text("outside")))
    }

    func testOutsideClickCancelsEvenWhenPointerExitDoesNot() {
        XCTAssertTrue(shouldCancelWorkspaceSidebarInputForPointer(
            isInside: false, isMouseDown: true, cancelsOnPointerExit: false, pointerHasEntered: false
        ))
        XCTAssertFalse(shouldCancelWorkspaceSidebarInputForPointer(
            isInside: false, isMouseDown: false, cancelsOnPointerExit: false, pointerHasEntered: true
        ))
        XCTAssertTrue(shouldCancelWorkspaceSidebarInputForPointer(
            isInside: false, isMouseDown: false, cancelsOnPointerExit: true, pointerHasEntered: true
        ))
        XCTAssertFalse(shouldCancelWorkspaceSidebarInputForPointer(
            isInside: true, isMouseDown: true, cancelsOnPointerExit: true, pointerHasEntered: true
        ))
    }
}

@MainActor
private final class InputOwner: WorkspaceSidebarInputOwner {
    var canCaptureSidebarInput = true
    var handlesKeys = true
    var cancellations = 0
    var text = ""

    func cancelInlineTextEditing() {
        cancellations += 1
        canCaptureSidebarInput = false
    }

    func handleInlineTextEditingKey(_ key: WorkspaceSidebarInlineTextKey) -> Bool {
        guard handlesKeys else { return false }
        if case .text(let string) = key { text += string }
        return true
    }
}
