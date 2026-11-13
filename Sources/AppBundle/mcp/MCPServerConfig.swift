import Common
import Foundation
import TOMLKit

/// The port WinMux's MCP server listens on unless the config names another.
let mcpServerDefaultPort = 41740
let mcpServerPortRange = 1024 ... 65535

/// `[mcp-server]`: WinMux's MCP server over HTTP. Off unless turned on. On, it listens on 127.0.0.1 only, so only
/// this Mac reaches it. With `require-token`, every request must carry the token Settings shows.
struct MCPServerConfig: ConvenienceCopyable, Equatable, Sendable {
    var enabled = false
    var port = mcpServerDefaultPort
    var requireToken = false
}

func parseMCPServer(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace, _ errors: inout [TomlParseError]) -> MCPServerConfig {
    parseTable(raw, MCPServerConfig(), [
        "enabled": Parser(\.enabled, parseBool),
        "port": Parser(\.port) { raw, backtrace in
            parseInt(raw, backtrace).flatMap { port in
                mcpServerPortRange.contains(port)
                    ? .success(port)
                    : .failure(.semantic(backtrace, "The port must be from \(mcpServerPortRange.lowerBound) to \(mcpServerPortRange.upperBound)"))
            }
        },
        "require-token": Parser(\.requireToken, parseBool),
    ], backtrace, &errors)
}
