@testable import AppBundle
import Network
import XCTest

/// Whom and what the MCP server answers: this Mac's loopback, by its peer, its Host and a browser's Origin.
final class MCPNetworkPolicyTest: XCTestCase {
    func testOnlyLoopbackPeersAreServed() {
        for peer in ["127.0.0.1", "127.0.0.53", "::1", "::ffff:127.0.0.1"] {
            XCTAssertTrue(mcpPeerIsAllowed(peer), peer)
        }
        for peer in ["100.101.102.103", "::ffff:100.101.102.103", "fd7a:115c:a1e0::1", "192.168.1.20", "10.0.0.1",
                     "fe80::1", "8.8.8.8", "0.0.0.0", "::", "", "not-an-address", "localhost"] {
            XCTAssertFalse(mcpPeerIsAllowed(peer), peer)
        }
    }

    /// A connection's peer, as the check before anything is read sees it.
    func testAConnectionsPeerIsReadAsItsNumericAddress() throws {
        func peer(_ host: NWEndpoint.Host) -> String { mcpPeerAddress(.hostPort(host: host, port: 41740)) }
        XCTAssertEqual(peer(.ipv4(try XCTUnwrap(IPv4Address("127.0.0.1")))), "127.0.0.1")
        XCTAssertEqual(peer(.ipv4(try XCTUnwrap(IPv4Address("192.168.1.20")))), "192.168.1.20")
        XCTAssertEqual(peer(.ipv6(try XCTUnwrap(IPv6Address("::1")))), "::1")
        XCTAssertEqual(peer(.ipv6(try XCTUnwrap(IPv6Address("::ffff:127.0.0.1")))), "127.0.0.1")
        XCTAssertEqual(peer(.name("evil.example", nil)), "")
        XCTAssertEqual(mcpPeerAddress(.unix(path: "/tmp/socket")), "")
        XCTAssertFalse(mcpPeerIsAllowed(peer(.name("localhost", nil))), "Only numeric addresses are trusted")
    }

    /// DNS rebinding: a page whose name an attacker points at this Mac names that name, not this server.
    func testTheHostHeaderMustNameThisServer() {
        for host in ["127.0.0.1:41740", "localhost:41740", "LOCALHOST", "localhost.", "[::1]:41740", "127.0.0.1"] {
            XCTAssertTrue(mcpHostIsAllowed(host), host)
        }
        for host: String? in [nil, "", "evil.example:41740", "192.168.1.20:41740", "100.101.102.103:41740", "mac-studio",
                              "mac-studio.tail1234.ts.net:41740", "localhost.evil.example", "::1"] {
            XCTAssertFalse(mcpHostIsAllowed(host), host ?? "nil")
        }
    }

    /// The tailnet port answers only a request naming this Mac as `tailscale serve` passes it on: rebinding a name
    /// an attacker controls to this Mac names the attacker's name, not this Mac's under ts.net.
    func testATailnetRequestMustNameThisMachineUnderTsNet() {
        let name = "alans-macbook-pro"
        for host in ["alans-macbook-pro.tail1234.ts.net", "Alans-MacBook-Pro.tail1234.ts.net", "alans-macbook-pro.tail1234.ts.net.",
                     "alans-macbook-pro.tail1234.ts.net:443", "alans-macbook-pro.yak-bebop.ts.net"] {
            XCTAssertTrue(mcpTailnetHostIsAllowed(host, machineName: name), host)
        }
        for host: String? in [nil, "", "localhost", "localhost:41741", "127.0.0.1:41741", "[::1]:41741", "100.101.102.103",
                              "other-mac.tail1234.ts.net", "alans-macbook-pro.ts.net", "alans-macbook-pro.tail1234.ts.net.evil.example",
                              "alans-macbook-pro.tail1234.evil.net", "evil.alans-macbook-pro.tail1234.ts.net",
                              "alans-macbook-pro.tail1234.ts.net:8443", "alans-macbook-pro.tail_1234.ts.net", "alans-macbook-pro"] {
            XCTAssertFalse(mcpTailnetHostIsAllowed(host, machineName: name), host ?? "nil")
        }
        XCTAssertFalse(mcpTailnetHostIsAllowed("x.tail1234.ts.net", machineName: ""), "Without a machine name, nothing passes")
    }

    func testATailnetBrowserMayAskOnlyFromThisSameHTTPSHost() {
        let host = "alans-macbook-pro.tail1234.ts.net"
        XCTAssertTrue(mcpTailnetOriginIsAllowed(nil, host: host), "Not a browser")
        XCTAssertTrue(mcpTailnetOriginIsAllowed("https://alans-macbook-pro.tail1234.ts.net", host: host))
        XCTAssertTrue(mcpTailnetOriginIsAllowed("https://Alans-MacBook-Pro.tail1234.ts.net", host: host + ":443"))
        for origin in ["http://alans-macbook-pro.tail1234.ts.net", "https://other-mac.tail1234.ts.net", "http://localhost:6274",
                       "null", "", "https://evil.example"] {
            XCTAssertFalse(mcpTailnetOriginIsAllowed(origin, host: host), origin)
        }
    }

    func testTheMachineNameIsTheConfiguredOneOrTheLocalHostNameLowercased() {
        XCTAssertEqual(mcpTailnetMachineName(configured: "", localHostName: "Alans-MacBook-Pro"), "alans-macbook-pro")
        XCTAssertEqual(mcpTailnetMachineName(configured: "studio", localHostName: "Alans-MacBook-Pro"), "studio")
        XCTAssertEqual(mcpTailnetMachineName(configured: "", localHostName: nil), "")
        XCTAssertEqual(mcpTailnetMachineName(configured: "", localHostName: "Not a label!"), "", "Then a name must be configured")
        XCTAssertEqual(mcpTailnetMachineName(configured: " Studio ", localHostName: nil), "studio", "However it's given")
        XCTAssertEqual(mcpTailnetMachineName(configured: "not a label", localHostName: "Alans-MacBook-Pro"), "", "Fails closed")
    }

    func testABrowsersOriginMustBeThisMacsLoopback() {
        XCTAssertTrue(mcpOriginIsAllowed(nil), "Not a browser")
        for origin in ["http://localhost:6274", "http://127.0.0.1:41740", "http://[::1]:3000", "https://localhost"] {
            XCTAssertTrue(mcpOriginIsAllowed(origin), origin)
        }
        for origin in ["null", "", "http://evil.example", "http://evil.example:41740", "file://", "chrome-extension://abc",
                       "http://192.168.1.20:41740", "https://mac-studio.tail1234.ts.net", "http://100.101.102.103:41740"] {
            XCTAssertFalse(mcpOriginIsAllowed(origin), origin)
        }
    }
}
