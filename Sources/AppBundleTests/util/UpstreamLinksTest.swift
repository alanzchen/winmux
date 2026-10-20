@testable import AppBundle
import Common
import Foundation
import XCTest

/// The fork's rebrand rewrote upstream AeroSpace history links into a `nikitabobko/WinMux`
/// repository that does not exist, so diagnostics sent users to 404 pages.
@MainActor
final class UpstreamLinksTest: XCTestCase {
    func testSourcesDoNotLinkToTheNonexistentRebrandedUpstreamRepository() throws {
        // Built from parts so this file never matches its own needle.
        let needle = ["github.com", "nikitabobko", "WinMux"].joined(separator: "/")
        let thisFile = URL(filePath: #filePath).resolvingSymlinksInPath().path
        let sources = projectRoot.appending(path: "Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scannedFileCount = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.resolvingSymlinksInPath().path
            if path == thisFile { continue }
            scannedFileCount += 1
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains(needle) {
                offenders.append("\(path.replacingOccurrences(of: projectRoot.path + "/", with: "")):\(index + 1)")
            }
        }
        XCTAssertGreaterThan(scannedFileCount, 100, "The scan must cover the Sources tree")
        assertEquals(offenders, [])
    }

    func testDeprecatedConfigKeyErrorsLinkToUpstreamAeroSpaceIssues() {
        let (_, afterLoginErrors) = parseConfig("after-login-command = ['workspace 1']")
        assertEquals(afterLoginErrors.descriptions, [
            "after-login-command: after-login-command is deprecated since AeroSpace 0.19.0. https://github.com/nikitabobko/AeroSpace/issues/1482",
        ])

        let (_, indentErrors) = parseConfig("indent-for-nested-containers-with-the-same-orientation = 'auto'")
        assertEquals(indentErrors.descriptions, [
            "indent-for-nested-containers-with-the-same-orientation: Deprecated. Please drop it from the config. See https://github.com/nikitabobko/AeroSpace/issues/96",
        ])
    }
}
