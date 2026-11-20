@testable import AppBundle
import AppKit
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarProjectGhostPageTest: XCTestCase {
    private final class Probe {
        var view: WorkspaceSidebarView?
        var actions: [WorkspaceSidebarAction] = []
    }

    func testMountedGhostPageRequiresConfirmationAndEscapeCancelsTheReturnTransition() async throws {
        setUpWorkspacesForTests()
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.targetMonitorScopeId = "test:ghost-page-no-panel"
        snapshot.projects = [.init(id: "first", displayName: "First", colorHex: nil), .init(id: "last", displayName: "Last", colorHex: nil)]
        snapshot.activeProjectId = "first"
        snapshot.configuration.showAppIcons = true
        snapshot.configuration.collapsedWidth = 44
        snapshot.configuration.expandedWidth = 280
        snapshot.visibleWidth = snapshot.configuration.expandedWidth
        let probe = Probe()
        var actions = WorkspaceSidebarActions()
        actions.send = { probe.actions.append($0) }
        var view = WorkspaceSidebarView(snapshot: snapshot, actions: actions, reduceMotionOverride: true)
        let mounted = expectation(description: "Installed sidebar state")
        view.inspectMountedView = { installed in
            guard probe.view == nil else { return }
            probe.view = installed
            mounted.fulfill()
        }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 500)
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [mounted], timeout: 5)
        defer { probe.view = nil }
        let installed = try XCTUnwrap(probe.view)
        XCTAssertNil(host.window, "No native window is opened or ordered")
        XCTAssertNil(installed.currentPanel(), "The test must never acquire a real sidebar's input session")

        XCTAssertTrue(installed.usesProjectColumns)
        installed.browseMode = .split(otherProjectId: "last")
        installed.completeProjectSwipeNavigation(to: nil, startProjectId: nil, startedOnCreationPage: false, serial: installed.projectSwipeNavigationSerial)
        XCTAssertTrue(installed.showsProjectCreationPage)
        XCTAssertEqual(installed.projectPagerDisplayIndex, 2)
        XCTAssertFalse(installed.browseMode.isSplit)
        XCTAssertTrue(probe.actions.isEmpty, "Landing creates nothing")
        for key: WorkspaceSidebarInlineTextKey in [.text("a"), .moveUp, .moveDown, .deleteBackward, .deleteForward, .ignored] {
            XCTAssertFalse(installed.handleProjectCreationKey(key), "The ghost page must pass through keys it does not use")
            XCTAssertFalse(installed.showsProjectCreationPage, "Continuing keyboard work disarms project creation immediately")
            installed.showProjectCreationPage()
        }
        XCTAssertTrue(probe.actions.isEmpty)
        XCTAssertTrue(installed.showsProjectCreationPage)
        let preview = ImageRenderer(content: installed.projectCreationPage.frame(width: 300, height: 240)
            .padding(12).background(Color.white).environment(\.colorScheme, .light))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(preview.cgImage))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-page-\(UUID().uuidString)/ghost-page.png")
        addTeardownBlock { try FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)

        installed.projectSwipeTranslation = 300
        installed.leaveProjectCreationPage()
        installed.completeProjectSwipeNavigation(to: "last", startProjectId: nil, startedOnCreationPage: true, serial: installed.projectSwipeNavigationSerial)
        XCTAssertFalse(installed.showsProjectCreationPage)
        XCTAssertEqual(installed.projectSwipeTranslation, 0)
        XCTAssertEqual(installed.projectPagerDisplayIndex, 0)
        XCTAssertTrue(probe.actions.isEmpty, "An escaped transition cannot select or create later")
        let staleSerial = installed.projectSwipeNavigationSerial
        installed.handleProjectSwipeChanged(horizontalTranslation: -80, verticalTranslation: 0, expansionProgress: 0)
        installed.completeProjectSwipeNavigation(to: nil, startProjectId: installed.projectSwipeStartProjectId,
            startedOnCreationPage: false, serial: staleSerial)
        XCTAssertFalse(installed.showsProjectCreationPage, "A newer gesture invalidates the earlier completion")
        XCTAssertTrue(probe.actions.isEmpty)
        installed.resetProjectSwipeWithoutAnimation()

        installed.browseMode = .split(otherProjectId: "last")
        installed.showProjectCreationPage()
        XCTAssertFalse(installed.browseMode.isSplit, "The ghost page must be visible when landing from split browse")
        XCTAssertTrue(installed.dockMagnificationBlockers.contains(.editing))
        XCTAssertTrue(installed.usesProjectColumns, "The ghost must retain the panel's supported Dock geometry")
        XCTAssertTrue(installed.shouldHandleProjectSwipe(horizontalTranslation: 80, verticalTranslation: 0, expansionProgress: 1))
        installed.resetTransientSidebarState()
        XCTAssertTrue(installed.showsProjectCreationPage, "Returning to compact width must retain the selected page")
        installed.activateProjectCreationPage()
        installed.activateProjectCreationPage()
        XCTAssertFalse(installed.showsProjectCreationPage)
        XCTAssertEqual(probe.actions.count, 1)
        guard case .createProject = probe.actions.first else { return XCTFail("Only explicit activation creates") }
    }
}
