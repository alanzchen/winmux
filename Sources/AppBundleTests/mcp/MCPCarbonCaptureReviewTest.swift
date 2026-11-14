@testable import AppBundle
import AppKit
import Common
import XCTest

/// Carbon's review of the screenshot tools, 2026-11-13: applying a configuration — at launch, on reload, from any
/// client, or for a server that then fails — must never ask macOS for Screen Recording. Only the Settings action may.
/// Run through the apply seam, as reload-config reaches it: reload-config itself also touches the host's login items.
@MainActor
final class MCPCarbonCaptureReviewTest: XCTestCase {
    private var savedCapture: (any DebugScreenCapturing)!
    private var probe: FakeDebugScreenCapture!
    private var savedTokenURL: (@MainActor () -> URL?)?
    private var folder: URL!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        probe = FakeDebugScreenCapture()
        probe.permission = false
        savedCapture = debugScreenCapture
        debugScreenCapture = probe
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-carbon-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedTokenURL = mcpServerTokenURL
        mcpServerTokenURL = { [folder] in folder?.appendingPathComponent("mcp-server-token") }
    }

    override func tearDown() async throws {
        setServerReadOnlyForTests(false)
        debugScreenCapture = savedCapture
        if let savedTokenURL { mcpServerTokenURL = savedTokenURL }
        try? FileManager.default.removeItem(at: folder)
        config = defaultConfig
    }

    func testAppLaunchWithSavedDebugScreenshotsMustNotRequestPermission() {
        let startupServer = MCPServer(waitsForAppStart: true)
        defer { startupServer.stop() }
        startupServer.apply(MCPServerConfig(enabled: true, port: 0, debugScreenshots: true))
        XCTAssertEqual(probe.requests, 0)
        startupServer.appDidStart()
        XCTAssertEqual(probe.requests, 0, "App launch / update relaunch must never trigger CGRequestScreenCaptureAccess()")
    }

    /// What reload-config does with a config edited on disk, for any client, with or without a token.
    func testRemoteReloadOfAnEditedConfigMustNotTriggerScreenRecordingPrompt() {
        let server = MCPServer()
        defer { server.stop() }
        server.apply(MCPServerConfig(enabled: true, port: 0, debugScreenshots: false))
        server.apply(MCPServerConfig(enabled: true, port: 0, debugScreenshots: true))
        server.apply(MCPServerConfig(enabled: false, port: 0, debugScreenshots: true))
        server.apply(MCPServerConfig(enabled: true, port: 0, debugScreenshots: true))
        XCTAssertEqual(probe.requests, 0, "A remote MCP request must never trigger macOS's Screen Recording permission prompt")
    }

    func testFailedTokenStartupMustNotRequestPermissionOrEnableDebugCapture() {
        let server = MCPServer()
        defer { server.stop() }
        setServerReadOnlyForTests(true)
        server.apply(MCPServerConfig(enabled: true, port: 0, requireToken: true, debugScreenshots: true))
        XCTAssertTrue(server.state.isFailed)
        XCTAssertEqual(probe.requests, 0, "A server that fails to start must not prompt for Screen Recording")
        XCTAssertNil(server.screenCaptureAllowed)
    }
}
