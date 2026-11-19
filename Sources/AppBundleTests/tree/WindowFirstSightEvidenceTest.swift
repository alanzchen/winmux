@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class WindowFirstSightEvidenceTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        WindowLifecycleLog.shared.reset()
        AuxiliaryWindowRegistry.shared.removeAll()
    }

    override func tearDown() async throws {
        WindowLifecycleLog.shared.reset()
        AuxiliaryWindowRegistry.shared.removeAll()
        config = defaultConfig
    }

    private func evidence(for opener: TestWindow, newWindowId: UInt32) -> AuxiliaryWindowOriginEvidence? {
        XCTAssertTrue(opener.focusWindow())
        let since = auxiliaryFocusSpan.since
        noteAppActivatedForAuxiliaryWindows(pid: opener.app.pid, at: since - 1)
        return captureAuxiliaryWindowOriginEvidence(newWindowId: newWindowId, pid: opener.app.pid, observedAt: since + 0.2,
            environment: auxiliaryTestEnvironment(order: [newWindowId, opener.windowId], pid: opener.app.pid, input: since + 0.1))
    }

    func testRegistrationPreservesRawFirstFrameAndOpenerBeforePlacement() async throws {
        let app = TestApp(pid: 991, bundleId: "com.example.messenger", name: "Messenger")
        let openerFrame = Rect(topLeftX: -1200.125, topLeftY: 35.375, width: 900.625, height: 700.875)
        let initialFrame = Rect(topLeftX: -1000.125, topLeftY: 150.375, width: 320.625, height: 240.875)
        let opener = TestWindow.new(id: 9911, parent: focus.workspace.rootTilingContainer, rect: openerFrame, app: app)
        let origin = evidence(for: opener, newWindowId: 9912)
        let captured = try XCTUnwrap(WindowFirstSightOpener(origin))
        let classification = await auxiliaryWindowPlacement(origin, type: .window, role: { nil })
        XCTAssertNil(classification, "Opener evidence also covers ordinary windows that match no auxiliary rule")
        let window = TestWindow.new(id: 9912, parent: focus.workspace.rootTilingContainer, rect: initialFrame, app: app)
        let laterFrame = Rect(topLeftX: 0, topLeftY: 0, width: 1600, height: 1000)
        opener.recordAuthoritativeActualRect(laterFrame)
        window.recordAuthoritativeActualRect(laterFrame)
        let focused = focus.windowOrNil
        WindowLifecycleLog.shared.reset()
        WindowLifecycleLog.shared.recordRegistration(of: window, type: .window, isAuxiliary: false,
            initialAxFrame: initialFrame, opener: captured)
        let event = try XCTUnwrap(WindowLifecycleLog.shared.events.last)
        XCTAssertEqual(event.kind, .registered)
        XCTAssertEqual(event.windowId, 9912)
        XCTAssertEqual(event.detail["initialAxFrame"], "(-1000.125, 150.375, 320.625, 240.875)")
        XCTAssertEqual(event.detail["openerWindowId"], "9911")
        XCTAssertEqual(event.detail["openerFrame"], "(-1200.125, 35.375, 900.625, 700.875)")
        XCTAssertEqual(event.detail["openerFrameSource"], "cachedActual")
        XCTAssertEqual(event.detail["auxiliary"], "false")
        XCTAssertEqual(debugSnapshotEvent(event)["detail"]?["initialAxFrame"], .string("(-1000.125, 150.375, 320.625, 240.875)"))
        XCTAssertEqual(debugSnapshotEvent(event)["detail"]?["openerWindowId"], .string("9911"))
        XCTAssertTrue(focus.windowOrNil === focused)
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: window))
        XCTAssertEqual([opener.axRectFetchCount, window.axRectFetchCount], [0, 0])
        XCTAssertEqual([opener.setAxFrameCount, window.setAxFrameCount], [0, 0])
    }

    func testMissingObservedFramesStayUnavailableEvenWithALayoutTarget() throws {
        let opener = TestWindow.new(id: 9921, parent: focus.workspace.rootTilingContainer)
        opener.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 100, topLeftY: 200, width: 900, height: 700)
        XCTAssertNotNil(opener.layoutPlacedRect)
        XCTAssertNil(opener.lastKnownActualRect)
        let captured = try XCTUnwrap(WindowFirstSightOpener(evidence(for: opener, newWindowId: 9922)))
        let window = TestWindow.new(id: 9922, parent: focus.workspace.rootTilingContainer)
        WindowLifecycleLog.shared.recordRegistration(of: window, type: .window, isAuxiliary: true,
            initialAxFrame: nil, opener: captured)
        let detail = try XCTUnwrap(WindowLifecycleLog.shared.events.last?.detail)
        XCTAssertEqual(detail["initialAxFrame"], "nil")
        XCTAssertEqual(detail["openerWindowId"], "9921")
        XCTAssertEqual(detail["openerFrame"], "nil")
        XCTAssertEqual(detail["openerFrameSource"], "unavailable")
        XCTAssertEqual(detail["auxiliary"], "true")
        XCTAssertEqual(opener.axRectFetchCount, 0)
    }

    func testRegistrationWithoutAnAttributedOpenerDoesNotInventOne() throws {
        let window = TestWindow.new(id: 9931, parent: focus.workspace.rootTilingContainer)
        let origin = try XCTUnwrap(evidence(for: window, newWindowId: 9932))
        let captured = try XCTUnwrap(WindowFirstSightOpener(origin))
        let other = TestWindow.new(id: 9933, parent: focus.workspace.rootTilingContainer)
        XCTAssertTrue(other.focusWindow())
        XCTAssertNil(WindowFirstSightOpener(origin), "Non-nil evidence is rejected after its focus span changes")
        XCTAssertEqual(captured.windowId, 9931, "The first-sight inference remains evidence even if later placement rejects it")
        XCTAssertNil(WindowFirstSightOpener(nil))
        WindowLifecycleLog.shared.recordRegistration(of: window, type: .dialog, isAuxiliary: false,
            initialAxFrame: nil, opener: nil)
        let detail = try XCTUnwrap(WindowLifecycleLog.shared.events.last?.detail)
        XCTAssertNil(detail["openerWindowId"])
        XCTAssertNil(detail["openerFrame"])
        XCTAssertNil(detail["openerFrameSource"])
    }
}
