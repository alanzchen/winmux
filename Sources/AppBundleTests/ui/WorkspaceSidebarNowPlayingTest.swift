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
        let stream = try XCTUnwrap(appleMusicNowPlaying(statusOutput: ["playing", "Radio", "missing value", "missing value",
            "missing value", "30"].joined(separator: sep)))
        XCTAssertEqual(stream.artist, "", "A stream's missing tags aren't shown as text")
        XCTAssertNil(stream.duration)
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

    func testMusicPlayerAtBottomIsATabsSettingThatDefaultsOff() {
        let (parsed, errors) = parseConfig("""
            [workspace-sidebar]
            mode = 'tabs'
            music-player-at-bottom = true
            """)
        XCTAssertEqual(errors.descriptions, [])
        XCTAssertTrue(parsed.workspaceSidebar.musicPlayerAtBottom)
        XCTAssertTrue(workspaceSidebarConfiguration(parsed).musicPlayerAtBottom)
        XCTAssertFalse(defaultConfig.workspaceSidebar.musicPlayerAtBottom)
        let field = SettingsCatalog.field("workspace-sidebar.music-player-at-bottom")
        XCTAssertEqual(field.modes, [.tabs])
        XCTAssertTrue(SettingsPanelLayout.sections(.tabs).contains { $0.id == "tabs.content" && $0.fields.contains(field.id) })
        XCTAssertTrue(SettingsCatalog.results("Music player").contains { $0.id == field.id })
    }

    func testTheBottomPlayerGoesToMusicsWindowWhereverItsTabIs() {
        let here = "monitor:0,0"
        func tab(_ name: String, _ windowId: UInt32, bundleId: String = appleMusicBundleId, scope: String = here,
                 visible: Bool = false) -> WorkspaceSidebarWorkspaceViewModel {
            .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: "", isGeneratedName: true,
                monitorScopeId: scope, monitorName: nil, isFocused: false, isVisible: visible,
                items: [.init(kind: .window(.init(windowId: windowId, workspaceName: name, appName: "App", appBundleId: bundleId,
                    appBundlePath: nil, title: nil, isFocused: false)))])
        }
        let safari = tab("web", 1, bundleId: "com.apple.Safari", visible: true)
        XCTAssertNil(workspaceSidebarBottomMusicPlayerAction([safari], targetMonitorScopeId: here),
            "With no Music window listed, the player opens Music")
        let hidden = tab("music", 2)
        XCTAssertEqual(workspaceSidebarBottomMusicPlayerAction([safari, hidden], targetMonitorScopeId: here), .selectWindow(2),
            "A Music tab that isn't on screen comes to this display, as its tab would")
        let elsewhere = tab("music 2", 3, scope: "monitor:1920,0", visible: true)
        XCTAssertEqual(workspaceSidebarBottomMusicPlayerAction([hidden, elsewhere], targetMonitorScopeId: here),
            .focusWindowInPlace(3), "Music on screen on another display is focused there rather than moved")
        let onScreen = tab("music 3", 4, visible: true)
        XCTAssertEqual(workspaceSidebarBottomMusicPlayerAction([hidden, elsewhere, onScreen], targetMonitorScopeId: here),
            .selectWindow(4), "Music already on this display comes first")
    }

    func testTheModelFollowsWhetherMusicIsOpen() {
        let music = MusicRunningFlag(true)
        let model = AppleMusicNowPlayingModel(isMusicRunning: { music.isRunning }, requestStatus: { _ in nil },
            requestArtwork: { .failed })
        XCTAssertFalse(model.isRunning)
        model.receive(track(.paused))
        XCTAssertTrue(model.isRunning)
        model.receive(track(.stopped))
        XCTAssertTrue(model.isRunning, "Music stays open with nothing playing")
        music.isRunning = false
        model.receive(statusResult: .success(""), sequence: model.stateSequence)
        XCTAssertFalse(model.isRunning, "Music says it isn't running")
        model.receive(track(.playing))
        XCTAssertFalse(model.isRunning, "A late notification from a Music that quit doesn't bring the player back")
        XCTAssertNil(model.nowPlaying)
    }

    func testTheBottomPlayerShowsOnlyWhileMusicIsOpen() async throws {
        let music = MusicRunningFlag(false)
        let model = AppleMusicNowPlayingModel(isMusicRunning: { music.isRunning }, requestStatus: { _ in nil },
            requestArtwork: { .failed })
        // One host throughout, so the player follows the model rather than being rebuilt.
        let host = NSHostingView(rootView: WorkspaceSidebarBottomMusicPlayer(onSelect: {}, model: model)
            .environment(\.workspaceSidebarReducesMotion, true)
            .frame(width: 280))
        func height() -> CGFloat {
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        XCTAssertEqual(height(), 0, accuracy: 0.5)
        music.isRunning = true
        model.receive(track(.playing))
        try await waitUntil { height() > 50 } // The artwork, title and controls.
        model.receive(statusResult: .success(""), sequence: model.stateSequence)
        try await waitUntil { height() < 0.5 } // Music quit.
    }

    /// Turning Tabs on while Music is already open shows the player at once, and a reply that
    /// Music sent before Tabs was turned off doesn't bring it back.
    func testTurningTabsOnAndOffFollowsWhetherMusicIsOpen() async throws {
        let music = MusicRunningFlag(true)
        let replies = AttemptCounter()
        let model = AppleMusicNowPlayingModel(isMusicRunning: { music.isRunning }, requestStatus: { _ in
            try? await Task.sleep(for: .milliseconds(100))
            _ = await replies.next()
            return .success(["playing", "Song", "Artist", "Album", "200", "10"].joined(separator: "\u{1F}"))
        }, requestArtwork: { .success("") })
        defer { model.setEnabled(false) }
        model.setEnabled(true)
        XCTAssertTrue(model.isRunning, "Shown before Music has answered, or when it may not be asked")
        model.setEnabled(false)
        XCTAssertFalse(model.isRunning)
        try await waitUntil { await replies.count == 1 }
        // The reply reaches the model on the main actor right after it's sent.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(model.isRunning, "The reply to a request from before Tabs turned off is dropped")
        XCTAssertNil(model.nowPlaying)
        model.setEnabled(true)
        XCTAssertTrue(model.isRunning)
        try await waitUntil { model.nowPlaying?.title == "Song" }
        music.isRunning = false
        model.setEnabled(false)
        model.setEnabled(true)
        XCTAssertFalse(model.isRunning, "Music closed while Tabs was off")
    }

    private func track(_ state: AppleMusicNowPlaying.State, title: String = "Song") -> AppleMusicNowPlaying {
        AppleMusicNowPlaying(state: state, title: title, artist: "Artist", album: "Album", duration: 200, position: nil,
            positionDate: Date())
    }

    private func status(_ state: String, title: String = "Song", position: String = "10") -> AppleMusicScriptOutput {
        .success([state, title, "Artist", "Album", "200", position].joined(separator: "\u{1F}"))
    }

    func testAnOlderReplyFromMusicNeverOverwritesANewerPause() {
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in nil },
            requestArtwork: { .failed })
        model.receive(track(.playing))
        let stale = model.stateSequence
        model.receive(track(.paused))
        model.receive(statusResult: status("playing"), sequence: stale)
        XCTAssertEqual(model.nowPlaying?.state, .paused, "A query sent while playing arrives after the pause")
        model.receive(statusResult: status("paused", position: "42"), sequence: model.stateSequence)
        XCTAssertEqual(model.nowPlaying?.position, 42)
    }

    func testArtworkThatFailsToLoadIsRetriedOnTheNextUpdate() async throws {
        let attempts = AttemptCounter()
        let png = try XCTUnwrap(NSImage(size: NSSize(width: 2, height: 2), flipped: false) { _ in
            NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); return true
        }.tiffRepresentation)
        let hex = png.map { String(format: "%02X", $0) }.joined()
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in nil },
            requestArtwork: { await attempts.next() == 1 ? .failed : .success("«data tdta\(hex)»") })
        model.receive(statusResult: status("playing"), sequence: model.stateSequence)
        try await waitUntil { await attempts.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.artwork)
        model.receive(statusResult: status("paused"), sequence: model.stateSequence)
        try await waitUntil { model.artwork != nil }
        let loadedAttempts = await attempts.count
        XCTAssertEqual(loadedAttempts, 2)
        model.receive(statusResult: status("playing"), sequence: model.stateSequence)
        try await Task.sleep(for: .milliseconds(50))
        let finalAttempts = await attempts.count
        XCTAssertEqual(finalAttempts, 2, "Loaded artwork isn't fetched again for the same track")
    }

    func testArtworkMusicReturnsButThatDoesntDecodeIsRetriedWhileNoneIsKept() async throws {
        let attempts = AttemptCounter()
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in nil },
            requestArtwork: { await attempts.next() == 1 ? .success("«data tdta0102»") : .success("") })
        model.receive(statusResult: status("playing"), sequence: model.stateSequence)
        try await waitUntil { await attempts.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        model.receive(statusResult: status("paused"), sequence: model.stateSequence)
        try await waitUntil { await attempts.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        model.receive(statusResult: status("playing"), sequence: model.stateSequence)
        try await Task.sleep(for: .milliseconds(50))
        let finalAttempts = await attempts.count
        XCTAssertEqual(finalAttempts, 2, "A track Music says has no artwork isn't asked again")
        XCTAssertNil(model.artwork)
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out")
    }
}

/// Whether a test's Music is open, as its model sees it.
@MainActor
final class MusicRunningFlag {
    var isRunning: Bool

    init(_ isRunning: Bool) { self.isRunning = isRunning }
}

private actor AttemptCounter {
    private(set) var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
