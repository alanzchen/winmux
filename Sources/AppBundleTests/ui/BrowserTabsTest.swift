import AppKit
@testable import AppBundle
import SwiftUI
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

    /// Windows something else reports changes of at once are read only now and then, the focused
    /// one too, but at once when they're reset, and as often as before when a notification
    /// marks them, a read fails, or they stop being relaxed.
    func testRelaxedWindowsAreReadOnlyNowAndThenUntilMarkedResetOrNoLongerRelaxed() {
        var schedule = BrowserTabReadSchedule()
        schedule.watch([1, 2])
        schedule.focus(1)
        schedule.relax([1, 2])
        for id: UInt32 in [1, 2] { schedule.didRead(id, now: 0, succeeded: true) }
        XCTAssertFalse(schedule.isDue(1, now: 4), "Focused or not")
        XCTAssertFalse(schedule.isDue(2, now: BrowserTabReadSchedule.relaxedInterval - 0.1))
        XCTAssertTrue(schedule.isDue(2, now: BrowserTabReadSchedule.relaxedInterval))
        schedule.markDirty(2)
        XCTAssertTrue(schedule.isDue(2, now: 1), "An Accessibility notification still reads it within a second")
        schedule.reset(1)
        XCTAssertTrue(schedule.isDue(1, now: 0.1), "A report that disagrees reads it at once")
        schedule.didRead(1, now: 1, succeeded: false)
        XCTAssertTrue(schedule.isDue(1, now: 2), "A failed read backs off as before")
        schedule.didRead(2, now: 1, succeeded: true)
        schedule.relax([])
        XCTAssertTrue(schedule.isDue(2, now: 5), "Once the extension stops describing it, as often as before")
    }

    /// A report says a window's tabs changed while a read of it is under way: that read saw them
    /// from before, so the window is read again right after it.
    func testAReadUnderWayWhenAReportSaysTheTabsChangedDoesntCountAsReadingThemAgain() {
        var schedule = BrowserTabReadSchedule()
        schedule.watch([1])
        schedule.relax([1])
        schedule.didRead(1, now: 0, succeeded: true)
        XCTAssertFalse(schedule.isDue(1, now: 4))
        schedule.invalidate(1, now: 4.2)
        XCTAssertTrue(schedule.isDue(1, now: 4.2))
        schedule.didRead(1, now: 4.4, succeeded: true, started: 4)
        XCTAssertTrue(schedule.isDue(1, now: 4.5), "The read under way began before the report")
        schedule.didRead(1, now: 4.7, succeeded: true, started: 4.5)
        XCTAssertFalse(schedule.isDue(1, now: 5))
        XCTAssertTrue(schedule.isDue(1, now: 4.7 + BrowserTabReadSchedule.relaxedInterval))
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
        XCTAssertTrue(tree.scanner.select(snapshot.tabs[0].target).isDispatched, "An unrelated unreadable tab cannot block an exact live target")
        tree.container.nodes.removeFirst()
        XCTAssertFalse(tree.scanner.select(snapshot.tabs[0].target).isDispatched, "A removed handle is rejected even before another complete scan")
    }

    func testLargeCachedStripGetsABoundedBudgetBasedOnItsSize() throws {
        let tree = fixture(.chromium)
        for _ in 0..<118 { tree.container.append(tab("Background", selected: false)) }
        var time = 0.0
        tree.container.nodes.forEach { $0.onInfoRead = { time += 0.0009 } }
        let scanner = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45, now: { time }, wait: { _ in })
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
        let scanner = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45, now: { time }, wait: { _ in })
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
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8, wait: { _ in })
        let snapshot = try XCTUnwrap(scanner.scan())
        XCTAssertEqual(snapshot.tabs.map(\.title), (1...24).map { String(format: "Tab %02d", $0) })
        XCTAssertEqual(snapshot.tabs.filter(\.isSelected).map(\.title), ["Tab 01"])
        XCTAssertTrue(scanner.container === window.tabBar)
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).tabs.map(\.id), snapshot.tabs.map(\.id), "Reads after discovery keep each tab")
    }

    func testATabOutOfViewIsActedOnOnlyOnceItsBarShowsIt() throws {
        // Natively, Safari accepts a press or close on a tab that names no parent and does neither.
        let window = try crowdedSafariWindow()
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8, wait: { _ in })
        let snapshot = try XCTUnwrap(scanner.scan())
        let close = "Name:close tab\nTarget:0x0\n\(browserTabCloseSelector)"
        let (hidden, other) = (window.tabs[4], window.tabs[5])
        hidden.reportsNoWindow = true
        hidden.actions = ["AXScrollToVisible", "AXPress", close]
        XCTAssertFalse(scanner.select(snapshot.tabs[4].target).isDispatched, "Scrolling that leaves it out of view says so")
        XCTAssertFalse(scanner.close(snapshot.tabs[4].target).isDispatched)
        XCTAssertEqual(hidden.presses, 0)
        XCTAssertEqual(hidden.performed, ["AXScrollToVisible", "AXScrollToVisible"])
        other.actions = ["AXPress", close]
        XCTAssertFalse(scanner.select(snapshot.tabs[5].target).isDispatched, "Nor is one that can't be scrolled into view pressed")
        XCTAssertEqual(other.presses, 0)
        // Once scrolling shows it, it names its bar again and is pressed or closed.
        hidden.onPerform = { action in
            if action == "AXScrollToVisible" { hidden.reportsNoParent = false; hidden.reportsNoWindow = false }
        }
        XCTAssertTrue(scanner.select(snapshot.tabs[4].target).isDispatched)
        XCTAssertEqual(hidden.presses, 1)
        hidden.reportsNoParent = true
        XCTAssertTrue(scanner.close(snapshot.tabs[4].target).isDispatched)
        XCTAssertEqual(hidden.performed.last, close)
    }

    func testATabPiledUpInTheBarIsScrolledIntoViewBeforeItsPressedOrClosed() throws {
        // Natively, Safari's piled-up tabs have no title, only a description, and offer only
        // AXScrollToVisible until they're in view.
        let window = try crowdedSafariWindow()
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8, wait: { _ in })
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
        XCTAssertTrue(scanner.select(snapshot.tabs[12].target).isDispatched)
        XCTAssertEqual(piled.presses, 1)
        piled.actions = ["AXScrollToVisible"]
        XCTAssertTrue(scanner.close(snapshot.tabs[12].target).isDispatched)
        XCTAssertEqual(piled.performed, ["AXScrollToVisible", "AXScrollToVisible", close])
        // A tab already in view is pressed without scrolling.
        XCTAssertTrue(scanner.select(snapshot.tabs[20].target).isDispatched)
        XCTAssertEqual(window.tabs[20].performed, [])
    }

    func testATabThatChangesWhileScrollingIntoViewIsCheckedAgainBeforeItsPressed() throws {
        try checkATabThatChangesWhileScrollingIntoView(closing: false)
        try checkATabThatChangesWhileScrollingIntoView(closing: true)
    }

    private func checkATabThatChangesWhileScrollingIntoView(closing: Bool) throws {
        let window = try crowdedSafariWindow()
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8, wait: { _ in })
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
                    let done = closing ? scanner.close(target, cancelled: { cancelled }).isDispatched : scanner.select(target, cancelled: { cancelled }).isDispatched
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
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8, wait: { _ in })
        let snapshot = try XCTUnwrap(scanner.scan())
        // The selected tab always shows, so it must name its tab bar.
        window.tabs[0].reportsNoParent = true
        XCTAssertNil(scanner.scan())
        XCTAssertNil(BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8, wait: { _ in }).scan())
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
            XCTAssertFalse(scanner.select(snapshot.tabs[4].target).isDispatched)
        }
        window.tabs[4].owner = window.root
        window.tabs[4].windowUnreadable = true
        window.tabs[4].actions = ["Name:Close Tab\nTarget:0x0\n\(browserTabCloseSelector)"]
        XCTAssertNil(scanner.scan())
        XCTAssertFalse(scanner.select(snapshot.tabs[4].target).isDispatched)
        XCTAssertFalse(scanner.close(snapshot.tabs[4].target).isDispatched)
        window.tabs[4].windowUnreadable = false
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).tabs.map(\.id), snapshot.tabs.map(\.id))
        // A tab its tab bar no longer lists can't be pressed.
        window.tabBar.nodes.remove(at: 5)
        XCTAssertFalse(scanner.select(snapshot.tabs[5].target).isDispatched)
        XCTAssertEqual(window.tabs.map(\.presses), Array(repeating: 0, count: 24))
        XCTAssertEqual(window.tabs[4].performed, [])
    }

    func testATabOutOfViewIsPressedOnlyWhileItsTabBarStillHoldsTheSelectedTab() throws {
        let window = try crowdedSafariWindow()
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8, wait: { _ in })
        let snapshot = try XCTUnwrap(scanner.scan())
        // The selected tab no longer names the bar, as when Safari replaces its tab bar: the
        // failed read keeps the old handles, but a tab taken on the bar's word isn't pressed.
        window.tabs[0].reportsNoParent = true
        XCTAssertNil(scanner.scan())
        XCTAssertFalse(scanner.select(snapshot.tabs[4].target).isDispatched)
        XCTAssertTrue(scanner.select(snapshot.tabs[10].target).isDispatched, "A tab that names its bar still can be")
        window.tabs[0].reportsNoParent = false
        window.tabBar.nodes.removeFirst()
        XCTAssertFalse(scanner.select(snapshot.tabs[4].target).isDispatched, "Nor once the bar stops listing that tab")
        XCTAssertEqual(window.tabs.map(\.presses), (0..<24).map { $0 == 10 ? 1 : 0 })
    }

    func testChromeFamilyTabsOutOfViewFollowTheSameRules() throws {
        let tree = fixture(.chromium)
        tree.tabs[1].reportsNoParent = true
        tree.tabs[1].reportsNoWindow = true
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertEqual(snapshot.tabs.map(\.title), ["Alpha", "Beta"])
        XCTAssertFalse(tree.scanner.select(snapshot.tabs[1].target).isDispatched, "Not pressed while it names no tab strip")
        tree.tabs[1].actions = ["AXScrollToVisible"]
        tree.tabs[1].onPerform = { _ in tree.tabs[1].reportsNoParent = false; tree.tabs[1].reportsNoWindow = false }
        XCTAssertTrue(tree.scanner.select(snapshot.tabs[1].target).isDispatched)
        tree.tabs[1].reportsNoParent = true
        tree.tabs[0].reportsNoParent = true
        XCTAssertNil(tree.scanner.scan(), "The selected tab must name its tab strip")
        XCTAssertFalse(tree.scanner.select(snapshot.tabs[1].target).isDispatched)
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
        let scanner = BrowserTabScanner(root: root, adapter: .safari, windowId: 1, pid: 2, wait: { _ in })
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
        XCTAssertTrue(tree.scanner.select(first.tabs[0].target).isDispatched)
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
        XCTAssertFalse(tree.scanner.select(first.tabs[0].target).isDispatched)
        let otherWindow = BrowserTestNode("AXWindow")
        tree.container.owner = otherWindow
        XCTAssertFalse(tree.scanner.select(first.tabs[1].target).isDispatched)
        XCTAssertEqual(tree.tabs.map(\.presses), [0, 0])
    }

    func testModeRestartDoesNotReuseIdsAndWrongProcessCannotSelect() throws {
        let tree = fixture(.chromium)
        let first = try XCTUnwrap(tree.scanner.scan())
        let restarted = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45, wait: { _ in })
        let second = try XCTUnwrap(restarted.scan())
        XCTAssertNotEqual(first.windowSession, second.windowSession)
        XCTAssertTrue(Set(first.tabs.map(\.id)).isDisjoint(with: second.tabs.map(\.id)))
        XCTAssertFalse(restarted.select(first.tabs[0].target).isDispatched)
        let wrong = BrowserTabTarget(windowId: 123, pid: 46, windowSession: first.windowSession, tabId: first.tabs[0].id)
        XCTAssertFalse(tree.scanner.select(wrong).isDispatched)
        tree.tabs[0].supportsPress = false
        XCTAssertFalse(tree.scanner.select(first.tabs[0].target).isDispatched)
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
            now: { time += 0.05; return time }, wait: { _ in })
        XCTAssertNil(scanner.scan())
        let cancelled = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45, isCancelled: { true }, wait: { _ in })
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

    /// The composed Tabs sidebar draws a browser window's tabs, alone and in a split. Each title is
    /// checked in the real rendered view, without reading text back from the image: drawing it with
    /// only that text changed changes pixels, and only in that title's row. That shows the view draws
    /// each title where it belongs, though not that the glyphs read as the word.
    @MainActor
    func testBrowserGroupAndSplitRenderWithoutChangingWindowIdentity() throws {
        let browser = try XCTUnwrap(fixture(.chromium).scanner.scan())
        XCTAssertEqual(browser.tabs.map(\.title), ["Alpha", "Beta"])
        func retitled(_ index: Int, _ title: String) -> BrowserTabsModel {
            var tabs = browser
            tabs.tabs[index].title = title
            return BrowserTabsModel(snapshots: [123: tabs])
        }
        let size = CGSize(width: 280, height: 480)
        for split in [false, true] {
            func tab(appName: String = "Google Chrome", notesTitle: String = "Research notes") -> WorkspaceSidebarWorkspaceViewModel {
                // No installed app's icon: one read again in the background could change between renders.
                let chrome = WorkspaceSidebarWindowViewModel(windowId: 123, workspaceName: "1", appName: appName,
                    appBundleId: "com.google.Chrome", appBundlePath: workspaceSidebarTestMissingAppPath, title: "Alpha", isFocused: true)
                let notes = WorkspaceSidebarWindowViewModel(windowId: 124, workspaceName: "1", appName: "Notes",
                    appBundleId: "com.apple.Notes", appBundlePath: workspaceSidebarTestMissingAppPath, title: notesTitle, isFocused: false)
                return WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId,
                    displayName: "1", sidebarLabel: "", isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil,
                    isFocused: true, isVisible: true, items: (split ? [chrome, notes] : [chrome]).map { .init(kind: .window($0)) })
            }
            func sidebar(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> WorkspaceSidebarSnapshot {
                var snapshot = WorkspaceSidebarSnapshot.empty
                snapshot.configuration.usesTabsList = true
                snapshot.configuration.expandedWidth = 280
                snapshot.configuration.collapsedWidth = 44
                snapshot.visibleWidth = 280
                snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
                snapshot.workspaces = [workspace]
                return snapshot
            }
            let workspace = tab()
            let render = try renderWorkspaceSidebarForTest(sidebar(workspace), browserTabs: BrowserTabsModel(snapshots: [123: browser]),
                size: size)
            let directory = projectRoot.appendingPathComponent(".build/browser-tabs-ui")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(render.bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(split ? "split.png" : "single.png"))

            XCTAssertNil(try renderWorkspaceSidebarForTest(sidebar(workspace), browserTabs: BrowserTabsModel(snapshots: [123: browser]),
                size: size).difference(from: render), "The same sidebar draws the same pixels, so a difference is the text's")
            func drawn(_ variant: WorkspaceSidebarTestRender, _ text: String) throws -> CGRect {
                try XCTUnwrap(variant.difference(from: render), "The sidebar draws “\(text)”, split: \(split)").bounds
            }
            let header = try XCTUnwrap(render.frame(of: .workspace("1")), "The tab's header row")
            let app = try drawn(renderWorkspaceSidebarForTest(sidebar(tab(appName: "Google Chromium")),
                browserTabs: BrowserTabsModel(snapshots: [123: browser]), size: size), "Google Chrome")
            let alpha = try drawn(renderWorkspaceSidebarForTest(sidebar(workspace), browserTabs: retitled(0, "Omega"), size: size), "Alpha")
            let beta = try drawn(renderWorkspaceSidebarForTest(sidebar(workspace), browserTabs: retitled(1, "Delta"), size: size), "Beta")
            // Alone, the browser's name is the tab's header; in a split, it heads the browser's half, under the split's.
            XCTAssertTrue(split ? app.minY >= header.maxY : header.contains(app), "The browser's name heads its tabs: \(app), \(header)")
            XCTAssertGreaterThanOrEqual(alpha.minY, app.maxY, "Alpha's row is under the browser's name: \(alpha)")
            XCTAssertGreaterThanOrEqual(beta.minY, alpha.maxY, "and Beta's under Alpha's: \(beta)")
            for row in [app, alpha, beta] {
                XCTAssertTrue(row.minX >= header.minX && row.maxX <= header.maxX, "Inside the sidebar's list: \(row)")
                XCTAssertLessThan(row.height, header.height, "One row's text: \(row)")
            }
            if split {
                let notes = try drawn(renderWorkspaceSidebarForTest(sidebar(tab(notesTitle: "Field notes")),
                    browserTabs: BrowserTabsModel(snapshots: [123: browser]), size: size), "Research notes")
                XCTAssertTrue(header.contains(notes), "The split's header names its other window: \(notes) in \(header)")
            }
            XCTAssertEqual(render.fittingSize.width, 280, accuracy: 0.5)
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

        func show(_ windows: [WorkspaceSidebarWindowViewModel], width: CGFloat = 280, scope: String = "monitor:0.0,0.0",
                  pinned: Set<UInt32> = []) {
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
                    monitorName: nil, isFocused: window.isFocused, isVisible: window.isFocused, items: [.init(kind: .window(window))],
                    appearance: .init(isFavorite: pinned.contains(window.windowId)))
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
        sidebar.show([a, b], pinned: [67])
        assertWatch(model, [83, 67], "A pinned tile shows its window's sound and website icon, so it's read too")
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
        let other = try XCTUnwrap(BrowserTabScanner(root: fixture(.chromium).root, adapter: .chromium, windowId: 456, pid: 45, wait: { _ in }).scan())
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
        func title(_ label: String) -> String { browserTabLabel(label, adapter: .chromium).title }
        XCTAssertEqual(title("Design - API - Memory usage - 64 MB"), "Design - API")
        XCTAssertEqual(title("Design - API - High memory usage - 1.2 GB"), "Design - API")
        XCTAssertEqual(title("项目 - 内存用量 - 64 MB"), "项目")
        XCTAssertEqual(title("Entwurf\u{a0}– Arbeitsspeichernutzung\u{a0}– 64 MB"), "Entwurf", "Chrome 154's German")
        XCTAssertEqual(title("Entwurf - Speichernutzung - 64 MB"), "Entwurf", "An older Chrome's German")
        XCTAssertEqual(title("Design - API"), "Design - API")
        XCTAssertEqual(title("Tips - Memory usage - "), "Tips - Memory usage - ", "A marker must be followed by the size")
        XCTAssertEqual(title(""), "Untitled tab")
        XCTAssertEqual(browserTabLabel("", adapter: .safari).title, "Untitled tab")
        XCTAssertNil(BrowserTabAdapter(bundleId: "company.thebrowser.Browser"))
        XCTAssertNotNil(BrowserTabAdapter(bundleId: "com.microsoft.edgemac"))
    }

    func testChromiumTabNamesSayWhetherTheTabPlaysSoundInTheBrowsersLanguage() {
        func label(_ text: String, _ adapter: BrowserTabAdapter = .chromium) -> String {
            let label = browserTabLabel(text, adapter: adapter)
            return "\(label.title)|\(label.audio.map { "\($0)" } ?? "silent")"
        }
        XCTAssertEqual(label("Lo-fi radio - YouTube - Audio playing"), "Lo-fi radio - YouTube|playing")
        XCTAssertEqual(label("Lo-fi radio - YouTube - Audio muted"), "Lo-fi radio - YouTube|muted")
        XCTAssertEqual(label("Lo-fi radio - Audio playing - Memory usage - 180 MB"), "Lo-fi radio|playing",
            "Memory use comes after the sound")
        XCTAssertEqual(label("Lo-fi radio – Audio playing"), "Lo-fi radio|playing", "British English uses a dash")
        XCTAssertEqual(label("Lo-fi 电台 - 正在播放音频"), "Lo-fi 电台|playing")
        XCTAssertEqual(label("Lo-fi 電台 - 靜音"), "Lo-fi 電台|muted")
        XCTAssertEqual(label("Radio – Audiowiedergabe"), "Radio|playing")
        XCTAssertEqual(label("Radio\u{a0}–\u{a0}Lecture audio"), "Radio|playing")
        XCTAssertEqual(label("Radio: reproducción de audio"), "Radio|playing")
        XCTAssertEqual(label("„Radijas“ – garso įrašo paleidimas"), "Radijas|playing", "Lithuanian quotes the title")
        XCTAssertEqual(label("Radio - オーディオ再生中です"), "Radio|playing")
        XCTAssertEqual(label("Uso de memoria de Radio: live: reproducción de audio: 64 MB"), "Radio: live|playing",
            "Spanish wraps the title in its memory label")
        XCTAssertEqual(label("Uso da memória em Rádio - Reprodução de áudio: 64 MB"), "Rádio|playing")
        XCTAssertEqual(label("Вкладка \"Радио: воспроизводится аудио\" использует 64 МБ памяти"), "Радио|playing")
        XCTAssertEqual(label("\"Radio - تشغيل الصوت\" - استخدام الذاكرة - 64 MB"), "Radio|playing")
        XCTAssertEqual(label("Audio playing guide - Docs"), "Audio playing guide - Docs|silent")
        XCTAssertEqual(label(" - Audio playing"), " - Audio playing|silent", "Chromium never names a tab by its sound alone")
        XCTAssertEqual(label("Radio - Camera recording"), "Radio - Camera recording|silent",
            "Another alert takes the sound's place, so it says nothing")
        XCTAssertEqual(label("Lo-fi radio - Audio playing", .safari), "Lo-fi radio - Audio playing|silent",
            "Safari names tabs by their titles alone")
        XCTAssertFalse(chromiumTabPlayingLabels.isEmpty || chromiumTabMutedLabels.isEmpty)
    }

    /// Every language's sound label, inside every language's memory label, still gives the title.
    func testEveryLanguagesSoundLabelIsFoundInsideAnyMemoryLabel() {
        for memory in chromiumTabMemoryLabels {
            for (labels, audio) in [(chromiumTabPlayingLabels, BrowserTabAudio.playing), (chromiumTabMutedLabels, .muted)] {
                for sound in labels {
                    let name = memory.prefix + sound.prefix + "Radio" + sound.suffix + memory.marker + "64 MB" + memory.suffix
                    let parsed = browserTabLabel(name, adapter: .chromium)
                    XCTAssertEqual(parsed.title, "Radio", name)
                    XCTAssertEqual(parsed.audio, audio, name)
                }
            }
        }
    }

    func testAChromiumReadGivesEachTabItsSoundAndStillConfirmsTheSelection() throws {
        let tree = fixture(.chromium)
        tree.tabs[0].title = "Alpha - Audio playing - Memory usage - 64 MB"
        tree.tabs[1].title = "Beta - Audio muted"
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertEqual(snapshot.tabs.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(snapshot.tabs.map(\.audio), [.playing, .muted])
        XCTAssertTrue(tree.scanner.confirmsSelection(in: snapshot, until: .infinity), "The selected tab's title is the one shown")
        let safari = fixture(.safari)
        safari.tabs[0].title = "Alpha - Audio playing"
        XCTAssertEqual(try XCTUnwrap(safari.scanner.scan()).tabs.map(\.audio), [nil, nil])
    }

    func testASafariTabPlayingSoundIsReadFromItsMuteButtonAndOnlySuchATabsControlsAreRead() throws {
        let tree = fixture(.safari)
        for tab in tree.tabs {
            tab.append(BrowserTestNode("AXImage"))
            tab.append(BrowserTestNode("AXStaticText"))
        }
        let mute = BrowserTestNode("AXButton")
        mute.title = "mute tab"
        mute.axDescription = "volume high"
        tree.tabs[1].append(mute)
        let first = try XCTUnwrap(tree.scanner.scan())
        XCTAssertEqual(first.tabs.map(\.audio), [nil, .playing])
        XCTAssertEqual(tree.tabs[0].nodes.map(\.structureReads), [0, 0], "A tab with only its icon and title has none read")
        XCTAssertEqual(tree.tabs[1].nodes.map(\.structureReads), [0, 0, 2],
            "The widest tab's last control also says, once per walk, how many a quiet tab has")
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()), first, "An unchanged strip reads the same, so nothing new is published")
        XCTAssertEqual(tree.tabs[1].nodes.map(\.structureReads), [0, 0, 3])
        mute.title = "unmute tab"
        mute.axDescription = "Volume Lower"
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [nil, .muted], "Muted, it offers to unmute")
        tree.tabs[1].nodes.removeLast()
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [nil, nil], "Stopped, the button goes")
        tree.tabs[1].append(BrowserTestNode("AXButton", subrole: "AXCloseButton"))
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [nil, nil], "A close button isn't a sound")
        tree.tabs[1].nodes.removeLast()

        tree.tabs[0].identifier = "TabBarTab?isNarrow=false&isExpanded=false&tabCount=&isPinned=true&isCluster=false&clusterID=&isActive=true"
        tree.tabs[0].nodes.removeLast()
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [nil, nil], "A pinned tab shows only its icon")
        let pinnedMute = BrowserTestNode("AXButton")
        pinnedMute.title = "mute tab"
        tree.tabs[0].append(pinnedMute)
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [.playing, nil])

        let chrome = fixture(.chromium)
        let chromeMute = BrowserTestNode("AXButton")
        chromeMute.title = "Mute tab"
        chrome.tabs[0].append(chromeMute)
        XCTAssertEqual(try XCTUnwrap(chrome.scanner.scan()).tabs.map(\.audio), [nil, nil], "Chromium says it in the tab's name")
        XCTAssertEqual(chrome.tabs.map(\.childReads), [0, 0], "and its tabs' controls are never read")
    }

    func testASafariTabsSoundControlIsToldApartFromItsCloseButtonInAnyLanguageAndWithoutIcons() throws {
        let tree = fixture(.safari)
        for tab in tree.tabs {
            tab.append(BrowserTestNode("AXImage"))
            tab.append(BrowserTestNode("AXStaticText"))
        }
        let close = "Tab schließen"
        tree.tabs[1].actions = ["AXPress", "Name:\(close)\nTarget:0x1\nSelector:_closeButtonClicked:"]
        let control = BrowserTestNode("AXButton")
        control.title = "Tab stummschalten"
        control.axDescription = "Lautstärke hoch"
        tree.tabs[1].append(control)
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [nil, .playing], "A German Safari's mute button")
        control.title = close
        control.axDescription = nil
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [nil, nil],
            "A close button under the pointer has the close action's name")
        XCTAssertEqual(safariCloseActionName(tree.tabs[1].actions), close)

        // Without the close action's name, only English words say a button is the sound.
        tree.tabs[1].actions = []
        control.title = "Tab schließen"
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [nil, nil])
        control.title = "mute tab"
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [nil, .playing])

        // Without website icons, a tab shows only its title.
        let plain = fixture(.safari)
        for tab in plain.tabs { tab.append(BrowserTestNode("AXStaticText")) }
        let mute = BrowserTestNode("AXButton")
        mute.title = "mute tab"
        plain.tabs[0].append(mute)
        XCTAssertEqual(try XCTUnwrap(plain.scanner.scan()).tabs.map(\.audio), [.playing, nil])
        XCTAssertEqual(mute.structureReads, 2, "The widest tab's last control says how many a quiet tab has, once per walk")
        XCTAssertEqual(try XCTUnwrap(plain.scanner.scan()).tabs.map(\.audio), [.playing, nil])
        XCTAssertEqual(mute.structureReads, 3)
        XCTAssertEqual(plain.tabs[1].nodes.map(\.structureReads), [0])
    }

    /// When every tab has a sound control, the fewest a tab has still includes one.
    func testSafarisTabsAllPlayingOrMutedStillShowTheirSound() throws {
        for icons in [true, false] {
            let tree = fixture(.safari)
            for tab in tree.tabs {
                if icons { tab.append(BrowserTestNode("AXImage")) }
                tab.append(BrowserTestNode("AXStaticText"))
                let unmute = BrowserTestNode("AXButton")
                unmute.title = "unmute tab"
                tab.append(unmute)
            }
            XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [.muted, .muted], "icons: \(icons)")
        }
        // A window's one unpinned tab, playing, beside the selected pinned tab, with and without icons.
        for icons in [true, false] {
            let tree = fixture(.safari)
            tree.tabs[0].identifier = safariTabIdentifier(active: true).replacingOccurrences(of: "isPinned=false", with: "isPinned=true")
            tree.tabs[0].append(BrowserTestNode("AXImage"))
            if icons { tree.tabs[1].append(BrowserTestNode("AXImage")) }
            tree.tabs[1].append(BrowserTestNode("AXStaticText"))
            let mute = BrowserTestNode("AXButton")
            mute.title = "mute tab"
            tree.tabs[1].append(mute)
            XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [nil, .playing], "icons: \(icons)")
        }
    }

    /// A failed read never teaches how many controls a quiet tab has: the scan says nothing, and
    /// the next one learns it.
    func testAFailedControlReadLeavesTheLastCompleteScanAndIsReadAgain() throws {
        let tree = fixture(.safari)
        for tab in tree.tabs {
            tab.append(BrowserTestNode("AXImage"))
            tab.append(BrowserTestNode("AXStaticText"))
        }
        let mute = BrowserTestNode("AXButton")
        mute.title = "mute tab"
        tree.tabs[0].append(mute)
        tree.tabs[1].append(BrowserTestNode("AXButton"))
        tree.tabs[1].nodes[2].title = "mute tab"
        mute.unreadable = true
        XCTAssertNil(tree.scanner.scan())
        mute.unreadable = false
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [.playing, .playing],
            "Both tabs' buttons count, as the failed read left nothing learned")
        tree.tabs[1].nodes[2].unreadable = true
        XCTAssertNil(tree.scanner.scan(), "Nor does a sound control that can't be read say the tab is quiet")
    }

    func testASafariScanWhoseSoundReadsRunOutOfTimeSaysNothing() {
        let tree = fixture(.safari)
        var time = 0.0
        let scanner = BrowserTabScanner(root: tree.root, adapter: .safari, windowId: 123, pid: 45, now: { time }, wait: { _ in })
        for tab in tree.tabs {
            tab.append(BrowserTestNode("AXImage"))
            tab.append(BrowserTestNode("AXStaticText"))
        }
        XCTAssertNotNil(scanner.scan())
        let mute = BrowserTestNode("AXButton")
        mute.title = "mute tab"
        mute.onStructureRead = { time += 1 }
        tree.tabs[1].append(mute)
        XCTAssertNil(scanner.scan(), "A sound control read past the deadline leaves the last complete read in place")
    }

    func testABrowserStartingOrStoppingPlayingRereadsItsWindowsAndWalksSafarisLaterToo() {
        let windows: [(id: UInt32, bundleId: String?)] = [(1, safariBundleId), (2, safariBundleId), (3, "com.google.Chrome"),
            (4, "com.google.Chrome"), (5, appleMusicBundleId), (6, nil)]
        let rereads = browserTabRereads(windows, changed: [safariBundleId, "com.google.Chrome", appleMusicBundleId], watched: [1, 3, 5])
        XCTAssertEqual(rereads.now, [1, 3], "The sidebar's browser windows are read now")
        XCTAssertEqual(rereads.rediscover, [1, 2],
            "Safari's are walked at their next read, even one the sidebar shows only later, so it can't keep the sound it had")
        XCTAssertEqual(browserTabRereads(windows, changed: [], watched: [1, 3]).now, [])
    }

    func testAOneTabSafariWindowsSoundComesFromTheSpeakerInItsAddressField() throws {
        let root = BrowserTestNode("AXWindow")
        root.ownTitle = "Lo-fi radio"
        let toolbar = BrowserTestNode("AXToolbar")
        root.append(toolbar)
        let field = BrowserTestNode("AXGroup")
        toolbar.append(field)
        let reload = BrowserTestNode("AXButton")
        reload.identifier = "ReloadButton"
        field.append(reload)
        let speaker = BrowserTestNode("AXButton")
        speaker.identifier = safariAudioIndicatorIdentifier
        speaker.axDescription = "Mute This Tab"
        field.append(speaker)
        var time = 0.0
        let scanner = BrowserTabScanner(root: root, adapter: .safari, windowId: 1, pid: 2, now: { time }, wait: { _ in })
        XCTAssertNil(scanner.scan())
        XCTAssertEqual(try XCTUnwrap(scanner.loneTab()).tabs.map(\.audio), [.playing])
        XCTAssertEqual(speaker.structureReads, 1, "Read with the walk, not on its own")
        speaker.axDescription = "Unmute This Tab"
        time = 2
        XCTAssertEqual(try XCTUnwrap(scanner.loneTab()).tabs.map(\.audio), [.playing], "Between walks, only the title is read")
        XCTAssertEqual(speaker.structureReads, 1)
        // Muting stops the sound, so WinMux walks the window again (MacApp's `rediscover`).
        XCTAssertNil(scanner.scan())
        XCTAssertEqual(try XCTUnwrap(scanner.loneTab()).tabs.map(\.audio), [.muted])
        // On a silent page it offers to mute the tab playing elsewhere: that's no sound here.
        speaker.axDescription = "Mute Other Tabs"
        XCTAssertNil(scanner.scan())
        XCTAssertEqual(try XCTUnwrap(scanner.loneTab()).tabs.map(\.audio), [nil])
        speaker.axDescription = "Diesen Tab stummschalten"
        XCTAssertNil(scanner.scan())
        XCTAssertEqual(try XCTUnwrap(scanner.loneTab()).tabs.map(\.audio), [nil], "Only English words say which tab")
        field.nodes.removeLast()
        XCTAssertNil(scanner.scan())
        XCTAssertEqual(try XCTUnwrap(scanner.loneTab()).tabs.map(\.audio), [nil])
        // While Safari plays, a window whose title stays is walked sooner.
        time = 2 + browserLoneTabRediscoveryWhilePlaying
        XCTAssertNotNil(scanner.loneTab())
        XCTAssertNil(scanner.loneTab(rediscoverAfter: browserLoneTabRediscoveryWhilePlaying))

        // With a tab strip, the tabs say which one plays; the field's speaker is only the shown tab's.
        let tree = fixture(.safari)
        let other = BrowserTestNode("AXToolbar")
        tree.root.append(other)
        let playing = BrowserTestNode("AXButton")
        playing.identifier = safariAudioIndicatorIdentifier
        other.append(playing)
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.audio), [nil, nil])
        XCTAssertNil(tree.scanner.loneTab())
    }

    /// The WinMux Tabs extension titles its toolbar button in each window with that window's ids.
    /// The walk finds the button by its identifier, which names the extension and its team; later
    /// reads ask only the button again. Buttons of other extensions, or of an unsigned copy, say nothing.
    func testASafariReadSaysWhatTheExtensionsToolbarButtonNamesAndRereadsOnlyThatButton() throws {
        let identifier = "WebExtension-com.zimengxiong.winmux.safari-extension (N9YEGD9WDP)"
        let tree = fixture(.safari)
        let toolbar = BrowserTestNode("AXToolbar")
        let other = BrowserTestNode("AXButton")
        other.identifier = "WebExtension-com.example.other (ABCDE12345)"
        other.axDescription = "WinMux Tabs \u{00B7} 3f2a9c1e-1-2"
        let unsigned = BrowserTestNode("AXButton")
        unsigned.identifier = "WebExtension-com.zimengxiong.winmux.safari-extension (UNSIGNED)"
        unsigned.axDescription = "WinMux Tabs \u{00B7} 3f2a9c1e-1-3"
        let button = BrowserTestNode("AXButton")
        button.identifier = identifier
        button.axDescription = "WinMux Tabs \u{00B7} 3f2a9c1e-1401-1402"
        for node in [other, unsigned, button] { toolbar.append(node) }
        tree.root.append(toolbar)
        var time = 0.0
        let scanner = BrowserTabScanner(root: tree.root, adapter: .safari, windowId: 123, pid: 45, markerIdentifier: identifier, now: { time }, wait: { _ in })
        let first = try XCTUnwrap(scanner.scan())
        XCTAssertEqual(first.marker, .init(session: "3f2a9c1e", window: 1401, tab: 1402))
        XCTAssertEqual(button.structureReads, 1, "Read with the walk")
        let walked = toolbar.childReads
        button.axDescription = "WinMux Tabs \u{00B7} 3f2a9c1e-1401-1500"
        time = 1
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).marker?.tab, 1500, "A later read asks the button again")
        XCTAssertEqual(button.structureReads, 2)
        XCTAssertEqual(toolbar.childReads, walked, "and nothing else outside the tab bar")
        XCTAssertEqual(other.structureReads, 1)

        button.axDescription = "WinMux Tabs"
        XCTAssertNil(try XCTUnwrap(scanner.scan()).marker, "Before the extension titles a new tab, the button names nothing")
        button.axDescription = "WinMux Tabs \u{00B7} 3f2a9c1e-1401-1402"
        button.identifier = "SidebarButton"
        XCTAssertNil(try XCTUnwrap(scanner.scan()).marker, "An element that's no longer the extension's button says nothing")
        button.identifier = identifier
        time = 62
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).marker?.tab, 1402, "The next walk finds it again")
        // The button is customized away, though its old element still answers.
        toolbar.nodes.removeLast()
        time = 123
        XCTAssertNil(try XCTUnwrap(scanner.scan()).marker, "A walk that doesn't find it says nothing")
        XCTAssertNil(try XCTUnwrap(scanner.scan()).marker, "and what was found before isn't asked again")
        toolbar.append(button)
        time = 184
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).marker?.tab, 1402, "One that finds it again reads it")
        // Its element stops answering.
        button.unreadable = true
        XCTAssertNil(try XCTUnwrap(scanner.scan()).marker)
        let reads = button.structureReads
        XCTAssertNil(try XCTUnwrap(scanner.scan()).marker, "Until the next walk, a gone button isn't asked again")
        XCTAssertEqual(button.structureReads, reads)
        button.unreadable = false

        let plain = BrowserTabScanner(root: tree.root, adapter: .safari, windowId: 123, pid: 45, now: { time }, wait: { _ in })
        XCTAssertNil(try XCTUnwrap(plain.scan()).marker, "Without the extension, WinMux looks for no button")
        plain.markerIdentifier = identifier
        XCTAssertEqual(try XCTUnwrap(plain.scan()).marker?.tab, 1402, "Once it has the extension, the next read walks the window for it")
        let chrome = fixture(.chromium)
        chrome.root.append(toolbar)
        XCTAssertNil(try XCTUnwrap(BrowserTabScanner(root: chrome.root, adapter: .chromium, windowId: 1, pid: 2,
            markerIdentifier: identifier, wait: { _ in }).scan()).marker)
    }

    func testASafariWindowWithoutATabBarCarriesWhatItsExtensionButtonNames() throws {
        let identifier = "WebExtension-com.zimengxiong.winmux.safari-extension (N9YEGD9WDP)"
        let root = BrowserTestNode("AXWindow")
        root.ownTitle = "Demo Page"
        let toolbar = BrowserTestNode("AXToolbar")
        let button = BrowserTestNode("AXButton")
        button.identifier = identifier
        button.axDescription = "WinMux Tabs \u{00B7} 3f2a9c1e-7-8"
        toolbar.append(button)
        root.append(toolbar)
        let scanner = BrowserTabScanner(root: root, adapter: .safari, windowId: 1, pid: 2, markerIdentifier: identifier, now: { 0 }, wait: { _ in })
        XCTAssertNil(scanner.scan())
        XCTAssertEqual(try XCTUnwrap(scanner.loneTab(afterWalk: true)).marker, .init(session: "3f2a9c1e", window: 7, tab: 8))
        XCTAssertEqual(button.structureReads, 1, "Right after the walk that read it, the button isn't asked again")
        // A walk's read that fails right after it, or is given up: the next read asks the button.
        XCTAssertNil(scanner.scan())
        root.ownTitle = nil
        XCTAssertNil(scanner.loneTab(afterWalk: true))
        root.ownTitle = "Demo Page"
        button.axDescription = "WinMux Tabs \u{00B7} 3f2a9c1e-7-10"
        let walkedReads = button.structureReads
        XCTAssertEqual(try XCTUnwrap(scanner.loneTab()).marker?.tab, 10, "Not what the earlier walk read")
        XCTAssertEqual(button.structureReads, walkedReads + 1)
        button.axDescription = "WinMux Tabs \u{00B7} 3f2a9c1e-7-8"
        button.axDescription = "WinMux Tabs \u{00B7} 3f2a9c1e-7-9"
        let walked = root.childReads
        XCTAssertEqual(try XCTUnwrap(scanner.loneTab()).marker?.tab, 9, "Each title-only read asks the button too")
        XCTAssertEqual(root.childReads, walked)
    }

    func testASafariWindowWithoutATabBarIsReadAsItsOneTabNamedByTheWindow() throws {
        let root = BrowserTestNode("AXWindow")
        root.ownTitle = "Lo-fi radio"
        root.append(BrowserTestNode("AXToolbar"))
        var time = 0.0
        let scanner = BrowserTabScanner(root: root, adapter: .safari, windowId: 1, pid: 2, now: { time }, wait: { _ in })
        XCTAssertNil(scanner.loneTab(), "Only once a full read found no tab strip")
        XCTAssertNil(scanner.scan())
        let lone = try XCTUnwrap(scanner.loneTab())
        XCTAssertEqual(lone.tabs.map(\.title), ["Lo-fi radio"])
        XCTAssertEqual(lone.tabs.map(\.isSelected), [true])
        XCTAssertFalse(lone.isGroup)
        XCTAssertEqual(lone.windowSession, scanner.windowSession)
        let walked = root.structureReads
        time = 29
        XCTAssertEqual(try XCTUnwrap(scanner.loneTab()), lone, "While its title stays, the same tab")
        XCTAssertEqual(root.structureReads, walked, "and only the title is read")
        XCTAssertFalse(scanner.select(lone.tabs[0].target).isDispatched, "There's no tab control to press")
        root.ownTitle = "Jazz radio"
        XCTAssertNil(scanner.loneTab(), "A new title may be a new tab, so the window is walked again")
        XCTAssertNil(scanner.scan())
        XCTAssertGreaterThan(root.structureReads, walked)
        let renamed = try XCTUnwrap(scanner.loneTab())
        XCTAssertEqual(renamed.tabs.map(\.title), ["Jazz radio"])
        XCTAssertEqual(renamed.tabs.map(\.id), lone.tabs.map(\.id), "The same tab while the window stays alone")
        time = 29 + browserLoneTabRediscovery
        XCTAssertNil(scanner.loneTab(), "And every half minute")
        XCTAssertNil(scanner.scan())
        XCTAssertEqual(try XCTUnwrap(scanner.loneTab()).tabs.map(\.id), lone.tabs.map(\.id))

        let strip = BrowserTestNode("AXOpaqueProviderGroup")
        root.append(strip)
        for tab in [tab("Jazz radio", selected: true), tab("Start Page", selected: false)] {
            tab.identifier = safariTabIdentifier(active: tab.selected)
            strip.append(tab)
        }
        time = 70
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).tabs.count, 2, "A second tab shows the tab bar")
        XCTAssertNil(scanner.loneTab())
        // Closing the second tab hides the tab bar again, and its elements go.
        root.nodes.removeLast()
        strip.owner = nil
        time = 80
        XCTAssertNil(scanner.scan())
        XCTAssertNotEqual(try XCTUnwrap(scanner.loneTab()).tabs.map(\.id), lone.tabs.map(\.id), "Alone again, it's a new tab")

        let unknown = BrowserTestNode("AXGroup")
        unknown.unreadable = true
        root.append(unknown)
        time = 90
        XCTAssertNil(scanner.scan())
        XCTAssertNil(scanner.loneTab(), "A read that couldn't see everything says nothing")
        let chrome = BrowserTabScanner(root: BrowserTestNode("AXWindow"), adapter: .chromium, windowId: 3, pid: 2, wait: { _ in })
        XCTAssertNil(chrome.scan())
        XCTAssertNil(chrome.loneTab(), "Chromium windows without a strip aren't browser windows")
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
        XCTAssertTrue(tree.scanner.close(snapshot.tabs[1].target).isDispatched, "A tab's only button is its close button")
        XCTAssertEqual(closeBeta.presses, 1)
        XCTAssertTrue(tree.scanner.close(snapshot.tabs[0].target).isDispatched, "Among several buttons, the close button")
        XCTAssertEqual(closeAlpha.presses, 1)
        XCTAssertEqual(tree.tabs.map(\.presses), [0, 0], "Closing never selects the tab")
    }

    func testSafarisHiddenCloseButtonIsReachedThroughItsUnlocalizedCloseAction() throws {
        let tree = fixture(.safari)
        let close = "Name:关闭标签页\nTarget:0x7801b6d500\nSelector:_closeButtonClicked:"
        tree.tabs[1].actions = ["AXScrollToVisible", "AXShowMenu", "AXPress", close]
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertTrue(tree.scanner.close(snapshot.tabs[1].target).isDispatched, "Found by selector, whatever the language")
        XCTAssertEqual(tree.tabs[1].performed, [close])
        XCTAssertEqual(tree.tabs.map(\.presses), [0, 0], "Not the tab's press, which would select it")
        tree.tabs[0].actions = ["AXPress", "Name:Other\nTarget:0x1\nSelector:_otherAction:"]
        XCTAssertFalse(tree.scanner.close(snapshot.tabs[0].target).isDispatched, "Another named action isn't a close")
        XCTAssertEqual(tree.tabs[0].performed, [])
    }

    func testATabWithoutAnUnambiguousCloseControlOrThatMovedIsLeftOpen() throws {
        let tree = fixture(.safari)
        let first = BrowserTestNode("AXButton"), second = BrowserTestNode("AXButton")
        tree.tabs[1].append(first)
        tree.tabs[1].append(second)
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertFalse(tree.scanner.close(snapshot.tabs[0].target).isDispatched, "No close button")
        XCTAssertFalse(tree.scanner.close(snapshot.tabs[1].target).isDispatched, "Two unnamed buttons: guessing could do something else")
        XCTAssertEqual(first.presses + second.presses, 0)
        tree.container.nodes.removeFirst()
        XCTAssertFalse(tree.scanner.close(snapshot.tabs[0].target).isDispatched, "A tab that's gone")
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

    func testASafariTabIdentifierSaysWhetherItHeadsOrIsInATopicAndNothingElseDoes() throws {
        let id = UUID().uuidString
        // An identifier that's missing, or not supported, is none; one whose read failed can't be read.
        for (error, unreadable) in [(AXError.noValue, false), (.attributeUnsupported, false), (.cannotComplete, true), (.failure, true)] {
            var code = error.rawValue
            let read = browserTabIdentifier(try XCTUnwrap(AXValueCreate(.axError, &code)))
            XCTAssertNil(read.identifier, "\(error)")
            XCTAssertEqual(read.unreadable, unreadable, "\(error)")
        }
        XCTAssertEqual(browserTabIdentifier(safariTabIdentifier()).identifier, safariTabIdentifier())
        XCTAssertFalse(browserTabIdentifier(safariTabIdentifier()).unreadable)
        XCTAssertEqual(SafariTabCluster(identifier: nil), .unknown)
        XCTAssertEqual(SafariTabCluster(identifier: "TabBar?isSeparate=false"), .unknown)
        XCTAssertEqual(SafariTabCluster(identifier: "TabBarTab?isPinned=true&isActive=true"), .unknown, "No topics said")
        XCTAssertEqual(SafariTabCluster(.init(role: "AXRadioButton", subrole: "AXTabButton", identifierUnreadable: true)), .malformed,
            "An identifier that couldn't be read may be a topic's")
        XCTAssertEqual(SafariTabCluster(identifier: "TabBarTab?isNarrow=false&isExpanded=false&tabCount=&isPinned=true&isCluster=false&clusterID=&isActive=true"),
            .plain, "A pinned tab, as Safari 27.0 named it")
        XCTAssertEqual(SafariTabCluster(identifier: safariTabIdentifier(cluster: id, active: true)), .member(id: id))
        XCTAssertEqual(SafariTabCluster(identifier: safariTabIdentifier(cluster: id, header: true, expanded: true, tabCount: 4)),
            .header(id: id, isExpanded: true, tabCount: 4))
        XCTAssertEqual(SafariTabCluster(identifier: "TabBarTab?clusterID=\(id)&tabCount=2&isNew=true&isCluster=true&isExpanded=false"),
            .header(id: id, isExpanded: false, tabCount: 2), "In any order, among other fields")
        for malformed in [
            safariTabIdentifier(header: true, expanded: true, tabCount: 4),
            safariTabIdentifier(cluster: id, header: true, expanded: true),
            safariTabIdentifier(cluster: id, header: true, expanded: true, tabCount: 0),
            "TabBarTab?isCluster=true&clusterID=\(id)&isExpanded=maybe&tabCount=4",
            "TabBarTab?isCluster=true&clusterID=\(id)&isExpanded=true&tabCount=many",
            "TabBarTab?isCluster=yes&clusterID=\(id)&isExpanded=true&tabCount=4",
            "TabBarTab?isCluster=false&isCluster=true&clusterID=\(id)&isExpanded=true&tabCount=4",
            "TabBarTab?isCluster&clusterID=",
            "TabBarTab?clusterID=\(id)",
            "TabBarTab?isCluster=false&isActive=true",
            "TabBarTab?isExpanded=true&tabCount=4",
            "TabBarTab?isNarrow=false&isExpanded=false&tabCount=&isPinned=false&isActive=false",
            "TabBarTab?isCluster=false&clusterID=&isExpanded=maybe&tabCount=many",
            safariTabIdentifier().replacingOccurrences(of: "tabCount=", with: "tabCount=4"),
            safariTabIdentifier(cluster: id).replacingOccurrences(of: "isExpanded=false", with: "isExpanded=true"),
            safariTabIdentifier().replacingOccurrences(of: "isPinned=false", with: "isPinned=maybe"),
            safariTabIdentifier().replacingOccurrences(of: "isActive=false", with: "isActive=1"),
            safariTabIdentifier().replacingOccurrences(of: "isNarrow=false", with: "isNarrow"),
        ] {
            XCTAssertEqual(SafariTabCluster(identifier: malformed), .malformed, malformed)
            XCTAssertFalse(SafariTabCluster(identifier: malformed).isPage, malformed)
        }
    }

    /// A Safari window without topics, whether or not its tabs' identifiers speak of them, is
    /// listed and acted on as before.
    func testSafariTabsWithoutTopicsAreListedAndActedOnAsBefore() throws {
        for identifier in [safariTabIdentifier(), "TabBarTab?isPinned=false&isActive=false", nil] {
            let window = safariTopicWindow("PPPPP", selected: 0)
            for page in window.pages { page.identifier = identifier }
            let snapshot = try XCTUnwrap(window.scanner.scan())
            XCTAssertEqual(snapshot.tabs.map(\.title), window.pages.map(\.title))
            XCTAssertTrue(snapshot.isComplete)
            for tab in snapshot.tabs {
                XCTAssertTrue(window.scanner.select(tab.target).isDispatched)
                XCTAssertTrue(window.scanner.close(tab.target).isDispatched)
            }
            XCTAssertEqual(window.pages.map(\.presses), [1, 1, 1, 1, 1])
            XCTAssertEqual(window.pages.map(\.performed), Array(repeating: [safariCloseAction], count: 5))
        }
    }

    /// Safari 27 lists an open topic's own button among the tabs, with a tab's role and subrole,
    /// then the topic's tabs. The button is never listed, selected or closed; the tabs are, in
    /// order, wherever the topic is, so they still pair with the extension's one for one.
    func testAnOpenSafariTopicsOwnButtonIsNeverListedSelectedOrClosedButItsTabsAre() throws {
        for order in ["PPPPTMMMMPP", "TMMMMPPPPPP", "PPPPPPTMMMM"] {
            let window = safariTopicWindow(order)
            let topic = try XCTUnwrap(window.topic)
            let snapshot = try XCTUnwrap(window.scanner.scan(), order)
            XCTAssertEqual(snapshot.tabs.map(\.title), window.pages.map(\.title), order)
            XCTAssertEqual(snapshot.tabs.map(\.isSelected), (0..<10).map { $0 == 7 }, order)
            XCTAssertTrue(snapshot.isComplete, order)
            for (tab, page) in zip(snapshot.tabs, window.pages) {
                XCTAssertTrue(window.scanner.select(tab.target).isDispatched, order)
                XCTAssertTrue(window.scanner.close(tab.target).isDispatched, order)
                XCTAssertEqual(page.presses, 1, order)
                XCTAssertEqual(page.performed, [safariCloseAction], order)
            }
            XCTAssertEqual(topic.presses, 0, order)
            XCTAssertEqual(topic.performed, [], order)
            XCTAssertEqual(topic.nodes.map(\.presses), [0, 0], order)

            let reported = SafariExtensionWindow(key: .init(source: "p:s", id: 1), session: "s",
                tabs: window.pages.enumerated().map { .init(id: 100 + $0, title: $1.title, isActive: $1.selected) }, measured: 0)
            XCTAssertEqual(safariExtensionPairs([.init(snapshot: snapshot)], [reported]), [123: reported.key], order)
            var associations = SafariExtensionAssociations()
            associations.update([.init(snapshot: snapshot, observed: 1)], windows: [reported], now: 1)
            associations.update([.init(snapshot: snapshot, observed: 2)], windows: [reported], now: 2)
            XCTAssertEqual(snapshot.tabs.map { associations.described($0).extensionTab?.id }, Array(100..<110), order)
        }
    }

    /// A topic's own button has two texts, its name and count, where a tab has an icon and a title.
    /// Without website icons, a tab has only its title, so the button would look like a tab with a
    /// control more: it doesn't teach how many a quiet tab has. (The button was seen only with
    /// icons shown; without them it's made up.)
    func testASafariTopicsOwnButtonDoesntHideATabsSound() throws {
        for icons in [true, false] {
            let window = safariTopicWindow()
            if !icons { for page in window.pages { page.nodes.removeAll { $0.role == "AXImage" } } }
            let mute = BrowserTestNode("AXButton")
            mute.title = "mute tab"
            window.pages[5].append(mute)
            XCTAssertEqual(try XCTUnwrap(window.scanner.scan()).tabs.map(\.audio), (0..<10).map { $0 == 5 ? BrowserTabAudio.playing : nil },
                "icons: \(icons)")
        }
    }

    /// A tab bar whose topics don't account for their tabs, or speak of them in a way that can't be
    /// read, lists the tabs it can tell are pages, but acts only on those that say they're in no
    /// topic or whose own topic still accounts for its tabs, and none pairs with the extension's by
    /// place. What may be a topic's button is never pressed.
    func testSafariTopicsThatDontAccountForTheirTabsActOnlyOnTabsInNoTopic() throws {
        let elsewhere = UUID().uuidString
        let cases: [(name: String, change: (_ topic: BrowserTestNode, _ pages: [BrowserTestNode]) -> [BrowserTestNode], actionable: [Int])] = [
            ("its count unreadable", { topic, pages in
                topic.identifier = topic.identifier?.replacingOccurrences(of: "tabCount=4", with: "tabCount=many")
                return pages
            }, [0, 1, 2, 3, 8, 9]),
            ("one tab more than listed", { topic, pages in
                topic.identifier = topic.identifier?.replacingOccurrences(of: "tabCount=4", with: "tabCount=5")
                return pages
            }, [0, 1, 2, 3, 8, 9]),
            ("a tab whose topic isn't listed", { _, pages in
                pages[0].identifier = self.safariTabIdentifier(cluster: elsewhere)
                return pages
            }, [1, 2, 3, 4, 5, 6, 7, 8, 9]),
            ("a tab that says nothing of topics", { _, pages in
                pages[0].identifier = nil
                return pages
            }, [1, 2, 3, 8, 9]),
            ("a tab that can't be read", { _, pages in
                pages[0].identifier = "TabBarTab?isCluster=false&isCluster=true&clusterID="
                return Array(pages.dropFirst())
            }, [1, 2, 3, 8, 9]),
            ("two buttons for one topic", { topic, pages in
                pages[0].identifier = topic.identifier
                return Array(pages.dropFirst())
            }, [1, 2, 3, 8, 9]),
        ]
        for (name, change, actionable) in cases {
            let window = safariTopicWindow()
            let topic = try XCTUnwrap(window.topic)
            let listed = change(topic, window.pages)
            let snapshot = try XCTUnwrap(window.scanner.scan(), name)
            XCTAssertEqual(snapshot.tabs.map(\.title), listed.map(\.title), name)
            XCTAssertFalse(snapshot.isComplete, name)
            for (tab, page) in zip(snapshot.tabs, listed) {
                let acts = actionable.contains { window.pages[$0] === page }
                XCTAssertEqual(window.scanner.select(tab.target).isDispatched, acts, "\(name): \(page.title)")
                XCTAssertEqual(window.scanner.close(tab.target).isDispatched, acts, "\(name): \(page.title)")
            }
            XCTAssertEqual(window.pages.map(\.presses), (0..<10).map { actionable.contains($0) ? 1 : 0 }, name)
            XCTAssertEqual(window.pages.map(\.performed), (0..<10).map { actionable.contains($0) ? [safariCloseAction] : [] }, name)
            XCTAssertEqual(topic.presses, 0, name)
            XCTAssertEqual(topic.performed, [], name)
            let reported = SafariExtensionWindow(key: .init(source: "p:s", id: 1), session: "s",
                tabs: listed.enumerated().map { .init(id: 100 + $0, title: $1.title, isActive: $1.selected) }, measured: 0)
            XCTAssertEqual(safariExtensionPairs([.init(snapshot: snapshot)], [reported]), [:], name)
        }
    }

    /// SYNTHETIC, not from a capture: a closed topic, whose tabs Safari doesn't list. The other tabs
    /// show and are acted on, each by its own button, but don't pair with the extension's by
    /// place, and the topic's button is never pressed. With the active tab inside the topic, no
    /// tab listed is selected: no list at all.
    func testAClosedSafariTopicLeavesItsButtonAloneAndTheOtherTabsUnpairedSynthetic() throws {
        let window = safariTopicWindow("PPPPTPP", selected: 0, expanded: false)
        let topic = try XCTUnwrap(window.topic)
        let snapshot = try XCTUnwrap(window.scanner.scan())
        XCTAssertEqual(snapshot.tabs.map(\.title), window.pages.map(\.title))
        XCTAssertFalse(snapshot.isComplete)
        for tab in snapshot.tabs {
            XCTAssertTrue(window.scanner.select(tab.target).isDispatched)
            XCTAssertTrue(window.scanner.close(tab.target).isDispatched)
        }
        XCTAssertEqual(window.pages.map(\.presses), Array(repeating: 1, count: 6))
        XCTAssertEqual(window.pages.map(\.performed), Array(repeating: [safariCloseAction], count: 6))
        XCTAssertEqual(topic.presses, 0)
        XCTAssertEqual(topic.performed, [])
        let reported = SafariExtensionWindow(key: .init(source: "p:s", id: 1), session: "s",
            tabs: window.pages.enumerated().map { .init(id: 100 + $0, title: $1.title, isActive: $1.selected) }, measured: 0)
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: snapshot)], [reported]), [:])

        window.pages[0].selected = false
        topic.selected = true
        XCTAssertNil(window.scanner.scan())
        XCTAssertEqual(topic.presses, 0)
    }

    /// A listed tab is checked again before it's acted on: it must still be the page it was listed
    /// as, in the same topic. A reorder acts on the same tab, wherever it went. Once a topic is
    /// read closed, only tabs that still say they're in no topic are acted on.
    func testASafariTabThatChangedTopicOrBecameATopicsButtonSinceItWasListedIsLeftAlone() throws {
        let window = safariTopicWindow()
        let topic = try XCTUnwrap(window.topic)
        let snapshot = try XCTUnwrap(window.scanner.scan())
        window.container.nodes.reverse()
        XCTAssertTrue(window.scanner.select(snapshot.tabs[9].target).isDispatched)
        XCTAssertEqual((window.pages + [topic]).map(\.presses), Array(repeating: 0, count: 9) + [1, 0], "Reordered, the same tab")
        window.container.nodes.reverse()

        let (plain, member) = (window.pages[0], window.pages[4])
        let (plainIdentifier, memberIdentifier) = (plain.identifier, member.identifier)
        plain.identifier = memberIdentifier
        member.identifier = topic.identifier
        for tab in [snapshot.tabs[0], snapshot.tabs[4]] {
            XCTAssertFalse(window.scanner.select(tab.target).isDispatched)
            XCTAssertFalse(window.scanner.close(tab.target).isDispatched)
        }
        XCTAssertEqual([plain, member].map(\.presses), [0, 0], "Now in a topic, or the topic's button")
        XCTAssertEqual([plain, member].flatMap(\.performed), [])
        plain.identifier = plainIdentifier
        member.identifier = memberIdentifier
        XCTAssertTrue(window.scanner.select(snapshot.tabs[4].target).isDispatched, "As listed again")

        // The topic closes: its tabs leave the tab bar, and once read so, only tabs in no topic count.
        let members = Array(window.pages[4...7])
        window.container.nodes.removeAll { node in members.contains { $0 === node } }
        topic.identifier = topic.identifier?.replacingOccurrences(of: "isExpanded=true", with: "isExpanded=false")
        window.pages[7].selected = false
        window.pages[0].selected = true
        XCTAssertFalse(window.scanner.select(snapshot.tabs[5].target).isDispatched, "Gone from the tab bar")
        let closed = try XCTUnwrap(window.scanner.scan())
        XCTAssertFalse(closed.isComplete)
        XCTAssertEqual(closed.tabs.map(\.title), (window.pages[0...3] + window.pages[8...9]).map(\.title))
        XCTAssertTrue(window.scanner.select(closed.tabs[0].target).isDispatched)
        window.pages[1].identifier = memberIdentifier
        XCTAssertFalse(window.scanner.select(closed.tabs[1].target).isDispatched, "Now says it's in a topic")
        XCTAssertFalse(window.scanner.close(closed.tabs[1].target).isDispatched)
        XCTAssertEqual(window.pages[1].presses, 0)
        XCTAssertEqual(topic.presses, 0)
    }

    /// Two topics, each with its own button and tabs: open, all their tabs are acted on. Once one
    /// is read closed (SYNTHETIC, not from a capture), the window no longer pairs by place, but the
    /// open topic still accounts for its own tabs, which are acted on as before.
    func testTwoSafariTopicsAreEachAccountedForByTheirOwnTabs() throws {
        let window = safariTopicWindow("TMMPTMMMPP", selected: 0)
        let first = try XCTUnwrap(window.container.nodes.first)
        let second = try XCTUnwrap(window.topic)
        let open = try XCTUnwrap(window.scanner.scan())
        XCTAssertEqual(open.tabs.map(\.title), window.pages.map(\.title))
        XCTAssertTrue(open.isComplete)
        for tab in open.tabs { XCTAssertTrue(window.scanner.select(tab.target).isDispatched) }
        XCTAssertEqual(window.pages.map(\.presses), Array(repeating: 1, count: 8))

        let members = Array(window.pages[3...5])
        window.container.nodes.removeAll { node in members.contains { $0 === node } }
        second.identifier = second.identifier?.replacingOccurrences(of: "isExpanded=true", with: "isExpanded=false")
        let closed = try XCTUnwrap(window.scanner.scan())
        XCTAssertFalse(closed.isComplete)
        XCTAssertEqual(closed.tabs.map(\.title), (window.pages[0...2] + window.pages[6...7]).map(\.title))
        XCTAssertEqual(closed.tabs.map { window.scanner.select($0.target).isDispatched }, [true, true, true, true, true],
            "The open topic's tabs too: the closed one says nothing of them")
        XCTAssertEqual(window.pages.map(\.presses), [2, 2, 2, 1, 1, 1, 2, 2])
        XCTAssertEqual([first, second].map(\.presses), [0, 0])
    }

    /// A tab bar read in full that no longer accounts for its topics' tabs counts as such even when
    /// that scan fails, as when no tab it lists is selected: the tabs listed before are acted on
    /// only if they say they're in no topic. SYNTHETIC: a topic read closed with its tabs still
    /// listed.
    func testATabBarReadInFullAsIncompleteCountsEvenWhenItsScanFails() throws {
        let window = safariTopicWindow()
        let topic = try XCTUnwrap(window.topic)
        let snapshot = try XCTUnwrap(window.scanner.scan())
        topic.identifier = topic.identifier?.replacingOccurrences(of: "isExpanded=true", with: "isExpanded=false")
        window.pages[7].selected = false
        XCTAssertNil(window.scanner.scan())
        XCTAssertFalse(window.scanner.select(snapshot.tabs[4].target).isDispatched, "A tab in the topic")
        XCTAssertTrue(window.scanner.select(snapshot.tabs[0].target).isDispatched, "A tab in none")
        XCTAssertEqual(window.pages.map(\.presses), [1] + Array(repeating: 0, count: 9))
        XCTAssertEqual(topic.presses, 0)
    }

    /// A Safari tab is closed only by the action its close button calls, found by its unlocalized
    /// selector. Without that action, nothing is pressed: a tab's only button may be its sound's,
    /// and Safari 27.0 wasn't seen to show a close button. A failed read of its actions reads as
    /// none. A topic's own button, or what may be one, is never closed.
    func testASafariTabClosesOnlyByItsCloseActionNeverByAnotherButton() throws {
        let window = safariTopicWindow("PPPP", selected: 0)
        var buttons: [BrowserTestNode] = []
        for (page, (title, subrole)) in zip(window.pages, [("mute tab", ""), ("unmute tab", ""), ("", ""), ("", "AXCloseButton")]) {
            page.actions = ["AXScrollToVisible", "AXShowMenu", "AXPress"]
            let button = BrowserTestNode("AXButton", subrole: subrole)
            button.title = title
            page.append(button)
            buttons.append(button)
        }
        let snapshot = try XCTUnwrap(window.scanner.scan())
        for tab in snapshot.tabs { XCTAssertFalse(window.scanner.close(tab.target).isDispatched, tab.title) }
        XCTAssertEqual(buttons.map(\.presses), [0, 0, 0, 0])
        XCTAssertEqual(window.pages.map(\.presses), [0, 0, 0, 0], "Nor is the tab pressed")
        XCTAssertEqual(window.pages.map(\.performed), Array(repeating: ["AXScrollToVisible"], count: 4), "Only scrolled into view, to try again")
        window.pages[1].performed = []
        window.pages[1].actions.append(safariCloseAction)
        XCTAssertTrue(window.scanner.close(snapshot.tabs[1].target).isDispatched)
        XCTAssertEqual(window.pages[1].performed, [safariCloseAction])
        XCTAssertEqual(buttons[1].presses, 0)

        // Only an action whose one selector line is exactly the close button's, wherever else its words show.
        XCTAssertTrue(safariIsCloseAction("Name:关闭标签页\nTarget:0x7801b6d500\nSelector:_closeButtonClicked:"))
        let lookalikes = ["Name:Close Tab\nTarget:0x1\nSelector:_closeButtonClicked:other:",
                          "Name:Selector:_closeButtonClicked:\nTarget:0x1\nSelector:_otherAction:",
                          "Name:Close Tab\nTarget:Selector:_closeButtonClicked:\nSelector:_otherAction:",
                          "Name:Close Tab\nTarget:0x1\nSelector:_closeButtonClicked:\nSelector:_otherAction:"]
        for action in lookalikes {
            XCTAssertFalse(safariIsCloseAction(action), action)
            window.pages[2].actions = ["AXScrollToVisible", action]
            XCTAssertFalse(window.scanner.close(snapshot.tabs[2].target).isDispatched, action)
        }
        XCTAssertEqual(Set(window.pages[2].performed), ["AXScrollToVisible"])
        let unproven = safariTopicWindow("PP", selected: 0)
        unproven.pages[1].identifier = nil
        unproven.pages[1].actions = ["AXScrollToVisible", "AXPress"] + lookalikes
        let listed = try XCTUnwrap(unproven.scanner.scan())
        XCTAssertEqual(listed.tabs.map(\.title), ["Page 1"], "Nor do they show a control closes as a tab")
        XCTAssertFalse(listed.isComplete)

        let id = UUID().uuidString
        for identifier in [safariTabIdentifier(cluster: id, header: true, expanded: true, tabCount: 4), "TabBarTab?isCluster=true&clusterID=\(id)"] {
            let topic = BrowserTestNode("AXRadioButton", subrole: "AXTabButton")
            topic.identifier = identifier
            topic.actions = ["AXPress", safariCloseAction]
            let button = BrowserTestNode("AXButton")
            topic.append(button)
            XCTAssertEqual(topic.pressSafariCloseAction(try XCTUnwrap(topic.structure())), .unavailable, identifier)
            XCTAssertEqual(topic.performed, [], identifier)
            XCTAssertEqual(button.presses, 0, identifier)
        }
    }

    /// A tab button whose identifier says nothing of topics (none, one that couldn't be read, or
    /// another kind) is a tab only if it can be closed as one: Safari's tabs offer their close
    /// button's action, and a topic's own button doesn't. Otherwise it's never listed, pressed or
    /// closed, and the window doesn't pair with the extension by place; tabs that say they're in no
    /// topic are still acted on. Open, and (SYNTHETIC) closed, so its tabs aren't listed either.
    func testASafariTabButtonThatSaysNothingOfTopicsIsATabOnlyIfItClosesAsOne() throws {
        let changes: [(String, (BrowserTestNode) -> Void)] = [
            ("no identifier", { $0.identifier = nil }),
            ("an identifier that can't be read", { $0.identifierUnreadable = true }),
            ("another kind of identifier", { $0.identifier = $0.identifier?.replacingOccurrences(of: "TabBarTab?", with: "TabBarItem?") }),
        ]
        for (name, change) in changes {
            for order in ["PPPPTMMMMPP", "PPPPTPP"] {
                let window = safariTopicWindow(order, selected: 0, expanded: order.contains("M"))
                let topic = try XCTUnwrap(window.topic)
                change(topic)
                let snapshot = try XCTUnwrap(window.scanner.scan(), "\(name), \(order)")
                XCTAssertEqual(snapshot.tabs.map(\.title), window.pages.map(\.title), "\(name), \(order)")
                XCTAssertFalse(snapshot.isComplete, "\(name), \(order)")
                let plain = order.filter { $0 != "T" }.map { $0 == "P" }
                XCTAssertEqual(snapshot.tabs.map { window.scanner.select($0.target).isDispatched }, plain, "\(name), \(order)")
                XCTAssertEqual(snapshot.tabs.map { window.scanner.close($0.target).isDispatched }, plain, "\(name), \(order)")
                XCTAssertEqual(topic.presses, 0, "\(name), \(order)")
                XCTAssertEqual(topic.performed, [], "\(name), \(order)")
                let reported = SafariExtensionWindow(key: .init(source: "p:s", id: 1), session: "s",
                    tabs: window.pages.enumerated().map { .init(id: 100 + $0, title: $1.title, isActive: $1.selected) }, measured: 0)
                XCTAssertEqual(safariExtensionPairs([.init(snapshot: snapshot)], [reported]), [:], "\(name), \(order)")
            }
        }

        // Tabs saying nothing of topics, as before Safari 27, that close as tabs, are tabs as before;
        // their actions are read once, while listed.
        let legacy = safariTopicWindow("PPPP", selected: 0)
        for page in legacy.pages { page.identifier = nil }
        let listed = try XCTUnwrap(legacy.scanner.scan())
        XCTAssertTrue(listed.isComplete)
        XCTAssertEqual(listed.tabs.map(\.title), legacy.pages.map(\.title))
        XCTAssertEqual(try XCTUnwrap(legacy.scanner.scan()), listed)
        XCTAssertEqual(legacy.pages.map(\.actionReads), [1, 1, 1, 1])
        legacy.pages[3].actions = ["AXScrollToVisible"]
        XCTAssertEqual(try XCTUnwrap(legacy.scanner.scan()), listed, "As a tab piled up in a crowded tab bar, offering no close for now")
        for tab in listed.tabs {
            XCTAssertTrue(legacy.scanner.select(tab.target).isDispatched)
            XCTAssertTrue(legacy.scanner.close(tab.target).isDispatched == (tab != listed.tabs[3]))
        }
        // One never seen to close as a tab isn't one, and the window no longer accounts for its tabs.
        let mixed = safariTopicWindow("PPPP", selected: 0)
        for page in mixed.pages { page.identifier = nil }
        mixed.pages[3].actions = ["AXScrollToVisible", "AXShowMenu", "AXPress"]
        let partial = try XCTUnwrap(mixed.scanner.scan())
        XCTAssertEqual(partial.tabs.map(\.title), mixed.pages.prefix(3).map(\.title))
        XCTAssertFalse(partial.isComplete)
        for tab in partial.tabs { XCTAssertFalse(mixed.scanner.select(tab.target).isDispatched) }
        XCTAssertEqual(mixed.pages.map(\.presses), [0, 0, 0, 0])
    }

    /// Before Safari 27 there are no topics, so a tab button whose identifier says nothing of them
    /// is a tab, as it always was: in a crowded tab bar, a tab piled up offers no close action until
    /// it's scrolled into view, yet it's listed, and selected and closed once scrolled into view,
    /// with nothing more read than before. Where topics can show (Safari 27 on, or a version that
    /// can't be read), it must show it closes as a tab.
    func testBeforeSafari27ATabButtonSayingNothingOfTopicsIsATabAsBefore() throws {
        // Only a version that reads plainly as one before 27 says topics can't show.
        let versions: [(String?, Bool)] = [
            ("26.4", false), ("18.6", false), ("13.1.2", false), ("26.6.2", false), ("26", false),
            ("27.0", true), ("27.0.1", true), ("28", true),
            (nil, true), ("", true), ("beta", true), ("26.invalid", true), ("-1", true), ("0.0", true), ("26.", true),
            (".26", true), ("26..1", true), ("+26", true), (" 26", true), ("26 ", true), (".", true), ("26.4.1.2", true),
            ("26.4b", true), ("99999999999999999999.1", true), ("26.99999999999999999999", true), ("\u{FF12}\u{FF16}.4", true),
        ]
        for (version, showsTopics) in versions {
            XCTAssertEqual(safariShowsTopics(version: version), showsTopics, version ?? "nil")
        }
        // A version that can't be read plainly keeps the stricter rule: a topic's button that lost its
        // identifier is no tab, never acted on, and the window doesn't pair with the extension by place.
        let lost = safariTopicWindow("PPPPTPP", selected: 0, expanded: false)
        let lostTopic = try XCTUnwrap(lost.topic)
        lostTopic.identifier = nil
        let unclear = BrowserTabScanner(root: lost.root, adapter: .safari, windowId: 9, pid: 8, showsTopics: safariShowsTopics(version: "26.invalid"), wait: { _ in })
        let unclearTabs = try XCTUnwrap(unclear.scan())
        XCTAssertEqual(unclearTabs.tabs.map(\.title), lost.pages.map(\.title))
        XCTAssertFalse(unclearTabs.isComplete)
        XCTAssertEqual(unclearTabs.tabs.map { unclear.select($0.target).isDispatched }, Array(repeating: true, count: 6))
        XCTAssertEqual(lostTopic.presses, 0)
        XCTAssertEqual(lostTopic.performed, [])
        let reported = SafariExtensionWindow(key: .init(source: "p:s", id: 1), session: "s",
            tabs: lost.pages.enumerated().map { .init(id: 100 + $0, title: $1.title, isActive: $1.selected) }, measured: 0)
        XCTAssertEqual(safariExtensionPairs([.init(snapshot: unclearTabs)], [reported]), [:])
        let close = safariCloseAction
        for showsTopics in [false, true] {
            let window = try crowdedSafariWindow()
            let piled = window.tabs[12]
            for tab in window.tabs {
                tab.identifier = nil
                tab.actions = tab === piled ? ["AXScrollToVisible"] : ["AXScrollToVisible", "AXShowMenu", "AXPress", close]
            }
            piled.supportsPress = false
            piled.onPerform = { [unowned piled] action in
                guard action == "AXScrollToVisible" else { return }
                piled.supportsPress = true
                piled.actions = ["AXScrollToVisible", "AXPress", close]
            }
            let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 7, pid: 8, showsTopics: showsTopics, wait: { _ in })
            let snapshot = try XCTUnwrap(scanner.scan(), "showsTopics: \(showsTopics)")
            if showsTopics {
                XCTAssertEqual(snapshot.tabs.map(\.title), window.tabs.filter { $0 !== piled }.map(\.title))
                XCTAssertFalse(snapshot.isComplete)
                XCTAssertFalse(scanner.select(snapshot.tabs[12].target).isDispatched, "Nor is a tab that says nothing of topics acted on")
                XCTAssertEqual(window.tabs.map(\.presses), Array(repeating: 0, count: 24))
            } else {
                XCTAssertEqual(snapshot.tabs.map(\.title), window.tabs.map(\.title))
                XCTAssertTrue(snapshot.isComplete)
                XCTAssertTrue(scanner.select(snapshot.tabs[12].target).isDispatched)
                XCTAssertEqual(piled.presses, 1)
                XCTAssertTrue(scanner.close(snapshot.tabs[12].target).isDispatched)
                XCTAssertEqual(piled.performed, ["AXScrollToVisible", close])
                XCTAssertEqual(window.tabs.filter { $0 !== piled }.map(\.actionReads), Array(repeating: 0, count: 23))
            }
        }
    }

    /// Where topics can show, each tab saying nothing of them is asked once whether it closes as a
    /// tab. A large tab bar whose tabs' records fit a read's time but not those questions too is
    /// still listed: each read keeps what it found, even when it ran out of time, and the next goes
    /// on from there. Only what was found is kept.
    func testSafariTabsShownToCloseAsTabsStaySoAcrossReadsThatRunOutOfTime() throws {
        let tree = fixture(.safari)
        for _ in 0..<118 { tree.container.append(tab("Background", selected: false)) }
        var time = 0.0
        for node in tree.container.nodes {
            node.identifier = nil
            node.actions = ["AXScrollToVisible", "AXShowMenu", "AXPress", safariCloseAction]
            node.onInfoRead = { time += 0.0009 }
            node.onActionRead = { time += 0.0005 }
        }
        let scanner = BrowserTabScanner(root: tree.root, adapter: .safari, windowId: 123, pid: 45, now: { time }, wait: { _ in })
        var reads: [BrowserWindowTabs?] = []
        while reads.count < 6, reads.last??.tabs == nil { reads.append(scanner.scan()) }
        XCTAssertEqual(reads.map { $0?.tabs.count }, [nil, nil, 120], "Records alone fill the first read; the questions, the next two")
        XCTAssertEqual(tree.container.nodes.map(\.actionReads), Array(repeating: 1, count: 120))
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).tabs.count, 120, "Then each read fits")
        XCTAssertEqual(tree.container.nodes.map(\.actionReads), Array(repeating: 1, count: 120))
    }

    /// A topic's own button that says it's selected is never the selected tab: with a tab also
    /// selected, that tab is; alone, no tab is, so there's no list. So too once it has lost its
    /// identifier.
    func testASelectedSafariTopicButtonIsNeverTheSelectedTab() throws {
        for lost in [false, true] {
            let window = safariTopicWindow(selected: 0)
            let topic = try XCTUnwrap(window.topic)
            if lost { topic.identifier = nil }
            topic.selected = true
            let both = try XCTUnwrap(window.scanner.scan(), "lost: \(lost)")
            XCTAssertEqual(both.tabs.map(\.title), window.pages.map(\.title), "lost: \(lost)")
            XCTAssertEqual(both.tabs.filter(\.isSelected).map(\.title), ["Page 1"], "lost: \(lost)")
            XCTAssertEqual(both.isComplete, !lost, "lost: \(lost)")
            window.pages[0].selected = false
            XCTAssertNil(window.scanner.scan(), "lost: \(lost)")
            XCTAssertEqual(topic.presses, 0, "lost: \(lost)")
        }
    }

    /// A tab in a topic is acted on only while the tab bar, read again then, still accounts for its
    /// topics' tabs: the topic may have lost a tab or changed since the last scan, a scan may have
    /// failed before reading every tab, or the topic may change while the tab scrolls into view.
    /// Tabs in no topic are acted on all the same.
    func testATabInASafariTopicIsActedOnOnlyWhileItsTopicStillAccountsForItsTabs() throws {
        for change in ["another of its tabs gone", "its count changed", "a tab that can't be read"] {
            let window = safariTopicWindow(selected: 0)
            let topic = try XCTUnwrap(window.topic)
            let snapshot = try XCTUnwrap(window.scanner.scan())
            switch change {
                case "another of its tabs gone": window.container.nodes.removeAll { $0 === window.pages[5] }
                case "its count changed": topic.identifier = topic.identifier?.replacingOccurrences(of: "tabCount=4", with: "tabCount=5")
                default:
                    window.pages[9].unreadable = true
                    XCTAssertNil(window.scanner.scan(), "A scan that can't read every tab")
            }
            XCTAssertFalse(window.scanner.select(snapshot.tabs[4].target).isDispatched, change)
            XCTAssertFalse(window.scanner.close(snapshot.tabs[4].target).isDispatched, change)
            XCTAssertEqual(window.pages[4].presses, 0, change)
            XCTAssertEqual(window.pages[4].performed, [], change)
            XCTAssertTrue(window.scanner.select(snapshot.tabs[0].target).isDispatched, change)
            XCTAssertTrue(window.scanner.close(snapshot.tabs[0].target).isDispatched, change)
            XCTAssertEqual(topic.presses, 0, change)
        }

        let window = safariTopicWindow(selected: 0)
        let member = window.pages[4]
        let snapshot = try XCTUnwrap(window.scanner.scan())
        member.reportsNoParent = true
        member.onPerform = { [unowned member, unowned container = window.container, unowned other = window.pages[5]] action in
            guard action == "AXScrollToVisible" else { return }
            member.reportsNoParent = false
            container.nodes.removeAll { $0 === other }
        }
        XCTAssertFalse(window.scanner.select(snapshot.tabs[4].target).isDispatched, "The topic changed as the tab scrolled into view")
        XCTAssertEqual(member.performed, ["AXScrollToVisible"])
        XCTAssertEqual(member.presses, 0)

        // The tab moves to another window while the tab bar is read again, its topics still
        // accounted for as read: it's checked again after that read, and left alone.
        for closing in [false, true] {
            let window = safariTopicWindow(selected: 0)
            let member = window.pages[4]
            let snapshot = try XCTUnwrap(window.scanner.scan())
            let elsewhere = BrowserTestNode("AXWindow"), bar = BrowserTestNode("AXOpaqueProviderGroup")
            elsewhere.append(bar)
            window.pages[8].onStructureRead = { [unowned member, unowned container = window.container] in
                container.nodes.removeAll { $0 === member }
                bar.append(member)
            }
            withExtendedLifetime(elsewhere) {
                let target = snapshot.tabs[4].target
                XCTAssertFalse(closing ? window.scanner.close(target).isDispatched : window.scanner.select(target).isDispatched, "closing: \(closing)")
            }
            XCTAssertEqual(member.presses, 0, "closing: \(closing)")
            XCTAssertEqual(member.performed, [], "closing: \(closing)")
        }
    }

    // Phase A (2026-10-04): what a sidebar click or close does in Safari 27 windows, with and without
    // topics, through the scanner's production path. Each asserts what the user needs: every tab the
    // sidebar lists can be selected and closed, before and after Safari's selection moves.

    /// Safari's selection moves to `page`, as a click in Safari does: only its tab says it's
    /// selected and active, and the tab bar may re-lay out its tabs narrower.
    private func moveSafariSelection(to page: BrowserTestNode, in window: (root: BrowserTestNode, container: BrowserTestNode,
        topic: BrowserTestNode?, pages: [BrowserTestNode], scanner: BrowserTabScanner<BrowserTestNode>), narrow: Bool = false) {
        for tab in window.pages {
            tab.selected = tab === page
            tab.identifier = tab.identifier?.replacingOccurrences(of: "isActive=\(!tab.selected)", with: "isActive=\(tab.selected)")
                .replacingOccurrences(of: "isNarrow=\(!narrow)", with: "isNarrow=\(narrow)")
        }
    }

    /// Selects then closes every listed tab, as the sidebar does, and says which the scanner refused.
    private func refusedActions(_ snapshot: BrowserWindowTabs, _ scanner: BrowserTabScanner<BrowserTestNode>) -> [String] {
        snapshot.tabs.flatMap { tab in
            (scanner.select(tab.target).isDispatched ? [] : ["select \(tab.title)"]) + (scanner.close(tab.target).isDispatched ? [] : ["close \(tab.title)"])
        }
    }

    func testPhaseAWithoutTopicsEveryTabIsSelectedAndClosedBeforeAndAfterTheSelectionMoves() throws {
        let window = safariTopicWindow("PPPPPP", selected: 0)
        let snapshot = try XCTUnwrap(window.scanner.scan())
        XCTAssertEqual(refusedActions(snapshot, window.scanner), [])
        moveSafariSelection(to: window.pages[3], in: window, narrow: true)
        XCTAssertEqual(refusedActions(snapshot, window.scanner), [], "Before the next read")
        XCTAssertEqual(refusedActions(try XCTUnwrap(window.scanner.scan()), window.scanner), [], "After it")
    }

    func testPhaseAInAnOpenTopicAsCapturedEveryTabIsSelectedAndClosedBeforeAndAfterTheSelectionMoves() throws {
        let window = safariTopicWindow()
        let topic = try XCTUnwrap(window.topic)
        let snapshot = try XCTUnwrap(window.scanner.scan())
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(refusedActions(snapshot, window.scanner), [])
        for page in [window.pages[1], window.pages[5]] {
            moveSafariSelection(to: page, in: window, narrow: page === window.pages[5])
            XCTAssertEqual(refusedActions(snapshot, window.scanner), [], "Before the next read, \(page.title) selected")
            XCTAssertEqual(refusedActions(try XCTUnwrap(window.scanner.scan()), window.scanner), [], "After it")
        }
        XCTAssertEqual(topic.presses + topic.performed.count, 0)
    }

    /// SYNTHETIC: a closed topic whose tabs Safari no longer lists (as the first diagnosis supposed).
    /// The tabs shown can be selected and closed; the topic's own aren't shown at all.
    func testPhaseAWithATopicClosedAndItsTabsGoneTheTabsShownAreSelectedAndClosedSynthetic() throws {
        let window = safariTopicWindow("PPPTPPP", selected: 0, expanded: false)
        let snapshot = try XCTUnwrap(window.scanner.scan())
        XCTAssertFalse(snapshot.isComplete)
        XCTAssertEqual(snapshot.tabs.count, 6, "Only the tabs outside the topic are listed")
        XCTAssertEqual(refusedActions(snapshot, window.scanner), [])
        moveSafariSelection(to: window.pages[4], in: window)
        XCTAssertEqual(refusedActions(try XCTUnwrap(window.scanner.scan()), window.scanner), [])
    }

    /// SYNTHETIC: a closed topic whose tabs Safari still lists, so the sidebar shows every tab. Its
    /// tabs aren't selected or closed yet (that awaits the extension's help); every other tab is.
    func testPhaseAWithATopicClosedButItsTabsListedOnlyItsTabsAreLeftAloneSynthetic() throws {
        let window = safariTopicWindow("PPPTMMMPPP", selected: 0)
        let topic = try XCTUnwrap(window.topic)
        topic.identifier = topic.identifier?.replacingOccurrences(of: "isExpanded=true", with: "isExpanded=false")
        let snapshot = try XCTUnwrap(window.scanner.scan())
        XCTAssertEqual(snapshot.tabs.map(\.title), window.pages.map(\.title), "Every tab is listed")
        XCTAssertEqual(refusedActions(snapshot, window.scanner), ["Page 4", "Page 5", "Page 6"].flatMap { ["select \($0)", "close \($0)"] })
        XCTAssertEqual(topic.presses + topic.performed.count, 0)
    }

    /// SYNTHETIC: two topics, one open and one closed. The open topic accounts for all its tabs, so
    /// they should be selectable and closable; today they're refused for the other topic's sake.
    func testPhaseAWithOneTopicClosedTheOpenTopicsTabsAreSelectedAndClosedSynthetic() throws {
        let window = safariTopicWindow("PPTMMMPTPP", selected: 0)
        let closed = try XCTUnwrap(window.topic)
        closed.identifier = closed.identifier?.replacingOccurrences(of: "isExpanded=true", with: "isExpanded=false")
            .replacingOccurrences(of: "tabCount=0", with: "tabCount=3")
        let snapshot = try XCTUnwrap(window.scanner.scan())
        XCTAssertFalse(snapshot.isComplete)
        XCTAssertEqual(refusedActions(snapshot, window.scanner), [], "Every listed tab should act")
    }

    // Phase B1 (2026-10-04): what a select or close did, as the browser then shows it.

    /// A select the browser accepted is done only once its tab then says it's selected, read at
    /// once and after short pauses; otherwise what it did isn't known. It's sent once, whatever
    /// the browser answers: an error is no reason to press again, as the press may have landed.
    func testASelectIsConfirmedOnlyOnceItsTabSaysItsSelectedAndIsSentOnce() throws {
        let window = safariTopicWindow("PPPP", selected: 0)
        let snapshot = try XCTUnwrap(window.scanner.scan())
        XCTAssertEqual(window.scanner.select(snapshot.tabs[1].target), .dispatched(.unknown), "Accepted, but never seen selected")
        XCTAssertEqual(window.pages[1].presses, 1)
        let page = window.pages[2]
        page.onPress = { [unowned page] in page.selected = true }
        XCTAssertEqual(window.scanner.select(snapshot.tabs[2].target), .dispatched(.confirmed))
        page.selected = false

        var pauses: [TimeInterval] = []
        let slow = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 123, pid: 45, wait: { [unowned page = window.pages[3]] pause in
            pauses.append(pause)
            if pauses.count == 2 { page.selected = true }
        })
        let tabs = try XCTUnwrap(slow.scan()).tabs
        XCTAssertEqual(slow.select(tabs[3].target), .dispatched(.confirmed), "Selected once Safari had a moment")
        XCTAssertEqual(pauses, Array(browserTabActionConfirmationPauses.prefix(2)))

        let failing = window.pages[1]
        failing.pressFailure = .timedOut
        XCTAssertEqual(window.scanner.select(snapshot.tabs[1].target), .failed(.timedOut))
        XCTAssertEqual(failing.presses, 2, "Pressed once more, not twice")
        XCTAssertEqual(failing.performed, [], "and not scrolled into view to press again")
        failing.onPress = { [unowned failing] in failing.selected = true }
        XCTAssertEqual(window.scanner.select(snapshot.tabs[1].target), .dispatched(.confirmed), "An error, yet it landed")
    }

    /// A close the browser accepted is done only once its tab is gone: from its tab bar, as an
    /// element, or with its window. Otherwise what it did isn't known. It's never sent twice.
    func testACloseIsConfirmedOnlyOnceItsTabIsGoneAndIsNeverSentTwice() throws {
        let window = safariTopicWindow("PPPPPP", selected: 0)
        let snapshot = try XCTUnwrap(window.scanner.scan())
        XCTAssertEqual(window.scanner.close(snapshot.tabs[1].target), .dispatched(.unknown), "Accepted, but the tab stayed")
        XCTAssertEqual(window.pages[1].performed, [safariCloseAction], "Sent once, and not after scrolling it into view")

        let closing = window.pages[2]
        closing.onPerform = { [unowned closing, unowned container = window.container] action in
            if action.hasSuffix("_closeButtonClicked:") { container.nodes.removeAll { $0 === closing } }
        }
        XCTAssertEqual(window.scanner.close(snapshot.tabs[2].target), .dispatched(.confirmed), "Gone from its tab bar")
        let destroyed = window.pages[3]
        destroyed.onPerform = { [unowned destroyed] _ in destroyed.gone = true }
        XCTAssertEqual(window.scanner.close(snapshot.tabs[3].target), .dispatched(.confirmed), "Its element gone")

        let failing = window.pages[4]
        failing.performFailure = .timedOut
        XCTAssertEqual(window.scanner.close(snapshot.tabs[4].target), .failed(.timedOut))
        XCTAssertEqual(failing.performed, [safariCloseAction], "An error is no reason to close again")
        failing.onPerform = { [unowned failing, unowned container = window.container] _ in container.nodes.removeAll { $0 === failing } }
        XCTAssertEqual(window.scanner.close(snapshot.tabs[4].target), .dispatched(.confirmed), "An error, yet it closed")

        // The last tab closes its window: the tab bar can't be read, and says it's gone.
        let last = window.pages[5]
        last.onPerform = { [unowned container = window.container] _ in
            container.unreadable = true
            container.gone = true
        }
        XCTAssertEqual(window.scanner.close(snapshot.tabs[5].target), .dispatched(.confirmed))
    }

    /// An action that isn't sent says why, in categories only.
    func testABrowserTabActionThatIsntSentSaysWhy() throws {
        let window = safariTopicWindow(selected: 0)
        let topic = try XCTUnwrap(window.topic)
        let snapshot = try XCTUnwrap(window.scanner.scan())
        XCTAssertEqual(window.scanner.select(snapshot.tabs[0].target, cancelled: { true }), .notDispatched(.cancelled))
        window.container.nodes.removeAll { $0 === window.pages[1] }
        XCTAssertEqual(window.scanner.close(snapshot.tabs[1].target), .notDispatched(.changed), "Closed meanwhile")
        let plain = window.pages[2].identifier
        window.pages[2].identifier = window.pages[4].identifier
        XCTAssertEqual(window.scanner.select(snapshot.tabs[2].target), .notDispatched(.changed), "Now in a topic")
        window.pages[2].identifier = plain
        window.pages[3].supportsPress = false
        window.pages[3].actions = ["AXShowMenu"]
        XCTAssertEqual(window.scanner.select(snapshot.tabs[3].target), .notDispatched(.noAction))
        window.pages[8].reportsNoParent = true
        window.pages[8].actions = ["AXPress"]
        XCTAssertEqual(window.scanner.select(snapshot.tabs[8].target), .notDispatched(.outOfView))
        topic.identifier = topic.identifier?.replacingOccurrences(of: "tabCount=4", with: "tabCount=5")
        XCTAssertEqual(window.scanner.select(snapshot.tabs[5].target), .notDispatched(.unaccounted), "Its topic lost a tab")
        topic.identifier = topic.identifier?.replacingOccurrences(of: "tabCount=5", with: "tabCount=4")
            .replacingOccurrences(of: "isExpanded=true", with: "isExpanded=false")
        XCTAssertEqual(window.scanner.close(snapshot.tabs[5].target), .notDispatched(.collapsedTopic))
        window.container.unreadable = true
        XCTAssertEqual(window.scanner.select(snapshot.tabs[9].target), .notDispatched(.noResponse))
        XCTAssertEqual(window.pages.map(\.presses) + [topic.presses], Array(repeating: 0, count: 11))
    }

    /// Each select or close leaves one debug line saying how it went: categories and timings,
    /// never a title, address or topic id.
    func testEachBrowserTabActionLeavesOneDebugLineWithoutTitles() throws {
        var lines: [String] = []
        let window = safariTopicWindow()
        let scanner = BrowserTabScanner(root: window.root, adapter: .safari, windowId: 123, pid: 45, wait: { _ in }, log: { lines.append($0) })
        let snapshot = try XCTUnwrap(scanner.scan())
        let member = window.pages[5]
        member.onPress = { [unowned member] in member.selected = true }
        _ = scanner.select(snapshot.tabs[5].target)
        _ = scanner.close(snapshot.tabs[0].target)
        _ = scanner.select(snapshot.tabs[1].target, cancelled: { true })
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("select result=dispatched.confirmed stage=confirm class=member link=parent ax=succeeded " +
            "dispatchAttempted=true postcondition=confirmed ms="), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("close result=dispatched.unknown stage=confirm class=plain link=parent ax=succeeded " +
            "dispatchAttempted=true postcondition=unknown ms="), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("select result=notDispatched.cancelled stage=check class=unread link=unread ax=none " +
            "dispatchAttempted=false postcondition=none ms="), lines[2])
        let topicId = try XCTUnwrap(window.topic?.identifier?.split(separator: "&").first { $0.hasPrefix("clusterID=") }?.dropFirst(10))
        XCTAssertFalse(lines.contains { $0.contains("Page") || $0.contains("Topic") || $0.contains(topicId) })
    }

    private let safariCloseAction = "Name:Close Tab\nTarget:0x1\nSelector:_closeButtonClicked:"

    /// A Safari tab button's identifier as Safari 27.0 writes it (`SafariTabCluster`).
    private func safariTabIdentifier(cluster: String = "", header: Bool = false, expanded: Bool = false, tabCount: Int? = nil,
                                     active: Bool = false) -> String {
        "TabBarTab?isNarrow=false&isExpanded=\(expanded)&tabCount=\(tabCount.map(String.init) ?? "")&isPinned=false" +
            "&isCluster=\(header)&clusterID=\(cluster)&isActive=\(active)"
    }

    /// A Safari window whose tab bar shows a topic, built as Safari 27.0 was seen to list an open
    /// one, with made-up titles and ids: by default 11 buttons, all tabs by role, for 10 pages, the
    /// topic's own fifth, its 4 tabs after it, the last of them active. `order` places the topic's
    /// button ("T"), its tabs ("M", in the last topic before them) and the others ("P"); `topic`
    /// is the last topic's button. `selected` is the selected page, counting pages only. The topic's button has two texts, its name and count, and no close action; a
    /// tab has an icon and a title. A closed topic (`expanded: false`) wasn't seen: its identifier
    /// here is made up.
    private func safariTopicWindow(_ order: String = "PPPPTMMMMPP", selected: Int = 7, expanded: Bool = true) -> (root: BrowserTestNode,
        container: BrowserTestNode, topic: BrowserTestNode?, pages: [BrowserTestNode], scanner: BrowserTabScanner<BrowserTestNode>) {
        let root = BrowserTestNode("AXWindow")
        let container = BrowserTestNode("AXOpaqueProviderGroup", subrole: "AXOpaqueProviderList")
        container.identifier = "TabBar?isSeparate=false"
        root.append(container)
        var cluster = ""
        var topic: BrowserTestNode?
        var pages: [BrowserTestNode] = []
        for (index, kind) in order.enumerated() {
            let node = BrowserTestNode("AXRadioButton", subrole: "AXTabButton")
            container.append(node)
            node.actions = ["AXScrollToVisible", "AXShowMenu", "AXPress"]
            if kind == "T" {
                cluster = UUID().uuidString
                let count = order.dropFirst(index + 1).prefix { $0 != "T" }.filter { $0 == "M" }.count
                node.title = "Topic"
                node.identifier = safariTabIdentifier(cluster: cluster, header: true, expanded: expanded, tabCount: expanded ? count : 4)
                node.append(BrowserTestNode("AXStaticText"))
                node.append(BrowserTestNode("AXStaticText"))
                topic = node
            } else {
                let page = pages.count
                node.title = "Page \(page + 1)"
                node.selected = page == selected
                node.identifier = safariTabIdentifier(cluster: kind == "M" ? cluster : "", active: page == selected)
                node.actions.append(safariCloseAction)
                node.append(BrowserTestNode("AXImage"))
                node.append(BrowserTestNode("AXStaticText"))
                pages.append(node)
            }
        }
        return (root, container, topic, pages, BrowserTabScanner(root: root, adapter: .safari, windowId: 123, pid: 45, wait: { _ in }))
    }

    private func fixture(_ adapter: BrowserTabAdapter) -> (root: BrowserTestNode, container: BrowserTestNode,
        tabs: [BrowserTestNode], scanner: BrowserTabScanner<BrowserTestNode>) {
        let root = BrowserTestNode("AXWindow")
        let container = BrowserTestNode(adapter == .safari ? "AXOpaqueProviderGroup" : "AXTabGroup")
        if adapter == .safari { root.append(BrowserTestNode("AXTabGroup")) }
        root.append(container)
        let tabs = [tab("Alpha", selected: true), tab("Beta", selected: false)]
        for tab in tabs {
            // As Safari 27 names every tab, here in no topic.
            if adapter == .safari { tab.identifier = safariTabIdentifier(active: tab.selected) }
            container.append(tab)
        }
        return (root, container, tabs, BrowserTabScanner(root: root, adapter: adapter, windowId: 123, pid: 45, wait: { _ in }))
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
            if node.subrole == "AXTabButton" {
                // The capture didn't record identifiers; Safari 27 names every tab this way.
                node.identifier = safariTabIdentifier(active: node.selected)
                tabs.append(node)
            }
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
    var identifier: String?
    /// Fails to answer its identifier, the rest being read.
    var identifierUnreadable = false
    var axDescription: String?
    var onStructureRead: () -> Void = {}
    func structure() -> BrowserTabAXStructure? {
        structureReads += 1
        onStructureRead()
        return unreadable ? nil : .init(role: role, subrole: subrole, identifier: identifierUnreadable ? nil : identifier,
            identifierUnreadable: identifierUnreadable, title: title.isEmpty ? nil : title, description: axDescription)
    }
    func children() -> [BrowserTestNode]? { childReads += 1; return unreadable ? nil : nodes }
    func parent() -> BrowserTestNode? { reportsNoParent ? nil : ancestor }
    func tabRecord(withChildren: Bool) -> BrowserTabAXRecord<BrowserTestNode>? {
        guard let structure = structure(), let info = tabInfo() else { return nil }
        let parent: BrowserTabAXLink<BrowserTestNode> = reportsNoParent ? .none : ancestor.map { .element($0) } ?? .unreadable
        let window: BrowserTabAXLink<BrowserTestNode> = windowUnreadable ? .unreadable
            : reportsNoWindow ? .none : owner.map { .element($0) } ?? .unreadable
        return .init(structure: structure, info: info, parent: parent, window: window, children: withChildren ? children() : nil)
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
    /// What a press or an action answers once called: nil, success.
    var pressFailure: BrowserTabAXFailure?
    var performFailure: BrowserTabAXFailure?
    var onPress: () -> Void = {}
    func press() -> BrowserTabAXCall {
        guard supportsPress else { return .unavailable }
        presses += 1
        onPress()
        return pressFailure.map { .failed($0) } ?? .succeeded
    }
    /// Says it no longer exists, as an element whose tab closed does.
    var gone = false
    func isGone() -> Bool { gone }
    var actions: [String] = []
    var performed: [String] = []
    var actionReads = 0
    var onActionRead: () -> Void = {}
    func actionNames() -> [String] {
        actionReads += 1
        onActionRead()
        return actions
    }
    var onPerform: (String) -> Void = { _ in }
    func perform(_ action: String) -> BrowserTabAXCall {
        performed.append(action)
        guard actions.contains(action) else { return .unavailable }
        onPerform(action)
        return performFailure.map { .failed($0) } ?? .succeeded
    }
    var ownTitle: String?
    func windowTitle() -> String? { ownTitle }
}
