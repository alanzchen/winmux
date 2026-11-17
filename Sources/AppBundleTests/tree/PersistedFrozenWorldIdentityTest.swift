@testable import AppBundle
import AppKit
import Common
import XCTest

/// Astra's audit A1: window-state.json puts windows back by id after WinMux restarts. A window number is
/// unique only within the user session that gave it, so a snapshot must put back only the windows it saved:
/// not another process's window, a relaunched app's, or anything after a reboot or logout.
@MainActor
final class PersistedFrozenWorldIdentityTest: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_793_000_000)
    private let boot = Date(timeIntervalSince1970: 1_792_900_000)
    private lazy var notes = TestApp(pid: 61, bundleId: "com.example.notes", name: "Notes", launchDate: launch)
    private var folder: URL!
    private var snapshotURL: URL!
    private var savedURL: (() throws -> URL)?
    private var savedBoot: (() -> Date?)?
    private var savedProcess: ((Int32) -> (bundleId: String?, launch: Date?)?)?
    private var running: [Int32: (bundleId: String?, launch: Date?)] = [:]
    private var currentBoot: Date?
    private var savedSession: (() -> String?)?
    private var currentSession: String? = "BOOT-A"

    override func setUp() async throws {
        setUpWorkspacesForTests()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-window-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        snapshotURL = folder.appendingPathComponent("window-state.json")
        savedURL = persistedFrozenWorldFileUrl
        savedBoot = liveWindowBootTime
        savedProcess = liveWindowRunningProcess
        persistedFrozenWorldFileUrl = { [snapshotURL] in snapshotURL! }
        currentBoot = boot
        liveWindowBootTime = { [unowned self] in currentBoot }
        running = [notes.pid: (notes.rawAppBundleId, launch)]
        liveWindowRunningProcess = { [unowned self] pid in running[pid] }
        savedSession = liveWindowBootSession
        currentSession = "BOOT-A"
        liveWindowBootSession = { [unowned self] in currentSession }
        setPendingPersistedFrozenWorldForTests(nil)
    }

    override func tearDown() async throws {
        setPendingPersistedFrozenWorldForTests(nil)
        if let savedURL { persistedFrozenWorldFileUrl = savedURL }
        if let savedBoot { liveWindowBootTime = savedBoot }
        if let savedProcess { liveWindowRunningProcess = savedProcess }
        if let savedSession { liveWindowBootSession = savedSession }
        try? FileManager.default.removeItem(at: folder)
        config = defaultConfig
    }

    // MARK: - Helpers

    /// Notes' window 10 in workspace "saved", written to window-state.json as WinMux quits.
    private func quitWithSavedWindow() throws -> TestWindow {
        let saved = Workspace.get(byName: "saved")
        let window = TestWindow.new(id: 10, parent: saved.rootTilingContainer, app: notes, title: "Notes")
        XCTAssertTrue(Workspace.get(byName: "elsewhere").focusWorkspace())
        persistFrozenWorldForRestartIfPossible()
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        return window
    }

    /// As WinMux starts again, a window with id 10 is seen in "elsewhere": `app`'s.
    private func windowSeenOnStart(_ app: TestApp, replacing old: TestWindow) -> TestWindow {
        old.unbindFromParent()
        return TestWindow.new(id: 10, parent: Workspace.get(byName: "elsewhere").rootTilingContainer, app: app, title: "Seen")
    }

    private func writeSnapshotWithoutWindows(savedAt: Date) throws {
        let data = try Data(contentsOf: snapshotURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "windows")
        try JSONSerialization.data(withJSONObject: object).write(to: snapshotURL)
        try FileManager.default.setAttributes([.modificationDate: savedAt], ofItemAtPath: snapshotURL.path)
    }

    // MARK: - Tests

    func testTheSnapshotSavesWhichWindowEachIdWas() throws {
        _ = try quitWithSavedWindow()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any])
        let windows = try XCTUnwrap(object["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?["windowId"] as? Int, 10)
        XCTAssertEqual(windows.first?["pid"] as? Int, 61)
        XCTAssertEqual(windows.first?["bundleId"] as? String, "com.example.notes")
        XCTAssertNotNil(windows.first?["processLaunch"])
        XCTAssertNotNil(windows.first?["boot"])
        XCTAssertEqual(windows.first?["bootSession"] as? String, "BOOT-A")
    }

    func testTheSameWindowIsPutBack() async throws {
        let old = try quitWithSavedWindow()
        let seen = windowSeenOnStart(notes, replacing: old)
        XCTAssertTrue(loadPersistedFrozenWorldForStartupIfPresent())
        XCTAssertTrue(persistedFrozenWorldContains(windowId: 10))
        let restored = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: seen)
        XCTAssertTrue(restored)
        XCTAssertEqual(seen.nodeWorkspace?.name, "saved")
    }

    func testAnotherProcesssWindowWithASavedIdIsNotPutBack() async throws {
        let old = try quitWithSavedWindow()
        let other = TestApp(pid: 62, bundleId: "com.example.mail", name: "Mail", launchDate: launch)
        running[other.pid] = (other.rawAppBundleId, launch)
        let seen = windowSeenOnStart(other, replacing: old)
        XCTAssertTrue(loadPersistedFrozenWorldForStartupIfPresent(), "Notes is still running: its window may still come")
        XCTAssertFalse(persistedFrozenWorldContains(windowId: 10), "Not a window to put back, so not held back from new-window placement")
        let restored = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: seen)
        XCTAssertFalse(restored)
        XCTAssertEqual(seen.nodeWorkspace?.name, "elsewhere")
        XCTAssertNil(Workspace.existing(byName: "saved")?.allLeafWindowsRecursive.first)
    }

    func testARelaunchedAppsWindowWithASavedIdIsNotPutBack() async throws {
        let old = try quitWithSavedWindow()
        let relaunched = TestApp(pid: 61, bundleId: "com.example.notes", name: "Notes", launchDate: launch.addingTimeInterval(60))
        running[61] = (relaunched.rawAppBundleId, relaunched.launchDate)
        let seen = windowSeenOnStart(relaunched, replacing: old)
        XCTAssertFalse(loadPersistedFrozenWorldForStartupIfPresent(), "The process that had the window has ended")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        let restored = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: seen)
        XCTAssertFalse(restored)
        XCTAssertEqual(seen.nodeWorkspace?.name, "elsewhere")
    }

    func testASnapshotFromAnotherBootPutsNothingBack() async throws {
        let old = try quitWithSavedWindow()
        currentBoot = boot.addingTimeInterval(86_400)
        currentSession = "BOOT-B"
        let seen = windowSeenOnStart(notes, replacing: old)
        XCTAssertFalse(loadPersistedFrozenWorldForStartupIfPresent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        let restored = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: seen)
        XCTAssertFalse(restored)
        XCTAssertEqual(seen.nodeWorkspace?.name, "elsewhere")
    }

    // Carbon ASD-C1: kern.boottime moves with sleep, wake and clock changes. The boot is the same, and so is the snapshot.
    func testABootTimeMovedBySleepOrAClockChangeKeepsTheSnapshot() async throws {
        for shift in [0.002, 60, -3_600] as [TimeInterval] {
            setUpWorkspacesForTests()
            setPendingPersistedFrozenWorldForTests(nil)
            currentBoot = boot
            let old = try quitWithSavedWindow()
            currentBoot = boot.addingTimeInterval(shift)
            let seen = windowSeenOnStart(notes, replacing: old)
            XCTAssertTrue(loadPersistedFrozenWorldForStartupIfPresent(), "\(shift)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path), "\(shift)")
            let restored = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: seen)
            XCTAssertTrue(restored, "\(shift)")
            XCTAssertEqual(seen.nodeWorkspace?.name, "saved", "\(shift)")
        }
    }

    /// Nothing decides whether a window is still the one saved: it isn't put back, and the snapshot isn't deleted.
    func testAWindowWhoseStandingCantBeToldIsNotPutBackAndTheSnapshotStays() async throws {
        let unlaunched = TestApp(pid: 65, bundleId: "com.example.tool", name: "Tool", launchDate: nil)
        running[unlaunched.pid] = (unlaunched.rawAppBundleId, nil)
        let saved = Workspace.get(byName: "saved")
        let old = TestWindow.new(id: 10, parent: saved.rootTilingContainer, app: unlaunched, title: "Tool")
        XCTAssertTrue(Workspace.get(byName: "elsewhere").focusWorkspace())
        persistFrozenWorldForRestartIfPossible()
        currentSession = nil
        currentBoot = boot.addingTimeInterval(30)
        let seen = windowSeenOnStart(unlaunched, replacing: old)
        XCTAssertTrue(loadPersistedFrozenWorldForStartupIfPresent())
        let restored = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: seen)
        XCTAssertFalse(restored, "Not shown to be the window saved")
        XCTAssertEqual(seen.nodeWorkspace?.name, "elsewhere")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path), "Not shown to be gone either")
    }

    /// Carbon ASD-R2-N2: string sysctls are decoded as UTF-8 up to their NUL, without the deprecated String(cString:).
    func testAStringSysctlIsReadWithoutItsTerminator() throws {
        XCTAssertEqual(liveWindowSystemString("kern.ostype"), "Darwin")
        let session = try XCTUnwrap(liveWindowSystemString("kern.bootsessionuuid"))
        XCTAssertNotNil(UUID(uuidString: session), session)
        XCTAssertNil(liveWindowSystemString("kern.no-such-name"))
    }

    /// Astra R2-A1: a window that can't be told yet isn't put back, and a refresh that finishes doesn't delete the
    /// snapshot for it. Evidence that comes later decides: the same boot puts it back; another boot ends the snapshot.
    func testAnUndecidedWindowKeepsTheSnapshotThroughARefreshUntilEvidenceDecides() async throws {
        for laterSession in ["BOOT-A", "BOOT-B"] {
            setUpWorkspacesForTests()
            setPendingPersistedFrozenWorldForTests(nil)
            currentSession = "BOOT-A"
            currentBoot = boot
            let unlaunched = TestApp(pid: 65, bundleId: "com.example.tool", name: "Tool", launchDate: nil)
            running[unlaunched.pid] = (unlaunched.rawAppBundleId, nil)
            let old = TestWindow.new(id: 10, parent: Workspace.get(byName: "saved").rootTilingContainer, app: unlaunched)
            XCTAssertTrue(Workspace.get(byName: "elsewhere").focusWorkspace())
            persistFrozenWorldForRestartIfPossible()
            currentSession = nil
            currentBoot = boot.addingTimeInterval(30)
            let seen = windowSeenOnStart(unlaunched, replacing: old)
            XCTAssertTrue(loadPersistedFrozenWorldForStartupIfPresent())
            let early = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: seen)
            XCTAssertFalse(early)
            XCTAssertFalse(persistedFrozenWorldContains(windowId: 10))
            // The refresh is complete: WinMux has registered every window the snapshot names.
            finalizePersistedFrozenWorldAfterRefresh(aliveWindowIds: [10], knownWindowIds: [10])
            XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path), "\(laterSession): kept while undecided")

            currentSession = laterSession
            let later = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: seen)
            XCTAssertEqual(later, laterSession == "BOOT-A", laterSession)
            XCTAssertEqual(seen.nodeWorkspace?.name, laterSession == "BOOT-A" ? "saved" : "elsewhere", laterSession)
            finalizePersistedFrozenWorldAfterRefresh(aliveWindowIds: [10], knownWindowIds: [10])
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path), "\(laterSession): decided, so done")
        }
    }

    // MARK: Snapshots written before identities were saved

    func testAnOldSnapshotIsKeptWhenThisBootsTimeCantBeRead() async throws {
        _ = try quitWithSavedWindow()
        try writeSnapshotWithoutWindows(savedAt: launch.addingTimeInterval(600))
        currentBoot = nil
        XCTAssertFalse(loadPersistedFrozenWorldForStartupIfPresent())
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    func testAnOldSnapshotWrittenInAnEarlierBootPutsNothingBack() async throws {
        let old = try quitWithSavedWindow()
        try writeSnapshotWithoutWindows(savedAt: boot.addingTimeInterval(-60))
        let seen = windowSeenOnStart(notes, replacing: old)
        XCTAssertFalse(loadPersistedFrozenWorldForStartupIfPresent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        let restored = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: seen)
        XCTAssertFalse(restored)
    }

    func testAnOldSnapshotFromThisBootPutsBackWindowsOfProcessesRunningWhenItWasWritten() async throws {
        let old = try quitWithSavedWindow()
        try writeSnapshotWithoutWindows(savedAt: launch.addingTimeInterval(600))
        let seen = windowSeenOnStart(notes, replacing: old)
        XCTAssertTrue(loadPersistedFrozenWorldForStartupIfPresent())
        let restored = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: seen)
        XCTAssertTrue(restored)
        XCTAssertEqual(seen.nodeWorkspace?.name, "saved")
    }

    func testAnOldSnapshotFromThisBootPutsBackNoWindowOfAProcessLaunchedSince() async throws {
        let old = try quitWithSavedWindow()
        try writeSnapshotWithoutWindows(savedAt: launch.addingTimeInterval(600))
        let later = TestApp(pid: 63, bundleId: "com.example.mail", name: "Mail", launchDate: launch.addingTimeInterval(1_200))
        let seen = windowSeenOnStart(later, replacing: old)
        XCTAssertTrue(loadPersistedFrozenWorldForStartupIfPresent())
        XCTAssertFalse(persistedFrozenWorldContains(windowId: 10))
        let restored = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: seen)
        XCTAssertFalse(restored)
        XCTAssertEqual(seen.nodeWorkspace?.name, "elsewhere")
    }

    func testAnOldSnapshotPutsBackNoWindowWhoseProcessLaunchIsUnknown() async throws {
        let old = try quitWithSavedWindow()
        try writeSnapshotWithoutWindows(savedAt: launch.addingTimeInterval(600))
        let unknown = TestApp(pid: 64, bundleId: "com.example.notes", name: "Notes", launchDate: nil)
        let seen = windowSeenOnStart(unknown, replacing: old)
        XCTAssertTrue(loadPersistedFrozenWorldForStartupIfPresent())
        let restored = try await restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: seen)
        XCTAssertFalse(restored, "Never guessed")
    }
}
