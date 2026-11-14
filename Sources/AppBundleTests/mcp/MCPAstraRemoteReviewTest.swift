@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class MCPAstraRemoteReviewTest: XCTestCase {
    private var savedRead: (@MainActor ([Window], Bool) async -> [UInt32: DebugSnapshotNativeRead])!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        WindowLifecycleLog.shared.reset()
        AxWindowErrorLog.shared.reset()
        savedRead = debugSnapshotNativeReads
        debugSnapshotNativeReads = { _, _ in [:] }
    }

    override func tearDown() async throws {
        debugSnapshotNativeReads = savedRead
        WindowLifecycleLog.shared.reset()
        AxWindowErrorLog.shared.reset()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private func send(host: String, access: MCPAccess, extra: [MCPHTTPHeader] = []) async -> MCPHTTPResponse {
        let request = MCPHTTPRequest(method: "POST", target: "/mcp", version: "HTTP/1.1",
            headers: [MCPHTTPHeader(name: "Host", value: host), MCPHTTPHeader(name: "Content-Type", value: "application/json")] + extra,
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
        return await handleMCPHTTPRequest(request, MCPRequestContext(peer: "127.0.0.1", token: nil, access: access, tailnetName: "fixture-mac"))
    }

    func testFunnelMarkerCannotReachTheLocalPortByChoosingLocalhostHost() async {
        let response = await send(host: "localhost", access: .local, extra: [
            MCPHTTPHeader(name: "X-Forwarded-Proto", value: "https"),
            MCPHTTPHeader(name: "X-Forwarded-Host", value: "localhost"),
            MCPHTTPHeader(name: "X-Forwarded-For", value: "203.0.113.8"),
            MCPHTTPHeader(name: "Tailscale-Funnel-Request", value: "?1"),
        ])
        XCTAssertEqual(response.status, 403)
    }

    func testMachineNameMismatchFailsClosedAndExplicitRenameWorks() async {
        let mismatch = await send(host: "fixture-mac-1.tail1234.ts.net", access: .tailnet)
        XCTAssertEqual(mismatch.status, 403)
        XCTAssertTrue(mcpTailnetHostIsAllowed("fixture-mac-1.tail1234.ts.net:443", machineName: "fixture-mac-1"))
        let missingOrigin = await send(host: "fixture-mac.tail1234.ts.net", access: .tailnet)
        XCTAssertEqual(missingOrigin.status, 200)
        let foreign = await send(host: "fixture-mac.tail1234.ts.net", access: .tailnet,
            extra: [MCPHTTPHeader(name: "Origin", value: "https://other.tail1234.ts.net")])
        XCTAssertEqual(foreign.status, 403)
    }

    func testSnapshotNeverReadsNativeWindowsExcludedByTheFilter() async throws {
        let one = Workspace.get(byName: "one")
        let two = Workspace.get(byName: "two")
        _ = TestWindow.new(id: 71, parent: one.rootTilingContainer)
        _ = TestWindow.new(id: 72, parent: two.rootTilingContainer)
        await updateWorkspaceSidebarModel()
        var readIds: [UInt32] = []
        debugSnapshotNativeReads = { windows, _ in
            readIds += windows.map(\.windowId)
            return Dictionary(uniqueKeysWithValues: windows.map { ($0.windowId, DebugSnapshotNativeRead(appListsWindow: true)) })
        }
        let snapshot = await mcpDebugSnapshot(MCPDebugSnapshotOptions(windowIds: [71]))
        XCTAssertEqual(readIds, [71])
        XCTAssertLessThanOrEqual(snapshot.encoded().count, 64 * 1024)
    }

    /// Astra's observation, now bounded: a timed-out read is still outstanding, and the next snapshot doesn't queue another
    /// for the same app behind it.
    func testTimeoutBoundsTheResponseAndRepeatedReadsDontPileUp() async throws {
        let workspace = Workspace.get(byName: "slow-fixture")
        _ = TestWindow.new(id: 88, parent: workspace.rootTilingContainer)
        await updateWorkspaceSidebarModel()
        let savedTimeout = mcpDebugSnapshotReadTimeout
        defer { mcpDebugSnapshotReadTimeout = savedTimeout }
        mcpDebugSnapshotReadTimeout = .milliseconds(100)
        var pending: [CheckedContinuation<[UInt32: DebugSnapshotNativeRead], Never>] = []
        let finished = expectation(description: "native read released")
        debugSnapshotNativeReads = { _, _ in
            let value = await withCheckedContinuation { pending.append($0) }
            finished.fulfill()
            return value
        }
        for expected in ["timedOut", "busy"] {
            let result = await mcpDebugSnapshot(MCPDebugSnapshotOptions(windowIds: [88]))
            XCTAssertTrue(String(decoding: result.encoded(), as: UTF8.self).contains(expected), expected)
            XCTAssertEqual(pending.count, 1, "The second snapshot doesn't queue another read while the first is pending")
        }
        for continuation in pending { continuation.resume(returning: [:]) }
        await fulfillment(of: [finished], timeout: 2)
    }

    func testASnapshotRemainsBoundedWithVeryLongLabelsAndManyMembers() async throws {
        let workspace = Workspace.get(byName: "fixture-workspace")
        let app = TestApp(pid: 901, bundleId: "com.example.fixture", name: "Fixture", bundlePath: "/Users/FIXTURE/Applications/Fixture.app")
        for id in 1000..<1200 {
            _ = SnapshotTestWindow(id: UInt32(id), parent: workspace.rootTilingContainer, app: app,
                title: "PRIVATE_LABEL_" + String(repeating: "quote\"slash\\", count: 100),
                frame: Rect(topLeftX: 0, topLeftY: 25, width: 400, height: 300))
        }
        await updateWorkspaceSidebarModel()
        for includeTitles in [false, true] {
            let snapshot = await mcpDebugSnapshot(MCPDebugSnapshotOptions(includeTitles: includeTitles))
            XCTAssertLessThanOrEqual(snapshot.encoded().count, 64 * 1024)
            XCTAssertNotNil(snapshot["truncated"])
            if !includeTitles {
                let text = String(decoding: snapshot.encoded(), as: UTF8.self)
                XCTAssertFalse(text.contains("PRIVATE_LABEL_"))
                XCTAssertFalse(text.contains("/Users/FIXTURE"))
            }
        }
    }
}
