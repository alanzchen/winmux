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
        // Music's numbers, as its replies spell them.
        XCTAssertEqual(appleMusicNowPlaying(playerInfo: ["Player State": "Paused",
            "PersistentID": NSNumber(value: Int64(8_650_430_949_386_142_921))])?.persistentId, "780C811DD434C4C9")
        XCTAssertEqual(appleMusicNowPlaying(playerInfo: ["Player State": "Paused",
            "PersistentID": NSNumber(value: Int64(-417_670_289_165_452_579))])?.persistentId, "FA342315BD0EFADD")
    }

    func testMusicStatusOutputParsesEvenWithADecimalComma() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let sep = "\u{1F}"
        let output = ["paused", "Song", "Artist", "", "245,5", "12,25", "780c811dd434c4c9"].joined(separator: sep) + "\n"
        let paused = try XCTUnwrap(appleMusicNowPlaying(statusOutput: output, date: date))
        XCTAssertEqual(paused.persistentId, "780C811DD434C4C9")
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.duration, 245.5)
        XCTAssertEqual(paused.position, 12.25)
        XCTAssertEqual(paused.elapsed(at: date.addingTimeInterval(60)), 12.25, "A paused track doesn't count on")
        XCTAssertEqual(appleMusicNowPlaying(statusOutput: "stopped\n")?.state, .stopped)
        XCTAssertNil(appleMusicNowPlaying(statusOutput: "playing\(sep)Song"))
        let stream = try XCTUnwrap(appleMusicNowPlaying(statusOutput: ["playing", "Radio", "missing value", "missing value",
            "missing value", "30", ""].joined(separator: sep)))
        XCTAssertNil(stream.persistentId, "A track Music gives no identifier is told apart by its name")
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
            return .success(["playing", "Song", "Artist", "Album", "200", "10", ""].joined(separator: "\u{1F}"))
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

    /// Music's two notifications per pause or play each read at once, as before.
    func testMusicsPairOfNotificationsPerPauseEachReadAtOnce() async throws {
        let requests = StatusRequests()
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { asking in
            await requests.request(askingMusic: asking)
        }, requestArtwork: { .success("") })
        model.receive(track(.playing))
        model.receive(track(.paused))
        try await waitUntil { await requests.count == 2 }
        await requests.answerNext(status("playing", position: "5"))
        await requests.answerNext(status("paused", position: "42"))
        try await waitUntil { model.nowPlaying?.position == 42 }
        XCTAssertEqual(model.nowPlaying?.state, .paused)
    }

    /// A burst of notifications asks Music a few times, not once each: the reads under way, whose
    /// replies are stale, then one fresh read after the last notification, whose reply shows.
    func testABurstOfNotificationsAsksMusicOnceMoreAndShowsTheLatest() async throws {
        let requests = StatusRequests()
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { asking in
            await requests.request(askingMusic: asking)
        }, requestArtwork: { .success("") })
        for index in 0 ..< 10 { model.receive(track(index.isMultiple(of: 2) ? .playing : .paused)) }
        try await Task.sleep(for: .milliseconds(50))
        var count = await requests.count
        XCTAssertEqual(count, appleMusicConcurrentStatusReads, "Later notifications wait for a read under way")
        await requests.answerNext(status("playing", position: "5"))
        try await waitUntil { await requests.count == appleMusicConcurrentStatusReads + 1 }
        XCTAssertEqual(model.nowPlaying?.state, .paused, "A reply from before the burst ended is dropped")
        XCTAssertNil(model.nowPlaying?.position)
        await requests.answerNext(status("playing", position: "6"))
        await requests.answerNext(status("paused", position: "42"))
        try await waitUntil { model.nowPlaying?.position == 42 }
        XCTAssertEqual(model.nowPlaying?.state, .paused)
        try await Task.sleep(for: .milliseconds(50))
        count = await requests.count
        XCTAssertEqual(count, appleMusicConcurrentStatusReads + 1)
        let asked = await requests.asked
        XCTAssertFalse(asked.contains(true), "The sidebar alone never asks to automate Music")
    }

    /// Reads Music is slow to answer hold a newer one back no longer than the overlap.
    func testASlowReadHoldsANewerOneBackOnlyBriefly() async throws {
        let requests = StatusRequests()
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { asking in
            await requests.request(askingMusic: asking)
        }, requestArtwork: { .success("") })
        model.receive(track(.playing))
        model.receive(track(.paused))
        try await waitUntil { await requests.count == 2 }
        let started = ContinuousClock.now
        model.receive(track(.playing))
        try await waitUntil(timeout: .seconds(3)) { await requests.count == 3 }
        let waited = ContinuousClock.now - started
        XCTAssertGreaterThan(waited, .milliseconds(Int(appleMusicStatusReadOverlap * 1000) - 300))
        XCTAssertLessThan(waited, .milliseconds(Int(appleMusicStatusReadOverlap * 1000) + 700))
        await requests.answerNext(status("playing", position: "5"))
        await requests.answerNext(status("paused", position: "6"))
        await requests.answerNext(status("playing", position: "42"))
        try await waitUntil { model.nowPlaying?.position == 42 }
        XCTAssertEqual(model.nowPlaying?.state, .playing)
    }

    /// Music quitting drops a read that was waiting for one under way.
    func testQuittingMusicDropsAWaitingRead() async throws {
        let music = MusicRunningFlag(true)
        let requests = StatusRequests()
        let model = AppleMusicNowPlayingModel(isMusicRunning: { music.isRunning }, requestStatus: { asking in
            await requests.request(askingMusic: asking)
        }, requestArtwork: { .success("") })
        model.receive(track(.playing))
        model.receive(track(.paused))
        model.receive(track(.playing))
        try await waitUntil { await requests.count == 2 }
        music.isRunning = false
        model.receive(track(.paused))
        XCTAssertNil(model.nowPlaying)
        await requests.answerNext(status("playing"))
        await requests.answerNext(status("playing"))
        try await Task.sleep(for: .milliseconds(Int(appleMusicStatusReadOverlap * 1000) + 300))
        let count = await requests.count
        XCTAssertEqual(count, 2)
        XCTAssertNil(model.nowPlaying)
        XCTAssertFalse(model.isRunning)
    }

    private func track(_ state: AppleMusicNowPlaying.State, title: String = "Song") -> AppleMusicNowPlaying {
        AppleMusicNowPlaying(state: state, title: title, artist: "Artist", album: "Album", duration: 200, position: nil,
            positionDate: Date())
    }

    private func status(_ state: String, title: String = "Song", position: String = "10") -> AppleMusicScriptOutput {
        .success([state, title, "Artist", "Album", "200", position, ""].joined(separator: "\u{1F}"))
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

    func testANewTrackStartsFromItsBeginningUntilMusicSaysWhereItIs() {
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in nil },
            requestArtwork: { .failed })
        model.receive(track(.playing))
        model.receive(track(.playing, title: "Next"))
        XCTAssertNil(model.nowPlaying?.position, "Nothing is assumed before Music has said where it is")
        model.receive(statusResult: status("playing", title: "Next", position: "120"), sequence: model.stateSequence)
        model.receive(track(.paused, title: "Next"))
        XCTAssertEqual(model.nowPlaying?.position ?? 0, 120, accuracy: 1, "The same track counts on from Music's answer")
        model.receive(track(.paused, title: "Third"))
        XCTAssertEqual(model.nowPlaying?.title, "Third")
        XCTAssertEqual(model.nowPlaying?.position, 0)
        XCTAssertEqual(model.nowPlaying?.elapsed(at: Date().addingTimeInterval(60)), 0, "A paused new track stays put")
        model.receive(track(.playing, title: "Fourth"))
        XCTAssertEqual(model.nowPlaying?.position, 0, "Skipping on before Music answers keeps the progress bar")
        model.receive(statusResult: status("playing", title: "Fourth", position: "0,5"), sequence: model.stateSequence)
        XCTAssertEqual(model.nowPlaying?.position, 0.5, "Music's answer replaces the assumption")
        model.receive(track(.stopped))
        XCTAssertNil(model.nowPlaying?.position)
        model.receive(track(.playing, title: "Fifth"))
        XCTAssertEqual(model.nowPlaying?.position, 0, "Playing again after a stop starts from the beginning too")
    }

    func testAnAssumedStartMusicDoesntConfirmIsDropped() {
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in nil },
            requestArtwork: { .failed })
        model.receive(statusResult: status("playing", position: "30"), sequence: model.stateSequence)
        let beforeTheChange = model.stateSequence
        model.receive(track(.playing, title: "Next"))
        model.receive(track(.playing, title: "Next"))
        XCTAssertEqual(model.nowPlaying?.position ?? -1, 0, accuracy: 1, "Music repeating itself keeps the assumption")
        model.receive(statusResult: .failed, sequence: beforeTheChange)
        XCTAssertNotNil(model.nowPlaying?.position, "A failure from before the track changed is ignored")
        model.receive(statusResult: .failed, sequence: model.stateSequence)
        XCTAssertNil(model.nowPlaying?.position, "A track that resumed partway doesn't count on from zero unchecked")
        model.receive(track(.playing, title: "Third"))
        XCTAssertNil(model.nowPlaying?.position, "Nothing is assumed until Music answers again")
        model.receive(statusResult: status("playing", title: "Third", position: "5"), sequence: model.stateSequence)
        model.receive(track(.playing, title: "Fourth"))
        XCTAssertEqual(model.nowPlaying?.position, 0)
        model.receive(statusResult: nil, sequence: model.stateSequence)
        XCTAssertNil(model.nowPlaying?.position, "Nor once WinMux may no longer ask Music")
        model.receive(statusResult: status("playing", title: "Fourth", position: "5"), sequence: model.stateSequence)
        model.receive(statusResult: .failed, sequence: model.stateSequence)
        XCTAssertEqual(model.nowPlaying?.position, 5, "A position Music gave is kept")
    }

    func testAnAssumedStartGoesOnceMusicMayNoLongerBeAsked() async throws {
        let attempts = AttemptCounter()
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in
            await attempts.next() == 1 ? .success(["playing", "Song", "Artist", "Album", "200", "30", ""].joined(separator: "\u{1F}")) : nil
        }, requestArtwork: { .success("") })
        model.receive(track(.playing))
        try await waitUntil { model.nowPlaying?.position == 30 }
        model.receive(track(.playing, title: "Next"))
        XCTAssertEqual(model.nowPlaying?.position, 0)
        try await waitUntil { model.nowPlaying?.position == nil }
        XCTAssertEqual(model.nowPlaying?.title, "Next")
    }

    /// Music's tab doesn't shrink and grow back while Music is asked where a new track is.
    func testSwitchingTracksKeepsTheProgressBarWhileMusicIsAsked() async throws {
        let replies = HeldReplies()
        defer { Task { await replies.release() } }
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in
            await replies.wait()
            return nil
        }, requestArtwork: { .failed })
        let host = NSHostingView(rootView: WorkspaceSidebarMusicNowPlayingView(onSelect: {}, model: model)
            .frame(width: 280))
        func height() -> CGFloat {
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        model.receive(track(.playing))
        try await waitUntil { height() > 40 }
        let withoutProgress = height()
        model.receive(statusResult: status("playing"), sequence: model.stateSequence)
        try await waitUntil { height() > withoutProgress + 5 }
        let withProgress = height()
        model.receive(track(.playing, title: "Next"))
        // Music's answer stays held throughout, past the track change's animation.
        var lowest = withProgress
        for _ in 0..<30 {
            lowest = min(lowest, height())
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.nowPlaying?.title, "Next")
        XCTAssertEqual(lowest, withProgress, accuracy: 0.5)
    }

    /// Music's notifications for the track already shown say only whether it plays; they may
    /// leave out its length or spell it differently from Music's replies.
    func testPausingChangesOnlyWhetherMusicPlays() async throws {
        let replies = HeldReplies()
        defer { Task { await replies.release() } }
        let artworkRequests = AttemptCounter()
        let hex = try redSquareHex()
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in
            await replies.wait()
            return nil
        }, requestArtwork: {
            _ = await artworkRequests.next()
            return .success("«data tdta\(hex)»")
        })
        model.receive(statusResult: .success(["playing", "Song", "Artist", "Album", "200", "30", "780C811DD434C4C9"]
            .joined(separator: "\u{1F}")), sequence: model.stateSequence)
        try await waitUntil { model.artwork != nil }
        let id = NSNumber(value: Int64(bitPattern: 0x780C_811D_D434_C4C9))
        func notify(_ info: [AnyHashable: Any]) throws {
            model.receive(try XCTUnwrap(appleMusicNowPlaying(playerInfo: info.merging(["PersistentID": id]) { $1 })))
        }
        // Music's notifications spell the track their own way, and this pause leaves out its length.
        try notify(["Player State": "Playing", "Name": "Song (Live)", "Artist": "Artist"])
        try notify(["Player State": "Paused", "Name": "Song (Live)", "Artist": "Artist"])
        XCTAssertEqual(model.nowPlaying?.state, .paused)
        XCTAssertEqual(model.nowPlaying?.duration, 200, "A notification without the length keeps it")
        XCTAssertEqual(model.nowPlaying?.title, "Song", "The track keeps what Music's reply said")
        XCTAssertEqual(model.nowPlaying?.album, "Album")
        XCTAssertEqual(model.nowPlaying?.position ?? 0, 30, accuracy: 1, "Nor does it start over")
        try notify(["Player State": "Playing", "Name": "Song (Live)", "Artist": "Artist",
            "Total Time": NSNumber(value: 200_000)])
        XCTAssertEqual(model.nowPlaying?.state, .playing)
        XCTAssertEqual(model.nowPlaying?.title, "Song")
        XCTAssertNotNil(model.artwork)
        try await Task.sleep(for: .milliseconds(50))
        let requests = await artworkRequests.count
        XCTAssertEqual(requests, 1, "The artwork isn't fetched again")
        try notify(["Player State": "Playing", "Name": "Next Song", "Artist": "Radio"])
        XCTAssertEqual(model.nowPlaying?.title, "Next Song", "A stream's next song under one identifier shows")
        XCTAssertNil(model.artwork, "and gets its own artwork")
        model.receive(try XCTUnwrap(appleMusicNowPlaying(playerInfo: ["Player State": "Playing", "Name": "Song",
            "Artist": "Artist", "Album": "Album", "PersistentID": NSNumber(value: 7), "Total Time": NSNumber(value: 100_000)])))
        XCTAssertEqual(model.nowPlaying?.duration, 100, "Another track, however it's spelled, is new")
        XCTAssertEqual(model.nowPlaying?.position, 0)
    }

    func testAReplyWithoutAnIdentifierTakesTheNotificationsOne() throws {
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in nil },
            requestArtwork: { .failed })
        model.receive(statusResult: status("playing"), sequence: model.stateSequence)
        model.receive(try XCTUnwrap(appleMusicNowPlaying(playerInfo: ["Player State": "Paused", "Name": "Song",
            "Artist": "Artist", "Album": "Album", "PersistentID": NSNumber(value: 42)])))
        XCTAssertEqual(model.nowPlaying?.state, .paused)
        XCTAssertEqual(model.nowPlaying?.persistentId, "000000000000002A")
        model.receive(statusResult: status("paused"), sequence: model.stateSequence)
        XCTAssertEqual(model.nowPlaying?.persistentId, "000000000000002A", "Nor does the next reply lose it")
        model.receive(statusResult: status("playing", title: "Other Song"), sequence: model.stateSequence)
        XCTAssertNil(model.nowPlaying?.persistentId, "Another track doesn't take it")
    }

    /// A stream's songs can share one identifier; Music's reply naming the next one brings its artwork.
    func testANewSongUnderOneIdentifierGetsItsOwnArtwork() async throws {
        let artworkRequests = AttemptCounter()
        let hex = try redSquareHex()
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in nil }, requestArtwork: {
            _ = await artworkRequests.next()
            return .success("«data tdta\(hex)»")
        })
        func reply(_ title: String) {
            model.receive(statusResult: .success(["playing", title, "Radio", "", "missing value", "30", "000000000000002A"]
                .joined(separator: "\u{1F}")), sequence: model.stateSequence)
        }
        reply("First Song")
        try await waitUntil { model.artwork != nil }
        reply("Second Song")
        XCTAssertEqual(model.nowPlaying?.title, "Second Song")
        try await waitUntil { await artworkRequests.count == 2 }
        try await waitUntil { model.artwork != nil }
    }

    func testWithoutMusicsRepliesNotificationsSayWhatsPlaying() throws {
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in nil },
            requestArtwork: { .failed })
        func notify(_ info: [AnyHashable: Any]) throws {
            model.receive(try XCTUnwrap(appleMusicNowPlaying(playerInfo: info.merging(["PersistentID": NSNumber(value: 42)])
                { $1 })))
        }
        try notify(["Player State": "Playing", "Name": "Song", "Total Time": NSNumber(value: 200_000)])
        try notify(["Player State": "Paused", "Name": "Song"])
        XCTAssertEqual(model.nowPlaying?.state, .paused)
        XCTAssertEqual(model.nowPlaying?.duration, 200, "A pause announced without the length keeps it")
        try notify(["Player State": "Playing", "Name": "Next Song"])
        XCTAssertEqual(model.nowPlaying?.title, "Next Song", "A stream's next song under one identifier still shows")
    }

    /// The player keeps its progress bar through a pause that Music announces without the length.
    func testPausingKeepsTheProgressBar() async throws {
        let replies = HeldReplies()
        defer { Task { await replies.release() } }
        let model = AppleMusicNowPlayingModel(isMusicRunning: { true }, requestStatus: { _ in
            await replies.wait()
            return nil
        }, requestArtwork: { .success("") })
        let host = NSHostingView(rootView: WorkspaceSidebarMusicNowPlayingView(onSelect: {}, model: model)
            .frame(width: 280))
        func height() -> CGFloat {
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        model.receive(statusResult: .success(["playing", "Song", "Artist", "Album", "200", "30", "000000000000002A"]
            .joined(separator: "\u{1F}")), sequence: model.stateSequence)
        try await waitUntil { height() > 60 }
        let withProgress = height()
        // Music says the old state first, then the new one, spelling the track its own way.
        for state in ["Playing", "Paused"] {
            model.receive(try XCTUnwrap(appleMusicNowPlaying(playerInfo: ["Player State": state, "Name": "Song (Live)",
                "Artist": "Artist", "PersistentID": NSNumber(value: 42)])))
        }
        var lowest = withProgress
        for _ in 0..<30 {
            lowest = min(lowest, height())
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.nowPlaying?.state, .paused)
        XCTAssertEqual(model.nowPlaying?.title, "Song")
        XCTAssertEqual(lowest, withProgress, accuracy: 0.5)
    }

    private func redSquareHex() throws -> String {
        let image = try XCTUnwrap(NSImage(size: NSSize(width: 2, height: 2), flipped: false) { _ in
            NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); return true
        }.tiffRepresentation)
        return image.map { String(format: "%02X", $0) }.joined()
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

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
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

/// Each request to Music, in order, held until the test answers it.
private actor StatusRequests {
    private(set) var asked: [Bool] = []
    private var pending: [CheckedContinuation<AppleMusicScriptOutput?, Never>] = []

    var count: Int { asked.count }

    func request(askingMusic: Bool) async -> AppleMusicScriptOutput? {
        asked.append(askingMusic)
        return await withCheckedContinuation { pending.append($0) }
    }

    func answerNext(_ output: AppleMusicScriptOutput?) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: output)
    }
}

/// Holds a test's requests to Music until it lets them through.
private actor HeldReplies {
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
