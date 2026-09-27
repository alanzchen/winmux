@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarTabDropLabelTest: XCTestCase {
    func testTheSplitLabelSitsAtTheEndOfTheHalfAwayFromThePointer() {
        // A 300-point tab: its left half is 0–150, the right 150–300.
        func edge(_ x: CGFloat, _ placement: WorkspaceSidebarTabDropPlacement?, previous: HorizontalEdge? = nil) -> HorizontalEdge? {
            workspaceSidebarTabDropLabelEdge(pointX: x, targetMinX: 0, targetMaxX: 300, placement: placement, previous: previous)
        }
        XCTAssertEqual(edge(40, .left), .trailing, "Held near the left edge, Split left moves right, clear of the dragged tab")
        XCTAssertEqual(edge(130, .left), .leading)
        XCTAssertEqual(edge(170, .right), .trailing)
        XCTAssertEqual(edge(280, .right), .leading)
        XCTAssertEqual(edge(70, .left, previous: .leading), .leading, "Near the half's middle it stays put")
        XCTAssertEqual(edge(60, .left, previous: .leading), .trailing)
        XCTAssertNil(edge(40, .stack))
        XCTAssertNil(edge(40, nil))
    }

    func testTheDropPreviewCarriesTheLabelEdgeOnlyWithASide() {
        var preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 1, label: "", appName: "",
            targetWorkspaceName: "a", targetsNewWorkspace: false, isTabGroup: false, windowCount: 1)
        preview.targetPlacement = .left
        preview.targetLabelEdge = .trailing
        var other = preview
        other.targetLabelEdge = .leading
        XCTAssertNotEqual(preview, other, "Moving the label redraws the highlight")
    }
}
