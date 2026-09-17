@testable import AppBundle
import Foundation
import XCTest

@MainActor
final class WorkspaceSidebarDockBadgeTest: XCTestCase {
    func testConfigIsOptInAndRoundTrips() {
        XCTAssertFalse(WorkspaceSidebarConfig().showAppBadges)
        let text = updateSettingsScalarConfig(in: "[workspace-sidebar]\nmode = 'dock'\n",
                                             section: "workspace-sidebar", key: "show-app-badges", renderedValue: "true")
        let (config, errors) = parseConfig(text)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(config.workspaceSidebar.showAppBadges)
        XCTAssertEqual(config.workspaceSidebar.mode, .dock)
        let (_, invalid) = parseConfig("[workspace-sidebar]\nshow-app-badges = 'yes'\n")
        XCTAssertEqual(invalid.count, 1)
    }

    func testLabelsMatchAppPathsAndPreserveText() {
        var snapshot = WorkspaceSidebarDockBadgeSnapshot()
        snapshot.insert(url: URL(fileURLWithPath: "/Applications/Chat.app"), label: " 12 \n")
        snapshot.insert(url: URL(fileURLWithPath: "/Applications/Other/Chat.app"), label: "•")
        snapshot.insert(url: URL(fileURLWithPath: "/Applications/Empty.app"), label: " \n")
        snapshot.insert(url: URL(fileURLWithPath: "/Documents/Chat.txt"), label: "99")
        XCTAssertEqual(snapshot.label(forPath: "/Applications/Chat.app/"), "12")
        XCTAssertEqual(snapshot.label(forPath: "/Applications/Other/Chat.app"), "•")
        XCTAssertNil(snapshot.label(forPath: "/Applications/Empty.app"))
        XCTAssertNil(snapshot.label(forPath: "/Documents/Chat.txt"))
        XCTAssertNil(snapshot.label(forPath: nil))
    }

    func testPollingPublishesWithoutMouseInputAndDisableClearsImmediately() async throws {
        let snapshot = WorkspaceSidebarDockBadgeSnapshot(labelsByPath: ["/Applications/Chat.app": "3"])
        let model = WorkspaceSidebarDockBadgeModel(read: { snapshot })
        XCTAssertTrue(model.snapshot.labelsByPath.isEmpty)
        model.setEnabled(true)
        for _ in 0..<100 where model.snapshot != snapshot {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(model.snapshot, snapshot)
        model.setEnabled(false)
        XCTAssertTrue(model.snapshot.labelsByPath.isEmpty)
    }

    func testInFlightReadCannotRestoreBadgeAfterDisable() async throws {
        let model = WorkspaceSidebarDockBadgeModel(read: {
            // A native AX read can complete after its polling task is cancelled.
            try? await Task.sleep(for: .milliseconds(30))
            return .init(labelsByPath: ["/Applications/Chat.app": "3"])
        })
        model.setEnabled(true)
        await Task.yield()
        model.setEnabled(false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(model.snapshot.labelsByPath.isEmpty)
    }
}
