@testable import AppBundle
import AppKit
import Common
import SwiftUI
import XCTest

@MainActor
final class CarbonBranchAProbeTest: XCTestCase {
    private final class Probe {
        var view: WorkspaceSidebarView?
        var actions: [WorkspaceSidebarAction] = []
    }

    private final class FakeSwipeEvent: NSEvent {
        let precise: Bool
        let scrollPhase: NSEvent.Phase
        let scrollMomentum: NSEvent.Phase
        let dx: CGFloat
        let dy: CGFloat
        weak var hostWindow: NSWindow?
        let winPoint: NSPoint

        init(precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase = [], dx: CGFloat, dy: CGFloat = 0,
             window: NSWindow? = nil, point: NSPoint = NSPoint(x: 20, y: 20)) {
            self.precise = precise
            self.scrollPhase = phase
            self.scrollMomentum = momentum
            self.dx = dx
            self.dy = dy
            self.hostWindow = window
            self.winPoint = point
            super.init()
        }

        required init?(coder: NSCoder) { fatalError() }
        override var hasPreciseScrollingDeltas: Bool { precise }
        override var phase: NSEvent.Phase { scrollPhase }
        override var momentumPhase: NSEvent.Phase { scrollMomentum }
        override var scrollingDeltaX: CGFloat { dx }
        override var scrollingDeltaY: CGFloat { dy }
        override var window: NSWindow? { hostWindow }
        override var locationInWindow: NSPoint { winPoint }
    }

    func testNoSwipeFlickMomentumOrMouseWheelPathCanEverCreateAProject() async throws {
        setUpWorkspacesForTests()
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.targetMonitorScopeId = "carbon:ghost-probe"
        snapshot.projects = [
            .init(id: "p0", displayName: "One", colorHex: nil),
            .init(id: "p1", displayName: "Two", colorHex: nil),
        ]
        snapshot.activeProjectId = "p0"
        snapshot.configuration.collapsedWidth = 44
        snapshot.configuration.expandedWidth = 280
        snapshot.visibleWidth = 280

        let probe = Probe()
        var actions = WorkspaceSidebarActions()
        actions.send = { probe.actions.append($0) }
        var view = WorkspaceSidebarView(snapshot: snapshot, actions: actions, reduceMotionOverride: true)
        let mounted = expectation(description: "Mounted sidebar view")
        view.inspectMountedView = { installed in
            guard probe.view == nil else { return }
            probe.view = installed
            mounted.fulfill()
        }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 500)
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [mounted], timeout: 5)
        defer { probe.view = nil }
        let installed = try XCTUnwrap(probe.view)

        // 1. Extreme left-edge pull (old left-edge creation gesture, e.g. +500 pt rightward translation on p0) rubber-bands and creates nothing:
        installed.handleProjectSwipeChanged(horizontalTranslation: 500, verticalTranslation: 0, expansionProgress: 1)
        XCTAssertEqual(workspaceSidebarProjectPagerDragOffset(horizontalTranslation: 500, currentIndex: 0, projectCount: 2, pageWidth: 280), 52,
                       "Left edge clamps to rubber-band limit 52")
        installed.handleProjectSwipeEnded(horizontalTranslation: 500, verticalTranslation: 0, expansionProgress: 1)
        XCTAssertFalse(installed.showsProjectCreationPage)
        XCTAssertTrue(probe.actions.isEmpty, "Left-edge swipe never creates a project")

        // 2. Scroll-wheel & momentum coordinator filtering: non-precise mouse wheel and momentum flick events are ignored:
        let coordinator = WorkspaceSidebarProjectSwipeScrollCapture.Coordinator()
        let dummyWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
        let captureView = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        dummyWindow.contentView = captureView
        coordinator.view = captureView
        coordinator.isEnabled = true
        var endedCount = 0
        coordinator.onEnded = { _, _ in endedCount += 1 }
        _ = coordinator.handle(FakeSwipeEvent(precise: false, phase: .began, dx: -300, window: dummyWindow))
        _ = coordinator.handle(FakeSwipeEvent(precise: false, phase: .ended, dx: -300, window: dummyWindow))
        _ = coordinator.handle(FakeSwipeEvent(precise: true, phase: [], momentum: .began, dx: -300, window: dummyWindow))
        _ = coordinator.handle(FakeSwipeEvent(precise: true, phase: [], momentum: .ended, dx: -300, window: dummyWindow))
        XCTAssertEqual(endedCount, 0, "Mouse scroll wheel and trackpad momentum never trigger swipe end")

        // 3. Swiping past the last project (`p1`, index 1 -> ghost page index 2) lands on ghost page without creating,
        //    and a second hard flick past the ghost page (index 2, -600 pt) only rubber-bands:
        installed.projectSwipeStartProjectId = "p1"
        let serialToGhost = installed.projectSwipeNavigationSerial
        installed.completeProjectSwipeNavigation(to: nil, startProjectId: "p1", startedOnCreationPage: false, serial: serialToGhost)
        XCTAssertTrue(installed.showsProjectCreationPage)
        XCTAssertEqual(installed.projectPagerDisplayIndex, 2)
        XCTAssertTrue(probe.actions.isEmpty, "Landing on ghost page creates nothing")

        installed.handleProjectSwipeChanged(horizontalTranslation: -600, verticalTranslation: 0, expansionProgress: 1)
        XCTAssertEqual(workspaceSidebarProjectPagerDragOffset(horizontalTranslation: -600, currentIndex: 2, projectCount: 2, pageWidth: 280), -52,
                       "Right edge beyond ghost page clamps to rubber-band limit -52")
        installed.handleProjectSwipeEnded(horizontalTranslation: -600, verticalTranslation: 0, expansionProgress: 1)
        XCTAssertTrue(installed.showsProjectCreationPage)
        XCTAssertTrue(probe.actions.isEmpty, "Flicking past ghost page never creates a project")
    }
}
