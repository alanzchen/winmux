@testable import AppBundle
import Common
import XCTest

/// `[mcp-server]` in the config, and its rows in Settings.
@MainActor
final class MCPServerConfigTest: XCTestCase {
    func testTheServerIsOffByDefaultOnItsOwnPortWithNoToken() {
        XCTAssertEqual(defaultConfig.mcpServer, MCPServerConfig(enabled: false, port: 41740, requireToken: false))
        XCTAssertEqual(parseConfig("start-at-login = false\n").config.mcpServer, MCPServerConfig())
    }

    func testTheMCPServerSectionIsRead() {
        let parsed = parseConfig("""
            [mcp-server]
            enabled = true
            port = 5123
            require-token = true
            """)
        XCTAssertEqual(parsed.errors.descriptions, [])
        XCTAssertEqual(parsed.config.mcpServer, MCPServerConfig(enabled: true, port: 5123, requireToken: true))
    }

    /// No key makes it listen anywhere but 127.0.0.1: `tailscale` and `listen` are unknown, as any other key is.
    func testAPrivilegedOrImpossiblePortOrAnUnknownKeyIsAnError() {
        for text in ["[mcp-server]\nport = 80\n", "[mcp-server]\nport = 70000\n", "[mcp-server]\nlisten = '0.0.0.0'\n",
                     "[mcp-server]\ntoken = 'abc'\n", "[mcp-server]\ntailscale = true\n"] {
            XCTAssertFalse(parseConfig(text).errors.isEmpty, text)
        }
    }

    func testSettingsShowsTheServeLinesForTheTailnetPortAndTheURLToUse() {
        XCTAssertEqual(mcpTailscaleServeCommand(port: 41741), "tailscale serve --bg --https=443 http://127.0.0.1:41741")
        XCTAssertEqual(mcpTailscaleServeOffCommand, "tailscale serve --https=443 off")
        XCTAssertEqual(mcpTailnetURL(machineName: "alans-macbook-pro"), "https://alans-macbook-pro.<tailnet>.ts.net/mcp")
        XCTAssertEqual(mcpTailnetURL(machineName: ""), "https://<name>.<tailnet>.ts.net/mcp")
    }

    func testDebugScreenshotsAreReadAndOffByDefault() {
        XCTAssertFalse(defaultConfig.mcpServer.debugScreenshots)
        let parsed = parseConfig("[mcp-server]\nenabled = true\ndebug-screenshots = true\n")
        XCTAssertEqual(parsed.errors.descriptions, [])
        XCTAssertTrue(parsed.config.mcpServer.debugScreenshots)
        XCTAssertFalse(parseConfig("[mcp-server]\ndebug-screenshots = 'yes'\n").errors.isEmpty)
        let row = SettingsCatalog.fields.first { $0.id == "mcp-server.debug-screenshots" }
        XCTAssertTrue(row?.help.contains("can't be redacted") == true, row?.help ?? "")
    }

    func testTheTailnetSettingsAreReadAndOffByDefault() {
        XCTAssertEqual(defaultConfig.mcpServer.tailnet, false)
        XCTAssertEqual(defaultConfig.mcpServer.tailnetPort, 41741)
        XCTAssertEqual(defaultConfig.mcpServer.tailnetName, "")
        let parsed = parseConfig("[mcp-server]\nenabled = true\ntailnet = true\ntailnet-port = 5124\ntailnet-name = 'Studio'\n")
        XCTAssertEqual(parsed.errors.descriptions, [])
        XCTAssertEqual(parsed.config.mcpServer, MCPServerConfig(enabled: true, tailnet: true, tailnetPort: 5124, tailnetName: "studio"))
        for text in ["[mcp-server]\ntailnet = true\nport = 5000\ntailnet-port = 5000\n", "[mcp-server]\ntailnet-name = 'not a name'\n",
                     "[mcp-server]\ntailnet-port = 80\n"] {
            XCTAssertFalse(parseConfig(text).errors.isEmpty, text)
        }
        XCTAssertFalse(parseConfig("[mcp-server]\ntailnet = true\nport = 5000\ntailnet-port = 5000\n").config.mcpServer.tailnet,
            "Never on with both on one port")
        XCTAssertEqual(parseConfig("[mcp-server]\nport = 41741\n").errors.descriptions, [], "Only a tailnet that's on needs its own port")
    }

    func testSettingsOffersTheServersRowsOnTheGeneralPageUsableOnlyWhileItsOn() throws {
        let fields = SettingsCatalog.fields.filter { $0.section == "mcp-server" }
        XCTAssertEqual(fields.map(\.id), ["mcp-server.enabled", "mcp-server.port", "mcp-server.require-token", "mcp-server.tailnet",
                                          "mcp-server.tailnet-port", "mcp-server.tailnet-name", "mcp-server.debug-screenshots"])
        XCTAssertTrue(fields.allSatisfy { $0.group.page == .general })
        var configuration = defaultConfig
        for field in fields.dropFirst() {
            XCTAssertFalse(field.availability(in: configuration).isAvailable, field.id)
        }
        configuration.mcpServer.enabled = true
        let needTailnet: Set<String> = ["tailnet-port", "tailnet-name"]
        for field in fields {
            XCTAssertEqual(field.availability(in: configuration).isAvailable, !needTailnet.contains(field.key), field.id)
        }
        configuration.mcpServer.tailnet = true
        for field in fields {
            XCTAssertTrue(field.availability(in: configuration).isAvailable, field.id)
        }
        let port = try XCTUnwrap(fields.first { $0.key == "port" })
        XCTAssertEqual(port.range(in: configuration), 1024 ... 65535)
        XCTAssertTrue(SettingsCatalog.results("mcp").contains { $0.id == "mcp-server.enabled" })
    }
}
