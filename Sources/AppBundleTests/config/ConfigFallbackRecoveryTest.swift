@testable import AppBundle
import Common
import Foundation
import XCTest

/// Astra's audit C2: a config that can't be applied as WinMux starts is replaced by the defaults. WinMux must still
/// watch the user's file, not the defaults standing in for it, so fixing the file recovers on its own: the fixed
/// config is applied, and the error item and the suspended write-back clear.
@MainActor
final class ConfigFallbackRecoveryTest: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var previousConfig: Config!
    private var previousConfigUrl: URL!
    private var previousActiveMode: String?

    override func setUp() async throws {
        setUpWorkspacesForTests()
        previousConfig = config
        previousConfigUrl = configUrl
        previousActiveMode = activeMode
        // No real hotkeys from these reloads.
        activeMode = nil
        resetConfigErrorStateForTests()
        TrayMenuModel.shared.isEnabled = true
        directory = FileManager.default.temporaryDirectory.appending(path: "config-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appending(path: "winmux.toml")
        // As `--config-path` would: the user's config is this file.
        setServerConfigLocationForTests(file.path)
    }

    override func tearDown() async throws {
        setServerConfigLocationForTests(nil)
        resetHotKeys()
        activeMode = previousActiveMode
        config = previousConfig
        configUrl = previousConfigUrl
        syncConfigFileWatcher()
        resetConfigErrorStateForTests()
        TrayMenuModel.shared.lastReloadConfigContainedWarnings = false
        WinMuxToastPanel.shared.dismiss()
        try? FileManager.default.removeItem(at: directory)
    }

    private func eventually(_ condition: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testFixingTheUsersBrokenConfigAfterAStartupFallbackReloadsItAndClearsTheErrorState() async throws {
        try "config-version = 2\ntab-group-padding = [\n".write(to: file, atomically: true, encoding: .utf8)
        try await loadConfigAtStartup(bootstrappedConfigUrl: nil)

        XCTAssertEqual(config.tabGroupPadding, defaultConfig.tabGroupPadding, "The defaults stand in")
        XCTAssertTrue(config.autoReloadConfig)
        XCTAssertEqual(configUrl.standardizedFileURL, file.standardizedFileURL, "Still the user's config, watched and edited")
        XCTAssertTrue(configErrorsPending)
        XCTAssertTrue(configWriteBackSuspended)
        XCTAssertNotNil(TrayMenuModel.shared.configErrorDetails)

        // The user fixes the file in an editor.
        try "config-version = 2\ntab-group-padding = 37\n".write(to: file, atomically: true, encoding: .utf8)
        let recovered = await eventually { !configErrorsPending && config.tabGroupPadding == 37 }
        XCTAssertTrue(recovered, "The fix was picked up without a manual reload")
        XCTAssertFalse(configWriteBackSuspended)
        XCTAssertNil(TrayMenuModel.shared.configErrorDetails)
        XCTAssertFalse(TrayMenuModel.shared.lastReloadConfigContainedWarnings)
        XCTAssertEqual(configUrl.standardizedFileURL, file.standardizedFileURL)
    }

    func testAConfigThatLoadsAtStartupIsTheOneWatched() async throws {
        try "config-version = 2\ntab-group-padding = 12\n".write(to: file, atomically: true, encoding: .utf8)
        try await loadConfigAtStartup(bootstrappedConfigUrl: nil)
        XCTAssertEqual(config.tabGroupPadding, 12)
        XCTAssertEqual(configUrl.standardizedFileURL, file.standardizedFileURL)
        XCTAssertFalse(configErrorsPending)
    }
}
