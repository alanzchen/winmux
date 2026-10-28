@testable import AppBundle
import Foundation
import XCTest

@MainActor
final class StartupTerminationTest: XCTestCase {
    func testPartialStartupKeepsPreviousSnapshotAndRestoresManagedWindows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WinMuxStartupTerminationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotUrl = directory.appending(path: "window-state.json")
        let previousSnapshot = Data("previous session".utf8)
        try previousSnapshot.write(to: snapshotUrl)
        var didRestoreManagedWindows = false

        try await prepareManagedWindowsForTermination(
            runtimeReady: false,
            persistSession: { try? FileManager.default.removeItem(at: snapshotUrl) },
            restoreWindows: { didRestoreManagedWindows = true },
        )

        XCTAssertEqual(try Data(contentsOf: snapshotUrl), previousSnapshot)
        XCTAssertTrue(didRestoreManagedWindows)
    }

    func testReadyRuntimeSavesModelBeforeRestoringNativeWindows() async throws {
        var operations: [String] = []
        try await prepareManagedWindowsForTermination(
            runtimeReady: true,
            persistSession: { operations.append("save") },
            restoreWindows: { operations.append("restore") },
        )
        XCTAssertEqual(operations, ["save", "restore"])
    }

    func testPermissionGrantAloneDoesNotMarkRuntimeReadyForPersistence() async throws {
        let previousRuntimeReady = isWinMuxRuntimeReady
        defer { isWinMuxRuntimeReady = previousRuntimeReady }
        isWinMuxRuntimeReady = false
        let model = TrayMenuModel()
        try await waitForAccessibilityPermission(model: model, checkTrusted: { _ in true })
        XCTAssertEqual(model.accessibilityPermissionStatus, .granted)
        var didPersistSession = false
        var didRestoreManagedWindows = false

        try await prepareManagedWindowsForTermination(
            persistSession: { didPersistSession = true },
            restoreWindows: { didRestoreManagedWindows = true },
        )

        XCTAssertFalse(didPersistSession)
        XCTAssertTrue(didRestoreManagedWindows)
    }
}
