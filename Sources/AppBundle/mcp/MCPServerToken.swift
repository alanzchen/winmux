import Common
import Darwin
import Foundation
import Security

/// The MCP server's access token lives in its own file, readable only by the user, never in the config,
/// which people share. Nil in unit tests, which set their own.
@MainActor var mcpServerTokenURL: @MainActor () -> URL? = {
    guard !isUnitTest, let saved = try? savedWorkspacesFileUrl() else { return nil }
    return saved.deletingLastPathComponent().appendingPathComponent("mcp-server-token")
}

/// The saved token, if there's a usable one: printable ASCII without spaces, as one line.
@MainActor func readMCPServerToken() -> String? {
    guard let url = mcpServerTokenURL(), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, token.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return nil }
    return token
}

/// A new random token of 256 bits, saved in place of any other with permissions for the user alone. Clients
/// using the old one are refused from then on.
@MainActor @discardableResult func generateMCPServerToken() throws -> String {
    guard let url = mcpServerTokenURL() else { throw MCPServerTokenError.nowhereToSave }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MCPServerTokenError.noRandomness }
    let token = Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Written beside it with the right permissions first, then moved over it, so it's never readable by others.
    let staging = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
    let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw MCPServerTokenError.cantWrite(staging.path) }
    let line = Array((token + "\n").utf8)
    let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    close(descriptor)
    guard written == line.count else {
        try? FileManager.default.removeItem(at: staging)
        throw MCPServerTokenError.cantWrite(staging.path)
    }
    guard rename(staging.path, url.path) == 0 else {
        try? FileManager.default.removeItem(at: staging)
        throw MCPServerTokenError.cantWrite(url.path)
    }
    return token
}

enum MCPServerTokenError: Error, LocalizedError {
    case nowhereToSave
    case noRandomness
    case cantWrite(String)

    var errorDescription: String? {
        switch self {
            case .nowhereToSave: "WinMux has no folder to save the MCP server's token in."
            case .noRandomness: "macOS didn't provide random bytes for a token."
            case .cantWrite(let path): "Couldn't write the MCP server's token to \(path)."
        }
    }
}
