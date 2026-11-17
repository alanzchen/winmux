@testable import AppBundle
import AppKit
import Common
import XCTest

/// Carbon's review: a Sparkle update quits WinMux with NSApp.terminate, which never went through Quit WinMux's
/// preparation, so window-state.json wasn't written and parked windows weren't put back. Every way out now goes
/// through one preparation, once. A private notification center stands in for AppKit's, so the test process's
/// own observers aren't told it's quitting.
@MainActor
final class TerminationPreparationTest: XCTestCase {
    private var folder: URL!
    private var snapshotURL: URL!
    private var savedURL: (() throws -> URL)?
    private let center = NotificationCenter()

    override func setUp() async throws {
        setUpWorkspacesForTests()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-termination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        snapshotURL = folder.appendingPathComponent("window-state.json")
        savedURL = persistedFrozenWorldFileUrl
        persistedFrozenWorldFileUrl = { [snapshotURL] in snapshotURL! }
    }

    override func tearDown() async throws {
        if let savedURL { persistedFrozenWorldFileUrl = savedURL }
        setPendingPersistedFrozenWorldForTests(nil)
        try? FileManager.default.removeItem(at: folder)
    }

    /// What Quit WinMux does, without moving the test's windows.
    private func preparation(_ runs: @escaping () -> Void) -> TerminationPreparation {
        TerminationPreparation {
            runs()
            prepareManagedWindowsForTermination(runtimeReady: true, restoreWindows: {})
        }
    }

    func testTerminatingFromElsewhereSavesTheRestartSnapshotAsQuitDoes() throws {
        _ = TestWindow.new(id: 40, parent: Workspace.get(byName: "kept").rootTilingContainer)
        var runs = 0
        let owner = preparation { runs += 1 }
        owner.observeTermination(on: center)

        // Sparkle installing an update, or logging out: NSApp.terminate, then willTerminate.
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path), "window-state.json written")
    }

    func testQuitThenWillTerminatePreparesOnce() {
        var runs = 0
        let owner = preparation { runs += 1 }
        owner.observeTermination(on: center)
        owner.run() // Quit WinMux, the CLI, a signal or die()
        center.post(name: NSApplication.willTerminateNotification, object: nil) // then NSApp.terminate
        XCTAssertEqual(runs, 1)
        owner.run()
        XCTAssertEqual(runs, 1)
    }
}
