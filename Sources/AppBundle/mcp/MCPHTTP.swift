import CryptoKit
import Foundation

/// The most a request's line and headers may take, and its body.
let mcpMaxHeaderBytes = 16 * 1024
let mcpMaxBodyBytes = 16 * 1024 * 1024

struct MCPHTTPHeader: Equatable, Sendable {
    let name: String
    let value: String
}

struct MCPHTTPRequest: Equatable, Sendable {
    var method: String
    var target: String
    var version: String
    var headers: [MCPHTTPHeader]
    var body: Data

    /// The first header with this name, in any case.
    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// HTTP/1.1 keeps the connection unless the client says `close`; HTTP/1.0 doesn't.
    var keepsAlive: Bool {
        let connection = header("Connection")?.lowercased() ?? ""
        return version == "HTTP/1.1" ? !connection.contains("close") : connection.contains("keep-alive")
    }
}

enum MCPHTTPParseResult: Equatable, Sendable {
    /// More bytes are needed.
    case incomplete
    case complete(MCPHTTPRequest, consumed: Int)
    /// Answered with this status, then the connection closes.
    case invalid(status: Int, message: String)
}

/// One HTTP/1.x request from the start of `data`, its body sized by `Content-Length` alone. Chunked bodies
/// aren't read. Too large a head or body is refused as soon as that's known, before the rest arrives.
func parseMCPHTTPRequest(_ data: Data, maxHeaderBytes: Int = mcpMaxHeaderBytes,
                         maxBodyBytes: Int = mcpMaxBodyBytes) -> MCPHTTPParseResult {
    let separator = Data("\r\n\r\n".utf8)
    guard let end = data.range(of: separator) else {
        return data.count > maxHeaderBytes ? .invalid(status: 431, message: "Request headers are too large") : .incomplete
    }
    let headLength = end.lowerBound - data.startIndex
    guard headLength <= maxHeaderBytes else { return .invalid(status: 431, message: "Request headers are too large") }
    guard let head = String(data: data[data.startIndex ..< end.lowerBound], encoding: .utf8) else {
        return .invalid(status: 400, message: "Request headers aren't UTF-8")
    }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
    guard requestLine.count == 3, !requestLine[0].isEmpty, requestLine[1].hasPrefix("/") || requestLine[1] == "*",
          requestLine[2].hasPrefix("HTTP/")
    else { return .invalid(status: 400, message: "Malformed request line") }
    let version = String(requestLine[2])
    guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
        return .invalid(status: 505, message: "Only HTTP/1.1 is supported")
    }
    var headers: [MCPHTTPHeader] = []
    for line in lines {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
              !line[..<colon].contains(where: \.isWhitespace)
        else { return .invalid(status: 400, message: "Malformed header") }
        headers.append(MCPHTTPHeader(name: String(line[..<colon]),
            value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
    }
    let request = MCPHTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), version: version,
        headers: headers, body: Data())
    if request.header("Transfer-Encoding") != nil {
        return .invalid(status: 411, message: "Send the body with a Content-Length")
    }
    let lengths = headers.filter { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
    var bodyLength = 0
    if !lengths.isEmpty {
        let text = lengths[0].value
        guard lengths.count == 1, !text.isEmpty, text.allSatisfy({ ("0" ... "9").contains($0) }), let value = Int(text) else {
            return .invalid(status: 400, message: "Malformed Content-Length")
        }
        bodyLength = value
    }
    guard bodyLength <= maxBodyBytes else { return .invalid(status: 413, message: "Request body is too large") }
    let bodyStart = end.upperBound
    guard data.endIndex - bodyStart >= bodyLength else { return .incomplete }
    var complete = request
    complete.body = Data(data[bodyStart ..< bodyStart + bodyLength])
    return .complete(complete, consumed: bodyStart + bodyLength - data.startIndex)
}

struct MCPHTTPResponse: Equatable, Sendable {
    var status: Int
    var headers: [MCPHTTPHeader] = []
    var body = Data()

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(mcpHTTPReason(status))\r\n"
        for header in headers { head += "\(header.name): \(header.value)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func json(_ value: MCPJSON, status: Int = 200) -> Self {
        MCPHTTPResponse(status: status, headers: [MCPHTTPHeader(name: "Content-Type", value: "application/json")], body: value.encoded())
    }

    /// A refusal: a short plain-text reason, never anything the request carried.
    static func refusal(_ status: Int, _ reason: String, headers: [MCPHTTPHeader] = []) -> Self {
        MCPHTTPResponse(status: status, headers: [MCPHTTPHeader(name: "Content-Type", value: "text/plain; charset=utf-8")] + headers,
            body: Data((reason + "\n").utf8))
    }
}

private func mcpHTTPReason(_ status: Int) -> String {
    switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        case 505: "HTTP Version Not Supported"
        default: "Status"
    }
}

/// Whether a request may proceed: always without a required token, otherwise only with
/// `Authorization: Bearer <token>`. Both are hashed first, so the comparison takes as long whatever
/// the header holds.
func mcpRequestIsAuthorized(authorization: String?, token: String?) -> Bool {
    guard let token else { return true }
    guard let authorization, authorization.count > 7,
          authorization.prefix(7).caseInsensitiveCompare("Bearer ") == .orderedSame
    else { return false }
    let offered = SHA256.hash(data: Data(authorization.dropFirst(7).utf8))
    let expected = SHA256.hash(data: Data(token.utf8))
    var difference: UInt8 = 0
    for (a, b) in zip(offered, expected) { difference |= a ^ b }
    return difference == 0
}
