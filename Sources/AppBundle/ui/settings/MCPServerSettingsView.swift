import AppKit
import SwiftUI

/// The server's URL on this port.
func mcpServerURL(port: Int) -> String { "http://\(mcpLoopbackAddress):\(port)\(mcpServerPath)" }

/// What Alan runs to forward his tailnet to the tailnet port. WinMux never runs it.
func mcpTailscaleServeCommand(port: Int) -> String { "tailscale serve --bg --https=443 http://\(mcpLoopbackAddress):\(port)" }
/// What stops that forwarding.
let mcpTailscaleServeOffCommand = "tailscale serve --https=443 off"

/// The URL a device in the tailnet uses: WinMux doesn't ask Tailscale for the tailnet's name, so it's left to fill in.
func mcpTailnetURL(machineName: String) -> String {
    "https://\(machineName.isEmpty ? "<name>" : machineName).<tailnet>.ts.net\(mcpServerPath)"
}

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
    @ObservedObject private var screenRecording = debugScreenRecordingPermission
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
                if settings.tailnet { tailnet }
                if settings.debugScreenshots { debugScreenshots }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text((settings.tailnet
                        ? "Apps on this Mac, and anyone your tailnet lets reach it through tailscale serve, can reach the server. "
                        : "Only this Mac can reach the server. ")
                    + "Any app that can, can do what the winmux command line can, including closing windows. See docs/mcp-server.md.")
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
    private var status: some View { statusLabel(server.state, listening: "Listening") }

    @ViewBuilder
    private func statusLabel(_ state: MCPServerState, listening: String) -> some View {
        switch state {
            case .off: Label("Not listening", systemImage: "circle").foregroundStyle(.secondary)
            case .starting: Label("Starting…", systemImage: "circle.dotted").foregroundStyle(.secondary)
            case .listening: Label(listening, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The tailnet port: whether it listens, the URL a device in the tailnet uses, and the `tailscale serve` lines
    /// to copy. WinMux runs neither.
    private var tailnet: some View {
        let port = server.tailnetPort ?? settings.tailnetPort
        return VStack(alignment: .leading, spacing: 6) {
            Text("Tailnet access").font(.callout.weight(.medium))
            statusLabel(server.tailnetState, listening: "Listening on 127.0.0.1:\(port) for tailscale serve")
            copyableLine(mcpTailnetURL(machineName: server.tailnetMachineName), button: "Copy URL")
            Text("WinMux doesn't run Tailscale. To forward your tailnet to this port, run in Terminal:")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            copyableLine(mcpTailscaleServeCommand(port: port), button: "Copy")
            Text("To stop forwarding, run the line below. Turning Allow access from my tailnet off closes the port and every "
                + "connection it let in, even while the serve rule remains.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            copyableLine(mcpTailscaleServeOffCommand, button: "Copy")
            if !settings.requireToken {
                Label("Without a token, anyone your tailnet lets reach this Mac can use the server. Turn on Require access token "
                    + "to ask for it too.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("settings.mcp-server.tailnet")
    }

    /// Allow debug screenshots: whether macOS allows them, the way to allow them, and what an image shows.
    private var debugScreenshots: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Debug screenshots").font(.callout.weight(.medium))
            if server.screenCaptureAllowed == true {
                Label("macOS allows WinMux to record the screen", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("macOS hasn't allowed WinMux to record the screen", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                HStack {
                    if !screenRecording.didRequest {
                        Button("Allow Screen Recording…") {
                            screenRecording.requestFromSettings()
                            server.refreshScreenCapturePermission()
                        }
                    }
                    Button("Open Privacy Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Check Again") { server.refreshScreenCapturePermission() }
                }
                Text("Until it does, recordings keep WinMux's state and events only. You may need to quit and reopen WinMux after allowing it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Screenshots and recorded frames show whatever is on screen, WinMux's own panels and private content included, "
                + "and can't be redacted. They're kept in memory only, never written to disk. While a recording runs, the menu "
                + "bar shows it and its menu can stop it; macOS shows its own screen recording indicator too.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if settings.tailnet, !settings.requireToken {
                Label("Requests from your tailnet get no images until Require access token is on.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { server.refreshScreenCapturePermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            server.refreshScreenCapturePermission()
        }
        .accessibilityIdentifier("settings.mcp-server.debug-screenshots")
    }

    private func copyableLine(_ text: String, button: String) -> some View {
        HStack {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button) { copy(text) }
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
