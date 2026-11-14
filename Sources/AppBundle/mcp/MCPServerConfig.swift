import Common
import Foundation
import TOMLKit

/// The port WinMux's MCP server listens on unless the config names another.
let mcpServerDefaultPort = 41740
/// The port of its listener for requests from the tailnet, which `tailscale serve` forwards to.
let mcpServerDefaultTailnetPort = 41741
let mcpServerPortRange = 1024 ... 65535

/// `[mcp-server]`: WinMux's MCP server over HTTP. Off unless turned on. On, it listens on 127.0.0.1 only, so only
/// this Mac reaches it. With `tailnet`, it also listens on a second port of 127.0.0.1 for requests `tailscale serve`
/// forwards from the tailnet; WinMux never runs Tailscale. With `require-token`, every request on either port must
/// carry the token Settings shows.
struct MCPServerConfig: ConvenienceCopyable, Equatable, Sendable {
    var enabled = false
    var port = mcpServerDefaultPort
    var requireToken = false
    var tailnet = false
    var tailnetPort = mcpServerDefaultTailnetPort
    /// This Mac's machine name in the tailnet, the first label of its MagicDNS name. Empty: this Mac's local
    /// hostname, lowercased.
    var tailnetName = ""
    /// Offers the debug screenshot and recording tools, which need macOS's Screen Recording permission.
    var debugScreenshots = false
}

func parseMCPServer(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace, _ errors: inout [TomlParseError]) -> MCPServerConfig {
    var config = parseTable(raw, MCPServerConfig(), [
        "enabled": Parser(\.enabled, parseBool),
        "port": Parser(\.port, parseMCPPort),
        "require-token": Parser(\.requireToken, parseBool),
        "tailnet": Parser(\.tailnet, parseBool),
        "tailnet-port": Parser(\.tailnetPort, parseMCPPort),
        "debug-screenshots": Parser(\.debugScreenshots, parseBool),
        "tailnet-name": Parser(\.tailnetName) { raw, backtrace in
            parseString(raw, backtrace).flatMap { name in
                let label = name.trimmingCharacters(in: .whitespaces).lowercased()
                return label.isEmpty || mcpIsDNSLabel(label)
                    ? .success(label)
                    : .failure(.semantic(backtrace, "A machine name is letters, digits and hyphens, up to 63, such as alans-macbook-pro"))
            }
        },
    ], backtrace, &errors)
    if config.tailnet, config.tailnetPort == config.port {
        errors.append(.semantic(backtrace, "tailnet-port must differ from port"))
        config.tailnet = false
    }
    return config
}

private func parseMCPPort(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<Int> {
    parseInt(raw, backtrace).flatMap { port in
        mcpServerPortRange.contains(port)
            ? .success(port)
            : .failure(.semantic(backtrace, "The port must be from \(mcpServerPortRange.lowerBound) to \(mcpServerPortRange.upperBound)"))
    }
}

/// One DNS label: letters, digits and hyphens, 1 to 63, not starting or ending with a hyphen.
func mcpIsDNSLabel(_ label: String) -> Bool {
    guard (1 ... 63).contains(label.count), label.first != "-", label.last != "-" else { return false }
    return label.unicodeScalars.allSatisfy { ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == "-" }
}
