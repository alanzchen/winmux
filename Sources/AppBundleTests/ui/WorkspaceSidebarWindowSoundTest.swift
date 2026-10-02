import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

/// Which of an app's windows show that it's playing sound.
final class WorkspaceSidebarWindowSoundTest: XCTestCase {
    private let chrome = "com.google.Chrome"

    private func window(_ id: UInt32, _ bundleId: String, title: String? = nil) -> WorkspaceSidebarWindowViewModel {
        .init(windowId: id, workspaceName: "\(id)", appName: bundleId == safariBundleId ? "Safari" : "App", appBundleId: bundleId,
            appBundlePath: nil, title: title ?? "Window \(id)", isFocused: false)
    }

    private func browser(_ id: UInt32, _ audio: [BrowserTabAudio?], knowsSound: Bool = false) -> BrowserWindowTabs {
        let session = UUID()
        var snapshot = BrowserWindowTabs(windowId: id, pid: 7, windowSession: session, tabs: audio.enumerated().map { index, audio in
            .init(target: .init(windowId: id, pid: 7, windowSession: session, tabId: UUID()), title: "Tab \(index)",
                isSelected: index == 0, audio: audio)
        })
        snapshot.knowsSound = knowsSound
        return snapshot
    }

    private func shown(_ info: WorkspaceSidebarBrowserWindows, _ windows: [WorkspaceSidebarWindowViewModel],
                       playing: Set<String>) -> [BrowserTabAudio?] {
        windows.map { info.audio(windowId: $0.windowId, bundleId: $0.appBundleId, appIsPlaying: $0.appBundleId.map(playing.contains) ?? false) }
    }

    func testOnlyTheSafariWindowWithAnAudibleTabShowsSound() {
        let windows = [1, 2, 3].map { window($0, safariBundleId) }
        let info = WorkspaceSidebarBrowserWindows([
            1: browser(1, [nil, nil], knowsSound: true),
            2: browser(2, [nil, .playing], knowsSound: true),
            3: browser(3, [nil], knowsSound: true),
        ], windows: windows)
        XCTAssertEqual(shown(info, windows, playing: [safariBundleId]), [nil, .playing, nil])
        XCTAssertEqual(shown(info, windows, playing: []), [nil, .playing, nil], "The tab says so even before Core Audio does")
        let quiet = WorkspaceSidebarBrowserWindows([1: browser(1, [nil], knowsSound: true), 2: browser(2, [nil], knowsSound: true)],
            windows: windows)
        XCTAssertEqual(shown(quiet, windows, playing: [safariBundleId]), [nil, nil, .playing],
            "Only a window the extension doesn't describe, such as a private one, can be where Safari's sound comes from")
        XCTAssertEqual(shown(quiet, Array(windows.prefix(2)), playing: [safariBundleId]), [nil, nil],
            "Windows whose tabs are all silent never show it")
    }

    func testAWindowPlayingSoundAccountsForItsAppsOtherWindows() {
        let windows = [4, 5, 6].map { window($0, chrome) }
        let info = WorkspaceSidebarBrowserWindows([4: browser(4, [nil, .playing, nil]), 5: browser(5, [nil, nil])], windows: windows)
        XCTAssertEqual(shown(info, windows, playing: [chrome]), [.playing, nil, nil],
            "Neither the other read window nor an unread one shows the app's sound")
        let unnamed = WorkspaceSidebarBrowserWindows([4: browser(4, [nil]), 5: browser(5, [nil, nil])], windows: windows)
        XCTAssertEqual(shown(unnamed, windows, playing: [chrome]), [.playing, .playing, .playing],
            "A Chromium tab without a sound label may still play, so while none says it does, every window shows it")
        XCTAssertEqual(shown(unnamed, windows, playing: []), [nil, nil, nil])
    }

    func testAMutedTabShowsOnItsWindowWithoutHidingSoundElsewhere() {
        let windows = [1, 2].map { window($0, chrome) }
        let info = WorkspaceSidebarBrowserWindows([1: browser(1, [.muted, nil]), 2: browser(2, [nil])], windows: windows)
        XCTAssertEqual(shown(info, windows, playing: []), [.muted, nil])
        XCTAssertEqual(shown(info, windows, playing: [chrome]), [.muted, .playing], "A muted tab isn't where sound comes from")
        let both = WorkspaceSidebarBrowserWindows([1: browser(1, [.muted, .playing])], windows: windows)
        XCTAssertEqual(shown(both, windows, playing: [chrome]), [.playing, nil], "A window playing sound shows that over a muted tab")
    }

    func testAppsWithoutBrowserTabsShowTheirSoundOnEveryWindow() {
        let music = [7, 8].map { window($0, appleMusicBundleId) }
        let chromeWindows = [9, 10].map { window($0, chrome) }
        let info = WorkspaceSidebarBrowserWindows([9: browser(9, [.playing])], windows: music + chromeWindows)
        XCTAssertEqual(shown(info, music + chromeWindows, playing: [appleMusicBundleId, chrome]), [.playing, .playing, .playing, nil])
        XCTAssertEqual(shown(WorkspaceSidebarBrowserWindows(), music, playing: [appleMusicBundleId]), [.playing, .playing],
            "Outside Tabs mode, as before")
        XCTAssertEqual(shown(info, [window(11, "com.example.NoBundle")], playing: []), [nil])
    }

    func testAReadsSoundCountsOnlyWhileTheReadIsRecent() {
        let snapshot = browser(1, [.playing, nil])
        let associations = SafariExtensionAssociations()
        XCTAssertEqual(browserTabsShown(snapshot, read: 100, now: 105, safari: associations, iconOrigins: [:]).tabs.map(\.audio),
            [.playing, nil])
        XCTAssertEqual(browserTabsShown(snapshot, read: 100, now: 100 + browserTabSoundLifetime, safari: associations,
            iconOrigins: [:]).tabs.map(\.audio), [nil, nil], "A window the sidebar stopped reading keeps its tabs but not their sound")
        XCTAssertEqual(browserTabsShown(snapshot, read: nil, now: 0, safari: associations, iconOrigins: [:]).tabs.map(\.audio), [nil, nil])
        XCTAssertFalse(browserTabsShown(snapshot, read: 100, now: 105, safari: associations, iconOrigins: [:]).knowsSound)
    }

    /// Safari's tabs show their sound in Accessibility too; while the extension describes a
    /// window, what it says wins.
    func testTheSafariExtensionsSoundWinsOverAccessibilitysWhileItDescribesTheWindow() {
        let session = UUID()
        let read = BrowserWindowTabs(windowId: 1, pid: 7, windowSession: session, tabs: ["Inbox", "Docs"].enumerated().map { index, title in
            .init(target: .init(windowId: 1, pid: 7, windowSession: session, tabId: UUID()), title: title, isSelected: index == 0,
                audio: index == 0 ? .playing : nil)
        })
        func reported(audible: [Bool], muted: [Bool] = [false, false]) -> SafariExtensionWindow {
            .init(key: .init(source: "p:s", id: 10), legacy: true, tabs: ["Inbox", "Docs"].enumerated().map { index, title in
                .init(title: title, isActive: index == 0, isAudible: audible[index], isMuted: muted[index])
            })
        }
        func shown(_ report: SafariExtensionWindow) -> [BrowserTabAudio?] {
            var associations = SafariExtensionAssociations()
            for time in [0.0, 1] { associations.update([.init(snapshot: read, observed: time)], windows: [report], now: time) }
            return browserTabsShown(read, read: 1, now: 1, safari: associations, iconOrigins: [:]).tabs.map(\.audio)
        }
        XCTAssertEqual(shown(reported(audible: [false, true])), [nil, .playing])
        XCTAssertEqual(shown(reported(audible: [true, false], muted: [true, false])), [.muted, nil])
        XCTAssertEqual(shown(reported(audible: [false, false])), [nil, nil], "The extension says it stopped")
        XCTAssertEqual(browserTabsShown(read, read: 1, now: 1, safari: SafariExtensionAssociations(), iconOrigins: [:]).tabs.map(\.audio),
            [.playing, nil], "Without the extension, Accessibility says which tab plays")
    }

    /// Safari hides the tab bar of a window with one tab. Such a window pairs with the extension
    /// by its title, so several of them tell apart which one plays.
    func testSafariWindowsWithoutTabBarsPairByTheirTitlesAndOnlyThePlayingOneShowsSound() {
        func lone(_ id: UInt32, _ title: String) -> BrowserWindowTabs {
            let session = UUID()
            return .init(windowId: id, pid: 7, windowSession: session,
                tabs: [.init(target: .init(windowId: id, pid: 7, windowSession: session, tabId: UUID()), title: title, isSelected: true)])
        }
        func reported(_ id: Int, _ title: String, audible: Bool = false) -> SafariExtensionWindow {
            .init(key: .init(source: "p:s", id: id), legacy: true, tabs: [.init(title: title, isActive: true, isAudible: audible)])
        }
        let snapshots = [lone(1, "Lo-fi radio"), lone(2, "Docs"), lone(3, "Mail")]
        let report = [reported(10, "Docs"), reported(11, "Lo-fi radio", audible: true), reported(12, "Mail")]
        var associations = SafariExtensionAssociations()
        for time in [0.0, 1] {
            associations.update(snapshots.map { .init(snapshot: $0, observed: time) }, windows: report, now: time)
        }
        let shownSnapshots = Dictionary(uniqueKeysWithValues: snapshots.map {
            ($0.windowId, browserTabsShown($0, read: 1, now: 1, safari: associations, iconOrigins: [:]))
        })
        XCTAssertEqual(shownSnapshots.values.filter(\.knowsSound).count, 3)
        let windows = [1, 2, 3].map { window($0, safariBundleId) }
        XCTAssertEqual(shown(WorkspaceSidebarBrowserWindows(shownSnapshots, windows: windows), windows, playing: [safariBundleId]),
            [.playing, nil, nil])
    }

    @MainActor
    private final class Changes {
        var list: [Set<String>] = []
    }

    @MainActor
    func testCoreAudioNamesTheAppsThatStartOrStopPlaying() {
        let changes = Changes()
        let model = AudioActivityModel(read: { [] }, changed: { changes.list.append($0) })
        model.setPlaying([chrome])
        model.setPlaying([chrome])
        model.setPlaying([chrome, safariBundleId])
        model.setPlaying([safariBundleId])
        model.setEnabled(false)
        XCTAssertEqual(changes.list, [[chrome], [safariBundleId], [chrome], [safariBundleId]])
    }

    @MainActor
    func testTheSpeakerFollowsItsWindowAndShowsAMutedTab() {
        let audio = AudioActivityModel(read: { [] })
        audio.setPlaying([safariBundleId])
        let windows = [1, 2, 3].map { window($0, safariBundleId) }
        let info = WorkspaceSidebarBrowserWindows([
            1: browser(1, [nil], knowsSound: true), 2: browser(2, [.playing], knowsSound: true), 3: browser(3, [.muted], knowsSound: true),
        ], windows: windows)
        func width(_ window: WorkspaceSidebarWindowViewModel, _ info: WorkspaceSidebarBrowserWindows) -> CGFloat {
            let host = NSHostingView(rootView: WorkspaceSidebarTabAudioIndicator(window: window, model: audio)
                .environment(\.workspaceSidebarBrowserWindows, info))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        XCTAssertEqual(width(windows[0], info), 0)
        XCTAssertGreaterThan(width(windows[1], info), 0)
        XCTAssertGreaterThan(width(windows[2], info), 0)
        XCTAssertGreaterThan(width(windows[0], WorkspaceSidebarBrowserWindows()), 0, "Without tabs, the app's sound shows")
    }

    /// Three Safari windows, one tab each, in the Tabs sidebar; only the second's tab plays. The
    /// composed sidebar is drawn with nothing playing, then with that tab playing: only the second
    /// window's row changes, at its trailing end, where the speaker sits, and only that row has ink
    /// there. Each row is the window it should be: changing a title changes only its row.
    @MainActor
    func testTheTabsSidebarShowsSoundOnlyOnTheWindowWhoseTabPlays() throws {
        defer { AudioActivityModel.shared.setPlaying([]) }
        let titles = ["Alpha", "Bravo", "Charlie"]
        func windows(_ titles: [String]) -> [WorkspaceSidebarWindowViewModel] {
            // No installed app's icon: one read again in the background could change between renders.
            titles.enumerated().map { index, title in
                .init(windowId: UInt32(index + 1), workspaceName: "\(index + 1)", appName: "Safari", appBundleId: safariBundleId,
                    appBundlePath: workspaceSidebarTestMissingAppPath, title: title, isFocused: false)
            }
        }
        func sidebar(_ titles: [String]) -> WorkspaceSidebarSnapshot {
            var snapshot = WorkspaceSidebarSnapshot.empty
            snapshot.configuration.usesTabsList = true
            snapshot.configuration.expandedWidth = 280
            snapshot.configuration.collapsedWidth = 44
            snapshot.visibleWidth = 280
            snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
            snapshot.workspaces = windows(titles).map { window in
                WorkspaceSidebarWorkspaceViewModel(name: window.workspaceName, projectId: workspaceProjectDefaultId,
                    displayName: window.workspaceName, sidebarLabel: "", isGeneratedName: true, monitorScopeId: "monitor:0,0",
                    monitorName: nil, isFocused: false, isVisible: false, items: [.init(kind: .window(window))])
            }
            return snapshot
        }
        func tabs(playing: Bool) -> BrowserTabsModel {
            BrowserTabsModel(snapshots: [
                1: browser(1, [nil], knowsSound: true), 2: browser(2, [playing ? .playing : nil], knowsSound: true),
                3: browser(3, [nil], knowsSound: true),
            ])
        }
        let size = CGSize(width: 280, height: 360)
        AudioActivityModel.shared.setPlaying([])
        let silent = try renderWorkspaceSidebarForTest(sidebar(titles), browserTabs: tabs(playing: false), size: size)
        AudioActivityModel.shared.setPlaying([safariBundleId])
        let playing = try renderWorkspaceSidebarForTest(sidebar(titles), browserTabs: tabs(playing: true), size: size)

        // Each window's row, as the sidebar laid it out: workspace n holds window n.
        let rows = try windows(titles).map { try XCTUnwrap(playing.frame(of: .workspace($0.workspaceName)), "\($0.title ?? "") row") }
        XCTAssertEqual(rows, windows(titles).map { silent.frame(of: .workspace($0.workspaceName)) }, "Sound moves no row")
        for (index, row) in rows.enumerated() {
            var renamed = titles
            renamed[index] = "Delta"
            let title = try XCTUnwrap(renderWorkspaceSidebarForTest(sidebar(renamed), browserTabs: tabs(playing: true), size: size)
                .difference(from: playing), "The sidebar draws “\(titles[index])”").bounds
            XCTAssertTrue(row.contains(title) && title.maxX <= row.midX, "\(titles[index]) is drawn at the start of its row: \(title) in \(row)")
        }

        let speaker = try XCTUnwrap(playing.difference(from: silent), "The sidebar shows the sound").bounds
        XCTAssertTrue(rows[1].contains(speaker), "Only Bravo's row changes: \(speaker) in \(rows)")
        XCTAssertGreaterThan(speaker.minX, rows[1].midX, "at its trailing end, where the speaker sits: \(speaker) in \(rows[1])")
        for index in [0, 2] {
            XCTAssertNil(playing.difference(from: silent, in: rows[index]), "\(titles[index])'s row shows no sound")
        }
        // And absolutely, as drawn: ink at a row's trailing end, past its title, is only the speaker.
        func trailingInk(_ render: WorkspaceSidebarTestRender) -> [Int] {
            rows.map { render.inkPixels(in: CGRect(x: $0.midX, y: $0.minY, width: $0.maxX - $0.midX, height: $0.height)) }
        }
        let ink = trailingInk(playing)
        XCTAssertEqual(ink[0], 0, "\(ink)")
        XCTAssertGreaterThan(ink[1], 10, "\(ink)")
        XCTAssertEqual(ink[2], 0, "\(ink)")
        XCTAssertEqual(trailingInk(silent), [0, 0, 0], "Nothing playing, no row shows sound")
    }
}
