import AppKit
import SwiftUI

/// The server's URL on this port.
func mcpServerURL(port: Int) -> String { "http://\(mcpLoopbackAddress):\(port)\(mcpServerPath)" }

/// A client config for `url`, as Claude Code's `.mcp.json` and other clients take it. The token is a
/// placeholder: copy it separately.
func mcpExampleClientConfig(url: String, requiresToken: Bool) -> String {
    let headers = requiresToken ? """
        ,
              "headers": { "Authorization": "Bearer <token>" }
        """ : ""
    return """
        {
          "mcpServers": {
            "winmux": {
              "type": "http",
              "url": "\(url)"\(headers)
            }
          }
        }
        """
}

/// Below the MCP server's rows in Settings: whether it's listening, its URL and a client config to copy, and its token.
struct MCPServerSettingsDetails: View {
    @ObservedObject var editor: SettingsEditor
    @ObservedObject var server: MCPServer = .shared
    @State private var problem: String?
    @State private var confirmsNewToken = false

    private var settings: MCPServerConfig { editor.projection.mcpServer }
    private var url: String? {
        guard server.state == .listening else { return nil }
        return mcpServerURL(port: server.port ?? settings.port)
    }

    var body: some View {
        if settings.enabled {
            VStack(alignment: .leading, spacing: 10) {
                status
                if let url {
                    HStack {
                        Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Copy URL") { copy(url) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Example client configuration").font(.callout.weight(.medium))
                        Text(mcpExampleClientConfig(url: url, requiresToken: settings.requireToken))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
                        Button("Copy Example Configuration") { copy(mcpExampleClientConfig(url: url, requiresToken: settings.requireToken)) }
                    }
                }
                if settings.requireToken { token }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text("Only this Mac can reach the server. Any app on it that can, can do what the winmux command line can, "
                    + "including closing windows. See docs/mcp-server.md.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5) }
            .accessibilityIdentifier("settings.mcp-server.details")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch server.state {
            case .off: Label("Not listening", systemImage: "circle").foregroundStyle(.secondary)
            case .starting: Label("Starting…", systemImage: "circle.dotted").foregroundStyle(.secondary)
            case .listening: Label("Listening", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var token: some View {
        HStack {
            Label(server.hasToken ? "Access token saved" : "No access token yet", systemImage: "key")
            Spacer()
            Button("Copy Token") {
                if let token = readMCPServerToken() { copy(token) }
            }
            .disabled(!server.hasToken)
            Button("Generate New Token…") {
                if server.hasToken { confirmsNewToken = true } else { generate() }
            }
            .disabled(serverArgs.isReadOnly)
        }
        .confirmationDialog("Generate a new access token?", isPresented: $confirmsNewToken) {
            Button("Generate New Token", role: .destructive) { generate() }
        } message: {
            Text("Clients using the current token are refused until you give them the new one.")
        }
    }

    private func generate() {
        do {
            try generateMCPServerToken()
            server.tokenDidChange()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
