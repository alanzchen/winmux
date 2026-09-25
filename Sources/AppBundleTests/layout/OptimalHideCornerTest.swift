@testable import AppBundle
import Common
import XCTest

@MainActor
final class OptimalHideCornerTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testSingleMonitorHidesInBottomRightCorner() {
        let monitor = hideCornerTestMonitor(id: 1, "Main", x: 0, y: 0, width: 1920, height: 1080, isMain: true)

        XCTAssertEqual(optimalHideCorner(for: monitor, among: [monitor]), .bottomRightCorner)
    }

    func testPortraitRightOfShorterLandscapeMovesLandscapeHidingToBottomLeft() {
        // The portrait monitor extends below the landscape monitor's bottom-right corner, so
        // windows parked there would show in the portrait monitor's bottom quarter.
        let landscape = hideCornerTestMonitor(id: 1, "Landscape", x: 0, y: 0, width: 2560, height: 1440, isMain: true)
        let portrait = hideCornerTestMonitor(id: 2, "Portrait", x: 2560, y: 0, width: 1080, height: 1920)
        let monitors: [Monitor] = [landscape, portrait]

        XCTAssertEqual(optimalHideCorner(for: landscape, among: monitors), .bottomLeftCorner)
        XCTAssertEqual(optimalHideCorner(for: portrait, among: monitors), .bottomRightCorner)
    }

    func testPortraitLeftOfShorterLandscapeKeepsBottomRightCorners() {
        let portrait = hideCornerTestMonitor(id: 2, "Portrait", x: 0, y: 0, width: 1080, height: 1920)
        let landscape = hideCornerTestMonitor(id: 1, "Landscape", x: 1080, y: 0, width: 2560, height: 1440, isMain: true)
        let monitors: [Monitor] = [landscape, portrait]

        XCTAssertEqual(optimalHideCorner(for: landscape, among: monitors), .bottomRightCorner)
        XCTAssertEqual(optimalHideCorner(for: portrait, among: monitors), .bottomRightCorner)
    }

    func testBottomAlignedPortraitRightOfLandscapeMovesLandscapeHidingToBottomLeft() {
        let landscape = hideCornerTestMonitor(id: 1, "Landscape", x: 0, y: 480, width: 2560, height: 1440, isMain: true)
        let portrait = hideCornerTestMonitor(id: 2, "Portrait", x: 2560, y: 0, width: 1080, height: 1920)
        let monitors: [Monitor] = [landscape, portrait]

        XCTAssertEqual(optimalHideCorner(for: landscape, among: monitors), .bottomLeftCorner)
        XCTAssertEqual(optimalHideCorner(for: portrait, among: monitors), .bottomRightCorner)
    }

    func testEqualSideBySideMonitorsHideAtTheirOuterCorners() {
        let left = hideCornerTestMonitor(id: 1, "Left", x: 0, y: 0, width: 1920, height: 1080, isMain: true)
        let right = hideCornerTestMonitor(id: 2, "Right", x: 1920, y: 0, width: 1920, height: 1080)
        let monitors: [Monitor] = [left, right]

        XCTAssertEqual(optimalHideCorner(for: left, among: monitors), .bottomLeftCorner)
        XCTAssertEqual(optimalHideCorner(for: right, among: monitors), .bottomRightCorner)
    }

    func testMiddleOfThreeSideBySideMonitorsKeepsBottomRightOnTie() {
        let left = hideCornerTestMonitor(id: 2, "Left", x: -1920, y: 0, width: 1920, height: 1080)
        let middle = hideCornerTestMonitor(id: 1, "Middle", x: 0, y: 0, width: 1920, height: 1080, isMain: true)
        let right = hideCornerTestMonitor(id: 3, "Right", x: 1920, y: 0, width: 1920, height: 1080)

        XCTAssertEqual(optimalHideCorner(for: middle, among: [left, middle, right]), .bottomRightCorner)
    }

    func testVerticallyStackedMonitorsKeepBottomRightCorners() {
        let top = hideCornerTestMonitor(id: 1, "Top", x: 0, y: 0, width: 1920, height: 1080, isMain: true)
        let bottom = hideCornerTestMonitor(id: 2, "Bottom", x: 0, y: 1080, width: 1920, height: 1080)
        let monitors: [Monitor] = [top, bottom]

        XCTAssertEqual(optimalHideCorner(for: top, among: monitors), .bottomRightCorner)
        XCTAssertEqual(optimalHideCorner(for: bottom, among: monitors), .bottomRightCorner)
    }

    func testMouseInteractionParksWindowsFullyOutsideTheChosenCorner() {
        let visibleRect = Rect(topLeftX: 0, topLeftY: 25, width: 2560, height: 1415)
        let window = Rect(topLeftX: 100, topLeftY: 200, width: 900, height: 700)

        XCTAssertEqual(
            mouseInteractionHiddenTopLeftCorner(for: window, monitorVisibleRect: visibleRect, corner: .bottomRightCorner),
            CGPoint(x: 2568, y: 1448),
        )
        // The window's right edge stays 8pt left of the monitor instead of spilling onto the
        // monitor to the right.
        XCTAssertEqual(
            mouseInteractionHiddenTopLeftCorner(for: window, monitorVisibleRect: visibleRect, corner: .bottomLeftCorner),
            CGPoint(x: -908, y: 1448),
        )
    }

    func testVisibleWorkspaceResolvesHideCornerFromItsMonitorArrangement() {
        let landscape = hideCornerTestMonitor(id: 1, "Landscape", x: 0, y: 0, width: 2560, height: 1440, isMain: true)
        let portrait = hideCornerTestMonitor(id: 2, "Portrait", x: 2560, y: 0, width: 1080, height: 1920)
        setMonitorsForTests([landscape, portrait])
        let landscapeWorkspace = Workspace.get(byName: "landscape")
        let portraitWorkspace = Workspace.get(byName: "portrait")
        XCTAssertTrue(landscape.setActiveWorkspace(landscapeWorkspace))
        XCTAssertTrue(portrait.setActiveWorkspace(portraitWorkspace))

        // Tab groups and fullscreen park hidden windows in this corner during layout.
        XCTAssertEqual(optimalHideCorner(for: landscapeWorkspace.workspaceMonitor), .bottomLeftCorner)
        XCTAssertEqual(optimalHideCorner(for: portraitWorkspace.workspaceMonitor), .bottomRightCorner)
    }
}

private func hideCornerTestMonitor(
    id: Int,
    _ name: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    isMain: Bool = false,
) -> TestMonitor {
    let rect = Rect(topLeftX: x, topLeftY: y, width: width, height: height)
    return TestMonitor(monitorAppKitNsScreenScreensId: id, name: name, rect: rect, visibleRect: rect, isMain: isMain)
}
