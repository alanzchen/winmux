@testable import AppBundle
import XCTest

// Reviewer reproducer assertions the coordinator's decision of 2026-11-15 supersedes: tombstones were removed, so these
// can't hold any more. The reviewers' files stay byte-identical and run in full. Only the assertions listed here, by file
// and line, are recorded as expected failures, each with its reason; any other assertion in those tests fails as usual.
// Strictness is XCTest's, per test: a test none of whose listed assertions fails any more is reported; one of several
// that alone stops failing isn't (Astra REVIEW-7). Replacement contracts are ordinary tests of our own
// (`SupersededReviewerReplacementTest`), as reviewers asked (Astra REVIEW-6).
//
// The goal they guarded: no permanent ghost, and no permanent lockout.
// - Review3BlockReproTest.testBlock2… (Carbon C2), lines 109 and 116: `confirmedClosed == [9]` and `mayRegister` false
//   during the lag. A corpse may be a short-lived ghost; the test's last assertion, gone once the window server drops
//   the id (row 1b), runs for real.
// - Review3RegressionTest.testTombstoneRejectsCorpse… (Astra A1), lines 62, 72 and 73: the same, admitted while the
//   window server lists the id; a corpse it no longer lists isn't admitted at all.
// - Review4BlockReproTest.testRow7Drop… (Carbon R4-1), line 63: the setup check `confirmedClosed == [9]`. Its follow-up
//   and re-admission assertions run for real.
// - Review5RegressionTest.testADropRestartsRechecks… (Astra a), lines 52 and 59: the attempt count and a restart through
//   the 1-argument `next`. Looks again are paced, and a drop restarts them through `startsSeries`.
// - Review5RegressionTest.testCharacterizeLongLivedCorpse… (Astra), line 176: the corpse kept after the window server's
//   drop. Row 1b lets it go: the characterized hole, closed.

private struct SupersededAssertions {
    let file: String
    let lines: Set<Int>
    let reason: String
}

private let supersededReviewerAssertions: [String: SupersededAssertions] = [
    "testBlock2TombstoneBypassedDuringWindowServerPostCloseOnScreenLag": .init(file: "Review3BlockReproTest.swift",
        lines: [109, 116], reason: "Superseded: tombstones removed (2026-11-15); a corpse is a short-lived ghost."),
    "testTombstoneRejectsCorpseWhileTheSameOnscreenSurfaceStillLingers": .init(file: "Review3RegressionTest.swift",
        lines: [62, 72, 73], reason: "Superseded: tombstones removed (2026-11-15); a corpse is a short-lived ghost."),
    "testRow7DropWhileWindowServerShowsOnScreenSchedulesFollowUpOrReadmitsReopenedWindow": .init(file: "Review4BlockReproTest.swift",
        lines: [63], reason: "Superseded setup check: no confirmedClosed any more (2026-11-15)."),
    "testADropRestartsRechecksWhenTheSameIdAlreadyExhaustedItsSeries": .init(file: "Review5RegressionTest.swift",
        lines: [52, 59], reason: "Superseded: looks again are paced, and a drop restarts them through startsSeries (2026-11-15)."),
    "testCharacterizeLongLivedCorpseReadmissionAndSubsequentRow1Keep": .init(file: "Review5RegressionTest.swift",
        lines: [176], reason: "Superseded characterization: row 1b lets the corpse go (2026-11-15)."),
]

private func runExpectingSupersededFailures(_ test: XCTestCase, _ run: () -> Void) {
    let method = test.name.split(separator: " ").last.map { String($0.dropLast()) } ?? ""
    guard let superseded = supersededReviewerAssertions[method] else { return run() }
    let options = XCTExpectedFailure.Options()
    options.issueMatcher = { issue in
        guard let location = issue.sourceCodeContext.location else { return false }
        return location.fileURL.lastPathComponent == superseded.file && superseded.lines.contains(location.lineNumber)
    }
    XCTExpectFailure(superseded.reason, options: options, failingBlock: run)
}

extension Review3BlockReproTest {
    nonisolated override func invokeTest() { runExpectingSupersededFailures(self) { super.invokeTest() } }
}

extension Review3RegressionTest {
    nonisolated override func invokeTest() { runExpectingSupersededFailures(self) { super.invokeTest() } }
}

extension Review4BlockReproTest {
    nonisolated override func invokeTest() { runExpectingSupersededFailures(self) { super.invokeTest() } }
}

extension Review5RegressionTest {
    nonisolated override func invokeTest() { runExpectingSupersededFailures(self) { super.invokeTest() } }
}
