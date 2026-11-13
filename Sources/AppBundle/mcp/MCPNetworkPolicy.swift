import Darwin
import Foundation

/// The one address the server listens on: this Mac's loopback, never any other interface.
let mcpLoopbackAddress = "127.0.0.1"

/// Whether a peer may be served: this Mac's loopback only. Anyone else is refused even if a listener accepted
/// the connection.
func mcpPeerIsAllowed(_ address: String) -> Bool {
    MCPIPAddress(address)?.isLoopback == true
}

/// Whether a request's `Host` names this server: localhost or a loopback address. A page an attacker's DNS points
/// at this Mac names the attacker's name.
func mcpHostIsAllowed(_ host: String?) -> Bool {
    guard let host, let name = mcpHostName(fromAuthority: host) else { return false }
    return mcpNameIsLoopback(name)
}

/// A browser's request names the page it came from. Only a page from this Mac's loopback may ask; any other page,
/// `null` included, is refused. A request with no `Origin` isn't a browser's.
func mcpOriginIsAllowed(_ origin: String?) -> Bool {
    guard let origin else { return true }
    guard let components = URLComponents(string: origin), let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty
    else { return false }
    return mcpNameIsLoopback(mcpNormalizedHostName(host))
}

private func mcpNameIsLoopback(_ name: String) -> Bool {
    name == "localhost" || MCPIPAddress(name)?.isLoopback == true
}

/// The host of `host[:port]` or `[v6][:port]`, lowercased, without a trailing dot.
private func mcpHostName(fromAuthority authority: String) -> String? {
    let trimmed = authority.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("[") {
        guard let close = trimmed.firstIndex(of: "]") else { return nil }
        let rest = trimmed[trimmed.index(after: close)...]
        guard rest.isEmpty || rest.hasPrefix(":") else { return nil }
        return mcpNormalizedHostName(String(trimmed[trimmed.index(after: trimmed.startIndex) ..< close]))
    }
    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count <= 2, let name = parts.first, !name.isEmpty else { return nil }
    return mcpNormalizedHostName(String(name))
}

private func mcpNormalizedHostName(_ name: String) -> String {
    var result = name.lowercased()
    if result.hasPrefix("["), result.hasSuffix("]") { result = String(result.dropFirst().dropLast()) }
    while result.hasSuffix(".") { result.removeLast() }
    return result
}

/// An IPv4 or IPv6 address, as bytes. IPv4-mapped IPv6 addresses count as their IPv4 address.
struct MCPIPAddress: Equatable, Sendable {
    let bytes: [UInt8]

    init?(_ text: String) {
        let unscoped = String(text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        var v4 = in_addr()
        if inet_pton(AF_INET, unscoped, &v4) == 1 {
            self.init(bytes: withUnsafeBytes(of: &v4) { Array($0) })
            return
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, unscoped, &v6) == 1 else { return nil }
        self.init(bytes: withUnsafeBytes(of: &v6) { Array($0) })
    }

    /// From 4 or 16 bytes in network order.
    init?(bytes raw: [UInt8]) {
        switch raw.count {
            case 4: bytes = raw
            case 16 where raw[0 ..< 10].allSatisfy({ $0 == 0 }) && raw[10] == 0xFF && raw[11] == 0xFF: bytes = Array(raw[12 ..< 16])
            case 16: bytes = raw
            default: return nil
        }
    }

    var isIPv4: Bool { bytes.count == 4 }

    var isLoopback: Bool {
        isIPv4 ? bytes[0] == 127 : bytes == [UInt8](repeating: 0, count: 15) + [1]
    }

    /// The canonical text form.
    var text: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = isIPv4 ? AF_INET : AF_INET6
        let written = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
        guard written != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
