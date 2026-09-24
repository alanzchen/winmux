@testable import AppBundle
import AppKit
import Common
import XCTest

final class SavedWorkspaceLayoutMergeTest: XCTestCase {
    private func merge(
        _ previous: SavedLayoutContainer,
        live: SavedLayoutContainer,
        keep: Set<String> = [],
        flatten: Bool = false,
        oppositeOrientation: Bool = false,
    ) -> SavedLayoutContainer {
        let liveIds = Set(live.allSlots.map(\.id))
        return mergeSavedLayout(
            previous: SavedWorkspaceLayout(root: previous),
            live: SavedWorkspaceLayout(root: live),
            context: SavedLayoutMergeContext(
                liveTiled: liveIds,
                liveFloating: [],
                keep: { keep.contains($0.id) },
                normalization: SavedLayoutNormalization(flatten: flatten, oppositeOrientation: oppositeOrientation),
            ),
        ).root
    }

    func testAllWindowsLiveUsesLiveTree() {
        let previous = savedRoot(.tiles, .h, [savedSlot("a"), savedSlot("b")])
        let live = savedRoot(.tiles, .v, [savedSlot("b"), savedContainer(.tabGroup, .h, [savedSlot("a"), savedSlot("c")])])

        XCTAssertEqual(savedShape(merge(previous, live: live)), "v[b t[a c]]")
    }

    func testQuitAppSlotsKeepTheirPosition() {
        let previous = savedRoot(.tiles, .h, [savedSlot("a"), savedSlot("b"), savedSlot("c")])
        let live = savedRoot(.tiles, .h, [savedSlot("a"), savedSlot("c")])

        XCTAssertEqual(savedShape(merge(previous, live: live, keep: ["b"])), "h[a b c]")
    }

    func testDroppedSlotLeavesTheLayout() {
        let previous = savedRoot(.tiles, .h, [savedSlot("a"), savedSlot("b"), savedSlot("c")])
        let live = savedRoot(.tiles, .h, [savedSlot("a"), savedSlot("c")])

        XCTAssertEqual(savedShape(merge(previous, live: live)), "h[a c]")
    }

    func testTabGroupSurvivesPartialQuitWithFlattenAndOppositeOrientationOn() {
        // h[ editor, t[ terminal, browser ] ]: quitting the browser flattens the live tab group.
        let previous = savedRoot(.tiles, .h, [savedSlot("editor"), savedContainer(.tabGroup, .v, [savedSlot("terminal"), savedSlot("browser")])])
        let live = savedRoot(.tiles, .h, [savedSlot("editor"), savedSlot("terminal")])

        let merged = merge(previous, live: live, keep: ["browser"], flatten: true, oppositeOrientation: true)

        XCTAssertEqual(savedShape(merged), "h[editor t[terminal browser]]")
    }

    func testEverythingQuitKeepsWholeTemplate() {
        let previous = savedRoot(.tiles, .h, [savedSlot("a"), savedContainer(.tiles, .v, [savedSlot("b"), savedSlot("c")])])
        let live = savedRoot(.tiles, .h, [])

        XCTAssertEqual(savedShape(merge(previous, live: live, keep: ["a", "b", "c"], flatten: true)), "h[a v[b c]]")
    }

    func testSavedRootSurvivesAnEmptyDefaultRoot() {
        // After a restart the workspace's root is a fresh default one (h, tiles).
        let vertical = savedRoot(.tiles, .v, [savedSlot("a"), savedContainer(.tiles, .h, [savedSlot("b"), savedSlot("c")])])
        let tabs = savedRoot(.tabGroup, .h, [savedSlot("a"), savedSlot("b")])
        let emptyDefault = savedRoot(.tiles, .h, [])

        XCTAssertEqual(savedShape(merge(vertical, live: emptyDefault, keep: ["a", "b", "c"], flatten: true, oppositeOrientation: true)), "v[a h[b c]]")
        XCTAssertEqual(savedShape(merge(tabs, live: emptyDefault, keep: ["a", "b"], flatten: true, oppositeOrientation: true)), "t[a b]")
    }

    func testQuittingAppsOneByOneKeepsTheSavedRoot() {
        let saved = savedRoot(.tiles, .h, [savedSlot("a"), savedContainer(.tiles, .v, [savedSlot("b"), savedSlot("c")])])

        // a quits: the live tree flattens to v[b c].
        let afterFirst = merge(saved, live: savedRoot(.tiles, .v, [savedSlot("b"), savedSlot("c")]), keep: ["a"], flatten: true, oppositeOrientation: true)
        // b and c quit too: the live root is an empty v.
        let afterAll = merge(afterFirst, live: savedRoot(.tiles, .v, []), keep: ["a", "b", "c"], flatten: true, oppositeOrientation: true)

        XCTAssertEqual(savedShape(afterFirst), "h[a v[b c]]")
        XCTAssertEqual(savedShape(afterAll), "h[a v[b c]]")
    }

    func testNewWindowsFollowTheSavedTreeWhileSavedWindowsAreAway() {
        let saved = savedRoot(.tiles, .v, [savedSlot("a"), savedSlot("b")])

        XCTAssertEqual(savedShape(merge(saved, live: savedRoot(.tiles, .h, [savedSlot("new")]), keep: ["a", "b"])), "v[a b new]")
    }

    func testSlotCapNeverDropsProtectedSlot() {
        let waiting = (0 ..< savedWorkspaceMaxSlotsPerWorkspace).map { savedSlot("w\($0)") }
        let previous = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, waiting + [savedSlot("claimed"), savedSlot("live")]))
        let live = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("live")]))

        let merged = mergeSavedLayout(previous: previous, live: live, context: SavedLayoutMergeContext(
            liveTiled: ["live"], liveFloating: [], keep: { _ in true },
            normalization: SavedLayoutNormalization(flatten: false, oppositeOrientation: false),
            protectedSlotIds: ["claimed"],
        ))

        XCTAssertEqual(merged.allSlots.count, savedWorkspaceMaxSlotsPerWorkspace)
        XCTAssertTrue(merged.allSlots.contains { $0.id == "claimed" })
        XCTAssertTrue(merged.allSlots.contains { $0.id == "live" })
    }

    func testNestedSingleChildContainersPairWithTheirLiveCounterparts() {
        // Without flattening, v[h[a b w]] and its live v[h[a b]] share one slot set per level.
        let previous = savedRoot(.tiles, .h, [savedContainer(.tiles, .v, weight: 1, [savedContainer(.tiles, .h, weight: 1, [savedSlot("a"), savedSlot("b"), savedSlot("w")])])])
        let live = savedRoot(.tiles, .h, [savedContainer(.tiles, .v, weight: 7, [savedContainer(.tiles, .h, weight: 3, [savedSlot("a", weight: 2), savedSlot("b", weight: 5)])])])

        let merged = merge(previous, live: live, keep: ["w"])

        guard case .container(let outer) = merged.children[0], case .container(let inner) = outer.children[0] else { return XCTFail() }
        XCTAssertEqual(outer.weight, 7)
        XCTAssertEqual(inner.weight, 3)
        XCTAssertEqual(inner.children.map(\.weight), [2, 5, 1])
    }

    func testLiveWeightsAreCopiedWhenNothingWasRestructured() {
        let previous = savedRoot(.tiles, .h, [savedSlot("a", weight: 1), savedSlot("b", weight: 1), savedSlot("c", weight: 1)])
        let live = savedRoot(.tiles, .h, [savedSlot("a", weight: 3), savedSlot("c", weight: 5)])

        let merged = merge(previous, live: live, keep: ["b"])

        XCTAssertEqual(merged.children.map(\.weight), [3, 1, 5])
    }

    func testSavedMostRecentTabSurvivesWhileSiblingsAreStillWaiting() {
        let previous = savedRoot(.tiles, .h, [savedContainer(.tabGroup, .v, [savedSlot("c"), savedSlot("d", isMostRecent: true)])])
        let live = savedRoot(.tiles, .h, [savedContainer(.tabGroup, .v, [savedSlot("c", isMostRecent: true)])])

        let merged = merge(previous, live: live, keep: ["d"])

        guard case .container(let tabs) = merged.children[0] else { return XCTFail() }
        XCTAssertEqual(tabs.children.map(\.isMostRecentInParent), [false, true])
    }

    func testFlattenedContainerKeepsSavedChildWeights() {
        let previous = savedRoot(.tiles, .h, [savedSlot("a", weight: 1), savedContainer(.tiles, .v, weight: 2, [savedSlot("b", weight: 4), savedSlot("c", weight: 6)])])
        // c quit; the v container flattened, and b took the container's slot in the root.
        let live = savedRoot(.tiles, .h, [savedSlot("a", weight: 1.5), savedSlot("b", weight: 2.5)])

        let merged = merge(previous, live: live, keep: ["c"], flatten: true)

        XCTAssertEqual(savedShape(merged), "h[a v[b c]]")
        XCTAssertEqual(merged.children.map(\.weight), [1.5, 2.5])
        guard case .container(let nested) = merged.children[1] else { return XCTFail() }
        XCTAssertEqual(nested.children.map(\.weight), [4, 6])
    }

    func testUserRestructureReinsertsWaitingUnitAfterItsLeftSibling() {
        let previous = savedRoot(.tiles, .h, [savedSlot("a"), savedSlot("b"), savedSlot("c")])
        // b quit, then the user swapped a and c.
        let live = savedRoot(.tiles, .h, [savedSlot("c"), savedSlot("a")])

        XCTAssertEqual(savedShape(merge(previous, live: live, keep: ["b"])), "h[c a b]")
    }

    func testRestructureKeepsConsecutiveWaitingUnitsInOrder() {
        let previous = savedRoot(.tiles, .h, [savedSlot("a"), savedSlot("w1"), savedSlot("w2"), savedSlot("c")])
        let live = savedRoot(.tiles, .v, [savedSlot("a"), savedSlot("c")])

        XCTAssertEqual(savedShape(merge(previous, live: live, keep: ["w1", "w2"])), "v[a w1 w2 c]")
    }

    func testRestructureUsesRightAnchorWhenNoLeftSibling() {
        let previous = savedRoot(.tiles, .h, [savedSlot("w"), savedSlot("a"), savedSlot("b")])
        let live = savedRoot(.tiles, .h, [savedSlot("b"), savedContainer(.tiles, .v, [savedSlot("a"), savedSlot("n")])])

        XCTAssertEqual(savedShape(merge(previous, live: live, keep: ["w"])), "h[b v[w a n]]")
    }

    func testWaitingContainerMovesAsOneUnit() {
        let previous = savedRoot(.tiles, .h, [savedSlot("a"), savedContainer(.tabGroup, .v, [savedSlot("x"), savedSlot("y")]), savedSlot("b")])
        let live = savedRoot(.tiles, .v, [savedSlot("b"), savedSlot("a")])

        XCTAssertEqual(savedShape(merge(previous, live: live, keep: ["x", "y"])), "v[b a t[x y]]")
    }

    func testFloatingSlotsKeepOrderAndNewOnesAppend() {
        let previous = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, []), floating: [
            SavedWindowSlot(id: "f1", bundleId: "x"), SavedWindowSlot(id: "f2", bundleId: "x"),
        ])
        let live = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, []), floating: [
            SavedWindowSlot(id: "f3", bundleId: "x"), SavedWindowSlot(id: "f2", bundleId: "x", title: "updated"),
        ])

        let merged = mergeSavedLayout(previous: previous, live: live, context: SavedLayoutMergeContext(
            liveTiled: [], liveFloating: ["f2", "f3"], keep: { $0.id == "f1" },
            normalization: SavedLayoutNormalization(flatten: false, oppositeOrientation: false),
        ))

        XCTAssertEqual(merged.floating.map(\.id), ["f1", "f2", "f3"])
        XCTAssertEqual(merged.floating[1].title, "updated")
    }

    func testSlotThatBecameFloatingLeavesTheTilingTemplate() {
        let previous = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("a"), savedSlot("b")]))
        let live = SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [savedSlot("a")]), floating: [SavedWindowSlot(id: "b", bundleId: "x")])

        let merged = mergeSavedLayout(previous: previous, live: live, context: SavedLayoutMergeContext(
            liveTiled: ["a"], liveFloating: ["b"], keep: { _ in true },
            normalization: SavedLayoutNormalization(flatten: false, oppositeOrientation: false),
        ))

        XCTAssertEqual(savedShape(merged.root), "h[a]")
        XCTAssertEqual(merged.floating.map(\.id), ["b"])
    }

    func testSlotCapDropsWaitingSlotsFirst() {
        let waiting = (0 ..< savedWorkspaceMaxSlotsPerWorkspace).map { savedSlot("w\($0)") }
        let previous = savedRoot(.tiles, .h, waiting + [savedSlot("live")])
        let live = savedRoot(.tiles, .h, [savedSlot("live")])

        let merged = merge(previous, live: live, keep: Set(waiting.flatMap(\.allSlots).map(\.id)))

        XCTAssertEqual(merged.allSlots.count, savedWorkspaceMaxSlotsPerWorkspace)
        XCTAssertTrue(merged.allSlots.contains { $0.id == "live" })
    }

    func testNormalizationEmulatesFlattenAndOppositeOrientation() {
        let tree = savedRoot(.tiles, .h, [savedContainer(.tiles, .h, [savedSlot("a"), savedContainer(.tiles, .h, [savedSlot("b")]), savedContainer(.tiles, .v, [])])])

        let normalized = normalizeSavedLayout(tree, SavedLayoutNormalization(flatten: true, oppositeOrientation: true))

        XCTAssertEqual(savedShape(normalized), "h[a b]")
        XCTAssertEqual(savedShape(normalizeSavedLayout(
            savedRoot(.tiles, .h, [savedSlot("a"), savedContainer(.tiles, .h, [savedSlot("b"), savedSlot("c")])]),
            SavedLayoutNormalization(flatten: false, oppositeOrientation: true),
        )), "h[a v[b c]]")
    }

    func testTitleScoring() {
        XCTAssertEqual(savedTitleMatchScore("main.swift — App", "main.swift — App"), 3)
        XCTAssertEqual(savedTitleMatchScore("README.md — Docs", "README.md — Docs (edited)"), 2)
        XCTAssertEqual(savedTitleMatchScore("Project Alpha", "Project Alpha - Slack"), 1)
        XCTAssertEqual(savedTitleMatchScore("zsh", "bash"), 0)
        XCTAssertEqual(savedTitleMatchScore(nil, "anything"), 0)
    }
}
