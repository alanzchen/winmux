@testable import AppBundle
import XCTest

/// Settings' Chrome setup against a synthetic app bundle and home folder. Never runs the real
/// CLI, writes Chrome's real host manifest or opens Chrome.
final class ChromeExtensionSetupTest: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ChromeExtensionSetupTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// An app with the extension's files and a helper script standing in for the CLI.
    private func app(helper script: String?) throws -> URL {
        let app = root.appendingPathComponent("WinMux.app")
        let folder = app.appendingPathComponent("Contents/Resources/WinMuxTabs-Chrome")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in [("manifest.json", "{\"manifest_version\":3}"), ("background.js", "new"), ("shared.js", "shared")] {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        if let script {
            let helper = app.appendingPathComponent("Contents/Helpers/winmux")
            try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n\(script)\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        }
        return app
    }

    func testSetupRegistersTheHostThroughTheEmbeddedCLIAndReplacesTheCopiedFolderWhole() async throws {
        let log = root.appendingPathComponent("arguments")
        let app = try app(helper: "echo \"$@\" > '\(log.path)'")
        let home = root.appendingPathComponent("home")
        // An earlier setup's copy, with a file the new extension no longer has.
        let earlier = ChromeExtensionSetup.folder(home: home)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: earlier.appendingPathComponent("background.js"))
        try Data("gone".utf8).write(to: earlier.appendingPathComponent("stale.js"))

        let folder = try await ChromeExtensionSetup.run(app: app, home: home)
        XCTAssertEqual(folder.path, home.appendingPathComponent("Library/Application Support/WinMux/WinMuxTabs-Chrome").path)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "chrome-extension install\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["background.js", "manifest.json", "shared.js"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("background.js"), encoding: .utf8), "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["WinMuxTabs-Chrome"], "No staged copy is left beside it")
    }

    func testAFailingOrHangingHostInstallIsReportedAndCopiesNothing() async throws {
        let home = root.appendingPathComponent("home")
        do {
            _ = try await ChromeExtensionSetup.run(app: try app(helper: "echo 'Run chrome-extension install with the CLI inside your installed WinMux.app.' >&2; exit 1"), home: home)
            XCTFail("A failed install must say so")
        } catch {
            XCTAssertEqual(error as? ChromeExtensionSetup.Failure,
                           .hostInstall("Run chrome-extension install with the CLI inside your installed WinMux.app."))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ChromeExtensionSetup.folder(home: home).path))

        let hanging = root.appendingPathComponent("hanging")
        let helper = hanging.appendingPathComponent("winmux")
        try FileManager.default.createDirectory(at: hanging, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let started = Date()
        do {
            try await ChromeExtensionSetup.installHost(helper: helper, timeout: 0.5)
            XCTFail("A helper that never finishes is stopped")
        } catch {
            guard case .hostInstall = error as? ChromeExtensionSetup.Failure else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testOnlyAnAppWithTheExtensionAndItsCLIOffersSetup() async throws {
        let bare = try app(helper: nil)
        XCTAssertNil(ChromeExtensionSetup.bundled(in: bare), "A development build has no embedded CLI")
        do {
            _ = try await ChromeExtensionSetup.run(app: bare, home: root.appendingPathComponent("home"))
            XCTFail("Nothing to set up")
        } catch { XCTAssertEqual(error as? ChromeExtensionSetup.Failure, .notBundled) }
        XCTAssertNotNil(ChromeExtensionSetup.bundled(in: try app(helper: "exit 0")))
    }
}
