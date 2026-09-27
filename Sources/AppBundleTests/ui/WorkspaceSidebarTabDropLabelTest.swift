@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarTabDropLabelTest: XCTestCase {
    private typealias Slot = WorkspaceSidebarTabDropLabelSlot

    /// The label's span on a tab from `minX` to `maxX`, as the highlight draws it.
    private func span(_ slot: Slot, minX: CGFloat, maxX: CGFloat, width: CGFloat) -> ClosedRange<CGFloat> {
        let midX = (minX + maxX) / 2
        let (start, end) = slot.half == .leading ? (minX, midX) : (midX, maxX)
        let x = slot.edge == .leading ? start + workspaceSidebarTabDropLabelInset : end - workspaceSidebarTabDropLabelInset - width
        return x...(x + width)
    }

    func testTheSplitLabelNeverSitsUnderTheDraggedTab() throws {
        let clearance = workspaceSidebarDragImageHalfWidth(.appIcon(size: 16)) + 4
        let width = workspaceSidebarTabDropLabelWidth(workspaceSidebarTabDropLabelText(.right))
        // Tabs from the narrowest sidebar to a wide one, held anywhere along them.
        for rowWidth in [200, 260, 300, 400] as [CGFloat] {
            for placement in [WorkspaceSidebarTabDropPlacement.left, .right] {
                let half = placement == .left ? 0...(rowWidth / 2) : (rowWidth / 2)...rowWidth
                for x in stride(from: half.lowerBound, through: half.upperBound, by: 2) {
                    let slot = try XCTUnwrap(workspaceSidebarTabDropLabelSlot(pointX: x, targetMinX: 0, targetMaxX: rowWidth,
                        placement: placement, labelWidth: width, clearance: clearance))
                    let label = span(slot, minX: 0, maxX: rowWidth, width: width)
                    let gap = max(0, label.lowerBound - x, x - label.upperBound)
                    XCTAssertGreaterThanOrEqual(gap, clearance, "\(placement) on a \(rowWidth)-point tab at \(x)")
                }
            }
        }
    }

    func testTheLabelStaysBesideItsHalfWhereItFitsAndHoldsItsPlace() {
        func slot(_ x: CGFloat, _ placement: WorkspaceSidebarTabDropPlacement?, previous: Slot? = nil) -> Slot? {
            workspaceSidebarTabDropLabelSlot(pointX: x, targetMinX: 0, targetMaxX: 300, placement: placement,
                labelWidth: 60, clearance: 18, previous: previous)
        }
        XCTAssertEqual(slot(40, .left), Slot(half: .leading, edge: .trailing),
            "Held near the left edge, Split left moves right, clear of the dragged tab")
        XCTAssertEqual(slot(130, .left), Slot(half: .leading, edge: .leading))
        XCTAssertEqual(slot(170, .right), Slot(half: .trailing, edge: .trailing))
        XCTAssertEqual(slot(280, .right), Slot(half: .trailing, edge: .leading))
        XCTAssertEqual(slot(100, .left, previous: Slot(half: .leading, edge: .leading)), Slot(half: .leading, edge: .leading),
            "It keeps its place while that stays clear")
        XCTAssertNil(slot(40, .stack))
        XCTAssertNil(slot(40, nil))
    }

    func testTheDropPreviewCarriesTheLabelSlot() {
        var preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 1, label: "", appName: "",
            targetWorkspaceName: "a", targetsNewWorkspace: false, isTabGroup: false, windowCount: 1)
        preview.targetPlacement = .left
        preview.targetLabelSlot = Slot(half: .leading, edge: .trailing)
        var other = preview
        other.targetLabelSlot = Slot(half: .trailing, edge: .leading)
        XCTAssertNotEqual(preview, other, "Moving the label redraws the highlight")
    }
}
