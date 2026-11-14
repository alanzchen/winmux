@testable import AppBundle
import AppKit
import Common
import Foundation
import XCTest

/// A screen capture that captures nothing: synthetic bytes per display, a permission to switch, and a log of what it
/// was asked.
final class FakeDebugScreenCapture: DebugScreenCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var _permission = true
    private var _requests = 0
    private var _captures: [(displays: [Int], maxLongEdge: Int, format: DebugImageFormat)] = []
    var bytesPerImage = 1000
    /// Runs while capturing, before the images are returned: to revoke, or hold a capture past a deadline.
    var whileCapturing: (@MainActor () async -> Void)?

    var permission: Bool {
        get { lock.withLock { _permission } }
        set { lock.withLock { _permission = newValue } }
    }
    var requests: Int { lock.withLock { _requests } }
    var captures: [(displays: [Int], maxLongEdge: Int, format: DebugImageFormat)] { lock.withLock { _captures } }

    func hasPermission() -> Bool { permission }

    func requestPermission() -> Bool {
        lock.withLock {
            _requests += 1
            return _permission
        }
    }

    func capture(_ displays: [DebugCaptureDisplay], maxLongEdge: Int, format: DebugImageFormat) async -> [DebugCaptureOutcome] {
        let bytes = lock.withLock {
            _captures.append((displays.map(\.monitorId), maxLongEdge, format))
            return bytesPerImage
        }
        if let whileCapturing { await whileCapturing() }
        return displays.map { display in
            .image(DebugCapturedImage(data: Data(repeating: UInt8(display.monitorId), count: bytes),
                                      width: min(maxLongEdge, 1600), height: 900, format: format))
        }
    }
}

/// A recorder's clock: sleeps move it on, and can be held so a recording stays running; timers wait to be fired.
/// `now` is time passing, and drives the deadline clock too; `wallClockOffset` moves only the time of day, as
/// changing the Mac's clock would.
@MainActor
final class FakeRecorderClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var wallClockOffset: TimeInterval = 0
    var holdsSleeps = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var timers: [(delay: Duration, action: @MainActor () -> Void)] = []
    var snapshotState = 0

    var heldSleeps: Int { held.count }

    func sleep(_ duration: Duration) async {
        if holdsSleeps { await withCheckedContinuation { held.append($0) } }
        now = now.addingTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    func release() {
        let continuations = held
        held = []
        for continuation in continuations { continuation.resume() }
    }

    var environment: DebugRecorderEnvironment {
        DebugRecorderEnvironment(
            now: { [weak self] in (self?.now ?? Date()).addingTimeInterval(self?.wallClockOffset ?? 0) },
            uptime: { [weak self] in self?.now.timeIntervalSince1970 ?? 0 },
            sleep: { [weak self] duration in await self?.sleep(duration) },
            after: { [weak self] delay, action in
                self?.timers.append((delay, action))
                return {}
            },
            snapshot: { [weak self] _ in
                .object(["schema": .string("winmux-debug-snapshot/1"), "generatedAt": .string("\(self?.now ?? Date())"),
                         "state": .int(self?.snapshotState ?? 0)])
            })
    }
}

@MainActor
final class MCPDebugCaptureTest: XCTestCase {
    private var capture: FakeDebugScreenCapture!
    private var clock: FakeRecorderClock!
    private var savedCapture: (any DebugScreenCapturing)!
    private var savedEnvironment: DebugRecorderEnvironment!
    private var savedByteLimit = 0
    private var savedPermission: ScreenRecordingPermissionModel!
    private var recorder: DebugRecorder { .shared }

    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests([
            TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Built-in Retina Display", rect: Rect(topLeftX: 0, topLeftY: 0, width: 1512, height: 982),
                        visibleRect: Rect(topLeftX: 0, topLeftY: 33, width: 1512, height: 949), isMain: true),
            TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Studio Display", rect: Rect(topLeftX: 1512, topLeftY: 0, width: 2560, height: 1440),
                        visibleRect: Rect(topLeftX: 1512, topLeftY: 25, width: 2560, height: 1415), isMain: false),
        ])
        capture = FakeDebugScreenCapture()
        savedCapture = debugScreenCapture
        debugScreenCapture = capture
        clock = FakeRecorderClock()
        savedEnvironment = recorder.environment
        recorder.environment = clock.environment
        savedByteLimit = recorder.byteLimit
        savedPermission = debugScreenRecordingPermission
        debugScreenRecordingPermission = ScreenRecordingPermissionModel(
            preflight: { MainActor.assumeIsolated { debugScreenCapture.hasPermission() } },
            request: { MainActor.assumeIsolated { debugScreenCapture.requestPermission() } })
        TrayMenuModel.shared.debugRecording = nil
    }

    override func tearDown() async throws {
        _ = recorder.stop(reason: "the test ended")
        clock.holdsSleeps = false
        clock.release()
        await recorder.waitForRecording()
        recorder.environment = savedEnvironment
        recorder.byteLimit = savedByteLimit
        debugScreenRecordingPermission = savedPermission
        debugScreenCapture = savedCapture
        TrayMenuModel.shared.debugRecording = nil
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
    }

    private let local = MCPRequestContext(peer: "127.0.0.1", token: nil, debugCapture: true)
    private let tailnetWithoutToken = MCPRequestContext(peer: "127.0.0.1", token: nil, access: .tailnet, tailnetName: "alans-macbook-pro",
                                                       debugCapture: true)

    private func rpc(_ method: String, _ params: MCPJSON, _ context: MCPRequestContext) async -> MCPJSON? {
        let body = MCPJSON.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string(method), "params": params])
        let host = context.access == .tailnet ? "alans-macbook-pro.tail1234.ts.net" : "127.0.0.1:41740"
        let response = await handleMCPHTTPRequest(MCPHTTPRequest(method: "POST", target: "/mcp", version: "HTTP/1.1",
            headers: [MCPHTTPHeader(name: "Host", value: host), MCPHTTPHeader(name: "Content-Type", value: "application/json")]
                + (context.token.map { [MCPHTTPHeader(name: "Authorization", value: "Bearer \($0)")] } ?? []),
            body: body.encoded()), context)
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        return MCPJSON.decode(response.body)
    }

    private func call(_ tool: String, _ arguments: [String: MCPJSON] = [:], _ context: MCPRequestContext? = nil) async -> MCPJSON? {
        await rpc("tools/call", .object(["name": .string(tool), "arguments": .object(arguments)]), context ?? local)
    }

    private func document(_ message: MCPJSON?) throws -> MCPJSON {
        let text = try XCTUnwrap(message?["result"]?["content"]?.array?.first?["text"]?.string, "\(message ?? .null)")
        return try XCTUnwrap(MCPJSON.decode(Data(text.utf8)), text)
    }

    private func images(_ message: MCPJSON?) -> [MCPJSON] {
        (message?["result"]?["content"]?.array ?? []).filter { $0["type"] == .string("image") }
    }

    private func errorText(_ message: MCPJSON?) -> String {
        message?["error"]?["message"]?.string ?? message?["result"]?["content"]?.array?.first?["text"]?.string ?? ""
    }

    private func record(_ arguments: [String: MCPJSON], _ context: MCPRequestContext? = nil) async -> MCPJSON? {
        await call("winmux_debug_recording", arguments, context)
    }

    // MARK: - Offered only while it's on

    func testTheCaptureToolsAreOfferedOnlyWhileDebugScreenshotsIsOn() async throws {
        let off = MCPRequestContext(peer: "127.0.0.1", token: nil)
        let hidden = await rpc("tools/list", .object([:]), off)?["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        XCTAssertFalse(hidden.contains("winmux_debug_screenshot"))
        XCTAssertFalse(hidden.contains("winmux_debug_recording"))
        XCTAssertTrue(hidden.contains("winmux_debug_snapshot"))
        for tool in ["winmux_debug_screenshot", "winmux_debug_recording"] {
            let refused = await call(tool, tool == "winmux_debug_recording" ? ["action": .string("start")] : [:], off)
            XCTAssertEqual(refused?["error"]?["code"], .int(-32602), tool)
            XCTAssertEqual(errorText(refused), "Unknown tool")
        }
        XCTAssertTrue(capture.captures.isEmpty)
        XCTAssertNil(recorder.recording)

        let listed = await rpc("tools/list", .object([:]), local)?["result"]?["tools"]?.array ?? []
        let names = listed.compactMap { $0["name"]?.string }
        XCTAssertTrue(names.contains("winmux_debug_screenshot"))
        XCTAssertTrue(names.contains("winmux_debug_recording"))
        for tool in listed where tool["name"]?.string?.hasPrefix("winmux_debug_") == true && tool["name"] != .string("winmux_debug_snapshot") {
            XCTAssertTrue(tool["description"]?.string?.contains("can't be redacted") == true, "\(tool)")
        }
    }

    // MARK: - Screenshots

    func testAScreenshotHasAnImageOfEachDisplayAndWhereItLies() async throws {
        let message = await call("winmux_debug_screenshot")
        XCTAssertEqual(message?["result"]?["isError"], .bool(false), "\(message ?? .null)")
        let described = try document(message)
        XCTAssertEqual(described["schema"], .string("winmux-debug-screenshot/1"))
        XCTAssertTrue(described["note"]?.string?.contains("can't be redacted") == true)
        let displays = try XCTUnwrap(described["displays"]?.array)
        XCTAssertEqual(displays.compactMap { $0["id"] }, [.int(1), .int(2)])
        XCTAssertEqual(displays[1]["frame"], .object(["x": .int(1512), "y": .int(0), "width": .int(2560), "height": .int(1440)]),
            "As winmux_debug_snapshot places it")
        XCTAssertEqual(displays.compactMap { $0["image"]?["contentIndex"] }, [.int(1), .int(2)])
        let images = images(message)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images.first?["mimeType"], .string("image/jpeg"))
        XCTAssertEqual(images[1]["data"]?.string.flatMap { Data(base64Encoded: $0) }, Data(repeating: 2, count: 1000))
        XCTAssertEqual(capture.captures.map(\.maxLongEdge), [1600])
        XCTAssertEqual(capture.requests, 0, "A tool never asks macOS")
    }

    func testOneDisplaySizeAndFormatCanBeAskedForAndBadArgumentsAreRefused() async throws {
        let message = await call("winmux_debug_screenshot", ["display": .int(2), "max_long_edge": .int(800), "format": .string("png")])
        XCTAssertEqual(try document(message)["displays"]?.array?.compactMap { $0["id"] }, [.int(2)])
        XCTAssertEqual(images(message).first?["mimeType"], .string("image/png"))
        XCTAssertEqual(capture.captures.last?.displays, [2])
        XCTAssertEqual(capture.captures.last?.maxLongEdge, 800)
        XCTAssertEqual(capture.captures.last?.format, .png)

        let missing = await call("winmux_debug_screenshot", ["display": .int(9)])
        XCTAssertEqual(missing?["result"]?["isError"], .bool(true))
        XCTAssertTrue(errorText(missing).contains("No display is numbered 9"), errorText(missing))
        for arguments: [String: MCPJSON] in [["max_long_edge": .int(10)], ["format": .string("gif")], ["display": .string("2")], ["displays": .int(1)]] {
            let refused = await call("winmux_debug_screenshot", arguments)
            XCTAssertEqual(refused?["error"]?["code"], .int(-32602), "\(arguments)")
        }
    }

    func testWithoutScreenRecordingPermissionAScreenshotSaysHowToAllowIt() async throws {
        capture.permission = false
        let message = await call("winmux_debug_screenshot")
        XCTAssertEqual(message?["result"]?["isError"], .bool(true))
        XCTAssertTrue(errorText(message).contains("Privacy & Security"), errorText(message))
        XCTAssertTrue(capture.captures.isEmpty)
        XCTAssertEqual(capture.requests, 0)
    }

    /// Images show what's on screen and can't be redacted: none goes to the tailnet unless a token is required.
    func testScreenImagesAreRefusedFromTheTailnetWithoutAToken() async throws {
        let refused = await call("winmux_debug_screenshot", [:], tailnetWithoutToken)
        XCTAssertEqual(refused?["result"]?["isError"], .bool(true))
        XCTAssertTrue(errorText(refused).contains("Require access token"), errorText(refused))
        XCTAssertTrue(images(refused).isEmpty)
        XCTAssertTrue(capture.captures.isEmpty, "Nothing is captured")

        var withToken = tailnetWithoutToken
        withToken.token = "synthetic-token"
        let allowed = await call("winmux_debug_screenshot", [:], withToken)
        XCTAssertEqual(images(allowed).count, 2)
    }

    func testTheImageSizeKeepsProportionsAndIsNeverLargerThanTheDisplay() {
        XCTAssertTrue(debugCaptureSize(points: CGSize(width: 1512, height: 982), scale: 2, maxLongEdge: 1600) == (1600, 1039))
        XCTAssertTrue(debugCaptureSize(points: CGSize(width: 1512, height: 982), scale: 2, maxLongEdge: 16384) == (3024, 1964))
        XCTAssertTrue(debugCaptureSize(points: CGSize(width: 1080, height: 1920), scale: 1, maxLongEdge: 960) == (540, 960))
        XCTAssertTrue(debugCaptureSize(points: .zero, scale: 2, maxLongEdge: 1600) == (0, 0))
    }

    func testImagesAreEncodedInMemory() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        let image = try XCTUnwrap(context.makeImage())
        let jpeg = await debugEncodeImage(image, .jpeg)
        XCTAssertEqual(jpeg?.prefix(2), Data([0xFF, 0xD8]))
        let png = await debugEncodeImage(image, .png)
        XCTAssertEqual(png?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    /// Images and recordings are kept in memory only: the code that makes and keeps them has no way to write a file.
    func testNothingThatCapturesOrRecordsCanWriteAFile() throws {
        for file in ["Sources/AppBundle/mcp/MCPDebugCapture.swift", "Sources/AppBundle/mcp/DebugRecorder.swift"] {
            let source = try String(contentsOf: projectRoot.appending(path: file), encoding: .utf8)
            for api in ["FileManager", "write(to", "writeToFile", "createFile", "CGImageDestinationCreateWithURL", "FileHandle",
                        "fopen", "URL(fileURLWithPath", "SCRecordingOutput", "AVAssetWriter", "UserDefaults"] {
                XCTAssertFalse(source.contains(api), "\(file) uses \(api)")
            }
        }
    }

    // MARK: - Recordings

    func testARecordingCapturesEveryIntervalForItsDurationAndTheMenuBarShowsIt() async throws {
        let started = await record(["action": .string("start"), "duration_seconds": .int(5), "interval_ms": .int(1000)])
        let status = try document(started)
        XCTAssertEqual(status["state"], .string("running"))
        XCTAssertEqual(status["capturesFrames"], .bool(true))
        XCTAssertNotNil(TrayMenuModel.shared.debugRecording)
        XCTAssertEqual(menuBarIconKind(TrayMenuModel.shared), .debugRecording)

        await recorder.waitForRecording()
        let finished = try document(await record(["action": .string("status")]))
        XCTAssertEqual(finished["state"], .string("finished"))
        XCTAssertEqual(finished["ticks"], .int(5), "Every second for 5 seconds")
        XCTAssertEqual(finished["frames"], .int(10), "Both displays each time")
        XCTAssertNil(TrayMenuModel.shared.debugRecording, "Nothing is captured any more")
        XCTAssertNotEqual(menuBarIconKind(TrayMenuModel.shared), .debugRecording)
        XCTAssertEqual(capture.captures.map(\.maxLongEdge), Array(repeating: 1024, count: 5), "Frames are smaller by default")
    }

    func testARecordingsBoundsAreRefusedOutsideTheirRanges() async throws {
        for arguments: [String: MCPJSON] in [["duration_seconds": .int(121)], ["duration_seconds": .int(0)], ["interval_ms": .int(249)],
                                             ["max_long_edge": .int(20000)], ["cursor": .int(0)], ["frames": .string("yes")]] {
            let start: [String: MCPJSON] = ["action": .string("start")]
            let refused = await record(start.merging(arguments) { first, _ in first })
            XCTAssertEqual(refused?["error"]?["code"], .int(-32602), "\(arguments)")
        }
        let unknown = await record(["action": .string("rewind")])
        XCTAssertEqual(unknown?["error"]?["code"], .int(-32602))
        let stray = await record(["action": .string("status"), "id": .string("x")])
        XCTAssertEqual(stray?["error"]?["code"], .int(-32602), "status takes no id")
        XCTAssertNil(recorder.recording)

        clock.holdsSleeps = true
        _ = await record(["action": .string("start"), "duration_seconds": .int(120), "interval_ms": .int(250)])
        let second = await record(["action": .string("start")])
        XCTAssertEqual(second?["error"]?["code"], .int(-32602), "One at a time")
        XCTAssertTrue(errorText(second).contains("is running"), errorText(second))
    }

    func testAStateTheSameAsTheTickBeforesIsKeptOnce() async throws {
        _ = await record(["action": .string("start"), "duration_seconds": .int(4), "frames": .bool(false)])
        clock.snapshotState = 0
        await recorder.waitForRecording()
        let entriesMessage = await record(["action": .string("fetch")])
        let states = try XCTUnwrap(try document(entriesMessage)["entries"]?.array).filter { $0["kind"] == .string("state") }
        XCTAssertEqual(states.count, 4)
        XCTAssertNotNil(states[0]["snapshot"]?.object)
        XCTAssertEqual(states.dropFirst().map { $0["snapshot"] }, Array(repeating: .string("unchanged"), count: 3))
    }

    func testOverItsMemoryTheOldestFramesGoFirstAndItSaysSo() async throws {
        recorder.byteLimit = 12_000
        capture.bytesPerImage = 2000
        _ = await record(["action": .string("start"), "duration_seconds": .int(6)])
        await recorder.waitForRecording()
        let status = try document(await record(["action": .string("status")]))
        XCTAssertLessThanOrEqual(status["bytes"]?.int ?? .max, 12_000)
        XCTAssertGreaterThan(status["truncated"]?["evictedFrames"]?.int ?? 0, 0, "\(status)")
        let entriesMessage = await record(["action": .string("fetch")])
        let entries = try XCTUnwrap(try document(entriesMessage)["entries"]?.array)
        func ofTick(_ tick: Int) -> [MCPJSON] { entries.filter { $0["tick"] == .int(tick) } }
        XCTAssertEqual(ofTick(0).filter { $0["kind"] == .string("frame") }.count, 0, "The oldest lost theirs")
        XCTAssertEqual(ofTick(0).compactMap { $0["evicted"]?.string }.filter { $0.hasPrefix("frame") }.count, 2)
        XCTAssertEqual(ofTick(5).filter { $0["kind"] == .string("frame") }.count, 2, "The newest kept theirs")
        XCTAssertNotNil(ofTick(0).first?["snapshot"]?.object, "States stay while frames can go")
    }

    func testFetchPagesAreBoundedAndTheLastPageDiscardsTheRecording() async throws {
        _ = await record(["action": .string("start"), "duration_seconds": .int(20)])
        await recorder.waitForRecording()
        var cursor: MCPJSON = .null
        var sequences: [Int] = []
        var ticks: [Int] = []
        var pages = 0
        while true {
            let page = await record(["action": .string("fetch"), "cursor": cursor])
            let described = try document(page)
            let entries = try XCTUnwrap(described["entries"]?.array)
            XCTAssertLessThanOrEqual(images(page).count, DebugRecorder.pageImages)
            XCTAssertLessThanOrEqual(described.encoded().count, DebugRecorder.pageTextBytes)
            sequences += entries.compactMap { $0["sequence"]?.int }
            ticks += entries.filter { $0["kind"] == .string("frame") }.compactMap { $0["tick"]?.int }
            pages += 1
            if described["complete"] == .bool(true) {
                XCTAssertEqual(described["nextCursor"], .null)
                break
            }
            cursor = try XCTUnwrap(described["nextCursor"])
            XCTAssertLessThan(pages, 20)
        }
        XCTAssertEqual(sequences, Array(0 ..< 60), "Every entry once, in order: a state and two frames a tick")
        XCTAssertEqual(ticks, (0 ..< 20).flatMap { [$0, $0] })
        XCTAssertEqual(pages, 5, "8 images a page, 2 displays a tick")
        let after = try document(await record(["action": .string("status")]))
        XCTAssertEqual(after["state"], .string("none"))
        XCTAssertEqual(after["lastDiscarded"]?["reason"], .string("its last page was fetched"))
        XCTAssertNil(recorder.recording, "Nothing is held")
    }

    func testAFinishedRecordingIsDiscardedTenMinutesAfterItEnds() async throws {
        _ = await record(["action": .string("start"), "duration_seconds": .int(2)])
        await recorder.waitForRecording()
        XCTAssertEqual(recorder.recording?.state, .finished)
        let expiry = try XCTUnwrap(clock.timers.last { $0.delay == .seconds(600) })
        expiry.action()
        XCTAssertNil(recorder.recording)
        XCTAssertEqual(recorder.lastDiscarded?.reason, "it wasn't fetched within 10 minutes of ending")
        let fetched = await record(["action": .string("fetch")])
        XCTAssertEqual(fetched?["error"]?["code"], .int(-32602))
        XCTAssertTrue(errorText(fetched).contains("discarded"), errorText(fetched))
    }

    func testStopEndsARecordingAndDiscardsItAtOnceAsTheMenuDoes() async throws {
        clock.holdsSleeps = true
        _ = await record(["action": .string("start"), "duration_seconds": .int(60)])
        for _ in 0 ..< 20 where clock.heldSleeps == 0 { await Task.yield() }
        XCTAssertEqual(recorder.recording?.state, .running)
        XCTAssertEqual(menuBarIconKind(TrayMenuModel.shared), .debugRecording)
        let stopped = try document(await record(["action": .string("stop")]))
        XCTAssertEqual(stopped["state"], .string("none"))
        XCTAssertNil(recorder.recording)
        XCTAssertNil(TrayMenuModel.shared.debugRecording)

        _ = await record(["action": .string("start"), "duration_seconds": .int(60)])
        XCTAssertNotNil(TrayMenuModel.shared.debugRecording)
        // What the menu's Debug recording… Stop does.
        _ = recorder.stop(reason: "it was stopped from the menu bar")
        XCTAssertNil(recorder.recording)
        XCTAssertEqual(recorder.lastDiscarded?.reason, "it was stopped from the menu bar")
        XCTAssertNotEqual(menuBarIconKind(TrayMenuModel.shared), .debugRecording)
    }

    func testTheMenuBarShowsARunningRecordingOverAnythingElse() {
        let model = TrayMenuModel()
        model.accessibilityPermissionStatus = .granted
        model.isEnabled = true
        XCTAssertEqual(menuBarIconKind(model), .appIcon)
        model.debugRecording = DebugRecordingIndicator(id: "synthetic", endsAt: Date())
        XCTAssertEqual(menuBarIconKind(model), .debugRecording)
        model.isEnabled = false
        model.accessibilityPermissionStatus = .waitingWithPrompt
        XCTAssertEqual(menuBarIconKind(model), .debugRecording)
        model.debugRecording = nil
        XCTAssertEqual(menuBarIconKind(model), .accessibilityMissing)
    }

    /// Inside a recording too: started from the tailnet without a token, it captures no frames; fetched from there, a
    /// recording that has frames sends none.
    func testFramesAreLeftOutForTheTailnetWithoutATokenInsideARecordingToo() async throws {
        let started = try document(await record(["action": .string("start"), "duration_seconds": .int(3)], tailnetWithoutToken))
        XCTAssertEqual(started["capturesFrames"], .bool(false))
        XCTAssertTrue(started["framesNote"]?.string?.contains("Require access token") == true, "\(started)")
        await recorder.waitForRecording()
        XCTAssertTrue(capture.captures.isEmpty, "No frame was captured")
        XCTAssertEqual(recorder.recording?.ticks, 3, "Its states and events are still recorded")
        _ = await record(["action": .string("stop")])

        _ = await record(["action": .string("start"), "duration_seconds": .int(6)])
        await recorder.waitForRecording()
        let fromTailnet = await record(["action": .string("fetch")], tailnetWithoutToken)
        XCTAssertTrue(images(fromTailnet).isEmpty)
        let described = try document(fromTailnet)
        XCTAssertTrue(described["framesOmitted"]?.string?.contains("Require access token") == true, "\(described)")
        XCTAssertEqual(described["entries"]?.array?.first { $0["kind"] == .string("frame") }?["frame"], .string("omitted"))
        XCTAssertEqual(described["complete"], .bool(false))
        let fromHere = await record(["action": .string("fetch")])
        XCTAssertEqual(images(fromHere).count, 8)
    }

    func testWithoutPermissionARecordingKeepsStatesAndEventsOnly() async throws {
        capture.permission = false
        let started = try document(await record(["action": .string("start"), "duration_seconds": .int(2)]))
        XCTAssertEqual(started["capturesFrames"], .bool(false))
        XCTAssertTrue(started["framesNote"]?.string?.contains("Screen & System Audio Recording") == true)
        await recorder.waitForRecording()
        XCTAssertEqual(recorder.recording?.ticks, 2)
        XCTAssertTrue(capture.captures.isEmpty)
        XCTAssertEqual(capture.requests, 0)
    }

    /// Every window event while it runs, not just the newest the event log keeps; past its cap, it counts the rest.
    func testEveryEventWhileItRunsIsKept() async throws {
        clock.holdsSleeps = true
        _ = await record(["action": .string("start"), "duration_seconds": .int(3), "frames": .bool(false)])
        for _ in 0 ..< 20 where clock.heldSleeps == 0 { await Task.yield() }
        for index in 0 ..< DebugRecorder.maxEvents + 5 {
            WindowLifecycleLog.shared.record(.moved, windowId: UInt32(index), ["to": "synthetic"])
        }
        clock.holdsSleeps = false
        clock.release()
        await recorder.waitForRecording()
        let status = try document(await record(["action": .string("status")]))
        XCTAssertEqual(status["events"], .int(DebugRecorder.maxEvents))
        XCTAssertEqual(status["truncated"]?["droppedEvents"], .int(5))
        let kept = recorder.recording?.entries.reduce(0) { total, entry in
            if case .events(let events) = entry.content { total + events.count } else { total }
        }
        XCTAssertEqual(kept, DebugRecorder.maxEvents)
        XCTAssertNil(WindowLifecycleLog.shared.observer, "Not listening once it ended")
    }

    /// Screenshots and recordings read; nothing moves, gets focus or changes in the tree.
    func testCapturingChangesNothing() async throws {
        recorder.environment.snapshot = { await mcpDebugSnapshot($0) }
        let chat = Workspace.get(byName: "chat")
        let telegram = SnapshotTestWindow(id: 11, parent: chat.rootTilingContainer, app: TestApp(pid: 601, bundleId: "ru.keepcoder.Telegram"),
            title: "Synthetic chat", frame: Rect(topLeftX: 0, topLeftY: 33, width: 756, height: 949))
        let mail = SnapshotTestWindow(id: 12, parent: chat.rootTilingContainer, app: TestApp(pid: 602, bundleId: "com.apple.mail"),
            title: "Synthetic inbox", frame: Rect(topLeftX: 756, topLeftY: 33, width: 756, height: 949))
        XCTAssertTrue(telegram.focusWindow())
        await updateWorkspaceSidebarModel()
        let windows = [telegram, mail]
        let writes = windows.map(\.frameWrites)
        let focusRequests = windows.map(\.focusRequests)
        let tree = Workspace.all.map { "\($0.name):\($0.allLeafWindowsRecursive.map(\.windowId))" }
        let sidebar = TrayMenuModel.shared.workspaceSidebarWorkspaces
        _ = await call("winmux_debug_screenshot")
        _ = await record(["action": .string("start"), "duration_seconds": .int(3)])
        await recorder.waitForRecording()
        _ = await record(["action": .string("fetch")])
        XCTAssertEqual(windows.map(\.frameWrites), writes)
        XCTAssertEqual(windows.map(\.focusRequests), focusRequests)
        XCTAssertEqual(Workspace.all.map { "\($0.name):\($0.allLeafWindowsRecursive.map(\.windowId))" }, tree)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarWorkspaces, sidebar)
        XCTAssertTrue(focus.windowOrNil === telegram)
    }

    // MARK: - The server

    /// Only the Settings action asks macOS: turning Allow debug screenshots on there, or Allow Screen Recording. Applying
    /// a config, at launch or on a reload from any client, never does; and a denial isn't asked again by anything.
    func testOnlyTheSettingsActionAsksMacOSAndOnlyOnce() throws {
        let server = MCPServer()
        defer { server.stop() }
        capture.permission = false
        server.apply(MCPServerConfig(enabled: true, port: 0, debugScreenshots: true))
        XCTAssertEqual(capture.requests, 0, "Applying a config never asks")
        XCTAssertEqual(server.screenCaptureAllowed, false, "It only looks")
        let field = try XCTUnwrap(SettingsCatalog.fields.first { $0.id == "mcp-server.debug-screenshots" })
        let turnedOn = try XCTUnwrap(field.onTurnedOn)
        turnedOn()
        XCTAssertEqual(capture.requests, 1, "Turning it on in Settings asks")
        turnedOn()
        debugScreenRecordingPermission.requestFromSettings()
        XCTAssertEqual(capture.requests, 1, "Denied: not asked again")
        server.apply(MCPServerConfig(enabled: false, port: 0, debugScreenshots: true))
        server.apply(MCPServerConfig(enabled: true, port: 0, debugScreenshots: true))
        XCTAssertEqual(capture.requests, 1)
        XCTAssertTrue(SettingsCatalog.fields.filter { $0.id != field.id }.allSatisfy { $0.onTurnedOn == nil }, "No other setting asks")
        capture.permission = true
        server.refreshScreenCapturePermission()
        XCTAssertEqual(server.screenCaptureAllowed, true)
    }

    /// The Settings toggle itself asks, when the user turns it on there; saving it another way, or another toggle, doesn't.
    func testTurningTheToggleOnInSettingsAsksAndNothingElseThere() async throws {
        capture.permission = false
        let disk = SettingsTestDisk()
        let editor = SettingsEditor(configuration: parseConfig(disk.text).config, persistence: disk.persistence)
        let fields = SettingsCatalog.fields
        let debug = try XCTUnwrap(fields.first { $0.id == "mcp-server.debug-screenshots" })
        let other = try XCTUnwrap(fields.first { $0.id == "mcp-server.require-token" })
        editor.toggle(other, to: true)
        editor.setDraft(.bool(true), for: debug)
        editor.commit(debug)
        await editor.waitUntilIdle()
        XCTAssertEqual(capture.requests, 0, "Not another toggle, nor a save that isn't the toggle")
        editor.setDraft(.bool(false), for: debug)
        editor.toggle(debug, to: true)
        await editor.waitUntilIdle()
        XCTAssertEqual(capture.requests, 1, "The user turning it on in Settings asks")
        editor.toggle(debug, to: false)
        editor.toggle(debug, to: true)
        await editor.waitUntilIdle()
        XCTAssertEqual(capture.requests, 1, "Denied once: not asked again")
    }

    /// Turning the tools off while a screenshot is being taken: what was captured isn't sent.
    func testTurningItOffWhileCapturingSendsNoImage() async throws {
        capture.whileCapturing = { revokeDebugCapture(reason: "synthetic revocation") }
        let message = await call("winmux_debug_screenshot")
        XCTAssertEqual(message?["result"]?["isError"], .bool(true))
        XCTAssertTrue(images(message).isEmpty)
        XCTAssertTrue(errorText(message).contains("turned off while capturing"), errorText(message))
    }

    /// Revoked during a recording's capture: everything goes, the late images included, and nothing more is captured.
    func testRevokingDuringARecordingsCaptureDropsEverything() async throws {
        capture.whileCapturing = { revokeDebugCapture(reason: "synthetic revocation") }
        _ = await record(["action": .string("start"), "duration_seconds": .int(5)])
        await recorder.waitForRecording()
        XCTAssertNil(recorder.recording)
        XCTAssertEqual(recorder.lastDiscarded?.reason, "synthetic revocation")
        XCTAssertNil(TrayMenuModel.shared.debugRecording)
        XCTAssertEqual(capture.captures.count, 1, "Nothing more was captured")
    }

    /// A capture that hangs doesn't keep a recording going: its deadline ends it, the menu bar stops showing it, and
    /// what the capture returns later isn't kept.
    func testARecordingEndsOnTimeWhileACaptureHangsAndKeepsNothingFromIt() async throws {
        var held: [CheckedContinuation<Void, Never>] = []
        capture.whileCapturing = { await withCheckedContinuation { held.append($0) } }
        _ = await record(["action": .string("start"), "duration_seconds": .int(2)])
        for _ in 0 ..< 50 where held.isEmpty { await Task.yield() }
        XCTAssertEqual(held.count, 1, "A capture is under way")
        let deadline = try XCTUnwrap(clock.timers.first { $0.delay == .seconds(2) })
        deadline.action()
        XCTAssertEqual(recorder.recording?.state, .finished)
        XCTAssertNil(TrayMenuModel.shared.debugRecording, "Not shown as recording past its deadline")
        capture.whileCapturing = nil
        for continuation in held { continuation.resume() }
        await recorder.waitForRecording()
        XCTAssertEqual(recorder.recording?.frameCount, 0, "What the late capture returned isn't kept")
    }

    /// Deadlines run on a clock that only moves forward: setting the Mac's clock back doesn't lengthen a recording.
    func testMovingTheMacsClockBackDoesntLengthenARecording() async throws {
        clock.snapshotState = 0
        recorder.environment.snapshot = { [clock] _ in
            if clock!.snapshotState == 0 {
                clock!.snapshotState = 1
                clock!.wallClockOffset = -3600
            }
            return .object(["schema": .string("winmux-debug-snapshot/1")])
        }
        _ = await record(["action": .string("start"), "duration_seconds": .int(3), "frames": .bool(false)])
        await recorder.waitForRecording()
        XCTAssertEqual(recorder.recording?.ticks, 3, "Still three seconds")
        XCTAssertEqual(recorder.recording?.state, .finished)
    }

    /// However many events one tick has, no page holds more text than its cap: they come in pieces.
    func testAPageNeverHoldsMoreTextThanItsCapHoweverManyEventsATickHas() async throws {
        clock.holdsSleeps = true
        _ = await record(["action": .string("start"), "duration_seconds": .int(2), "frames": .bool(false)])
        for _ in 0 ..< 50 where clock.heldSleeps == 0 { await Task.yield() }
        let name = String(repeating: "n", count: 150)
        for index in 0 ..< 2000 { WindowLifecycleLog.shared.record(.moved, windowId: UInt32(index), ["to": name]) }
        clock.holdsSleeps = false
        clock.release()
        await recorder.waitForRecording()
        var cursor: MCPJSON = .null
        var events = 0
        var pages = 0
        while true {
            let described = try document(await record(["action": .string("fetch"), "cursor": cursor]))
            XCTAssertLessThanOrEqual(described.encoded().count, DebugRecorder.pageTextBytes)
            events += described["entries"]?.array?.reduce(0) { $0 + ($1["events"]?.array?.count ?? 0) } ?? 0
            pages += 1
            if described["complete"] == .bool(true) { break }
            cursor = try XCTUnwrap(described["nextCursor"])
            XCTAssertLessThan(pages, 50)
        }
        XCTAssertEqual(events, 2000)
        XCTAssertGreaterThan(pages, 2, "In pieces, across pages")
    }

    /// Nothing larger than a page is ever kept, but should something be, fetching skips it and still moves on.
    func testAnEntryLargerThanAPageIsSkippedSoFetchingMovesOn() async throws {
        recorder.environment.snapshot = { _ in .object(["schema": .string("synthetic"), "padding": .string(String(repeating: "p", count: 200_000))]) }
        _ = await record(["action": .string("start"), "duration_seconds": .int(1), "frames": .bool(false)])
        await recorder.waitForRecording()
        let described = try document(await record(["action": .string("fetch")]))
        XCTAssertLessThanOrEqual(described.encoded().count, DebugRecorder.pageTextBytes)
        XCTAssertEqual(described["entries"]?.array?.first?["kind"], .string("omitted"))
        XCTAssertEqual(described["complete"], .bool(true))
    }

    /// Ending a recording drops what it holds even while something else still has it, as a capture under way might.
    func testEndingARecordingDropsItsDataEvenWhileSomethingStillHoldsIt() async throws {
        _ = await record(["action": .string("start"), "duration_seconds": .int(2)])
        await recorder.waitForRecording()
        let held = try XCTUnwrap(recorder.recording)
        XCTAssertEqual(held.frameCount, 4)
        _ = await record(["action": .string("stop")])
        XCTAssertEqual(held.frameCount, 0)
        XCTAssertEqual(held.entries.count, 0)
        XCTAssertEqual(held.bytes, 0)
        XCTAssertEqual(held.state, .discarded)
    }

    /// A long event is kept, cut, rather than dropped: its values stop at 200 characters.
    func testALongEventIsKeptCut() async throws {
        clock.holdsSleeps = true
        _ = await record(["action": .string("start"), "duration_seconds": .int(2), "frames": .bool(false)])
        for _ in 0 ..< 50 where clock.heldSleeps == 0 { await Task.yield() }
        WindowLifecycleLog.shared.record(.moved, windowId: 7, ["to": String(repeating: "w", count: 8192)])
        clock.holdsSleeps = false
        clock.release()
        await recorder.waitForRecording()
        let events = recorder.recording?.entries.flatMap { entry -> [WindowLifecycleEvent] in
            if case .events(let events) = entry.content { events } else { [] }
        } ?? []
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.detail["to"]?.count, debugRecordingEventValueLimit + 1, "200 characters and an ellipsis")
    }

    /// A frame too large for any page isn't kept, says so, and fetching still reaches the end.
    func testAFrameTooLargeForAPageIsNotKeptAndFetchingFinishes() async throws {
        capture.bytesPerImage = DebugRecorder.pageImageBytes + 1
        _ = await record(["action": .string("start"), "duration_seconds": .int(1), "display": .int(1)])
        await recorder.waitForRecording()
        let status = try document(await record(["action": .string("status")]))
        XCTAssertEqual(status["truncated"]?["droppedFrames"], .int(1))
        let page = await record(["action": .string("fetch")])
        let described = try document(page)
        XCTAssertEqual(described["complete"], .bool(true), "One fetch reaches the end")
        XCTAssertTrue(images(page).isEmpty)
        XCTAssertTrue(described["entries"]?.array?.contains { $0["kind"] == .string("frameError")
            && $0["error"]?.string?.contains("Not kept") == true } == true, "\(described)")
    }

    /// Carbon's nit: a fetch that withholds frames (the tailnet without a token) doesn't drop a recording at its end.
    func testAFetchThatWithholdsFramesDoesntDropTheRecordingAtItsEnd() async throws {
        _ = await record(["action": .string("start"), "duration_seconds": .int(2)])
        await recorder.waitForRecording()
        let fromTailnet = try document(await record(["action": .string("fetch")], tailnetWithoutToken))
        XCTAssertEqual(fromTailnet["complete"], .bool(true))
        XCTAssertNotNil(fromTailnet["kept"]?.string)
        XCTAssertNotNil(recorder.recording, "Kept for a request that may see its frames")
        let fromHere = await record(["action": .string("fetch")])
        XCTAssertEqual(images(fromHere).count, 4)
        XCTAssertNil(recorder.recording, "Dropped once it was all sent")
    }

    func testTurningItOffEndsAndDiscardsARecording() async throws {
        let server = MCPServer()
        defer { server.stop() }
        server.apply(MCPServerConfig(enabled: true, port: 0, debugScreenshots: true))
        clock.holdsSleeps = true
        _ = await record(["action": .string("start"), "duration_seconds": .int(60)])
        XCTAssertNotNil(recorder.recording)
        server.apply(MCPServerConfig(enabled: true, port: 0))
        XCTAssertNil(recorder.recording)
        XCTAssertTrue(recorder.lastDiscarded?.reason.contains("turned off") == true)
        XCTAssertNil(TrayMenuModel.shared.debugRecording)
    }

    /// The server offers the tools on its port while it's on, and not while it's off.
    func testTheServerOffersTheToolsOnlyWhileItsOn() async throws {
        let server = MCPServer()
        defer { server.stop() }
        func listed() async throws -> [String] {
            var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(try XCTUnwrap(server.port))/mcp")))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
            request.timeoutInterval = 5
            let (data, _) = try await URLSession.shared.data(for: request)
            return MCPJSON.decode(data)?["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        }
        for on in [true, false] {
            server.apply(MCPServerConfig(enabled: true, port: 0, debugScreenshots: on))
            let deadline = Date().addingTimeInterval(5)
            while server.state != .listening || server.port == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            let names = try await listed()
            XCTAssertEqual(names.contains("winmux_debug_screenshot"), on, "\(names)")
            XCTAssertEqual(names.contains("winmux_debug_recording"), on)
        }
    }
}
