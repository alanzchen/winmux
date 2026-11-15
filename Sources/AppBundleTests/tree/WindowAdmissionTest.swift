@testable import AppBundle
import AppKit
import XCTest

/// A window an app lists that isn't registered is registered only if the window server had it after its app's AXWindows
/// was read (Astra REVIEW-7, R7-1): a list taken before then that has it says nothing.
@MainActor
final class WindowAdmissionTest: XCTestCase {
    private func decide(_ server: WindowServerWindowList, listed: @escaping () -> [(UInt32, FakeLivenessWindow)]?) throws
        -> RegisteredWindowsRefresh<FakeLivenessWindow>
    {
        try refreshRegisteredAxWindows([:], frontmostAppBundleId: nil, windowServer: server, listed: listed,
            rebind: { _, fresh in fresh }, register: { alive, id, element in alive[id] = element }, RunLoopJob())
    }

    /// Another app's refresh took the shared list while this app's AXWindows was being read, and it had the window:
    /// that says nothing of an element the app handed out; a list read now decides.
    func testAListTakenDuringItsAppsAXWindowsReadDoesntAdmitAWindowItHas() throws {
        let reads = WindowServerReads([[1: true, 9: true], [1: true]])
        let server = WindowServerWindowList(readWindows: { reads.next() })
        let corpse = FakeLivenessWindow((9, .success))
        let result = try decide(server, listed: {
            server.take()
            return [(UInt32(9), corpse)]
        })
        XCTAssertNil(result.alive[9])
        XCTAssertEqual(reads.count, 2)
    }

    /// The refresh's list taken after the app's AXWindows read, with the window in it: admitted, with no list read again.
    func testAListTakenAfterItsAppsAXWindowsReadIsTakenAsIs() throws {
        let reads = WindowServerReads([[1: true, 9: true], [1: true]])
        let live = FakeLivenessWindow((9, .success))
        let result = try decide(WindowServerWindowList(readWindows: { reads.next() }), listed: { [(UInt32(9), live)] })
        XCTAssertTrue(result.alive[9] === live)
        XCTAssertEqual(reads.count, 1)
    }

    /// An older list that had it, and none to go by read now: admitted, as with no list at all.
    func testAnOlderListThatHadItWithNoListReadNowAdmits() throws {
        let reads = WindowServerReads([[1: true, 9: true], nil])
        let server = WindowServerWindowList(readWindows: { reads.next() })
        server.take()
        let live = FakeLivenessWindow((9, .success))
        XCTAssertTrue(try decide(server, listed: { [(UInt32(9), live)] }).alive[9] === live)
    }
}
