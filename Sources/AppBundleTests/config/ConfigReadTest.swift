@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class ConfigReadTest: XCTestCase {
    override func setUp() {
        super.setUp()
        installConfigErrorStateReset()
    }

    func testSelectedMissingConfigReportsReadFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "missing.toml")

        assertReadFailure(url)
    }

    func testSelectedDirectoryReportsReadFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        assertReadFailure(directory)
    }

    func testSelectedInvalidUtf8ConfigReportsReadFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "invalid.toml")
        try Data([0xC3, 0x28]).write(to: url)

        assertReadFailure(url)
    }

    func testReadFailuresRetainLiveConfigurationAndLocation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidUrl = directory.appending(path: "invalid.toml")
        try Data([0xC3, 0x28]).write(to: invalidUrl)

        let previousConfig = config
        let previousUrl = configUrl
        defer {
            config = previousConfig
            configUrl = previousUrl
        }
        config.tabGroupPadding = 47
        config.autoReloadConfig = false
        config.workspaceSidebar.workspaceLabels = ["preserved": "Live configuration"]
        configUrl = directory.appending(path: "live.toml")
        let liveUrl = configUrl

        for selectedUrl in [directory.appending(path: "missing.toml"), directory, invalidUrl] {
            let result = try await reloadConfig(
                args: ReloadConfigCmdArgs(rawArgs: []).copy(\.noGui, true),
                forceConfigUrl: selectedUrl,
            )
            XCTAssertFalse(result.isOk)
            XCTAssertFalse(result.appliedConfig)
            XCTAssertTrue(result.stdout.contains(selectedUrl.path))
            XCTAssertEqual(config.tabGroupPadding, 47)
            XCTAssertEqual(config.workspaceSidebar.workspaceLabels, ["preserved": "Live configuration"])
            XCTAssertEqual(configUrl, liveUrl)
        }
    }

    func testBundledDefaultConfigStillLoads() throws {
        let result = readConfig(forceConfigUrl: defaultConfigUrl)
        XCTAssertEqual(result.parseConfigResult.errors, [])
        XCTAssertEqual(result.configUrl, defaultConfigUrl)
    }

    func testSelectedValidConfigStillParses() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "valid.toml")
        try "tab-group-padding = 47".write(to: url, atomically: true, encoding: .utf8)

        let result = readConfig(forceConfigUrl: url)
        XCTAssertEqual(result.parseConfigResult.errors, [])
        XCTAssertEqual(result.parseConfigResult.config.tabGroupPadding, 47)
        XCTAssertEqual(result.configUrl, url)
    }

    private func assertReadFailure(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        let result = readConfig(forceConfigUrl: url).parseConfigResult
        XCTAssertFalse(result.allowReloadConfig, "A selected unreadable config must not load", file: file, line: line)
        let error = result.errors.map { $0.description(.error) }.joined(separator: "\n")
        XCTAssertTrue(error.contains(url.path), error, file: file, line: line)
        XCTAssertTrue(error.contains("utf8"), error, file: file, line: line)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "WinMuxConfigReadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
