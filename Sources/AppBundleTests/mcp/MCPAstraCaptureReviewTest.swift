@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class MCPAstraCaptureReviewTest: XCTestCase {
    private var oldCapture: (any DebugScreenCapturing)!
    private var fake: FakeDebugScreenCapture!
    private var clock: FakeRecorderClock!
    private var recorder: DebugRecorder!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        setMonitorsForTests([TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Synthetic",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1600, height: 1000),
            visibleRect: Rect(topLeftX: 0, topLeftY: 25, width: 1600, height: 975), isMain: true)])
        oldCapture = debugScreenCapture
        fake = FakeDebugScreenCapture()
        debugScreenCapture = fake
        clock = FakeRecorderClock()
        recorder = DebugRecorder()
        recorder.environment = clock.environment
    }

    override func tearDown() async throws {
        _ = recorder.stop(reason: "review ended")
        clock.holdsSleeps = false
        clock.release()
        clock.timers = []
        WindowLifecycleLog.shared.reset()
        debugScreenCapture = oldCapture
        setMonitorsForTests(nil)
        config = defaultConfig
    }

    func testDiscardReleasesFinishedRecordingPayloadBeforeExpiryTimer() async throws {
        for _ in 0..<3 {
            _ = try recorder.start(DebugRecordingSettings(durationSeconds: 1), refusesImages: false).get()
            await recorder.waitForRecording()
            weak var retired = recorder.recording
            XCTAssertEqual(retired?.frameCount, 1)
            _ = try recorder.stop(reason: "discard now").get()
            XCTAssertNil(recorder.recording)
            XCTAssertEqual(retired?.frameCount ?? 0, 0, "The ten-minute timer must not retain discarded screen images")
        }
    }

    func testLastPageFetchReleasesFinishedPayloadBeforeExpiryTimer() async throws {
        _ = try recorder.start(DebugRecordingSettings(durationSeconds: 1), refusesImages: false).get()
        await recorder.waitForRecording()
        weak var retired = recorder.recording
        _ = try recorder.fetch(after: nil, id: nil, refusesImages: false).get()
        XCTAssertNil(recorder.recording)
        XCTAssertEqual(retired?.frameCount ?? 0, 0, "Fetching the last page must release the retained original image data")
    }

    func testSnapshotThatFinishesAfterDeadlineDoesNotStartAScreenCapture() async throws {
        recorder.environment.snapshot = { [clock] _ in
            clock!.now = clock!.now.addingTimeInterval(2)
            return .object(["schema": .string("fixture")])
        }
        _ = try recorder.start(DebugRecordingSettings(durationSeconds: 1), refusesImages: false).get()
        await recorder.waitForRecording()
        XCTAssertEqual(fake.captures.count, 0, "A slow snapshot finished after endsAt; no new screen capture may start")
    }

    func testEventPayloadsCountAgainstTheRecordingMemoryLimit() async throws {
        recorder.byteLimit = 1024
        clock.holdsSleeps = true
        _ = try recorder.start(DebugRecordingSettings(durationSeconds: 1, frames: false), refusesImages: false).get()
        for _ in 0..<100 where clock.heldSleeps == 0 { await Task.yield() }
        XCTAssertEqual(clock.heldSleeps, 1)
        WindowLifecycleLog.shared.record(.moved, windowId: 1, ["to": String(repeating: "w", count: 8192)])
        let pendingBytes = recorder.recording?.pendingEvents.reduce(0) { $0 + debugSnapshotEvent($1).encoded().count } ?? 0
        XCTAssertLessThanOrEqual(pendingBytes, recorder.byteLimit, "An event's workspace name is not bounded to the 200-byte estimate")
        clock.holdsSleeps = false
        clock.release()
        await recorder.waitForRecording()
    }

    func testOneLargeFrameDoesNotBypassFetchPageImageByteLimit() async throws {
        fake.bytesPerImage = DebugRecorder.pageImageBytes + 1
        _ = try recorder.start(DebugRecordingSettings(durationSeconds: 1), refusesImages: false).get()
        await recorder.waitForRecording()
        let page = try recorder.fetch(after: nil, id: nil, refusesImages: false).get()
        let bytes = (page["content"]?.array ?? []).reduce(0) { total, item in
            total + (item["data"]?.string.flatMap { Data(base64Encoded: $0)?.count } ?? 0)
        }
        XCTAssertLessThanOrEqual(bytes, DebugRecorder.pageImageBytes)
    }

    /// Exercises the same configuration-application seam reached by reload-config from the MCP winmux tool.
    /// Do not run reload-config itself here: its unrelated start-at-login cleanup touches the host's LaunchAgents.
    func testRemoteConfigurationApplyNeverRequestsScreenCapturePermission() async {
        let server = MCPServer()
        defer { server.stop() }
        fake.permission = false
        server.apply(MCPServerConfig(enabled: true, port: 0))
        await MCPRequestRestrictions.$refusesScreenImages.withValue(true) {
            server.apply(MCPServerConfig(enabled: true, port: 0, debugScreenshots: true))
        }
        XCTAssertEqual(fake.requests, 0, "Remote reload of an edited config must not produce a permission prompt")
    }
}
