import AppKit
@testable import AppBundle
import XCTest

final class WorkspaceSidebarGhostKeyTest: XCTestCase {
    @MainActor
    func testEveryKeyOutsideTheGhostDisarmsAndPassesThrough() {
        let session = WorkspaceSidebarInputSession()
        let owner = GhostInputOwner()
        session.acquire(owner)
        for key: WorkspaceSidebarInlineTextKey in [.commit, .cancel, .text("a"), .ignored] {
            XCTAssertFalse(session.handle(key))
        }
        XCTAssertEqual(owner.ignoredKeys, 4)
    }

    func testGhostCommandsKeepTheCurrentApplicationActive() {
        XCTAssertFalse(WorkspaceSidebarInputPurpose.projectCreation.activatesPanel)
        XCTAssertTrue(WorkspaceSidebarInputPurpose.textEditing.activatesPanel)
    }

    func testOnlyUnmodifiedNavigationKeysActOnGhost() throws {
        for code: CGKeyCode in [36, 76, 53] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
            event.flags = []
            XCTAssertEqual(workspaceSidebarProjectCreationAction(for: workspaceSidebarInlineTextKey(from: event, purpose: .projectCreation)), code == 53 ? .leave : .create)
            for flags: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift, [.maskCommand, .maskShift]] {
                event.flags = flags
                XCTAssertNil(workspaceSidebarProjectCreationAction(for: workspaceSidebarInlineTextKey(from: event, purpose: .projectCreation)),
                    "A modified navigation key must pass through")
                XCTAssertEqual(workspaceSidebarProjectCreationAction(for: workspaceSidebarInlineTextKey(from: event, purpose: .textEditing)),
                    code == 53 ? .leave : .create, "Text editing retains its existing modified-key behavior")
            }
        }
    }
}

@MainActor
private final class GhostInputOwner: WorkspaceSidebarInputOwner {
    let canCaptureSidebarInput = false
    let sidebarInputPurpose = WorkspaceSidebarInputPurpose.projectCreation
    var ignoredKeys = 0

    func cancelInlineTextEditing() {}
    func handleInlineTextEditingKey(_ key: WorkspaceSidebarInlineTextKey) -> Bool {
        if case .ignored = key { ignoredKeys += 1 }
        return false
    }
}
