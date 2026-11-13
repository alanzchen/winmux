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

    func testSettingsOffersTheServersRowsOnTheGeneralPageUsableOnlyWhileItsOn() throws {
        let fields = SettingsCatalog.fields.filter { $0.section == "mcp-server" }
        XCTAssertEqual(fields.map(\.id), ["mcp-server.enabled", "mcp-server.port", "mcp-server.require-token"])
        XCTAssertTrue(fields.allSatisfy { $0.group.page == .general })
        var configuration = defaultConfig
        for field in fields.dropFirst() {
            XCTAssertFalse(field.availability(in: configuration).isAvailable, field.id)
        }
        configuration.mcpServer.enabled = true
        for field in fields {
            XCTAssertTrue(field.availability(in: configuration).isAvailable, field.id)
        }
        let port = try XCTUnwrap(fields.first { $0.key == "port" })
        XCTAssertEqual(port.range(in: configuration), 1024 ... 65535)
        XCTAssertTrue(SettingsCatalog.results("mcp").contains { $0.id == "mcp-server.enabled" })
    }
}
