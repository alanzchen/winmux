import AppKit
@testable import AppBundle
import SwiftUI
import Vision
import XCTest

final class BrowserTabsTest: XCTestCase {
    func testTabRadioValueFallsBackToSelectedWhenUnavailable() {
        XCTAssertEqual(browserTabSelectedValue(value: 0, selected: 1), false)
        XCTAssertEqual(browserTabSelectedValue(value: 1, selected: 1), true)
        XCTAssertEqual(browserTabSelectedValue(value: nil, selected: 1), true)
        XCTAssertNil(browserTabSelectedValue(value: nil, selected: nil))
    }

    func testPollingBacksOffFailuresAndNeverReadsHiddenWindows() {
        var schedule = BrowserTabReadSchedule()
        XCTAssertFalse(schedule.isDue(1, now: 0))
        schedule.watch([1, 2])
        schedule.focus(1)
        XCTAssertTrue(schedule.isDue(1, now: 0))
        var time = 0.0
        for interval in [1.0, 2, 4, 8, 16, 30, 30] {
            schedule.didRead(1, now: time, succeeded: false)
            schedule.markDirty(1)
            XCTAssertFalse(schedule.isDue(1, now: time + interval - 0.1))
            XCTAssertTrue(schedule.isDue(1, now: time + interval))
            time += interval
        }
        schedule.markDirty(1)
        XCTAssertTrue(schedule.isDue(1, now: time))
        schedule.didRead(1, now: time, succeeded: true)
        schedule.markDirty(1)
        XCTAssertFalse(schedule.isDue(1, now: time + 0.5), "Noisy notifications cannot cause four scans a second")
        XCTAssertTrue(schedule.isDue(1, now: time + 1))
        schedule.watch([])
        XCTAssertFalse(schedule.isDue(1, now: time + 1000))
        schedule.watch([1, 2])
        XCTAssertTrue(schedule.isDue(1, now: time), "Revealing the sidebar refreshes immediately")
        schedule.didRead(2, now: time, succeeded: false)
        schedule.focus(2)
        XCTAssertTrue(schedule.isDue(2, now: time), "Changing focus resets retry backoff")
    }

    func testIncompleteCachedStripKeepsContainerAndSelectionOnlyRechecksItsTarget() throws {
        let tree = fixture(.chromium)
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        let rootReads = tree.root.structureReads
        tree.tabs[1].unreadable = true
        XCTAssertNil(tree.scanner.scan())
        XCTAssertTrue(tree.scanner.container === tree.container)
        XCTAssertTrue(tree.scanner.observedNodes.contains(tree.tabs[0]), "Incomplete icon confirmation must keep the selected tab's subscriptions")
        XCTAssertNil(tree.scanner.scan())
        XCTAssertEqual(tree.root.structureReads, rootReads)
        XCTAssertTrue(tree.scanner.select(snapshot.tabs[0].target), "An unrelated unreadable tab cannot block an exact live target")
        tree.container.nodes.removeFirst()
        XCTAssertFalse(tree.scanner.select(snapshot.tabs[0].target), "A removed handle is rejected even before another complete scan")
    }

    func testLargeCachedStripGetsABoundedBudgetBasedOnItsSize() throws {
        let tree = fixture(.chromium)
        for _ in 0..<118 { tree.container.append(tab("Background", selected: false)) }
        var time = 0.0
        tree.container.nodes.forEach { $0.onInfoRead = { time += 0.0009 } }
        let scanner = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45, now: { time })
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).tabs.count, 120)
        let snapshot = try XCTUnwrap(scanner.scan())
        XCTAssertEqual(snapshot.tabs.count, 120, "A 108 ms complete cached scan fits the scaled 150 ms cap")
        XCTAssertTrue(scanner.confirmsSelection(in: snapshot, until: time + 0.02), "Icons recheck just the selected control, not 120 tab records")
        tree.tabs[0].selected = false
        XCTAssertFalse(scanner.confirmsSelection(in: snapshot, until: time + 0.02))
        tree.tabs[0].selected = true
        XCTAssertFalse(scanner.confirmsSelection(in: snapshot, until: time + 0.02, cancelled: { true }))
        XCTAssertNil(scanner.scan(until: time + 0.02), "An outer job budget is still authoritative")
        XCTAssertTrue(scanner.container === tree.container)
    }

    func testUnreadableDiscoveryBranchNeverHidesAnUnknownSecondStrip() {
        let tree = fixture(.chromium)
        let unknown = BrowserTestNode("AXGroup")
        unknown.unreadable = true
        tree.root.append(unknown)
        XCTAssertNil(tree.scanner.scan(), "An unreadable branch may contain another tab container")
        unknown.unreadable = false
        XCTAssertNotNil(tree.scanner.scan())
    }

    func testCachedChromeStructureIsPeriodicallyRediscovered() throws {
        let tree = fixture(.chromium)
        var time = 0.0
        let scanner = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45, now: { time })
        let first = try XCTUnwrap(scanner.scan())
        let extra = BrowserTestNode("AXTabGroup")
        tree.root.append(extra)
        time = 61
        XCTAssertNil(scanner.scan(), "A new second strip must eventually invalidate the original complete-list assumption")
        tree.root.nodes.removeLast()
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).tabs.map(\.id), first.tabs.map(\.id))
    }
    func testSafariFindsTabsOutsideEmptyTabGroupAndSkipsPageAndSidebar() throws {
        let tree = fixture(.safari)
        let forbidden = BrowserTestNode("AXWebArea")
        let fakeTab = tab("Page radio", selected: true)
        forbidden.append(fakeTab)
        let outline = BrowserTestNode("AXOutline")
        outline.append(tab("Sidebar", selected: true))
        tree.root.append(forbidden)
        tree.root.append(outline)
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertEqual(snapshot.tabs.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(forbidden.childReads, 0)
        XCTAssertEqual(forbidden.infoReads, 0)
        XCTAssertEqual(fakeTab.structureReads, 0)
        XCTAssertEqual(outline.childReads, 0)
    }

    func testSafarisTabsScrolledOutOfACrowdedTabBarStillMakeTheWholeGroup() throws {
        // Safari 27 tabs outside the visible tab bar answer AXParent with kAXErrorNoValue.
        let window = try crowdedSafariWindow()
        XCTAssertEqual(window.tabs.filter(\.reportsNoParent).map(\.title), (2...8).map { String(format: "Tab %02d", $0) })
        // With 40 tabs, the native check found those tabs naming no window either, and others
        // piled up with no title, only a description.
        window.tabs.filter(\.reportsNoParent).forEach { $0.reportsNoWindow = true }
        for tab in window.tabs[8...15] {
            tab.summary = tab.title
            tab.title = "unused"
            tab.reportsNoTitle = true
        }
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8)
        let snapshot = try XCTUnwrap(scanner.scan())
        XCTAssertEqual(snapshot.tabs.map(\.title), (1...24).map { String(format: "Tab %02d", $0) })
        XCTAssertEqual(snapshot.tabs.filter(\.isSelected).map(\.title), ["Tab 01"])
        XCTAssertTrue(scanner.container === window.tabBar)
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).tabs.map(\.id), snapshot.tabs.map(\.id), "Reads after discovery keep each tab")
    }

    func testATabOutOfViewIsActedOnOnlyOnceItsBarShowsIt() throws {
        // Natively, Safari accepts a press or close on a tab that names no parent and does neither.
        let window = try crowdedSafariWindow()
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8)
        let snapshot = try XCTUnwrap(scanner.scan())
        let close = "Name:close tab\nTarget:0x0\n\(browserTabCloseSelector)"
        let (hidden, other) = (window.tabs[4], window.tabs[5])
        hidden.reportsNoWindow = true
        hidden.actions = ["AXScrollToVisible", "AXPress", close]
        XCTAssertFalse(scanner.select(snapshot.tabs[4].target), "Scrolling that leaves it out of view says so")
        XCTAssertFalse(scanner.close(snapshot.tabs[4].target))
        XCTAssertEqual(hidden.presses, 0)
        XCTAssertEqual(hidden.performed, ["AXScrollToVisible", "AXScrollToVisible"])
        other.actions = ["AXPress", close]
        XCTAssertFalse(scanner.select(snapshot.tabs[5].target), "Nor is one that can't be scrolled into view pressed")
        XCTAssertEqual(other.presses, 0)
        // Once scrolling shows it, it names its bar again and is pressed or closed.
        hidden.onPerform = { action in
            if action == "AXScrollToVisible" { hidden.reportsNoParent = false; hidden.reportsNoWindow = false }
        }
        XCTAssertTrue(scanner.select(snapshot.tabs[4].target))
        XCTAssertEqual(hidden.presses, 1)
        hidden.reportsNoParent = true
        XCTAssertTrue(scanner.close(snapshot.tabs[4].target))
        XCTAssertEqual(hidden.performed.last, close)
    }

    func testATabPiledUpInTheBarIsScrolledIntoViewBeforeItsPressedOrClosed() throws {
        // Natively, Safari's piled-up tabs have no title, only a description, and offer only
        // AXScrollToVisible until they're in view.
        let window = try crowdedSafariWindow()
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8)
        let snapshot = try XCTUnwrap(scanner.scan())
        let piled = window.tabs[12]
        let close = "Name:close tab\nTarget:0x0\n\(browserTabCloseSelector)"
        piled.supportsPress = false
        piled.actions = ["AXScrollToVisible"]
        piled.onPerform = { action in
            guard action == "AXScrollToVisible" else { return }
            piled.supportsPress = true
            piled.actions = ["AXScrollToVisible", "AXPress", close]
        }
        XCTAssertTrue(scanner.select(snapshot.tabs[12].target))
        XCTAssertEqual(piled.presses, 1)
        piled.actions = ["AXScrollToVisible"]
        XCTAssertTrue(scanner.close(snapshot.tabs[12].target))
        XCTAssertEqual(piled.performed, ["AXScrollToVisible", "AXScrollToVisible", close])
        // A tab already in view is pressed without scrolling.
        XCTAssertTrue(scanner.select(snapshot.tabs[20].target))
        XCTAssertEqual(window.tabs[20].performed, [])
    }

    func testATabThatChangesWhileScrollingIntoViewIsCheckedAgainBeforeItsPressed() throws {
        try checkATabThatChangesWhileScrollingIntoView(closing: false)
        try checkATabThatChangesWhileScrollingIntoView(closing: true)
    }

    private func checkATabThatChangesWhileScrollingIntoView(closing: Bool) throws {
        let window = try crowdedSafariWindow()
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8)
        let snapshot = try XCTUnwrap(scanner.scan())
        let close = "Name:close tab\nTarget:0x0\n\(browserTabCloseSelector)"
        let elsewhere = BrowserTestNode("AXGroup")
        let otherWindow = BrowserTestNode("AXWindow")
        var cancelled = false
        // Each way the tab can stop being this bar's while it scrolls, for a piled-up tab and for
        // one out of view.
        let changes: [(String, (BrowserTestNode) -> Void)] = [
            ("moves to another group", { $0.reportsNoParent = false; $0.ancestor = elsewhere }),
            ("names another window", { $0.reportsNoParent = false; $0.owner = otherWindow }),
            ("can't say its window", { $0.reportsNoParent = false; $0.windowUnreadable = true }),
            ("leaves the bar", { tab in tab.reportsNoParent = false; window.tabBar.nodes.removeAll { $0 === tab } }),
            ("is cancelled", { $0.reportsNoParent = false; cancelled = true }),
            ("is cancelled as it's read again", { tab in
                tab.reportsNoParent = false
                tab.onInfoRead = { cancelled = true }
            }),
        ]
        withExtendedLifetime((elsewhere, otherWindow)) {
            for (index, (change, apply)) in changes.enumerated() {
                for piled in [true, false] {
                    let tab = window.tabs[piled ? 10 + index : 1 + index]
                    tab.reportsNoParent = !piled
                    tab.supportsPress = !piled
                    tab.actions = piled ? ["AXScrollToVisible"] : ["AXScrollToVisible", "AXPress", close]
                    tab.onPerform = { action in
                        guard action == "AXScrollToVisible" else { return }
                        tab.supportsPress = true
                        tab.actions = ["AXScrollToVisible", "AXPress", close]
                        apply(tab)
                    }
                    let target = snapshot.tabs[window.tabs.firstIndex { $0 === tab }!].target
                    let done = closing ? scanner.close(target, cancelled: { cancelled }) : scanner.select(target, cancelled: { cancelled })
                    XCTAssertFalse(done, "\(change), piled: \(piled), closing: \(closing)")
                    XCTAssertEqual(tab.presses, 0, "\(change), piled: \(piled), closing: \(closing)")
                    XCTAssertEqual(tab.performed, ["AXScrollToVisible"], "\(change), piled: \(piled), closing: \(closing)")
                    cancelled = false
                    tab.onInfoRead = {}
                }
            }
        }
        XCTAssertFalse(window.tabs.contains { $0.performed.contains(close) })
    }

    func testAPiledUpTabWithoutATitleIsNamedByItsDescription() throws {
        var noValue = AXError.noValue.rawValue
        var cannotComplete = AXError.cannotComplete.rawValue
        let missing = try XCTUnwrap(AXValueCreate(.axError, &noValue))
        XCTAssertEqual(browserTabTitle("Tab 09", description: "Other"), "Tab 09")
        XCTAssertEqual(browserTabTitle(missing, description: "Tab 09"), "Tab 09")
        XCTAssertEqual(browserTabTitle("", description: "Tab 09"), "", "An empty title is still the tab's title")
        XCTAssertNil(browserTabTitle(try XCTUnwrap(AXValueCreate(.axError, &cannotComplete)), description: "Tab 09"))
        XCTAssertNil(browserTabTitle(missing, description: missing))
    }

    func testOnlyTheTabBarsOwnUnselectedTabsMayLackAParent() throws {
        let window = try crowdedSafariWindow()
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8)
        let snapshot = try XCTUnwrap(scanner.scan())
        // The selected tab always shows, so it must name its tab bar.
        window.tabs[0].reportsNoParent = true
        XCTAssertNil(scanner.scan())
        XCTAssertNil(BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8).scan())
        window.tabs[0].reportsNoParent = false
        // A tab that names some other parent, or whose parent can't be read, isn't the bar's.
        let elsewhere = BrowserTestNode("AXGroup")
        window.tabs[3].reportsNoParent = false
        window.tabs[3].ancestor = elsewhere
        withExtendedLifetime(elsewhere) { XCTAssertNil(scanner.scan()) }
        window.tabs[3].ancestor = window.tabBar
        window.tabs[3].unreadable = true
        XCTAssertNil(scanner.scan())
        window.tabs[3].unreadable = false
        window.tabs[3].reportsNoParent = true
        XCTAssertNotNil(scanner.scan())
        // A tab out of view that names another window, or whose window can't be read, is neither
        // listed nor pressed or closed; the rejected read keeps every tab's identity.
        let otherWindow = BrowserTestNode("AXWindow")
        window.tabs[4].owner = otherWindow
        withExtendedLifetime(otherWindow) {
            XCTAssertNil(scanner.scan())
            XCTAssertFalse(scanner.select(snapshot.tabs[4].target))
        }
        window.tabs[4].owner = window.root
        window.tabs[4].windowUnreadable = true
        window.tabs[4].actions = ["Name:Close Tab\nTarget:0x0\n\(browserTabCloseSelector)"]
        XCTAssertNil(scanner.scan())
        XCTAssertFalse(scanner.select(snapshot.tabs[4].target))
        XCTAssertFalse(scanner.close(snapshot.tabs[4].target))
        window.tabs[4].windowUnreadable = false
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).tabs.map(\.id), snapshot.tabs.map(\.id))
        // A tab its tab bar no longer lists can't be pressed.
        window.tabBar.nodes.remove(at: 5)
        XCTAssertFalse(scanner.select(snapshot.tabs[5].target))
        XCTAssertEqual(window.tabs.map(\.presses), Array(repeating: 0, count: 24))
        XCTAssertEqual(window.tabs[4].performed, [])
    }

    func testATabOutOfViewIsPressedOnlyWhileItsTabBarStillHoldsTheSelectedTab() throws {
        let window = try crowdedSafariWindow()
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8)
        let snapshot = try XCTUnwrap(scanner.scan())
        // The selected tab no longer names the bar, as when Safari replaces its tab bar: the
        // failed read keeps the old handles, but a tab taken on the bar's word isn't pressed.
        window.tabs[0].reportsNoParent = true
        XCTAssertNil(scanner.scan())
        XCTAssertFalse(scanner.select(snapshot.tabs[4].target))
        XCTAssertTrue(scanner.select(snapshot.tabs[10].target), "A tab that names its bar still can be")
        window.tabs[0].reportsNoParent = false
        window.tabBar.nodes.removeFirst()
        XCTAssertFalse(scanner.select(snapshot.tabs[4].target), "Nor once the bar stops listing that tab")
        XCTAssertEqual(window.tabs.map(\.presses), (0..<24).map { $0 == 10 ? 1 : 0 })
    }

    func testChromeFamilyTabsOutOfViewFollowTheSameRules() throws {
        let tree = fixture(.chromium)
        tree.tabs[1].reportsNoParent = true
        tree.tabs[1].reportsNoWindow = true
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertEqual(snapshot.tabs.map(\.title), ["Alpha", "Beta"])
        XCTAssertFalse(tree.scanner.select(snapshot.tabs[1].target), "Not pressed while it names no tab strip")
        tree.tabs[1].actions = ["AXScrollToVisible"]
        tree.tabs[1].onPerform = { _ in tree.tabs[1].reportsNoParent = false; tree.tabs[1].reportsNoWindow = false }
        XCTAssertTrue(tree.scanner.select(snapshot.tabs[1].target))
        tree.tabs[1].reportsNoParent = true
        tree.tabs[0].reportsNoParent = true
        XCTAssertNil(tree.scanner.scan(), "The selected tab must name its tab strip")
        XCTAssertFalse(tree.scanner.select(snapshot.tabs[1].target))
        XCTAssertEqual(tree.tabs.map(\.presses), [0, 1])
    }

    func testAnAttributeReadThatAnsweredNoValueIsToldApartFromOtherErrors() throws {
        var noValue = AXError.noValue.rawValue
        var unsupported = AXError.attributeUnsupported.rawValue
        var point = CGPoint(x: 1, y: 2)
        XCTAssertEqual(browserTabAXError(try XCTUnwrap(AXValueCreate(.axError, &noValue))), -25212)
        XCTAssertEqual(browserTabAXError(try XCTUnwrap(AXValueCreate(.axError, &unsupported))), -25205)
        XCTAssertNil(browserTabAXError(try XCTUnwrap(AXValueCreate(.cgPoint, &point))))
        XCTAssertNil(browserTabAXError("Tab" as CFString))
    }

    func testOnlyAFullReadWithNoTabAtAllSaysAWindowHasNoTabStrip() {
        let root = BrowserTestNode("AXWindow")
        root.append(BrowserTestNode("AXToolbar"))
        root.append(BrowserTestNode("AXGroup"))
        let scanner = BrowserTabScanner(root: root, adapter: .safari, windowId: 1, pid: 2)
        XCTAssertNil(scanner.scan())
        XCTAssertTrue(scanner.foundNoTabStrip, "Such as Safari's Settings, or a lone tab with the tab bar hidden")
        let unknown = BrowserTestNode("AXGroup")
        unknown.unreadable = true
        root.append(unknown)
        XCTAssertNil(scanner.scan())
        XCTAssertFalse(scanner.foundNoTabStrip, "An unreadable branch could hold a tab strip")
        root.nodes.removeLast()
        XCTAssertNil(scanner.scan())
        XCTAssertTrue(scanner.foundNoTabStrip)
        XCTAssertNil(scanner.scan(cancelled: { true }))
        XCTAssertFalse(scanner.foundNoTabStrip, "A scan that stopped early says nothing about the window")
        let tree = fixture(.safari)
        XCTAssertNotNil(tree.scanner.scan())
        XCTAssertFalse(tree.scanner.foundNoTabStrip)
    }

    func testDuplicateTitlesReorderByIdentityAndSelectExactControl() throws {
        let tree = fixture(.chromium)
        tree.tabs.forEach { $0.title = "Duplicate" }
        let first = try XCTUnwrap(tree.scanner.scan())
        XCTAssertNotEqual(first.tabs[0].id, first.tabs[1].id)
        tree.container.nodes.reverse()
        let second = try XCTUnwrap(tree.scanner.scan())
        XCTAssertEqual(second.tabs.map(\.id), first.tabs.reversed().map(\.id))
        XCTAssertTrue(tree.scanner.select(first.tabs[0].target))
        XCTAssertEqual(tree.tabs[0].presses, 1)
        XCTAssertEqual(tree.tabs[1].presses, 0)
    }

    func testIncompleteReadsKeepIdentityButRetiredAndMovedTargetsCannotPress() throws {
        let tree = fixture(.chromium)
        let first = try XCTUnwrap(tree.scanner.scan())
        tree.container.unreadable = true
        XCTAssertNil(tree.scanner.scan())
        tree.container.unreadable = false
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.id), first.tabs.map(\.id))
        tree.container.nodes.removeFirst()
        tree.tabs[1].selected = true
        let single = try XCTUnwrap(tree.scanner.scan())
        XCTAssertFalse(single.isGroup)
        XCTAssertFalse(tree.scanner.select(first.tabs[0].target))
        let otherWindow = BrowserTestNode("AXWindow")
        tree.container.owner = otherWindow
        XCTAssertFalse(tree.scanner.select(first.tabs[1].target))
        XCTAssertEqual(tree.tabs.map(\.presses), [0, 0])
    }

    func testModeRestartDoesNotReuseIdsAndWrongProcessCannotSelect() throws {
        let tree = fixture(.chromium)
        let first = try XCTUnwrap(tree.scanner.scan())
        let restarted = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45)
        let second = try XCTUnwrap(restarted.scan())
        XCTAssertNotEqual(first.windowSession, second.windowSession)
        XCTAssertTrue(Set(first.tabs.map(\.id)).isDisjoint(with: second.tabs.map(\.id)))
        XCTAssertFalse(restarted.select(first.tabs[0].target))
        let wrong = BrowserTabTarget(windowId: 123, pid: 46, windowSession: first.windowSession, tabId: first.tabs[0].id)
        XCTAssertFalse(tree.scanner.select(wrong))
        tree.tabs[0].supportsPress = false
        XCTAssertFalse(tree.scanner.select(first.tabs[0].target))
    }

    func testAmbiguousSelectionAndNativeGroupsNeverPublishPartialTabList() {
        let tree = fixture(.chromium)
        tree.tabs[0].selected = false
        XCTAssertNil(tree.scanner.scan())
        tree.tabs.forEach { $0.selected = true }
        XCTAssertNil(tree.scanner.scan())
        tree.tabs[1].selected = false
        tree.container.append(BrowserTestNode("AXButton"))
        XCTAssertNil(tree.scanner.scan(), "Unrecognized native group headers must not silently lose hidden tabs")
    }

    func testTraversalLimitsAndCancellationReturnNoPartialList() {
        let tree = fixture(.chromium)
        var time = 0.0
        let scanner = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45,
            now: { time += 0.05; return time })
        XCTAssertNil(scanner.scan())
        let cancelled = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45, isCancelled: { true })
        XCTAssertNil(cancelled.scan())
        XCTAssertNil(tree.scanner.scan(cancelled: { true }))
        for _ in 0..<260 { tree.container.append(tab("Extra", selected: false)) }
        XCTAssertNil(tree.scanner.scan())
    }

    func testCacheExpiresAndRemovesOwnersWithoutChangingCompleteSnapshots() throws {
        let snapshot = try XCTUnwrap(fixture(.chromium).scanner.scan())
        var cache = BrowserTabSnapshotCache()
        cache.receive(snapshot, now: 1)
        cache.recordFailure(windowId: 123, now: 2)
        cache.reconcile(owners: [123: 45], now: 8)
        XCTAssertEqual(cache.snapshots[123], snapshot)
        cache.reconcile(owners: [123: 45], now: 12)
        XCTAssertTrue(cache.snapshots.isEmpty)
        cache.receive(snapshot, now: 13)
        cache.reconcile(owners: [123: 99], now: 13)
        XCTAssertTrue(cache.snapshots.isEmpty, "A recycled window ID in a new process is not the old owner")
        cache.receive(snapshot, now: 20)
        cache.reconcile(owners: [123: 45], now: 81)
        XCTAssertEqual(cache.snapshots[123], snapshot, "Hidden panels keep stable geometry until an actual failed read or owner retirement")
    }

    @MainActor
    func testSettingsDefaultToBrowserTabsWithIconsOptIn() {
        let (parsed, errors) = parseConfig("""
            [workspace-sidebar]
            mode = 'tabs'
            browser-tabs = false
            browser-tab-icons = true
            """)
        XCTAssertEqual(errors.descriptions, [])
        XCTAssertFalse(parsed.workspaceSidebar.browserTabs)
        XCTAssertTrue(parsed.workspaceSidebar.browserTabIcons)
        XCTAssertTrue(defaultConfig.workspaceSidebar.browserTabs)
        XCTAssertFalse(defaultConfig.workspaceSidebar.browserTabIcons)
        XCTAssertEqual(SettingsCatalog.field("workspace-sidebar.browser-tabs").title, "Show browser tabs")
    }

    @MainActor
    func testBrowserSelectionKeepsTheDisplayTakeoverGuard() {
        setUpWorkspacesForTests()
        defer { setMonitorsForTests(nil); config = defaultConfig }
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT")
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        Workspace.reconcileWorkspaceState()
        let workspace = Workspace.get(byName: "browser")
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertTrue(right.setActiveWorkspace(workspace))
        XCTAssertFalse(browserTabSelectionAllowed(workspace: workspace, monitorScopeId: workspaceSidebarMonitorScopeId(for: left)))
        XCTAssertTrue(browserTabSelectionAllowed(workspace: workspace, monitorScopeId: workspaceSidebarMonitorScopeId(for: right)))
        XCTAssertFalse(browserTabSelectionAllowed(workspace: workspace, monitorScopeId: "missing-display"))
        XCTAssertTrue(right.setActiveWorkspace(Workspace.get(byName: "other")))
        XCTAssertTrue(browserTabSelectionAllowed(workspace: workspace, monitorScopeId: workspaceSidebarMonitorScopeId(for: left)))
    }

    @MainActor
    func testBrowserGroupAndSplitRenderWithoutChangingWindowIdentity() throws {
        let browser = try XCTUnwrap(fixture(.chromium).scanner.scan())
        let chrome = WorkspaceSidebarWindowViewModel(windowId: 123, workspaceName: "1", appName: "Google Chrome",
            appBundleId: "com.google.Chrome", appBundlePath: "/Applications/Google Chrome.app", title: "Alpha", isFocused: true)
        let notes = WorkspaceSidebarWindowViewModel(windowId: 124, workspaceName: "1", appName: "Notes",
            appBundleId: "com.apple.Notes", appBundlePath: nil, title: "Research notes", isFocused: false)
        for split in [false, true] {
            var snapshot = WorkspaceSidebarSnapshot.empty
            snapshot.configuration.usesTabsList = true
            snapshot.configuration.expandedWidth = 280
            snapshot.configuration.collapsedWidth = 44
            snapshot.visibleWidth = 280
            snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
            let workspace = WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId,
                displayName: "1", sidebarLabel: "", isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil,
                isFocused: true, isVisible: true, items: (split ? [chrome, notes] : [chrome]).map { .init(kind: .window($0)) })
            snapshot.workspaces = [workspace]
            let model = BrowserTabsModel(snapshots: [123: browser])
            let view = WorkspaceSidebarView(snapshot: snapshot, reduceMotionOverride: true,
                reduceTransparencyOverride: true, browserTabsModel: model)
            let host = NSHostingView(rootView: view.frame(width: 280, height: 480).environment(\.colorScheme, .light))
            host.frame = CGRect(x: 0, y: 0, width: 280, height: 480)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let recognize = VNRecognizeTextRequest()
            recognize.recognitionLevel = .accurate
            recognize.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([recognize])
            let renderedText = (recognize.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(renderedText.contains("Alpha"), renderedText)
            XCTAssertTrue(renderedText.contains("Beta"), renderedText)
            XCTAssertTrue(renderedText.contains("Chrome"), renderedText)
            let directory = projectRoot.appendingPathComponent(".build/browser-tabs-ui")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(split ? "split.png" : "single.png"))
            XCTAssertEqual(host.fittingSize.width, 280, accuracy: 0.5)
            XCTAssertEqual(workspaceSidebarPinnedTabWindows(workspace).count, split ? 2 : 1)
        }
    }

    /// Hosts a Tabs sidebar the way its panel does: the same view, given each new snapshot.
    @MainActor
    private final class BrowserWatchSidebar {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let model: BrowserTabsModel

        init(model: BrowserTabsModel) {
            self.model = model
            host.frame = CGRect(x: 0, y: 0, width: 280, height: 480)
        }

        func show(_ windows: [WorkspaceSidebarWindowViewModel], width: CGFloat = 280, scope: String = "monitor:0.0,0.0") {
            var snapshot = WorkspaceSidebarSnapshot.empty
            snapshot.configuration.usesTabsList = true
            snapshot.configuration.expandedWidth = 280
            snapshot.configuration.collapsedWidth = 44
            snapshot.visibleWidth = width
            snapshot.targetMonitorScopeId = scope
            snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
            snapshot.workspaces = windows.map { window in
                WorkspaceSidebarWorkspaceViewModel(name: window.workspaceName, projectId: workspaceProjectDefaultId,
                    displayName: window.workspaceName, sidebarLabel: "", isGeneratedName: true, monitorScopeId: scope,
                    monitorName: nil, isFocused: window.isFocused, isVisible: window.isFocused, items: [.init(kind: .window(window))])
            }
            host.rootView = AnyView(WorkspaceSidebarView(snapshot: snapshot, reduceMotionOverride: true,
                reduceTransparencyOverride: true, browserTabsModel: model).frame(width: 280, height: 480))
            host.layoutSubtreeIfNeeded()
        }

        func hide() {
            host.rootView = AnyView(EmptyView())
            host.layoutSubtreeIfNeeded()
        }
    }

    private func browserWindow(_ id: UInt32, workspace: String, focused: Bool = false) -> WorkspaceSidebarWindowViewModel {
        .init(windowId: id, workspaceName: workspace, appName: "Google Chrome", appBundleId: "com.google.Chrome",
            appBundlePath: nil, title: "Page \(id)", isFocused: focused)
    }

    /// SwiftUI applies a new root view on its next pass. Let it run first, even when the watch
    /// shouldn't change, then wait for the expected watch rather than a fixed time.
    @MainActor
    private func assertWatch(_ model: BrowserTabsModel, _ expected: Set<UInt32>, _ message: String, line: UInt = #line) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let deadline = Date(timeIntervalSinceNow: 2)
        while model.watchedWindowIds != expected, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(model.watchedWindowIds, expected, message, line: line)
    }

    @MainActor
    func testTheSidebarReadsTheBrowserWindowsItShowsAfterEachSnapshot() {
        // Each change must be read from the new snapshot, not the view before it: a watch one change
        // behind never read a window after launch, or one that joined a project later.
        let model = BrowserTabsModel()
        let sidebar = BrowserWatchSidebar(model: model)
        let a = browserWindow(83, workspace: "1", focused: true)
        let b = browserWindow(67, workspace: "2")
        sidebar.show([], width: 0)
        assertWatch(model, [], "A panel first appears empty")
        sidebar.show([a, b])
        assertWatch(model, [83, 67], "The first real snapshot's windows are read")
        sidebar.show([a])
        assertWatch(model, [83], "A window that leaves the sidebar stops being read at once")
        sidebar.show([a, b])
        assertWatch(model, [83, 67], "A window that joins the project is read")
        sidebar.show([browserWindow(83, workspace: "1"), browserWindow(67, workspace: "2", focused: true)])
        assertWatch(model, [83, 67], "Focusing the other window changes nothing read")
        sidebar.show([a, b], width: 44)
        assertWatch(model, [], "The collapsed rail shows no browser tabs, so it reads none")
        sidebar.show([a, b])
        assertWatch(model, [83, 67], "Expanding it again reads them again")
        sidebar.hide()
        assertWatch(model, [], "A sidebar that goes away stops its reads")
        sidebar.show([a])
        assertWatch(model, [83], "One that appears with windows reads them at once")
    }

    @MainActor
    func testEachDisplaysSidebarKeepsItsOwnReadsWhenOneMovesOrGoes() {
        let model = BrowserTabsModel()
        let left = BrowserWatchSidebar(model: model)
        let right = BrowserWatchSidebar(model: model)
        left.show([browserWindow(83, workspace: "1", focused: true)], scope: "monitor:0.0,0.0")
        right.show([browserWindow(67, workspace: "2", focused: true)], scope: "monitor:1920.0,0.0")
        assertWatch(model, [83, 67], "Both sidebars' windows are read")
        // The left panel now describes another display with the same windows...
        left.show([browserWindow(83, workspace: "1", focused: true)], scope: "monitor:0.0,1080.0")
        assertWatch(model, [83, 67], "Moving keeps its windows read")
        // ...and its old display's reads are gone, not left behind to keep a window read.
        left.show([], scope: "monitor:0.0,1080.0")
        assertWatch(model, [67], "Only the new display's reads remained to clear")
        right.hide()
        assertWatch(model, [], "The other sidebar's reads end with it")
    }

    func testAChosenBrowserTabShowsSelectedAtOnceAndUntilTheBrowserSaysOtherwise() throws {
        let tree = fixture(.chromium)
        tree.container.append(tab("Gamma", selected: false))
        let before = try XCTUnwrap(tree.scanner.scan())
        XCTAssertEqual(before.tabs.map(\.isSelected), [true, false, false])
        let third = before.tabs[2].target
        var pending = BrowserTabPendingSelections()
        let attempt = pending.begin(third, now: 10)
        XCTAssertEqual(pending.apply(before).tabs.map(\.isSelected), [false, false, true], "The row chosen is the one shown selected")
        pending.settle(attempt: attempt, windowId: 123, refused: false, now: 10.2)
        pending.observe(before, readStarted: 10.1)
        pending.observe(before, readStarted: 11.1)
        XCTAssertEqual(pending.apply(before).tabs.map(\.isSelected), [false, false, true],
            "Reads begun before the switch, or before the browser redrew its tab strip, still show the first tab")
        tree.tabs[0].selected = false
        tree.container.nodes[2].selected = true
        let after = try XCTUnwrap(tree.scanner.scan())
        pending.observe(after, readStarted: 11.15)
        XCTAssertEqual(pending.apply(before).tabs.map(\.isSelected), [true, false, false], "Once confirmed, reads alone decide")

        // A read well after the switch that shows another tab wins, as when the browser declined.
        let second = pending.begin(before.tabs[1].target, now: 20)
        pending.settle(attempt: second, windowId: 123, refused: false, now: 20.1)
        pending.observe(after, readStarted: 21.1)
        XCTAssertEqual(pending.apply(after).tabs.map(\.isSelected), [false, false, true])
        // A press the browser refused shows the real selection straight away.
        let refused = pending.begin(before.tabs[1].target, now: 30)
        pending.settle(attempt: refused, windowId: 123, refused: true, now: 30.1)
        XCTAssertEqual(pending.apply(after).tabs.map(\.isSelected), [false, false, true])
        // Nothing lingers: a choice unconfirmed for three seconds lapses.
        _ = pending.begin(before.tabs[1].target, now: 40)
        pending.expire(now: 42.9)
        XCTAssertEqual(pending.apply(after).tabs.map(\.isSelected), [false, true, false])
        pending.expire(now: 43)
        XCTAssertEqual(pending.apply(after).tabs.map(\.isSelected), [false, false, true])
        // A choice whose tab has since closed changes nothing.
        _ = pending.begin(BrowserTabTarget(windowId: 123, pid: 45, windowSession: after.windowSession, tabId: UUID()), now: 50)
        XCTAssertEqual(pending.apply(after).tabs.map(\.isSelected), [false, false, true])
    }

    func testAPressAnotherClickSupersededNeverSettlesTheNewerChoice() throws {
        let snapshot = try XCTUnwrap({ () -> BrowserWindowTabs? in
            let tree = fixture(.chromium)
            tree.container.append(tab("Gamma", selected: false))
            return tree.scanner.scan()
        }())
        let (second, third) = (snapshot.tabs[1].target, snapshot.tabs[2].target)
        var pending = BrowserTabPendingSelections()
        // The same tab clicked twice, and the first press comes back refused.
        let again = pending.begin(third, now: 0)
        let latest = pending.begin(third, now: 0.1)
        pending.settle(attempt: again, windowId: 123, refused: true, now: 0.2)
        XCTAssertEqual(pending.apply(snapshot).tabs.map(\.isSelected), [false, false, true], "The second click still shows")
        pending.settle(attempt: latest, windowId: 123, refused: false, now: 0.3)
        pending.observe(snapshot, readStarted: 0.4)
        XCTAssertEqual(pending.apply(snapshot).tabs.map(\.isSelected), [false, false, true])
        // Second, then third, then second again: only the last press settles the choice.
        let a = pending.begin(second, now: 1)
        let b = pending.begin(third, now: 1.1)
        let c = pending.begin(second, now: 1.2)
        pending.settle(attempt: a, windowId: 123, refused: true, now: 1.3)
        pending.settle(attempt: b, windowId: 123, refused: true, now: 1.3)
        XCTAssertEqual(pending.apply(snapshot).tabs.map(\.isSelected), [false, true, false])
        pending.settle(attempt: c, windowId: 123, refused: true, now: 1.4)
        XCTAssertEqual(pending.apply(snapshot).tabs.map(\.isSelected), [true, false, false])
        // A click in another window cuts this press short before it presses: each window keeps its own.
        let other = try XCTUnwrap(BrowserTabScanner(root: fixture(.chromium).root, adapter: .chromium, windowId: 456, pid: 45).scan())
        let here = pending.begin(third, now: 2)
        _ = pending.begin(other.tabs[1].target, now: 2.1)
        pending.settle(attempt: here, windowId: 123, refused: true, now: 2.2)
        XCTAssertEqual(pending.apply(snapshot).tabs.map(\.isSelected), [true, false, false])
        XCTAssertEqual(pending.apply(other).tabs.map(\.isSelected), [false, true])
    }

    func testAReadBegunBeforeAClickNeverConfirmsIt() throws {
        let tree = fixture(.chromium)
        tree.container.append(tab("Gamma", selected: false))
        let read = try XCTUnwrap(tree.scanner.scan())
        func selecting(_ index: Int) -> BrowserWindowTabs {
            var snapshot = read
            snapshot.tabs = snapshot.tabs.enumerated().map { offset, tab in
                var tab = tab
                tab.isSelected = offset == index
                return tab
            }
            return snapshot
        }
        let (second, third) = (read.tabs[1].target, read.tabs[2].target)
        var pending = BrowserTabPendingSelections()
        let toSecond = pending.begin(second, now: 1)
        pending.settle(attempt: toSecond, windowId: 123, refused: false, now: 1.1)
        pending.observe(selecting(1), readStarted: 1.2)
        // Third, whose tab strip still shows the second tab, then quickly the second again.
        let toThird = pending.begin(third, now: 2)
        pending.settle(attempt: toThird, windowId: 123, refused: false, now: 2.1)
        pending.observe(selecting(1), readStarted: 2.2)
        let back = pending.begin(second, now: 2.3)
        pending.observe(selecting(1), readStarted: 2.25)
        XCTAssertEqual(pending.apply(selecting(2)).tabs.map(\.isSelected), [false, true, false],
            "A read from before the click back, still showing the second tab, doesn't confirm it")
        pending.settle(attempt: back, windowId: 123, refused: false, now: 2.4)
        pending.observe(selecting(1), readStarted: 2.35)
        XCTAssertEqual(pending.apply(selecting(2)).tabs.map(\.isSelected), [false, true, false],
            "Nor does one begun after the click but before its press, arriving later")
        pending.observe(selecting(2), readStarted: 2.45)
        XCTAssertEqual(pending.apply(selecting(2)).tabs.map(\.isSelected), [false, true, false],
            "The third tab, shown while the browser redraws, doesn't flash back")
        pending.observe(selecting(1), readStarted: 2.5)
        XCTAssertEqual(pending.apply(selecting(2)).tabs.map(\.isSelected), [false, false, true], "Once confirmed, reads alone decide")
    }

    func testTitlesOnlyRemoveKnownDiagnosticSuffixes() {
        XCTAssertEqual(browserTabDisplayTitle("Design - API - Memory usage - 64 MB"), "Design - API")
        XCTAssertEqual(browserTabDisplayTitle("项目 - 内存用量 - 64 MB"), "项目")
        XCTAssertEqual(browserTabDisplayTitle("Design - API"), "Design - API")
        XCTAssertEqual(browserTabDisplayTitle(""), "Untitled tab")
        XCTAssertNil(BrowserTabAdapter(bundleId: "company.thebrowser.Browser"))
        XCTAssertNotNil(BrowserTabAdapter(bundleId: "com.microsoft.edgemac"))
    }

    @MainActor
    func testSearchKeyboardAndScrollTargetUseTheSameBrowserChild() throws {
        let snapshot = try XCTUnwrap(fixture(.chromium).scanner.scan())
        let window = WorkspaceSidebarWindowViewModel(windowId: 123, workspaceName: "1", appName: "Chrome",
            appBundleId: "com.google.Chrome", appBundlePath: nil, title: "Alpha", isFocused: true)
        let workspace = WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId,
            displayName: "1", sidebarLabel: "", isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil,
            isFocused: true, isVisible: true, items: [.init(kind: .window(window))])
        let browsers = [window.id: snapshot]
        let results = workspaceSidebarFilteredWorkspacesByProject([workspace.projectId: [workspace]], projects: [],
            query: "Beta", browserTabs: browsers)[workspace.projectId] ?? []
        XCTAssertEqual(results.map(\.name), ["1"])
        let choices = workspaceSidebarSearchSelections(workspaces: results, browserTabs: browsers, query: "Beta")
        XCTAssertEqual(choices, [.browserTab(snapshot.tabs[1].target)])
        XCTAssertEqual(workspaceSidebarTabScrollTarget(folders: results, searchSelection: choices.first)?.rowId,
            snapshot.tabs[1].target.rowId)
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: results), [.window(123)], "Other modes use only windows")
        XCTAssertEqual(workspaceSidebarTabPresentation(workspace), .single(window), "The layout still owns exactly one window")
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [workspace], browserTabs: browsers, query: "Alpha"),
            [.browserTab(snapshot.tabs[0].target)], "The active window title must not match every sibling tab")
        for headerQuery in ["Chrome", "1"] {
            XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [workspace], browserTabs: browsers, query: headerQuery).first,
                .window(123), "Matching an app or workspace focuses its window without switching to its first browser tab")
        }
        let projects = [WorkspaceSidebarProjectViewModel(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil)]
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [workspace], browserTabs: browsers, query: "Research", projects: projects).first,
            .window(123))
    }

    @MainActor
    func testSplitSearchOrderFollowsHeadersThenBrowserChildren() throws {
        let browser = try XCTUnwrap(fixture(.chromium).scanner.scan())
        let chrome = WorkspaceSidebarWindowViewModel(windowId: 123, workspaceName: "1", appName: "Chrome",
            appBundleId: "com.google.Chrome", appBundlePath: nil, title: "Alpha", isFocused: true)
        let notes = WorkspaceSidebarWindowViewModel(windowId: 124, workspaceName: "1", appName: "Notes",
            appBundleId: "com.apple.Notes", appBundlePath: nil, title: "Notes", isFocused: false)
        let workspace = WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId,
            displayName: "Research", sidebarLabel: "Research", isGeneratedName: false, monitorScopeId: "monitor:0,0",
            monitorName: nil, isFocused: true, isVisible: true, items: [chrome, notes].map { .init(kind: .window($0)) })
        let browsers: [UInt32: BrowserWindowTabs] = [123: browser]
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [workspace], browserTabs: browsers),
            [.window(123), .window(124)] + browser.tabs.map { .browserTab($0.target) })
        let results = workspaceSidebarFilteredWorkspacesByProject([workspace.projectId: [workspace]], projects: [],
            query: "Research Beta", browserTabs: browsers)[workspace.projectId] ?? []
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: results, browserTabs: browsers, query: "Research Beta"),
            [.browserTab(browser.tabs[1].target)], "Only the matching child remains when the other split half does not match")
        let otherSession = UUID()
        let otherBrowser = BrowserWindowTabs(windowId: 124, pid: 45, windowSession: otherSession,
            tabs: browser.tabs.map { .init(target: .init(windowId: 124, pid: 45, windowSession: otherSession, tabId: UUID()),
                title: $0.title, isSelected: $0.isSelected) })
        let otherChrome = WorkspaceSidebarWindowViewModel(windowId: 124, workspaceName: "1", appName: "Chrome",
            appBundleId: "com.google.Chrome", appBundlePath: nil, title: "Alpha", isFocused: false)
        let pair = WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId,
            displayName: "Research", sidebarLabel: "Research", isGeneratedName: false, monitorScopeId: "monitor:0,0",
            monitorName: nil, isFocused: true, isVisible: true, items: [chrome, otherChrome].map { .init(kind: .window($0)) })
        let pairBrowsers = [UInt32(123): browser, UInt32(124): otherBrowser]
        let pairResults = workspaceSidebarFilteredWorkspacesByProject([pair.projectId: [pair]], projects: [],
            query: "Beta", browserTabs: pairBrowsers)[pair.projectId] ?? []
        XCTAssertEqual(workspaceSidebarTabPresentation(try XCTUnwrap(pairResults.first)), .split(chrome, otherChrome))
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: pairResults, browserTabs: pairBrowsers, query: "Beta"),
            [.browserTab(browser.tabs[1].target), .browserTab(otherBrowser.tabs[1].target)],
            "A specific tab match must reach that tab when both browser halves remain in the split")
        XCTAssertEqual(Array(workspaceSidebarSearchSelections(workspaces: [pair], browserTabs: pairBrowsers, query: "Chrome").prefix(2)),
            [.window(123), .window(124)])
    }

    @MainActor
    func testLegacyFolderSearchAndScrollNeverTargetUndisplayedBrowserChildren() throws {
        let browser = try XCTUnwrap(fixture(.chromium).scanner.scan())
        let chrome = WorkspaceSidebarWindowViewModel(windowId: 123, workspaceName: "1", appName: "Chrome",
            appBundleId: "com.google.Chrome", appBundlePath: nil, title: "Alpha", isFocused: true)
        let notes = WorkspaceSidebarWindowViewModel(windowId: 124, workspaceName: "1", appName: "Notes",
            appBundleId: "com.apple.Notes", appBundlePath: nil, title: "Notes", isFocused: false)
        let stack = WorkspaceSidebarTabGroupViewModel(representativeWindowId: 124, workspaceName: "1", title: "Stack",
            windowCount: 1, isFocused: false, tabs: [notes], allWindows: [notes])
        let workspace = WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId,
            displayName: "1", sidebarLabel: "", isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil,
            isFocused: true, isVisible: true, items: [.init(kind: .window(chrome)), .init(kind: .tabGroup(stack))])
        let browsers: [UInt32: BrowserWindowTabs] = [123: browser]
        XCTAssertEqual(workspaceSidebarTabPresentation(workspace), .folder)
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [workspace], browserTabs: browsers), [.window(123), .window(124)])
        XCTAssertEqual(workspaceSidebarTabScrollTarget(folders: [workspace], searchSelection: nil, browserTabs: browsers)?.rowId, "window:123")
        XCTAssertEqual(workspaceSidebarTabScrollTarget(folders: [workspace], searchSelection: .browserTab(browser.tabs[0].target),
            browserTabs: browsers)?.rowId, "window:123")
        XCTAssertTrue((workspaceSidebarFilteredWorkspacesByProject([workspace.projectId: [workspace]], projects: [],
            query: "Beta", browserTabs: browsers)[workspace.projectId] ?? []).isEmpty)
        let appMatches = workspaceSidebarFilteredWorkspacesByProject([workspace.projectId: [workspace]], projects: [],
            query: "Chrome", browserTabs: browsers)[workspace.projectId] ?? []
        XCTAssertEqual(workspaceSidebarTabPresentation(try XCTUnwrap(appMatches.first)), .folder)
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: appMatches, browserTabs: browsers, query: "Chrome"), [.window(123)],
            "Filtering a legacy folder cannot reveal previously unsearchable browser children")
    }

    func testClosingATabPressesOnlyThatTabsOwnCloseButtonAndNeverSelectsIt() throws {
        let tree = fixture(.chromium)
        let closeAlpha = BrowserTestNode("AXButton", subrole: "AXCloseButton")
        tree.tabs[0].append(BrowserTestNode("AXButton"))
        tree.tabs[0].append(closeAlpha)
        let closeBeta = BrowserTestNode("AXButton")
        tree.tabs[1].append(BrowserTestNode("AXStaticText"))
        tree.tabs[1].append(closeBeta)
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertEqual(snapshot.tabs.count, 2, "A tab's own controls aren't tabs")
        XCTAssertTrue(tree.scanner.close(snapshot.tabs[1].target), "A tab's only button is its close button")
        XCTAssertEqual(closeBeta.presses, 1)
        XCTAssertTrue(tree.scanner.close(snapshot.tabs[0].target), "Among several buttons, the close button")
        XCTAssertEqual(closeAlpha.presses, 1)
        XCTAssertEqual(tree.tabs.map(\.presses), [0, 0], "Closing never selects the tab")
    }

    func testSafarisHiddenCloseButtonIsReachedThroughItsUnlocalizedCloseAction() throws {
        let tree = fixture(.safari)
        let close = "Name:关闭标签页\nTarget:0x7801b6d500\nSelector:_closeButtonClicked:"
        tree.tabs[1].actions = ["AXScrollToVisible", "AXShowMenu", "AXPress", close]
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertTrue(tree.scanner.close(snapshot.tabs[1].target), "Found by selector, whatever the language")
        XCTAssertEqual(tree.tabs[1].performed, [close])
        XCTAssertEqual(tree.tabs.map(\.presses), [0, 0], "Not the tab's press, which would select it")
        tree.tabs[0].actions = ["AXPress", "Name:Other\nTarget:0x1\nSelector:_otherAction:"]
        XCTAssertFalse(tree.scanner.close(snapshot.tabs[0].target), "Another named action isn't a close")
        XCTAssertEqual(tree.tabs[0].performed, [])
    }

    func testATabWithoutAnUnambiguousCloseControlOrThatMovedIsLeftOpen() throws {
        let tree = fixture(.safari)
        let first = BrowserTestNode("AXButton"), second = BrowserTestNode("AXButton")
        tree.tabs[1].append(first)
        tree.tabs[1].append(second)
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertFalse(tree.scanner.close(snapshot.tabs[0].target), "No close button")
        XCTAssertFalse(tree.scanner.close(snapshot.tabs[1].target), "Two unnamed buttons: guessing could do something else")
        XCTAssertEqual(first.presses + second.presses, 0)
        tree.container.nodes.removeFirst()
        XCTAssertFalse(tree.scanner.close(snapshot.tabs[0].target), "A tab that's gone")
    }

    func testAClosedTabLeavesTheListBeforeTheNextRead() {
        var cache = BrowserTabSnapshotCache()
        let session = UUID()
        let tabs = (0..<3).map { index in
            BrowserTab(target: .init(windowId: 1, pid: 2, windowSession: session, tabId: UUID()), title: "\(index)",
                isSelected: index == 0)
        }
        cache.receive(.init(windowId: 1, pid: 2, windowSession: session, tabs: tabs), now: 0)
        cache.removeTab(tabs[1].target)
        XCTAssertEqual(cache.snapshots[1]?.tabs.map(\.title), ["0", "2"])
        cache.removeTab(.init(windowId: 1, pid: 2, windowSession: UUID(), tabId: tabs[0].target.tabId))
        XCTAssertEqual(cache.snapshots[1]?.tabs.count, 2, "A target from an earlier scan of the window is ignored")
    }

    private func fixture(_ adapter: BrowserTabAdapter) -> (root: BrowserTestNode, container: BrowserTestNode,
        tabs: [BrowserTestNode], scanner: BrowserTabScanner<BrowserTestNode>) {
        let root = BrowserTestNode("AXWindow")
        let container = BrowserTestNode(adapter == .safari ? "AXOpaqueProviderGroup" : "AXTabGroup")
        if adapter == .safari { root.append(BrowserTestNode("AXTabGroup")) }
        root.append(container)
        let tabs = [tab("Alpha", selected: true), tab("Beta", selected: false)]
        for tab in tabs { container.append(tab) }
        return (root, container, tabs, BrowserTabScanner(root: root, adapter: adapter, windowId: 123, pid: 45))
    }

    /// A Safari window with 24 tabs, from the capture in test-fixtures/accessibility.
    private func crowdedSafariWindow() throws -> (root: BrowserTestNode, tabBar: BrowserTestNode, tabs: [BrowserTestNode]) {
        let url = projectRoot.appending(path: "test-fixtures/accessibility/safari-27.0-crowded-tab-bar.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let window = try XCTUnwrap(fixture["window"] as? [String: Any])
        var tabBar: BrowserTestNode?
        var tabs: [BrowserTestNode] = []
        func node(_ record: [String: Any]) -> BrowserTestNode {
            let node = BrowserTestNode(record["AXRole"] as? String ?? "", subrole: record["AXSubrole"] as? String ?? "")
            node.title = record["AXTitle"] as? String ?? ""
            node.selected = record["AXValue"] as? Int == 1
            node.reportsNoParent = (record["AXParent"] as? [String: Any])?["error"] as? Int == -25212
            if record["tabBar"] as? Bool == true { tabBar = node }
            if node.subrole == "AXTabButton" { tabs.append(node) }
            return node
        }
        // Parents first, so each node learns its window as it's added.
        func add(_ children: [[String: Any]]?, to parent: BrowserTestNode) {
            for record in children ?? [] {
                let child = node(record)
                parent.append(child)
                add(record["children"] as? [[String: Any]], to: child)
            }
        }
        let root = node(window)
        add(window["children"] as? [[String: Any]], to: root)
        return (root, try XCTUnwrap(tabBar), tabs)
    }

    private func tab(_ title: String, selected: Bool) -> BrowserTestNode {
        let node = BrowserTestNode("AXRadioButton", subrole: "AXTabButton")
        node.title = title
        node.selected = selected
        return node
    }
}

private final class BrowserTestNode: BrowserTabAXNode {
    static func == (lhs: BrowserTestNode, rhs: BrowserTestNode) -> Bool { lhs === rhs }
    let role: String
    let subrole: String
    var title = ""
    var selected = false
    var unreadable = false
    /// Answers its parent with kAXErrorNoValue, as Safari's tabs scrolled out of view do.
    var reportsNoParent = false
    /// Answers its window with kAXErrorNoValue, or fails to answer at all.
    var reportsNoWindow = false
    var windowUnreadable = false
    /// Answers its title with kAXErrorNoValue and has only a description, as Safari's piled-up tabs do.
    var reportsNoTitle = false
    var summary = ""
    var supportsPress = true
    var presses = 0
    var structureReads = 0
    var childReads = 0
    var infoReads = 0
    var onInfoRead: () -> Void = {}
    var nodes: [BrowserTestNode] = []
    weak var ancestor: BrowserTestNode?
    weak var owner: BrowserTestNode?

    init(_ role: String, subrole: String = "") { self.role = role; self.subrole = subrole }
    func append(_ child: BrowserTestNode) {
        child.ancestor = self
        child.owner = role == "AXWindow" ? self : owner
        nodes.append(child)
    }
    func structure() -> BrowserTabAXStructure? {
        structureReads += 1
        return unreadable ? nil : .init(role: role, subrole: subrole)
    }
    func children() -> [BrowserTestNode]? { childReads += 1; return unreadable ? nil : nodes }
    func parent() -> BrowserTestNode? { reportsNoParent ? nil : ancestor }
    func tabRecord() -> BrowserTabAXRecord<BrowserTestNode>? {
        guard let structure = structure(), let info = tabInfo() else { return nil }
        let parent: BrowserTabAXLink<BrowserTestNode> = reportsNoParent ? .none : ancestor.map { .element($0) } ?? .unreadable
        let window: BrowserTabAXLink<BrowserTestNode> = windowUnreadable ? .unreadable
            : reportsNoWindow ? .none : owner.map { .element($0) } ?? .unreadable
        return .init(structure: structure, info: info, parent: parent, window: window)
    }
    func window() -> BrowserTestNode? { reportsNoWindow || windowUnreadable ? nil : owner }
    func tabInfo() -> BrowserTabAXInfo? {
        infoReads += 1
        onInfoRead()
        var noValue = AXError.noValue.rawValue
        guard !unreadable, let title = reportsNoTitle ? AXValueCreate(.axError, &noValue).flatMap { browserTabTitle($0, description: summary) } : title
        else { return nil }
        return .init(title: title, selected: selected)
    }
    func press() -> Bool { if supportsPress { presses += 1 }; return supportsPress }
    var actions: [String] = []
    var performed: [String] = []
    func actionNames() -> [String] { actions }
    var onPerform: (String) -> Void = { _ in }
    func perform(_ action: String) -> Bool {
        performed.append(action)
        guard actions.contains(action) else { return false }
        onPerform(action)
        return true
    }
}
