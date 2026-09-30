@testable import AppBundle
import XCTest

/// A custom sidebar drag's session: a release commits once, a cancel commits nothing, and late
/// callbacks of either are refused while the next real drag works.
@MainActor
final class WorkspaceSidebarDragSessionTest: XCTestCase {
    func testAReleaseIsConsumedOnce() {
        let sessions = WorkspaceSidebarDragSessions()
        XCTAssertTrue(sessions.acceptUpdate())
        let generation = sessions.active?.generation
        XCTAssertTrue(sessions.acceptUpdate(), "Updates of the same drag continue its session")
        XCTAssertEqual(sessions.active?.generation, generation)
        XCTAssertEqual(sessions.consumeRelease()?.generation, generation)
        XCTAssertNil(sessions.consumeRelease(), "The mouse-up cleanup after the gesture's own end finds nothing")
        XCTAssertNil(sessions.active)
    }

    func testTheNextDragAfterAReleaseStartsWithTheNextPress() {
        let sessions = WorkspaceSidebarDragSessions()
        sessions.noteLeftMouseDown()
        XCTAssertTrue(sessions.acceptUpdate())
        let first = sessions.consumeRelease()?.generation
        XCTAssertFalse(sessions.acceptUpdate(), "A late update of the released press, after its mouse-up")
        XCTAssertTrue(sessions.hasEndedThisPress)
        sessions.noteLeftMouseDown()
        XCTAssertFalse(sessions.hasEndedThisPress)
        XCTAssertTrue(sessions.acceptUpdate())
        XCTAssertNotEqual(sessions.active?.generation, first)
    }

    /// Escape mid-drag: the rest of that press is refused, before and after the button goes up,
    /// whichever comes first of the gesture's end and the mouse-up cleanup. The next press drags.
    func testACancelRefusesTheRestOfItsPressButNotTheNextOne() {
        let sessions = WorkspaceSidebarDragSessions()
        sessions.noteLeftMouseDown()
        XCTAssertTrue(sessions.acceptUpdate())
        XCTAssertTrue(sessions.cancel())
        XCTAssertFalse(sessions.cancel(), "Only an active drag cancels")
        XCTAssertFalse(sessions.acceptUpdate(), "A late update of the cancelled gesture")
        XCTAssertNil(sessions.consumeRelease(), "Its end commits nothing")
        XCTAssertFalse(sessions.acceptUpdate(), "Nor does an update after the mouse-up revive it")
        XCTAssertNil(sessions.consumeRelease())
        sessions.noteLeftMouseDown()
        XCTAssertTrue(sessions.acceptUpdate(), "The next drag")
        XCTAssertNotNil(sessions.active)
    }

    /// Escape during a pinned tile's drag, through the real update and release: the drag's feedback
    /// goes, its late update and release do nothing, and the next press drags again.
    func testEscapeCancelsAPinnedTileDragUntilTheNextPress() throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        let sessions = WorkspaceSidebarDragSessions.shared
        sessions.resetForTests()
        defer {
            sessions.resetForTests()
            WorkspaceSidebarTabDragState.shared.set(false)
            clearWorkspaceSidebarDropPreview()
            workspaceSidebarOrganizationStore = .init()
            config = defaultConfig
        }
        let tab = Workspace.get(byName: "pin")
        _ = TestWindow.new(id: 1, parent: tab.rootTilingContainer)
        try setWorkspaceSidebarTabFavorite(tab, true)

        sessions.noteLeftMouseDown()
        updateSidebarPinnedTabDrag(tab.name, pointer: .zero)
        XCTAssertTrue(WorkspaceSidebarTabDragState.shared.isDragging)
        XCTAssertTrue(workspaceSidebarHandleEscapeDuringDrag(keyCode: 53))
        XCTAssertFalse(WorkspaceSidebarTabDragState.shared.isDragging, "Its feedback goes at once")
        XCTAssertFalse(workspaceSidebarHandleEscapeDuringDrag(keyCode: 53), "Nothing left to cancel")
        updateSidebarPinnedTabDrag(tab.name, pointer: .zero)
        XCTAssertFalse(WorkspaceSidebarTabDragState.shared.isDragging, "A late update of the cancelled drag")
        finishSidebarPinnedTabDrag(tab.name, pointer: .zero)
        XCTAssertTrue(workspacePinnedTabs(in: tab.projectId).contains(tab), "Nothing was dropped")

        sessions.noteLeftMouseDown()
        updateSidebarPinnedTabDrag(tab.name, pointer: .zero)
        XCTAssertTrue(WorkspaceSidebarTabDragState.shared.isDragging, "The next press drags")
        finishSidebarPinnedTabDrag(tab.name, pointer: .zero)
        XCTAssertFalse(WorkspaceSidebarTabDragState.shared.isDragging)
    }
}
