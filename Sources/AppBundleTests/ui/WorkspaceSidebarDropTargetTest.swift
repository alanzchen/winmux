import AppKit
@testable import AppBundle
import XCTest

final class WorkspaceSidebarDropTargetTest: XCTestCase {
    func testClippingAndLatestOverlappingTargetMatchVisibleDock() {
        let surface = CGRect(x: 0, y: 100, width: 64, height: 200)
        let targets: [WorkspaceSidebarDropTargetFrame] = [
            .init(kind: .workspace("offscreen"), frame: CGRect(x: 7, y: 10, width: 50, height: 40)),
            .init(kind: .workspace("1"), frame: CGRect(x: 7, y: 80, width: 50, height: 100)),
            .init(kind: .workspace("2"), frame: CGRect(x: 7, y: 160, width: 50, height: 180)),
        ]
        let hit = workspaceSidebarLocalDropTarget(at: CGPoint(x: 30, y: 170), targets: targets, surface: surface)
        XCTAssertEqual(hit?.kind, .workspace("2"))
        XCTAssertEqual(hit?.frame, CGRect(x: 7, y: 160, width: 50, height: 140))
        XCTAssertNil(workspaceSidebarLocalDropTarget(at: CGPoint(x: 30, y: 90), targets: targets, surface: surface))
        XCTAssertNil(workspaceSidebarLocalDropTarget(at: CGPoint(x: 65, y: 170), targets: targets, surface: surface))
    }

    func testAsymmetricHitSlopAndChangedGeometryAreUsedImmediately() {
        let surface = CGRect(x: 0, y: 0, width: 64, height: 300)
        var targets = [WorkspaceSidebarDropTargetFrame(kind: .workspace("1"),
            frame: CGRect(x: 7, y: 100, width: 50, height: 40))]
        let slop = NSEdgeInsets(top: 10, left: 7, bottom: 2, right: 0)
        XCTAssertNotNil(workspaceSidebarLocalDropTarget(at: CGPoint(x: 3, y: 95), targets: targets, surface: surface, hitSlop: slop))
        XCTAssertNil(workspaceSidebarLocalDropTarget(at: CGPoint(x: 30, y: 145), targets: targets, surface: surface, hitSlop: slop))
        targets[0] = .init(kind: .workspace("1"), frame: targets[0].frame.offsetBy(dx: 0, dy: 50))
        XCTAssertNil(workspaceSidebarLocalDropTarget(at: CGPoint(x: 30, y: 110), targets: targets, surface: surface))
        XCTAssertNotNil(workspaceSidebarLocalDropTarget(at: CGPoint(x: 30, y: 160), targets: targets, surface: surface))
        XCTAssertNil(workspaceSidebarLocalDropTarget(at: CGPoint(x: 30, y: 160), targets: [], surface: surface))
    }
}
