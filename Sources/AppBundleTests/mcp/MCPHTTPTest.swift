@testable import AppBundle
import Foundation
import XCTest

/// The MCP server's HTTP: requests read only within their limits, responses, and the optional token.
@MainActor
final class MCPHTTPTest: XCTestCase {
    private func status(_ result: MCPHTTPParseResult) -> Int? {
        if case .invalid(let status, _) = result { status } else { nil }
    }

    func testARequestIsReadOnceItsBodyHasArrivedAndLeavesTheNextOnesBytes() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:41740\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n"
        let full = Data((head + body).utf8)
        XCTAssertEqual(parseMCPHTTPRequest(Data(head.utf8).prefix(20)), .incomplete)
        XCTAssertEqual(parseMCPHTTPRequest(full.prefix(head.utf8.count + 5)), .incomplete)
        guard case .complete(let request, let consumed) = parseMCPHTTPRequest(full + Data("POST /mcp".utf8)) else {
            return XCTFail("Not read")
        }
        XCTAssertEqual(consumed, full.count)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/mcp")
        XCTAssertEqual(request.version, "HTTP/1.1")
        XCTAssertEqual(request.header("content-type"), "application/json")
        XCTAssertEqual(request.header("HOST"), "127.0.0.1:41740")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), body)

        guard case .complete(let get, _) = parseMCPHTTPRequest(Data("GET /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)) else {
            return XCTFail("A request with no body is complete")
        }
        XCTAssertEqual(get.body, Data())
    }

    func testOversizedMalformedOrChunkedRequestsAreRefusedBeforeTheirBodyIsKept() {
        XCTAssertEqual(status(parseMCPHTTPRequest(Data(("POST /mcp HTTP/1.1\r\nX-Long: " + String(repeating: "a", count: 200)).utf8),
            maxHeaderBytes: 100)), 431)
        XCTAssertEqual(status(parseMCPHTTPRequest(Data("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000\r\n\r\n".utf8),
            maxBodyBytes: 100)), 413, "Refused from its length, before the body arrives")
        XCTAssertEqual(status(parseMCPHTTPRequest(Data("POST /mcp HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))), 411)
        XCTAssertEqual(status(parseMCPHTTPRequest(Data("HELLO\r\n\r\n".utf8))), 400)
        XCTAssertEqual(status(parseMCPHTTPRequest(Data("POST /mcp HTTP/1.1\r\nContent-Length: -4\r\n\r\n".utf8))), 400)
        XCTAssertEqual(status(parseMCPHTTPRequest(Data("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n".utf8))), 400)
        XCTAssertEqual(status(parseMCPHTTPRequest(Data("POST /mcp HTTP/2.0\r\nHost: localhost\r\n\r\n".utf8))), 505)
    }

    func testAResponseCarriesItsLengthAndWhetherTheConnectionStays() {
        let response = MCPHTTPResponse(status: 200, headers: [MCPHTTPHeader(name: "Content-Type", value: "application/json")],
            body: Data("{}".utf8))
        let open = String(decoding: response.serialized(keepAlive: true), as: UTF8.self)
        XCTAssertTrue(open.hasPrefix("HTTP/1.1 200 OK\r\n"), open)
        XCTAssertTrue(open.contains("Content-Type: application/json\r\n"), open)
        XCTAssertTrue(open.contains("Content-Length: 2\r\n"), open)
        XCTAssertTrue(open.contains("Connection: keep-alive\r\n"), open)
        XCTAssertTrue(open.hasSuffix("\r\n\r\n{}"), open)
        XCTAssertTrue(String(decoding: response.serialized(keepAlive: false), as: UTF8.self).contains("Connection: close\r\n"))
        XCTAssertTrue(String(decoding: MCPHTTPResponse(status: 401).serialized(keepAlive: false), as: UTF8.self)
            .hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    }

    func testATokenIsNeededOnlyWhenOneIsRequiredAndThenMustMatchExactly() {
        XCTAssertTrue(mcpRequestIsAuthorized(authorization: nil, token: nil))
        XCTAssertTrue(mcpRequestIsAuthorized(authorization: "Bearer anything", token: nil))
        let token = "s3cr3t-Token_value"
        XCTAssertTrue(mcpRequestIsAuthorized(authorization: "Bearer \(token)", token: token))
        XCTAssertTrue(mcpRequestIsAuthorized(authorization: "bearer \(token)", token: token), "The scheme's case doesn't matter")
        for header: String? in [nil, "", "Bearer", "Bearer ", "Bearer s3cr3t-token_value", "Bearer \(token)x",
                                "Bearer \(token.dropLast())", "Basic \(token)", token, "Bearer  \(token)"] {
            XCTAssertFalse(mcpRequestIsAuthorized(authorization: header, token: token), header ?? "nil")
        }
    }

    func testATokenIsSavedForTheUserAloneAndANewOneReplacesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-mcp-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("mcp-server-token")
        let saved = mcpServerTokenURL
        mcpServerTokenURL = { url }
        defer { mcpServerTokenURL = saved }

        XCTAssertNil(readMCPServerToken())
        let first = try generateMCPServerToken()
        XCTAssertGreaterThanOrEqual(first.count, 43, "At least 256 random bits")
        XCTAssertTrue(first.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }, first)
        XCTAssertEqual(readMCPServerToken(), first)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let second = try generateMCPServerToken()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(readMCPServerToken(), second)
        try " \n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(readMCPServerToken(), "A blank file holds no token")
    }
}
