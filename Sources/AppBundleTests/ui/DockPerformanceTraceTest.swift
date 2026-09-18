import AppKit
@testable import AppBundle
import Combine
import XCTest

@MainActor
final class DockPerformanceTraceTest: XCTestCase {
    private func record(_ trace: DockPerformanceTrace, at time: Double, rate: Double = 60,
                        cost: Double = 0.001, changed: Bool = true, slack: Double? = nil) {
        let target = time + (slack ?? 1 / rate)
        trace.record(arrival: time, displayTimestamp: target - 1 / rate,
            targetTimestamp: target, duration: 1 / rate, publishEnd: time + cost, changed: changed)
    }

    func testHealthy60And120HzFramesAreNotReportedAsStutters() {
        for rate in [60.0, 120.0] {
            let trace = DockPerformanceTrace()
            for step in 0..<240 { record(trace, at: Double(step) / rate, rate: rate) }
            XCTAssertEqual(trace.summary.changedPoses, 240)
            XCTAssertEqual(trace.summary.lateCallbacks, 0)
            XCTAssertEqual(trace.summary.expensivePublications, 0)
            XCTAssertEqual(trace.summary.missedDeadlines, 0)
        }
    }

    func testDelayedDeliveryAndSlowPublicationAreKeptSeparately() {
        let trace = DockPerformanceTrace()
        for step in 0..<3 { record(trace, at: Double(step) / 60) }
        trace.beforeWaiting(at: 0.085)
        record(trace, at: 0.09, cost: 0.0001)
        record(trace, at: 0.09 + 1 / 60, cost: 0.02)
        XCTAssertEqual(trace.summary.lateCallbacks, 1)
        XCTAssertEqual(trace.summary.expensivePublications, 1)
        XCTAssertEqual(trace.summary.missedDeadlines, 1)
        XCTAssertEqual(trace.snapshot(panel: 1, maximumFPS: 60, scale: 2).suspectedFrames.count, 2)
        XCTAssertEqual(trace.snapshot(panel: 1, maximumFPS: 60, scale: 2).suspectedFrames.first?.previousBeforeWaiting, 0.085)
    }

    func testIdleWakeAndRefreshRateTransitionsResetCadence() {
        let trace = DockPerformanceTrace()
        for step in 0..<3 { record(trace, at: Double(step) / 60) }
        trace.resetBaseline()
        record(trace, at: 90)
        record(trace, at: 90 + 1 / 60)
        for step in 1...20 { record(trace, at: 91 + Double(step) / 120, rate: 120) }
        XCTAssertEqual(trace.summary.lateCallbacks, 0)
        XCTAssertEqual(trace.summary.missedDeadlines, 0)
    }

    func testUnchangedPosesDoNotReportMissedPresentations() {
        let trace = DockPerformanceTrace()
        for step in 0..<4 { record(trace, at: Double(step) / 60) }
        record(trace, at: 1, cost: 0.020, changed: false, slack: -0.010)
        XCTAssertEqual(trace.summary.frames, 5)
        XCTAssertEqual(trace.summary.lateCallbacks, 0)
        XCTAssertEqual(trace.summary.missedDeadlines, 0)
        XCTAssertEqual(trace.summary.expensivePublications, 0)
    }

    func testWakeDropsOldGeometryAndLegacyCallbacksDoNotInventDeadlines() {
        let trace = DockPerformanceTrace()
        trace.geometry(surfaceY: 10, icons: 5)
        trace.geometry(surfaceY: 20)
        trace.hoverRecheck()
        trace.columnOrigin(delta: 0.5)
        trace.input(at: 1)
        trace.resetBaseline(preservingInput: true) // Initial display-rate setup keeps the entry packet.
        record(trace, at: 1.01)
        let first = trace.snapshot(panel: 1, maximumFPS: 60, scale: 2).recentFrames[0]
        XCTAssertEqual(first.inputEvents, 1)
        XCTAssertEqual(first.geometryUpdates, 0)
        XCTAssertEqual(first.hoverRechecks, 0)
        XCTAssertEqual(first.surfaceOriginDelta, 0)
        XCTAssertEqual(first.columnOriginUpdates, 0)
        trace.beforeWaiting(at: 1.014)
        record(trace, at: 1.030, cost: 0.02)
        XCTAssertEqual(trace.snapshot(panel: 1, maximumFPS: 60, scale: 2).recentFrames.last?.previousBeforeWaiting, 1.014,
            "Cadence warm-up still has useful preceding-turn context")
        trace.resetBaseline()
        for step in 0..<5 {
            trace.record(arrival: Double(step), displayTimestamp: Double(step), targetTimestamp: 0,
                duration: 1 / 120, publishEnd: Double(step) + 0.001, changed: true, nativeDisplayTiming: false)
        }
        XCTAssertEqual(trace.summary.lateCallbacks, 0)
        XCTAssertEqual(trace.summary.missedDeadlines, 0)
    }

    func testRejectedOutsideHoverDoesNotAccumulateIdleInput() {
        let view = WorkspaceSidebarDockDisplayLinkView()
        let trace = DockPerformanceTrace()
        view.performanceTrace = trace
        for _ in 0..<100 { view.receive(nil) }
        view.receive(CGPoint(x: 20, y: 100))
        view.advance(to: 1)
        XCTAssertEqual(trace.snapshot(panel: 1, maximumFPS: 60, scale: 2).recentFrames[0].inputEvents, 1)
    }

    func testInputBurstsAndDeferredWorkRemainNumericAndBounded() {
        let trace = DockPerformanceTrace()
        for step in 0..<1_000 { trace.input(at: Double(step) / 10_000) }
        trace.geometry(surfaceY: 10, icons: 9)
        trace.geometry(surfaceY: 8)
        trace.hoverRecheck()
        record(trace, at: 0.1)
        trace.beforeWaiting(at: 0.104)
        trace.beforeWaiting(at: 0.4) // An idle loop must not overwrite the turn's first end.
        let sample = trace.snapshot(panel: 1, maximumFPS: 120, scale: 2).recentFrames[0]
        XCTAssertEqual(sample.inputEvents, 1_000)
        XCTAssertEqual(sample.latestInput, 0.0999)
        XCTAssertEqual(sample.geometryUpdates, 2)
        XCTAssertEqual(sample.iconCount, 9)
        XCTAssertEqual(sample.surfaceOriginDelta, -2)
        XCTAssertEqual(sample.hoverRechecks, 1)
        XCTAssertEqual(sample.beforeWaiting, 0.104)
        XCTAssertEqual(trace.summary.maximumRunLoopTail, 0.003, accuracy: 0.000001)
        for step in 1...2_000 { record(trace, at: Double(step) / 20) }
        let report = trace.snapshot(panel: 1, maximumFPS: 120, scale: 2)
        XCTAssertEqual(report.recentFrames.count, 512)
        XCTAssertEqual(report.suspectedFrames.count, 128)
        XCTAssertEqual(report.recentFrames.last?.sequence, 2_001)
        XCTAssertEqual(report.overwrittenRecentFrames, 1_489)
        XCTAssertGreaterThan(report.overwrittenSuspectedFrames, 0)
    }

    func testPausedInputRetainsRejectionAndRecoveryWithoutRequiringAFrame() throws {
        let trace = DockPerformanceTrace()
        func input(_ time: Double, blocked: Bool, running: Bool) {
            trace.pointerEvent(.nativePointer, at: time, nativeTimestamp: time - 0.001,
                blockers: blocked ? WorkspaceSidebarDockPointerBlockers.menu.rawValue : 0,
                inside: true, accepted: !blocked, targetChanged: !blocked,
                running: running, hasTarget: !blocked, passthrough: false)
        }
        record(trace, at: 1)
        trace.resetBaseline()
        input(2, blocked: true, running: false)
        input(3, blocked: false, running: false)
        for index in 0..<1_000 { input(4 + Double(index) / 120, blocked: false, running: true) }
        let report = try XCTUnwrap(trace.snapshot(panel: 1, maximumFPS: 60, scale: 2).input)
        XCTAssertEqual(trace.summary.frames, 1, "Input capture must survive a silent display link")
        XCTAssertEqual(report.nativeEvents, 1_002)
        XCTAssertEqual(report.acceptedNativeEvents, 1_001)
        XCTAssertEqual(report.recentEvents.count, 256)
        XCTAssertEqual(report.overwrittenRecentEvents, 746)
        XCTAssertEqual(report.transitions.map(\.receivedAt), [2, 3, 4], "High-rate movement must not evict the recovery")
        XCTAssertEqual(report.transitions[0].blockers, WorkspaceSidebarDockPointerBlockers.menu.rawValue)
        XCTAssertEqual(report.transitions[1].accepted, true)
        XCTAssertEqual(report.transitions[1].lastCallbackAt, 1, "Baseline resets must not hide how long callbacks stopped")
        XCTAssertEqual(report.transitions[1].callbackSequence, 1)
        XCTAssertEqual(report.transitions[1].nativeTimestamp!, 2.999, accuracy: 0.000001)
    }

    func testInputLifecycleRetentionIsBoundedAndOldPanelReportsStillDecode() throws {
        let trace = DockPerformanceTrace()
        for index in 0..<1_000 {
            trace.pointerEvent(.reset, at: Double(index), nativeTimestamp: nil, blockers: 0,
                inside: nil, accepted: nil, targetChanged: false, running: false, hasTarget: false, passthrough: true)
        }
        let report = trace.snapshot(panel: 1, maximumFPS: 60, scale: 2)
        XCTAssertEqual(report.input?.transitions.count, 128)
        XCTAssertEqual(report.input?.overwrittenTransitions, 872)
        let retired = trace.snapshot(panel: 1, maximumFPS: 60, scale: 2, retired: true)
        XCTAssertEqual(retired.input?.recentEvents.count, 32)
        XCTAssertEqual(retired.input?.transitions.count, 16)
        XCTAssertEqual(retired.input?.overwrittenRecentEvents, 968)
        let data = try JSONEncoder().encode(report)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "input")
        let decoded = try JSONDecoder().decode(DockPerformancePanelReport.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.input)
    }

    func testFullFrameAndInputBuffersFitTheEightPanelReportBudget() throws {
        let trace = DockPerformanceTrace()
        for index in 0..<1_000 {
            let time = 123_456.123456789 + Double(index) / 30
            trace.input(at: time - 0.005)
            trace.geometry(surfaceY: Double(index), icons: 50)
            record(trace, at: time)
            trace.beforeWaiting(at: time + 0.004)
            trace.pointerEvent(.nativePointer, at: time + 0.005, nativeTimestamp: time,
                blockers: index % 2, inside: true, accepted: index.isMultiple(of: 2),
                targetChanged: true, running: true, hasTarget: true, passthrough: false)
        }
        let current = (0..<8).map { trace.snapshot(panel: $0, maximumFPS: 120, scale: 2) }
        let retired = (8..<16).map { trace.snapshot(panel: $0, maximumFPS: 120, scale: 2, retired: true) }
        let data = try JSONEncoder().encode(current + retired)
        XCTAssertLessThan(data.count, 5 * 1_024 * 1_024 - 100_000, "Leave space for report metadata and refresh spans")
    }

    func testDisabledRecorderDoesNotCollectOrPublishFrameUpdatesAndStopSaves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DockPerformanceRecorder(outputDirectory: directory)
        let view = WorkspaceSidebarDockDisplayLinkView()
        XCTAssertNil(view.performanceTrace)
        recorder.start()
        recorder.register(view)
        XCTAssertNotNil(view.performanceTrace)
        var notifications = 0
        let subscription = recorder.objectWillChange.sink { notifications += 1 }
        view.receive(CGPoint(x: 20, y: 100))
        for frame in 1...10 { view.advance(to: Double(frame) / 60) }
        XCTAssertEqual(notifications, 0, "Frame capture must not invalidate the Settings/Dock UI")
        subscription.cancel()
        recorder.stop()
        recorder.start()
        XCTAssertFalse(recorder.isRecording, "Starting during an export must not queue another capture")
        XCTAssertNil(view.performanceTrace)
        XCTAssertFalse(recorder.isRecording)
        let deadline = Date().addingTimeInterval(5)
        while recorder.isSaving && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let file = try XCTUnwrap(recorder.lastReport)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
        let panels = try XCTUnwrap(json["panels"] as? [[String: Any]])
        XCTAssertEqual(panels.count, 1)
        XCTAssertEqual((panels[0]["summary"] as? [String: Any])?["frames"] as? Int, 10)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testAutomaticStopRetiresRecreatedPanelsWithoutExhaustingActiveSlots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DockPerformanceRecorder(outputDirectory: directory, captureDuration: .milliseconds(30))
        recorder.start()
        for _ in 0..<12 {
            let view = WorkspaceSidebarDockDisplayLinkView()
            recorder.register(view)
            XCTAssertNotNil(view.performanceTrace)
            view.receive(CGPoint(x: 20, y: 100))
            view.advance(to: 1)
        }
        let deadline = Date().addingTimeInterval(5)
        while (recorder.isRecording || recorder.isSaving) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(recorder.isRecording)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DockPerformanceReport.self,
            from: Data(contentsOf: XCTUnwrap(recorder.lastReport)))
        XCTAssertEqual(report.omittedPanels, 0)
        XCTAssertEqual(report.panels.count, 8, "Detach at stop also retires the last panel, keeping a bounded archive")
        XCTAssertEqual(report.overwrittenRetiredPanels, 4)
        XCTAssertTrue(report.panels.allSatisfy(\.retired))
        XCTAssertEqual(report.panels.last?.summary.frames, 1)
    }

    func testReportRotationAndOversizeRejectionPreserveBoundedStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func report(settings: [String: String] = [:]) -> DockPerformanceReport {
            .init(schemaVersion: 1, startedUTC: Date(), hostTimeAnchor: 0, endedHostTime: 1,
                version: "test", gitHash: "test", operatingSystem: "test", hardwareModel: "test",
                processorCount: 1, lowPowerMode: false, thermalState: 0, settings: settings,
                panels: [], refreshSpans: [], overwrittenRefreshSpans: 0,
                omittedPanels: 0, overwrittenRetiredPanels: 0)
        }
        let first = try writeDockPerformanceReport(report(), to: directory)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: first.path)
        for _ in 0..<3 { _ = try writeDockPerformanceReport(report(), to: directory) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 3)
        XCTAssertThrowsError(try writeDockPerformanceReport(report(settings: ["fixture": String(repeating: "x", count: 6 * 1_024 * 1_024)]), to: directory)) {
            XCTAssertTrue($0 is DockPerformanceWriteError)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 3)
    }
}
