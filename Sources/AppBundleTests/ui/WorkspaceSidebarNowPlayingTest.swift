import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarNowPlayingTest: XCTestCase {
    func testAHelperPlayingSoundCountsForItsAppButWinMuxNever() {
        let samples = [
            AudioProcessSample(pid: 10, isRunningOutput: true, responsiblePid: 10),
            AudioProcessSample(pid: 21, isRunningOutput: true, responsiblePid: 20),
            AudioProcessSample(pid: 30, isRunningOutput: false, responsiblePid: nil),
            AudioProcessSample(pid: 40, isRunningOutput: true, responsiblePid: nil),
            AudioProcessSample(pid: 50, isRunningOutput: true, responsiblePid: -1),
            AudioProcessSample(pid: 99, isRunningOutput: true, responsiblePid: 99),
        ]
        XCTAssertEqual(audioPlayingAppPids(samples, ownPid: 99), [10, 20, 40, 50])
    }

    func testCoreAudioReadsWithoutPermission() {
        // Nothing need be playing; the read must just not fail or hang.
        _ = readAudioProcessSamples()
    }

    func testMusicPlayerNotificationsGiveTheTrackAndState() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let playing = try XCTUnwrap(appleMusicNowPlaying(playerInfo: [
            "Player State": "Playing", "Name": "Song", "Artist": "Artist", "Album": "Album",
            "Total Time": NSNumber(value: 245_000),
        ], date: date))
        XCTAssertEqual(playing, AppleMusicNowPlaying(state: .playing, title: "Song", artist: "Artist", album: "Album",
            duration: 245, position: nil, positionDate: date))
        XCTAssertEqual(appleMusicNowPlaying(playerInfo: ["Player State": "Stopped"])?.state, .stopped)
        XCTAssertNil(appleMusicNowPlaying(playerInfo: ["Name": "Song"]))
    }

    func testMusicStatusOutputParsesEvenWithADecimalComma() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let sep = "\u{1F}"
        let output = ["paused", "Song", "Artist", "", "245,5", "12,25"].joined(separator: sep) + "\n"
        let paused = try XCTUnwrap(appleMusicNowPlaying(statusOutput: output, date: date))
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.duration, 245.5)
        XCTAssertEqual(paused.position, 12.25)
        XCTAssertEqual(paused.elapsed(at: date.addingTimeInterval(60)), 12.25, "A paused track doesn't count on")
        XCTAssertEqual(appleMusicNowPlaying(statusOutput: "stopped\n")?.state, .stopped)
        XCTAssertNil(appleMusicNowPlaying(statusOutput: "playing\(sep)Song"))
    }

    func testPlayingPositionCountsOnButStopsAtTheTrackEnd() {
        let date = Date(timeIntervalSince1970: 1000)
        let track = AppleMusicNowPlaying(state: .playing, title: "Song", artist: "", album: "", duration: 100,
            position: 90, positionDate: date)
        XCTAssertEqual(track.elapsed(at: date.addingTimeInterval(5)), 95)
        XCTAssertEqual(track.elapsed(at: date.addingTimeInterval(50)), 100)
        XCTAssertEqual(workspaceSidebarNowPlayingTime(95.9), "1:35")
        XCTAssertEqual(workspaceSidebarNowPlayingTime(3725), "1:02:05")
    }

    func testArtworkDecodesFromOsascriptsRawDataOutput() {
        XCTAssertEqual(appleScriptRawData("«data tdtaFFD8ffE0»\n"), Data([0xFF, 0xD8, 0xFF, 0xE0]))
        XCTAssertEqual(appleScriptRawData("«data JPEG0102»"), Data([0x01, 0x02]))
        XCTAssertNil(appleScriptRawData(""))
        XCTAssertNil(appleScriptRawData("«data tdtaFFD»"))
        XCTAssertNil(appleScriptRawData("«data tdtaZZ»"))
    }

    func testOnlyMusicsTabShowsNowPlaying() {
        func window(_ bundleId: String?) -> WorkspaceSidebarWindowViewModel {
            WorkspaceSidebarWindowViewModel(windowId: 1, workspaceName: "a", appName: "App", appBundleId: bundleId,
                appBundlePath: nil, title: nil, isFocused: false)
        }
        XCTAssertTrue(workspaceSidebarShowsNowPlaying(window("com.apple.Music")))
        XCTAssertFalse(workspaceSidebarShowsNowPlaying(window("com.apple.Safari")))
        XCTAssertFalse(workspaceSidebarShowsNowPlaying(window(nil)))
    }
}
