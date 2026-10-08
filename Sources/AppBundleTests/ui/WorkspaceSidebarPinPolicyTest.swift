import AppKit
@testable import AppBundle
import Common
import XCTest

/// Review V1 of the one-window pin. Every way a user puts windows together goes by the pins' one rule:
/// a command, a window dragged on screen or in the sidebar. An empty pin takes one window, never more. A
/// pinned split stays one whatever it holds now, and never opens windows while its own are open. A pin's
/// link to a window holds only while it's the same window, and a minimized one comes back restored.
@MainActor
final class WorkspaceSidebarPinPolicyTest: XCTestCase {
    private var notices: [String] = []
    private var restoreMinimized: (@MainActor (AppBundle.Window) async -> Bool)?
    private var recallNotice: (@MainActor (String, String) -> Void)?
    private var bootTime: (() -> Date?)?
    private var runningProcess: ((Int32) -> (bundleId: String?, launch: Date?)?)?

    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        TrayMenuModel.shared.isEnabled = true
        restoreMinimized = restoreMinimized ?? workspaceSidebarRestoreMinimizedWindow
        recallNotice = recallNotice ?? workspaceSidebarPinRecallNotice
        bootTime = bootTime ?? workspaceSidebarBootTime
        runningProcess = runningProcess ?? workspaceSidebarRunningProcess
        notices = []
        workspaceSidebarPinRecallNotice = { [unowned self] title, body in notices.append("\(title): \(body)") }
    }

    override func tearDown() async throws {
        clearPendingWindowDragIntent()
        MousePointerTracker.shared.reset()
        WorkspaceSidebarTabUndo.shared.clear()
        clearWorkspaceSidebarDropPreview()
        workspaceSidebarOrganizationStore = .init()
        if let restoreMinimized { workspaceSidebarRestoreMinimizedWindow = restoreMinimized }
        if let recallNotice { workspaceSidebarPinRecallNotice = recallNotice }
        if let bootTime { workspaceSidebarBootTime = bootTime }
        if let runningProcess { workspaceSidebarRunningProcess = runningProcess }
        appForTests = nil
        setMonitorsForTests(nil)
        config = defaultConfig
        try await super.tearDown()
    }

    // MARK: 1. Commands and the screen go by the pins' rule

    func testAMoveCommandIntoAOneWindowPinSplitsInAnOrdinaryTab() async throws {
        let (a, b, d, e) = try tabs()
        let one = try window(1), two = try window(2)
        _ = try window(4).focusWindow()
        let into = try await move(to: "a")
        XCTAssertEqual(into.exitCode, 0)
        XCTAssertEqual(into.stderr, [], "The pin's window came to 4's own tab: nothing to complain of")
        XCTAssertEqual(ids(d), [4, 1], "d, which 4 was the whole of, takes the split")
        XCTAssertEqual(ids(a), [], "a isn't turned into a pinned split")
        XCTAssertTrue(workspaceSidebarLentWindow(of: a) === one, "It lends its window, grey")

        // A window of a split gets a new ordinary tab with the pin's window, which comes forward.
        _ = try window(6).focusWindow()
        try await assertMove(to: "b")
        XCTAssertEqual(ids(e), [5])
        let split = try XCTUnwrap(Workspace.all.first { ids($0) == [2, 6] })
        XCTAssertFalse(workspaceSidebarIsPinned(split))
        XCTAssertTrue(workspaceSidebarLentWindow(of: b) === two)
        XCTAssertEqual(focus.windowOrNil?.windowId, 6)
        XCTAssertEqual(pins(), ["a", "b"])
        XCTAssertEqual([1, 2, 4, 5, 6].map(occurrences(of:)), [1, 1, 1, 1, 1])
    }

    func testAMoveCommandOutOfAOneWindowPinLendsItsWindow() async throws {
        let (a, b, d, _) = try tabs()
        let one = try window(1)
        _ = one.focusWindow()
        try await assertMove(to: "d")
        XCTAssertEqual(ids(d), [4, 1])
        XCTAssertTrue(workspaceSidebarLentWindow(of: a) === one, "The pin it left lends it")
        XCTAssertEqual(pins(), ["a", "b"])

        // From one pin into another: both lend their windows to a new ordinary tab.
        let four = try window(4)
        _ = tab("c", 3)
        try setWorkspaceSidebarTabFavorite(try XCTUnwrap(Workspace.existing(byName: "c")), true)
        _ = try window(3).focusWindow()
        try await assertMove(to: "b")
        let split = try XCTUnwrap(Workspace.all.first { ids($0) == [2, 3] })
        XCTAssertFalse(workspaceSidebarIsPinned(split))
        XCTAssertEqual(ids(b), [])
        XCTAssertEqual(workspaceSidebarLentWindow(of: b)?.windowId, 2)
        XCTAssertEqual(workspaceSidebarLentWindow(of: Workspace.get(byName: "c"))?.windowId, 3)
        XCTAssertTrue(four.nodeWorkspace === d)
    }

    func testAMoveCommandIntoAPinThatTakesNoWindowIsRefusedAndSaysWhy() async throws {
        let (a, _, d, e) = try tabs()
        try setWorkspaceSidebarTabFavorite(e, true)
        _ = try window(4).focusWindow()
        let intoSplit = try await move(to: "e")
        XCTAssertNotEqual(intoSplit.exitCode, 0)
        XCTAssertTrue(intoSplit.stderr.joined().contains("pinned split"), "\(intoSplit.stderr)")
        XCTAssertEqual(ids(e), [5, 6], "The pinned split takes no window")
        XCTAssertEqual(ids(d), [4])

        // A pin lending its window takes none either.
        _ = try window(1).focusWindow()
        try await assertMove(to: "d")
        _ = try window(5).focusWindow()
        try await assertMove(to: "a", refused: true)
        XCTAssertEqual(ids(a), [])
        XCTAssertEqual(ids(e), [5, 6])

        // An empty pin takes one window, which is its own.
        let z = Workspace.get(byName: "z")
        try setWorkspaceSidebarTabFavorite(z, true)
        _ = try window(4).focusWindow()
        try await assertMove(to: "z")
        XCTAssertEqual(ids(z), [4])
        XCTAssertNil(workspaceSidebarLentWindow(of: z))
    }

    func testAWindowDraggedOnScreenOntoAOneWindowPinsWindowSplitsInAnOrdinaryTab() throws {
        let (a, b, d, e) = try tabs()
        XCTAssertTrue(dropOnScreen(4, .stackSplit(targetWindowId: 1, position: .right)))
        XCTAssertEqual(ids(d), [1, 4], "Beside the pin's window, in 4's own tab")
        XCTAssertEqual(ids(a), [])
        XCTAssertEqual(workspaceSidebarLentWindow(of: a)?.windowId, 1)

        XCTAssertTrue(dropOnScreen(6, .moveToWorkspaceZone(workspaceName: "b", zone: .left)))
        XCTAssertEqual(ids(e), [5])
        let split = try XCTUnwrap(Workspace.all.first { ids($0) == [6, 2] }, "On the zone's side of the pin's window")
        XCTAssertFalse(workspaceSidebarIsPinned(split))
        XCTAssertEqual(workspaceSidebarLentWindow(of: b)?.windowId, 2)
        XCTAssertEqual(pins(), ["a", "b"])
    }

    func testAWindowDroppedOnScreenOnAPinMovesThereByTheSameRule() throws {
        let (a, _, d, e) = try tabs()
        XCTAssertTrue(dropOnScreen(4, .moveToWorkspace(workspaceName: "a")))
        XCTAssertEqual(Set(ids(d)), [1, 4], "Moved by the screen's own move, into 4's tab with the pin's window")
        XCTAssertEqual(ids(a), [])
        XCTAssertEqual(workspaceSidebarLentWindow(of: a)?.windowId, 1)

        // A pinned split and a lending pin take none, by any drop on screen.
        try setWorkspaceSidebarTabFavorite(e, true)
        let z = Workspace.get(byName: "z")
        _ = TestWindow.new(id: 9, parent: z.rootTilingContainer)
        for kind: WindowDragIntentKind in [.moveToWorkspace(workspaceName: "e"), .moveToWorkspaceZone(workspaceName: "e", zone: .right),
                                           .stackSplit(targetWindowId: 5, position: .left), .moveToWorkspace(workspaceName: "a")]
        {
            XCTAssertFalse(dropOnScreen(9, kind), "\(kind)")
            XCTAssertEqual(ids(z), [9], "\(kind)")
        }
        XCTAssertEqual(ids(e), [5, 6])
        // Windows aren't swapped across tabs with a pin, whose window would change.
        XCTAssertFalse(dropOnScreen(9, .swap(targetWindowId: 5)))
        XCTAssertEqual(ids(e), [5, 6])
    }

    func testAPinsWindowDraggedOutOnScreenIsLent() throws {
        let (a, b, d, e) = try tabs()
        XCTAssertTrue(dropOnScreen(1, .moveToWorkspace(workspaceName: "d")))
        XCTAssertEqual(Set(ids(d)), [1, 4])
        XCTAssertEqual(ids(a), [])
        XCTAssertEqual(workspaceSidebarLentWindow(of: a)?.windowId, 1, "The pin it left lends it")
        XCTAssertTrue(dropOnScreen(2, .moveToWorkspaceZone(workspaceName: "e", zone: .left)))
        XCTAssertEqual(ids(e), [2, 5, 6])
        XCTAssertEqual(workspaceSidebarLentWindow(of: b)?.windowId, 2)
        XCTAssertEqual(pins(), ["a", "b"])
    }

    func testAPinsWindowDraggedToNewTabInTheSidebarIsLent() async throws {
        let (_, b, _, _) = try tabs()
        let two = try window(2)
        let scope = workspaceSidebarMonitorScopeId(for: b.workspaceMonitor)
        await queueWorkspaceSidebarDrop(2, subject: .window, target: .newWorkspace(projectId: b.projectId, monitorScopeId: scope),
            placement: nil, intent: .physical)?.value
        XCTAssertFalse(two.nodeWorkspace === b)
        XCTAssertFalse(two.nodeWorkspace.map(workspaceSidebarIsPinned) ?? true, "A new ordinary tab")
        XCTAssertTrue(workspaceSidebarLentWindow(of: b) === two, "The pin lends it there")
    }

    /// The previews offer what the moves make: no split onto a pinned split's window, no swap with a pin's.
    func testScreenPreviewsOfferOnlyWhatThePinsRuleAllows() throws {
        let (a, _, _, e) = try tabs()
        let rect = Rect(topLeftX: 100, topLeftY: 100, width: 400, height: 300)
        for window in [try window(1), try window(5)] { window.lastAppliedLayoutPhysicalRect = rect }
        let four = try window(4)
        XCTAssertNotNil(stackSplitDestination(sourceWindow: four, targetWindow: try window(1), subject: .window, position: .left,
            detachOrigin: .window), "A one-window pin's window takes a split")
        try setWorkspaceSidebarTabFavorite(e, true)
        XCTAssertNil(stackSplitDestination(sourceWindow: four, targetWindow: try window(5), subject: .window, position: .left,
            detachOrigin: .window), "A pinned split's doesn't")
        XCTAssertNil(swapDestination(sourceWindow: four, targetWindow: try window(1), subject: .window, detachOrigin: .window))
        XCTAssertTrue(workspaceSidebarIsPinned(a))
    }

    // MARK: 2. An empty pin takes one window, never a group

    func testAGroupOfWindowsNeverGoesIntoAnEmptyPin() async throws {
        let (z, g, group) = try emptyPinAndGroup()
        XCTAssertFalse(workspaceSidebarPinPolicyAllows(group, into: z))
        XCTAssertTrue(workspaceSidebarPinPolicyAllows(try window(7), into: z), "One window still goes in")

        // In the sidebar, nothing is shown for the group; a window is.
        previewWorkspaceSidebarDrop(9, subject: .window, target: .workspace("z"))
        XCTAssertNotNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "One window is shown going in")
        previewWorkspaceSidebarDrop(7, subject: .group, target: .workspace("z"))
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "No drop is shown for the group")

        // On screen, over the empty pin on its display: nothing is offered for the group; a window is.
        XCTAssertTrue(z.workspaceMonitor.setActiveWorkspace(z))
        let point = z.workspaceMonitor.visibleRect.center
        XCTAssertNil(currentWindowDragIntentDestination(sourceWindow: try window(7), mouseLocation: point, subject: .group,
            detachOrigin: .window))
        XCTAssertNotNil(currentWindowDragIntentDestination(sourceWindow: try window(9), mouseLocation: point, subject: .window,
            detachOrigin: .window))

        // Released anyway, from the screen or onto the pin's row: not made.
        for style: WindowTabDropPreviewStyle in [.sidebarWorkspaceMove, .workspaceMove] {
            XCTAssertFalse(dropOnScreen(7, subject: .group, .moveToWorkspace(workspaceName: "z"), style: style))
        }
        XCTAssertFalse(dropOnScreen(7, subject: .group, .moveToWorkspaceZone(workspaceName: "z", zone: .left)))
        // Every move into a tab goes through the one rule, which checks it again.
        XCTAssertFalse(try moveWorkspaceSidebarNodeKeepingPins(group, onto: z) { _ in XCTFail("Not moved") })
        XCTAssertEqual(ids(z), [])
        XCTAssertEqual(ids(g), [7, 8, 9])
        XCTAssertTrue(try window(7).parent === group)

        // An empty pin over a split tab takes nothing in, at the release too.
        try applyWorkspaceSidebarPinnedTabDrop(z, .join("g", placement: .left, operation: .fill(.init(try window(7)))))
        XCTAssertEqual(ids(z), [])
        XCTAssertEqual(ids(g), [7, 8, 9])

        // Tabs mode has no stacks: a session gives each window of one its own tab first, so a group
        // dropped from the sidebar is one window by the time it's made, which the pin may take.
        await queueWorkspaceSidebarDrop(7, subject: .group, target: .workspace("z"), placement: nil, intent: .physical)?.value
        XCTAssertLessThanOrEqual(ids(z).count, 1)
        XCTAssertEqual([7, 8, 9].map(occurrences(of:)), [1, 1, 1])
    }

    // MARK: 6. A drop is made as the pin was at the release, or not at all

    /// A window dropped on a pin with one window splits with that window, and one dropped on an empty
    /// pin goes in, only while the pin is as it was at the release: never decided again from what it
    /// holds when the session runs.
    func testAWindowDropOnAPinIsMadeOnlyWhileThePinIsAsItWasAtTheRelease() async throws {
        for changed in ["one window", "empty"] {
            try await setUp()
            let (a, _, d, _) = try tabs()
            let z = Workspace.get(byName: "z")
            try setWorkspaceSidebarTabFavorite(z, true)
            let pin = changed == "empty" ? z : a
            let target = WorkspaceSidebarDropTarget(kind: .workspace(pin.name),
                rect: Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 36), acceptsSides: true)
            let intent = try XCTUnwrap(WorkspaceSidebarDropIntent.captured(for: target))
            XCTAssertEqual(intent.targetPinRole, changed == "empty" ? .empty : .single(.init(try window(1))), changed)
            let session = queueWorkspaceSidebarDrop(4, subject: .window, target: .workspace(pin.name), placement: .left,
                intent: intent)
            // Released: before its session runs, the pin's window is replaced, or the empty pin gets one.
            if pin === a { try window(1).unbindFromParent() }
            _ = TestWindow.new(id: 9, parent: pin.rootTilingContainer)
            await session?.value
            XCTAssertEqual(ids(d), [4], "\(changed): nothing moved")
            XCTAssertEqual(ids(pin), [9], changed)
            XCTAssertNil(workspaceSidebarLentWindow(of: pin), changed)
        }
    }

    // MARK: 3. A pinned split stays one whatever it holds

    func testAPinnedSplitWithOneWindowLeftIsStillAPinnedSplit() async throws {
        let (a, b, d, e) = try tabs()
        let one = try window(1)
        try splitPinnedTabWindowWithTab(a, "d", placement: .right)
        try setWorkspaceSidebarTabFavorite(d, true)
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(a), .returned(one))
        XCTAssertEqual(ids(d), [4])
        XCTAssertEqual(workspaceSidebarPinSplitRole(d), .composition, "Not a pin of its one window")
        XCTAssertFalse(workspaceSidebarTakesSplit(d))

        // Every deliberate move into it, or splitting it, is refused.
        await queueWorkspaceSidebarDrop(6, subject: .window, target: .workspace("d"), placement: .left, intent: .physical)?.value
        try applyWorkspaceSidebarPinnedTabDrop(b, .split("d", placement: .left, projectId: b.projectId,
            source: .init(try window(2)), target: .init(try window(4))))
        try applyWorkspaceSidebarPinnedTabDrop(d, .split("b", placement: .left, projectId: b.projectId,
            source: .init(try window(4)), target: .init(try window(2))))
        try applyWorkspaceSidebarPinnedTabDrop(d, .join("e", placement: .left, operation: .lend(.init(try window(4)))))
        _ = try window(5).focusWindow()
        try await assertMove(to: "d", refused: true)
        XCTAssertFalse(dropOnScreen(5, .moveToWorkspace(workspaceName: "d")))
        XCTAssertFalse(dropOnScreen(5, .stackSplit(targetWindowId: 4, position: .left)))
        XCTAssertEqual(ids(d), [4])
        XCTAssertEqual(ids(b), [2])
        XCTAssertEqual(ids(e), [5, 6])

        // Its window brought back fills its place again.
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(d), .recalled([one], elsewhere: []))
        XCTAssertEqual(ids(d), [4, 1])
    }

    /// With none of its windows in it, but some open elsewhere, a pinned split never opens its saved
    /// apps: a click brings back those it can, says where the rest are, and opens nothing.
    func testAnEmptyPinnedSplitWhoseWindowsAreOpenElsewhereOpensNothing() async throws {
        let (a, _, d, e) = try tabs()
        try splitPinnedTabWindowWithTab(a, "d", placement: .right)
        try setWorkspaceSidebarTabFavorite(d, true)
        // 1 back in its pin, then moved on to e by a command, which the pin lends it to; 4 moved out too.
        _ = try recallWorkspaceSidebarPinWindows(a)
        _ = try window(1).focusWindow()
        try await assertMove(to: "e")
        _ = try window(4).focusWindow()
        try await assertMove(to: "e")
        XCTAssertEqual(ids(d), [])
        XCTAssertEqual(Set(ids(e)), [1, 4, 5, 6])
        XCTAssertEqual(workspaceSidebarPinSplitRole(d), .composition, "Empty, still a pinned split")
        XCTAssertTrue(workspaceSidebarPinRecallsWindows(d), "Its windows are open: a click mustn't open its saved apps")

        let windowCount = Workspace.all.flatMap(\.allLeafWindowsRecursive).count
        recallPinWindowsFromSidebar("d", focusing: nil, targetMonitorScopeId: nil)
        try await waitUntil { !self.notices.isEmpty }
        XCTAssertEqual(ids(d), [], "Nothing taken from another tab")
        XCTAssertEqual(Set(ids(e)), [1, 4, 5, 6])
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("open elsewhere"), notices[0])
        XCTAssertEqual(Workspace.all.flatMap(\.allLeafWindowsRecursive).count, windowCount, "Nothing opened")

        // Once its window is back in its own pin, a click brings that one back.
        _ = try recallWorkspaceSidebarPinWindows(a)
        XCTAssertEqual(ids(a), [1])
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(d), .recalled([try window(1)], elsewhere: [try window(4)]))
        XCTAssertEqual(ids(d), [1])

        // With every window of it closed, it may open its saved apps again: none is open to clash with.
        for id: UInt32 in [1, 4] { try window(id).unbindFromParent() }
        XCTAssertFalse(workspaceSidebarPinRecallsWindows(d))
        XCTAssertEqual(workspaceSidebarPinSplitRole(d), .composition)
    }

    // MARK: 4. A minimized lent window comes back restored

    func testAGreyPinBringsBackItsMinimizedWindowOnceMacOSRestoresIt() async throws {
        let (a, _, d, _) = try tabs()
        let one = try XCTUnwrap(try window(1) as? TestWindow)
        try splitPinnedTabWindowWithTab(a, "d", placement: .right)
        minimize(one)
        XCTAssertTrue(workspaceSidebarLentWindow(of: a) === one, "Still lent while minimized")
        XCTAssertTrue(workspaceSidebarPinRecallsWindows(a))
        var restored: [UInt32] = []
        workspaceSidebarRestoreMinimizedWindow = { window in
            restored.append(window.windowId)
            (window as? TestWindow)?.nativeIsMacosMinimized = false
            return true
        }
        let windowCount = allWindowCount()
        recallPinWindowsFromSidebar("a", focusing: nil, targetMonitorScopeId: nil)
        try await waitUntil { ids(a) == [1] }
        XCTAssertEqual(restored, [1], "macOS restores it first")
        XCTAssertTrue(a.anyLeafWindowRecursive === one, "The same window")
        XCTAssertEqual(one.layoutReason, .standard)
        XCTAssertNil(workspaceSidebarLentWindow(of: a))
        XCTAssertEqual(ids(d), [4])
        XCTAssertEqual(allWindowCount(), windowCount, "Nothing opened")
        XCTAssertEqual(notices, [])
    }

    /// What the pin lent may change while macOS restores it: unpinned, given a window back, or the
    /// window closed. Then nothing comes back, and a notice says so; nothing is opened.
    func testAMinimizedWindowIsntBroughtBackIfItChangedWhileMacOSRestoredIt() async throws {
        for change in ["restore failed", "unpinned", "closed", "pin took a window"] {
            try await setUp()
            let (a, _, d, _) = try tabs()
            let one = try XCTUnwrap(try window(1) as? TestWindow)
            try splitPinnedTabWindowWithTab(a, "d", placement: .right)
            minimize(one)
            workspaceSidebarRestoreMinimizedWindow = { window in
                switch change {
                    case "restore failed": return false
                    case "unpinned": try? setWorkspaceSidebarTabFavorite(a, false)
                    case "closed": window.unbindFromParent()
                    default: _ = TestWindow.new(id: 9, parent: a.rootTilingContainer)
                }
                (window as? TestWindow)?.nativeIsMacosMinimized = false
                return true
            }
            let windowCount = allWindowCount()
            recallPinWindowsFromSidebar("a", focusing: nil, targetMonitorScopeId: nil)
            try await waitUntil { !self.notices.isEmpty }
            XCTAssertEqual(notices.count, 1, change)
            XCTAssertTrue(notices[0].contains(change == "restore failed" ? "stayed minimized" : "stayed where it is"),
                "\(change): \(notices)")
            XCTAssertFalse(one.nodeWorkspace === a, change)
            XCTAssertEqual(ids(d), [4], change)
            let made = change == "pin took a window" ? 1 : change == "closed" ? -1 : 0
            XCTAssertEqual(allWindowCount(), windowCount + made, "\(change): nothing opened")
        }
    }

    /// A hidden app's or full-screen window is shown where it is, never moved or opened again, and a
    /// notice says so. Pending Alan's decision.
    func testAHiddenOrFullScreenLentWindowIsShownWhereItIs() async throws {
        for fullScreen in [false, true] {
            try await setUp()
            let (a, _, d, _) = try tabs()
            let one = try window(1)
            try splitPinnedTabWindowWithTab(a, "d", placement: .right)
            one.bind(to: fullScreen ? d.macOsNativeFullscreenWindowsContainer : d.macOsNativeHiddenAppsWindowsContainer,
                adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
            XCTAssertEqual(try recallWorkspaceSidebarPinWindows(a), .elsewhere(one))
            recallPinWindowsFromSidebar("a", focusing: nil, targetMonitorScopeId: nil)
            try await waitUntil { !self.notices.isEmpty }
            XCTAssertTrue(notices[0].contains(fullScreen ? "in full screen" : "hidden"), notices[0])
            XCTAssertTrue(one.nodeWorkspace === d, "It stays where it is")
            XCTAssertEqual(ids(a), [])
        }
    }

    // MARK: 5. A link to a window holds only while it's the same window

    func testALinkIsToOneLifetimeOfAWindow() throws {
        let boot = Date(timeIntervalSince1970: 1_000_000)
        let launch = Date(timeIntervalSince1970: 2_000_000)
        workspaceSidebarBootTime = { boot }
        let notes = TestApp(pid: 501, bundleId: "com.example.notes", launchDate: launch)
        let a = Workspace.get(byName: "a"), d = Workspace.get(byName: "d")
        let window = TestWindow.new(id: 30, parent: d.rootTilingContainer, app: notes)
        try setWorkspaceSidebarTabFavorite(a, true)
        let link = WorkspaceSidebarPinWindow(window)
        XCTAssertEqual(link, .init(windowId: 30, pid: 501, bundleId: "com.example.notes", processLaunch: launch, boot: boot))
        XCTAssertTrue(link.live === window)
        try workspaceSidebarOrganizationStore.update { $0.workspaces["a"]?.lentWindow = link }
        XCTAssertTrue(workspaceSidebarLentWindow(of: a) === window)

        var other = link
        other.windowId = 31
        XCTAssertNil(other.live, "Another number")
        other = link
        other.pid = 502
        XCTAssertNil(other.live, "Another process")
        other = link
        other.bundleId = "com.example.mail"
        XCTAssertNil(other.live, "Another app")
        other = link
        other.processLaunch = launch.addingTimeInterval(5)
        XCTAssertNil(other.live, "Another launch")

        // Another boot: the same number and process are another window.
        workspaceSidebarBootTime = { boot.addingTimeInterval(60) }
        XCTAssertNil(link.live)
        XCTAssertNil(workspaceSidebarLentWindow(of: a))
        workspaceSidebarBootTime = { boot }

        // The app relaunched with the same process number, its window given the same number.
        window.unbindFromParent()
        let relaunched = TestApp(pid: 501, bundleId: "com.example.notes", launchDate: launch.addingTimeInterval(60))
        let later = TestWindow.new(id: 30, parent: d.rootTilingContainer, app: relaunched)
        XCTAssertNil(link.live, "The same number, process and app, in another launch")
        XCTAssertNil(workspaceSidebarLentWindow(of: a))
        XCTAssertEqual(workspaceSidebarPinSplitRole(a), .empty, "An empty pin again, not grey")
        XCTAssertFalse(workspaceSidebarPinRecallsWindows(a))
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(a), .nothing)
        XCTAssertTrue(d.anyLeafWindowRecursive === later, "The later window isn't taken")
    }

    /// A window closing, or its app quitting, forgets it everywhere: lent, away from a pinned split, or
    /// in its layout, as `MacWindow.garbageCollect` and `MacApp.destroy` do.
    func testAClosedWindowOrQuitAppIsForgotten() throws {
        let (a, _, d, _) = try tabs()
        try splitPinnedTabWindowWithTab(a, "d", placement: .right)
        try setWorkspaceSidebarTabFavorite(d, true)
        _ = try recallWorkspaceSidebarPinWindows(a)
        XCTAssertEqual(appearance("d")?.composition?.away.map(\.window.windowId), [1])
        XCTAssertEqual(appearance("d")?.composition?.layout.windows.map(\.windowId), [4, 1])

        forgetWorkspaceSidebarPinWindows { $0.windowId == 1 && $0.pid == 0 }
        XCTAssertEqual(appearance("d")?.composition?.away, [])
        XCTAssertEqual(appearance("d")?.composition?.layout.windows.map(\.windowId), [4], "Its place goes too")

        _ = try recallWorkspaceSidebarPinWindows(d)
        try splitPinnedTabWindowWithTab(Workspace.get(byName: "b"), "e", placement: .right)
        XCTAssertEqual(appearance("b")?.lentWindow?.windowId, 2)
        forgetWorkspaceSidebarPinWindows { $0.pid == 0 }
        XCTAssertNil(appearance("b")?.lentWindow, "Every window of a process that ended")
        XCTAssertNotNil(appearance("d")?.composition, "The pinned split stays one, with no window of its own")
        XCTAssertEqual(appearance("d")?.composition?.layout, .empty, "Review V2 C: its last window goes from its layout too")
    }

    /// WinMux started again: a link stays only while its process may still have the window, the same
    /// app, launched when it was, in the same boot. Its window may not be seen yet.
    func testAWinMuxRestartKeepsOnlyLinksWhoseProcessIsStillTheSame() throws {
        let boot = Date(timeIntervalSince1970: 1_000_000)
        let launch = Date(timeIntervalSince1970: 2_000_000)
        workspaceSidebarBootTime = { boot }
        let running: [Int32: (bundleId: String?, launch: Date?)] = [501: ("com.example.notes", launch),
            503: ("com.example.notes", launch.addingTimeInterval(9)), 504: ("com.example.mail", launch)]
        workspaceSidebarRunningProcess = { running[$0] }
        func link(_ id: UInt32, _ pid: Int32, boot: Date = boot) -> WorkspaceSidebarPinWindow {
            .init(windowId: id, pid: pid, bundleId: "com.example.notes", processLaunch: launch, boot: boot)
        }
        let kept = link(1, 501), quit = link(2, 502), relaunched = link(3, 503), reused = link(4, 504)
        let otherBoot = link(5, 501, boot: boot.addingTimeInterval(-3600))
        try workspaceSidebarOrganizationStore.update { state in
            for (name, lent) in [("a", kept), ("b", quit), ("c", relaunched), ("d", reused), ("e", otherBoot)] {
                state.workspaces[name] = .init(isFavorite: true)
                state.workspaces[name]?.lentWindow = lent
            }
            state.workspaces["s"] = .init(isFavorite: true)
            state.workspaces["s"]?.composition = .init(
                layout: .split(.h, weight: 1, children: [.window(kept, weight: 1), .window(quit, weight: 1)]),
                away: [.init(window: quit, pinName: "b"), .init(window: kept, pinName: "a")])
        }
        forgetWorkspaceSidebarPinWindowsNoLongerOpen()
        XCTAssertEqual(appearance("a")?.lentWindow, kept, "Its process still runs: it may still be open")
        for name in ["b", "c", "d", "e"] { XCTAssertNil(appearance(name)?.lentWindow, name) }
        XCTAssertEqual(appearance("s")?.composition?.layout, .window(kept, weight: 1))
        XCTAssertEqual(appearance("s")?.composition?.away, [.init(window: kept, pinName: "a")])
    }

    /// An appearance saved before these fields reads; one saved with them reads back the same.
    func testPinLinksAreReadBackAndOlderRecordsStillRead() throws {
        let older = try JSONDecoder().decode(WorkspaceSidebarItemAppearance.self, from: Data(#"{"isFavorite":true}"#.utf8))
        XCTAssertTrue(older.isFavorite)
        XCTAssertNil(older.lentWindow)
        XCTAssertNil(older.composition)
        let window = WorkspaceSidebarPinWindow(windowId: 7, pid: 501, bundleId: "com.example.notes",
            processLaunch: Date(timeIntervalSince1970: 2_000_000), boot: Date(timeIntervalSince1970: 1_000_000))
        var appearance = WorkspaceSidebarItemAppearance(isFavorite: true)
        appearance.lentWindow = window
        appearance.composition = .init(layout: .split(.h, weight: 1, children: [.window(window, weight: 300),
            .split(.v, weight: 500, children: [.window(window, weight: 1)])]), away: [.init(window: window, pinName: "a")])
        let decoded = try JSONDecoder().decode(WorkspaceSidebarItemAppearance.self, from: JSONEncoder().encode(appearance))
        XCTAssertEqual(decoded, appearance)
    }

    // MARK: 7. A pinned split's windows come back to their places

    func testAPinnedSplitBringsItsWindowsBackToTheirPlacesInAnyOrder() async throws {
        for order in [["a", "b"], ["c", "a"], ["b", "c", "a"]] {
            try await setUp()
            let s = try pinnedSplit { root in
                for (id, weight) in [(1, 100), (2, 200), (3, 300), (4, 400)] as [(UInt32, CGFloat)] {
                    _ = TestWindow.new(id: id, parent: root, adaptiveWeight: weight)
                }
            }
            for name in order { _ = try recallWorkspaceSidebarPinWindows(Workspace.get(byName: name)) }
            XCTAssertEqual(ids(s).count, 4 - order.count, "\(order)")
            let back = try recallWorkspaceSidebarPinWindows(s)
            guard case .recalled(let windows, let elsewhere) = back else { return XCTFail("\(order): \(back)") }
            let expected: [String: UInt32] = ["a": 1, "b": 2, "c": 3]
            XCTAssertEqual(Set(windows.map(\.windowId)), Set(order.compactMap { expected[$0] }), "\(order)")
            XCTAssertEqual(elsewhere, [])
            XCTAssertEqual(ids(s), [1, 2, 3, 4], "\(order): each in its place")
            XCTAssertEqual(s.rootTilingContainer.children.map { $0.getWeight(.h) }, [100, 200, 300, 400], "\(order): its length")
            for name in ["a", "b", "c"] { XCTAssertNotNil(workspaceSidebarLentWindow(of: Workspace.get(byName: name)), name) }
        }
    }

    func testAPinnedSplitLeavesTheSlotOfAWindowThatIsElsewhereAndFillsItLater() async throws {
        let s = try pinnedSplit { root in
            for id: UInt32 in [1, 2, 3, 4] { _ = TestWindow.new(id: id, parent: root) }
        }
        let b = Workspace.get(byName: "b")
        _ = try recallWorkspaceSidebarPinWindows(Workspace.get(byName: "a"))
        _ = try recallWorkspaceSidebarPinWindows(b)
        // b's window moves on to d: b lends it there, and it isn't b's to give back.
        _ = try window(2).focusWindow()
        try await assertMove(to: "d")
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(s), .recalled([try window(1)], elsewhere: [try window(2)]))
        XCTAssertEqual(ids(s), [1, 3, 4])
        XCTAssertEqual(ids(Workspace.get(byName: "d")), [7, 2])

        _ = try recallWorkspaceSidebarPinWindows(b)
        XCTAssertEqual(ids(b), [2])
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(s), .recalled([try window(2)], elsewhere: []))
        XCTAssertEqual(ids(s), [1, 2, 3, 4], "Into the slot it left")
    }

    func testANestedPinnedSplitComesBackNested() throws {
        let s = try pinnedSplit { root in
            _ = TestWindow.new(id: 1, parent: root)
            let column = TilingContainer(parent: root, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST)
            _ = TestWindow.new(id: 2, parent: column, adaptiveWeight: 30)
            _ = TestWindow.new(id: 3, parent: column, adaptiveWeight: 70)
            _ = TestWindow.new(id: 4, parent: root)
        }
        for name in ["c", "b"] { _ = try recallWorkspaceSidebarPinWindows(Workspace.get(byName: name)) }
        XCTAssertEqual(ids(s), [1, 4])
        _ = try recallWorkspaceSidebarPinWindows(s)
        let root = s.rootTilingContainer
        XCTAssertEqual(root.orientation, .h)
        XCTAssertEqual(root.children.count, 3)
        let column = try XCTUnwrap(root.children[1] as? TilingContainer, "2 and 3 are stacked again, between 1 and 4")
        XCTAssertEqual(column.orientation, .v)
        XCTAssertEqual(column.children.map { ($0 as? AppBundle.Window)?.windowId }, [2, 3])
        XCTAssertEqual(column.children.map { $0.getWeight(.v) }, [30, 70])
        XCTAssertEqual(ids(s), [1, 2, 3, 4])
    }

    // MARK: Recalling leaves no empty row

    /// The counterpart, for a saved or grouped tab, of an emptied ordinary tab closing: the tab a grey
    /// pin's window is taken back from isn't listed while empty, and keeps its name and group.
    func testASavedOrGroupedTabTheWindowLeavesIsntListedAndKeepsWhatsSaved() throws {
        for kind in ["saved", "grouped"] {
            try setUp_sync()
            let (a, _, _, _) = try tabs()
            let f = tab("f", 8)
            try splitPinnedTabWindowWithTab(a, "f", placement: .right)
            XCTAssertEqual(ids(f), [8, 1])
            if kind == "saved" {
                try saveWorkspaceForSidebar(workspaceName: "f", displayName: "Research")
            } else {
                let group = try workspaceSidebarOrganizationStore.create(projectId: f.projectId, workspaceNames: [])
                try assignWorkspaceToSidebarCollection(f, collectionId: group.id)
            }
            try window(8).unbindFromParent()
            XCTAssertEqual(try recallWorkspaceSidebarPinWindows(a), .returned(try window(1)), kind)
            XCTAssertEqual(ids(a), [1])
            XCTAssertFalse(Workspace.existing(byName: "f").map(workspaceTabIsShown) ?? false, "\(kind): no empty row")
            if kind == "saved" {
                XCTAssertEqual(config.workspaceSidebar.workspaceLabels["f"], "Research", "Its name stays")
            } else {
                XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: "f")?.workspaceNames, ["f"], "Its group stays")
            }
        }
    }

    // MARK: Review V2 A: an agent's whole-tab layout goes by the pins' rule

    func testAnAgentLayoutPutsNoOtherWindowInAOneWindowPin() async throws {
        for asOperation in [true, false] {
            try await setUp()
            let (a, _, d, _) = try tabs()
            let result = try await applyAgentLayout("a", [1, 4], asOperation: asOperation)
            XCTAssertEqual(result.exitCode, 1, "\(asOperation)")
            XCTAssertTrue(result.stderr.joined().contains("setWorkspaceLayout 'a'"), "\(result.stderr)")
            XCTAssertTrue(result.stderr.joined().contains("pin with one window"), "\(result.stderr)")
            XCTAssertEqual(ids(a), [1], "Refused before anything changed")
            XCTAssertEqual(ids(d), [4])
            XCTAssertNil(appearance("a")?.composition, "No pinned split made")
        }
    }

    func testAnAgentLayoutPutsOneWindowInAnEmptyPinAndNoMore() async throws {
        for asOperation in [true, false] {
            try await setUp()
            let (_, _, d, e) = try tabs()
            let z = Workspace.get(byName: "z")
            try setWorkspaceSidebarTabFavorite(z, true)
            let two = try await applyAgentLayout("z", [4, 5], asOperation: asOperation)
            XCTAssertEqual(two.exitCode, 1, "\(asOperation)")
            XCTAssertTrue(two.stderr.joined().contains("empty pin: it takes one window, not 2"), "\(two.stderr)")
            XCTAssertEqual(ids(z), [])
            XCTAssertEqual(ids(d), [4])
            XCTAssertEqual(ids(e), [5, 6])
            let one = try await applyAgentLayout("z", [4], asOperation: asOperation)
            XCTAssertEqual(one.exitCode, 0, "\(one.stderr)")
            XCTAssertEqual(ids(z), [4])
        }
    }

    /// (Layouts here take windows from other tabs: unit tests find no window in a tab's replaced tree.)
    func testAnAgentLayoutTakingAPinsWindowLendsIt() async throws {
        for asOperation in [true, false] {
            try await setUp()
            let (a, _, d, e) = try tabs()
            let one = try window(1)
            let result = try await applyAgentLayout("n", [4, 1], asOperation: asOperation)
            XCTAssertEqual(result.exitCode, 0, "\(result.stderr)")
            XCTAssertEqual(ids(Workspace.get(byName: "n")), [4, 1])
            XCTAssertEqual(ids(a), [])
            XCTAssertTrue(workspaceSidebarLentWindow(of: a) === one, "\(asOperation): the pin lends it, grey")
            XCTAssertFalse(workspaceSidebarIsPinned(Workspace.get(byName: "n")))
            // Ordinary layouts are made as they always were.
            let ordinary = try await applyAgentLayout("m", [6, 5], asOperation: asOperation)
            XCTAssertEqual(ordinary.exitCode, 0, "\(ordinary.stderr)")
            XCTAssertEqual(ids(Workspace.get(byName: "m")), [6, 5])
            XCTAssertEqual(ids(e), [])
            XCTAssertEqual(ids(d), [])
        }
    }

    /// A request with a layout the pins' rule refuses changes nothing, not even its other edits.
    func testAnAgentRequestWithARefusedLayoutChangesNothing() async throws {
        let (a, _, d, e) = try tabs()
        let result = try await agentApply("""
            {"operations": [{"type": "moveWindowToWorkspace", "windowId": 6, "workspace": "d"}],
             "layout": {"workspaces": [\(agentLayoutJson("d", [4, 5])), \(agentLayoutJson("a", [1, 4]))]}}
            """)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(ids(a), [1])
        XCTAssertEqual(ids(d), [4])
        XCTAssertEqual(ids(e), [5, 6])
    }

    // MARK: Review V2 E: an agent's move the pins refuse says so, and where

    func testAnAgentMoveThePinsRefuseIsReportedWithItsTargetAndReason() async throws {
        let (a, _, d, e) = try tabs()
        try setWorkspaceSidebarTabFavorite(e, true)
        let intoSplit = try await agentApply(#"{"operations": [{"type": "moveWindowToWorkspace", "windowId": 4, "workspace": "e"}]}"#)
        XCTAssertEqual(intoSplit.exitCode, 1)
        XCTAssertTrue(intoSplit.stderr.joined().contains("moveWindowToWorkspace window 4"), "\(intoSplit.stderr)")
        XCTAssertTrue(intoSplit.stderr.joined().contains("Workspace 'e' is a pinned split"), "\(intoSplit.stderr)")
        XCTAssertEqual(ids(d), [4])
        XCTAssertEqual(ids(e), [5, 6])

        // Out of a pin, it lends its window; then the lending pin takes none, parked or moved.
        let out = try await agentApply(#"{"operations": [{"type": "moveWindowToWorkspace", "windowId": 1, "workspace": "d"}]}"#)
        XCTAssertEqual(out.exitCode, 0, "\(out.stderr)")
        XCTAssertEqual(workspaceSidebarLentWindow(of: a)?.windowId, 1)
        let park = try await agentApply(#"{"operations": [{"type": "parkWindow", "pane": {"windowId": 4}, "workspace": "a"}]}"#)
        XCTAssertEqual(park.exitCode, 1)
        XCTAssertTrue(park.stderr.joined().contains("parkWindow: Workspace 'a' is a pin whose window is in another tab"),
            "\(park.stderr)")
        XCTAssertEqual(Set(ids(d)), [1, 4])

        // A move to where the window already is stays a quiet success, as before.
        let noOp = try await agentApply(#"{"operations": [{"type": "moveWindowToWorkspace", "windowId": 4, "workspace": "d"}]}"#)
        XCTAssertEqual(noOp.exitCode, 0, "\(noOp.stderr)")
        XCTAssertEqual(noOp.stderr, [])
    }

    // MARK: Review V2 B: a pinned split keeps its type and its windows

    /// A split pinned before pinned splits were recorded is recorded once, while it shows its windows,
    /// and stays a pinned split as it loses them. One recorded with its tab's saved layout, its windows
    /// not back yet, takes them in as they come back.
    func testALegacyPinnedSplitIsRecordedOnceAndStaysOneAfterLosingAWindow() async throws {
        let (_, b, d, _) = try tabs()
        let s = tab("s", 7, 8)
        let t = Workspace.get(byName: "t")
        var saved = SavedWorkspaceRecord(workspaceName: "t")
        saved.layout.root.children = [.slot(.init(bundleId: "com.example.notes")), .slot(.init(bundleId: "com.example.mail"))]
        XCTAssertTrue(savedWorkspaceStore.insert(saved))
        try workspaceSidebarOrganizationStore.update { state in
            state.pinnedSplitsRecorded = nil
            for name in ["s", "t"] { state.workspaces[name] = .init(isFavorite: true) }
        }
        XCTAssertEqual(workspaceSidebarPinSplitRole(s), .composition, "Before it's recorded, by its windows")
        refreshModel()
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.pinnedSplitsRecorded, true)
        XCTAssertEqual(appearance("s")?.composition?.layout.windows.map(\.windowId), [7, 8])
        XCTAssertEqual(appearance("t")?.composition?.layout, .empty, "Its windows aren't back yet")

        // s loses a window, closed; t gets one of its two back.
        try window(8).unbindFromParent()
        forgetWorkspaceSidebarPinWindows { $0.windowId == 8 }
        _ = TestWindow.new(id: 9, parent: t.rootTilingContainer)
        refreshModel()
        XCTAssertEqual(appearance("t")?.composition?.layout.windows.map(\.windowId), [9], "Taken in as it came back")
        for split in [s, t] {
            XCTAssertEqual(workspaceSidebarPinSplitRole(split), .composition, "\(split.name): still a pinned split, with one window")
            // Every gesture into it, or splitting it, is refused, as for any pinned split.
            await queueWorkspaceSidebarDrop(4, subject: .window, target: .workspace(split.name), placement: .left,
                intent: .physical)?.value
            let only = try XCTUnwrap(split.anyLeafWindowRecursive)
            try applyWorkspaceSidebarPinnedTabDrop(b, .split(split.name, placement: .left, projectId: b.projectId,
                source: .init(try window(2)), target: .init(only)))
            try applyWorkspaceSidebarPinnedTabDrop(split, .join("d", placement: .left, operation: .lend(.init(only))))
            XCTAssertEqual(ids(split).count, 1, split.name)
            XCTAssertEqual(ids(d), [4], split.name)
            XCTAssertEqual(ids(b), [2], split.name)
        }

        // Recorded once: a one-window pin given a second window by its app later isn't made one.
        _ = TestWindow.new(id: 10, parent: b.rootTilingContainer)
        refreshModel()
        XCTAssertNil(appearance("b")?.composition)
        XCTAssertEqual(workspaceSidebarPinSplitRole(b), .refuses, "Two windows it wasn't pinned with: no splits, no pinned split")
        try window(10).unbindFromParent()
        XCTAssertEqual(workspaceSidebarPinSplitRole(b), .single(try window(2)))
    }

    /// A pinned split reopened takes in the windows reopened in it. Moved away from it, they keep it
    /// from opening its saved apps again: a click brings back what it can and opens nothing.
    func testAReopenedPinnedSplitKeepsItsNewWindowsAndOpensNothingWhileTheyreOpen() async throws {
        let (_, _, d, _) = try tabs()
        let s = tab("s", 7, 8)
        try setWorkspaceSidebarTabFavorite(s, true)
        XCTAssertEqual(appearance("s")?.composition?.layout.windows.map(\.windowId), [7, 8])
        // Both closed, as WinMux forgets a closed window.
        for id: UInt32 in [7, 8] {
            try window(id).unbindFromParent()
            forgetWorkspaceSidebarPinWindows { $0.windowId == id }
        }
        XCTAssertEqual(appearance("s")?.composition?.layout, .empty)
        // Reopened: new windows come back into it, as saved routing restores them.
        for id: UInt32 in [17, 18] { _ = TestWindow.new(id: id, parent: s.rootTilingContainer) }
        refreshModel()
        XCTAssertEqual(appearance("s")?.composition?.layout.windows.map(\.windowId), [17, 18], "Its own now")

        for id: UInt32 in [17, 18] {
            _ = try window(id).focusWindow()
            try await assertMove(to: "d")
        }
        XCTAssertEqual(ids(s), [])
        XCTAssertEqual(ids(d), [4, 17, 18])
        XCTAssertTrue(workspaceSidebarPinRecallsWindows(s), "Its windows are open")
        await updateWorkspaceSidebarModel()
        let tile = try XCTUnwrap(TrayMenuModel.shared.workspaceSidebarWorkspaces.first { $0.name == "s" })
        XCTAssertTrue(tile.recallsWindows, "Its tile's click recalls, instead of opening its saved apps")

        let windowCount = allWindowCount()
        recallPinWindowsFromSidebar("s", focusing: nil, targetMonitorScopeId: nil)
        try await waitUntil { !self.notices.isEmpty }
        XCTAssertEqual(allWindowCount(), windowCount, "No new window")
        XCTAssertEqual(ids(d), [4, 17, 18], "None taken from another tab")
        XCTAssertTrue(notices[0].contains("open elsewhere"), notices[0])
    }

    // MARK: Review V2 C: a closed window leaves no link behind

    /// A pinned split's last window closed, or all of them dropped as WinMux starts, it keeps no link to
    /// them: a later window given the same number by the same process isn't taken for one of its own.
    func testAPinnedSplitForgetsItsLastWindowAndDoesntTakeANewOneForIt() async throws {
        let launch = Date(timeIntervalSince1970: 2_000_000)
        let notes = TestApp(pid: 501, bundleId: "com.example.notes", launchDate: launch)
        let s = Workspace.get(byName: "s"), d = tab("d", 4)
        for id: UInt32 in [30, 31] { _ = TestWindow.new(id: id, parent: s.rootTilingContainer, app: notes) }
        try setWorkspaceSidebarTabFavorite(s, true)
        for id: UInt32 in [30, 31] {
            try window(id).unbindFromParent()
            forgetWorkspaceSidebarPinWindows { $0.windowId == id && $0.pid == 501 }
        }
        XCTAssertEqual(appearance("s")?.composition?.layout, .empty, "Its last window goes, not back into it")
        XCTAssertEqual(workspaceSidebarPinSplitRole(s), .composition)

        // The same process gives a later window the number 30, in another tab.
        let later = TestWindow.new(id: 30, parent: d.rootTilingContainer, app: notes)
        XCTAssertFalse(workspaceSidebarPinRecallsWindows(s), "Not one of its own")
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(s), .nothing)
        XCTAssertTrue(later.nodeWorkspace === d)

        // All of a pinned split's windows dropped as WinMux starts, the same.
        try workspaceSidebarOrganizationStore.update { state in
            state.workspaces["s"]?.composition = .init(layout: .split(.h, weight: 1, children: [
                .window(.init(windowId: 40, pid: 502, bundleId: "com.example.mail", processLaunch: launch, boot: nil), weight: 1),
                .window(.init(windowId: 41, pid: 502, bundleId: "com.example.mail", processLaunch: launch, boot: nil), weight: 1),
            ]))
        }
        forgetWorkspaceSidebarPinWindowsNoLongerOpen()
        XCTAssertEqual(appearance("s")?.composition?.layout, .empty)
    }

    // MARK: Review V2 D: a drop released on an ordinary tab is made only into an ordinary tab

    func testADropReleasedOnAnOrdinaryTabIsntMadeOnceThatTabIsPinned() async throws {
        let (_, _, d, _) = try tabs()
        let o = tab("o", 3)
        let target = WorkspaceSidebarDropTarget(kind: .workspace("o"), rect: Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 36),
            acceptsSides: true)
        let intent = try XCTUnwrap(WorkspaceSidebarDropIntent.captured(for: target))
        XCTAssertEqual(intent.targetPinRole, .ordinary)
        let session = queueWorkspaceSidebarDrop(4, subject: .window, target: .workspace("o"), placement: .left, intent: intent)
        // Released: before its session runs, o is pinned, with its one window.
        try setWorkspaceSidebarTabFavorite(o, true)
        await session?.value
        XCTAssertEqual(ids(o), [3], "Nothing moved")
        XCTAssertEqual(ids(d), [4])
        XCTAssertNil(workspaceSidebarLentWindow(of: o))
    }

    // MARK: Review V2 P3: a display's tab in the sidebar's display selector takes a window by the same rule

    func testTheDisplaySelectorOffersAWindowOnlyWhereThePinsRuleTakesIt() throws {
        let (a, _, d, e) = try tabs()
        try setWorkspaceSidebarTabFavorite(e, true)
        let monitor = e.workspaceMonitor
        let target = WorkspaceSidebarDropTarget(kind: .monitor(workspaceSidebarMonitorScopeId(for: monitor)),
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 80, height: 24))
        let four = try window(4)
        func offered(showing workspace: Workspace) -> Bool {
            XCTAssertTrue(monitor.setActiveWorkspace(workspace))
            return sidebarWorkspaceDropDestination(sourceWindow: four, target: target, mouseLocation: .zero, subject: .window) != nil
        }
        XCTAssertFalse(offered(showing: e), "A pinned split on the display takes no window: nothing offered")
        XCTAssertTrue(offered(showing: a), "A one-window pin splits in an ordinary tab: offered")
        let other = tab("o", 9)
        XCTAssertTrue(offered(showing: other))
        XCTAssertTrue(four.nodeWorkspace === d)
    }

    // MARK: Review V3 1: a window taken in while one is away leaves that one its place

    /// A|B pinned, A taken back by its own pin, C opened beside B: C is taken in beside B, and A, clicked
    /// back, takes its own place again, first. Laid out on a real display with the default gaps, every
    /// window has room.
    func testAWindowTakenInWhileOneIsAwayLeavesItsPlaceAndRoom() async throws {
        setMonitorsForTests([display(width: 1200)])
        Workspace.reconcileWorkspaceState()
        let (a, _, d, _) = try tabs()
        let one = try window(1)
        try splitPinnedTabWindowWithTab(a, "d", placement: .left)
        XCTAssertEqual(ids(d), [1, 4])
        try await layOut(d)
        try setWorkspaceSidebarTabFavorite(d, true)
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(a), .returned(one))
        try await layOut(d)
        _ = TestWindow.new(id: 9, parent: d.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await layOut(d)
        refreshModel()
        XCTAssertEqual(appearance("d")?.composition?.layout.windows.map(\.windowId), [1, 4, 9], "A keeps its place, first")

        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(d), .recalled([one], elsewhere: []))
        XCTAssertEqual(ids(d), [1, 4, 9])
        try await layOut(d)
        try assertRoom(d, atLeast: 250)
    }

    /// The same nested: A | (B over D), A away, C opened under D. C goes into the column, under D, and A,
    /// back, is beside the column again, which has room for all three.
    func testAWindowTakenInWhileOneIsAwayKeepsANestedSplitNested() async throws {
        setMonitorsForTests([display(width: 1200)])
        Workspace.reconcileWorkspaceState()
        let s = Workspace.get(byName: "s")
        _ = TestWindow.new(id: 1, parent: s.rootTilingContainer)
        let column = TilingContainer(parent: s.rootTilingContainer, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST)
        _ = TestWindow.new(id: 2, parent: column)
        _ = TestWindow.new(id: 4, parent: column)
        let a = Workspace.get(byName: "a")
        try setWorkspaceSidebarTabsFavorite([a], true)
        try workspaceSidebarOrganizationStore.update { $0.workspaces["a"]?.lentWindow = .init(try! XCTUnwrap(Window.get(byId: 1))) }
        try await layOut(s)
        try setWorkspaceSidebarTabFavorite(s, true)
        let one = try window(1)
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(a), .returned(one))
        refreshModel()
        try await layOut(s)
        let parent = try XCTUnwrap(try window(4).parent as? TilingContainer)
        _ = TestWindow.new(id: 9, parent: parent, adaptiveWeight: WEIGHT_AUTO)
        try await layOut(s)
        refreshModel()
        guard case .split(.h, _, let top)? = appearance("s")?.composition?.layout, top.count == 2,
              case .split(.v, _, let stacked) = top[1] else {
            return XCTFail("\(String(describing: appearance("s")?.composition?.layout))")
        }
        XCTAssertEqual(top[0].windows.map(\.windowId), [1], "A keeps its place")
        XCTAssertEqual(stacked.map { $0.windows.map(\.windowId) }, [[2], [4], [9]], "C under D, in the column")

        _ = try recallWorkspaceSidebarPinWindows(s)
        let root = s.rootTilingContainer
        XCTAssertEqual(root.orientation, .h)
        XCTAssertEqual((root.children.first as? AppBundle.Window)?.windowId, 1)
        let rebuilt = try XCTUnwrap(root.children.last as? TilingContainer)
        XCTAssertEqual(rebuilt.orientation, .v)
        XCTAssertEqual(rebuilt.children.map { ($0 as? AppBundle.Window)?.windowId }, [2, 4, 9])
        try await layOut(s)
        try assertRoom(s, atLeast: 150)
    }

    // MARK: Review V3 2: a record a change needs is saved first, or the change isn't made

    /// A pinned split reopened, its new windows not taken in yet, and the organization file can't be
    /// written: an agent moving one of them out, by a move or a layout, is refused, says why, and moves
    /// nothing, so the pinned split never loses track of them. A move that needs no record still works.
    func testAnAgentMoveThatNeedsAPinnedSplitSavedFirstIsRefusedWhenItCantBe() async throws {
        let (_, _, d, e) = try tabs()
        let s = tab("s", 7, 8)
        try setWorkspaceSidebarTabFavorite(s, true)
        for id: UInt32 in [7, 8] {
            try window(id).unbindFromParent()
            forgetWorkspaceSidebarPinWindows { $0.windowId == id }
        }
        for id: UInt32 in [17, 18] { _ = TestWindow.new(id: id, parent: s.rootTilingContainer) }
        let saved = workspaceSidebarOrganizationStore.state
        workspaceSidebarOrganizationStore = .init(state: saved, url: unwritableOrganizationFile)

        let move = try await agentApply(#"{"operations": [{"type": "moveWindowToWorkspace", "windowId": 17, "workspace": "d"}]}"#)
        XCTAssertEqual(move.exitCode, 1)
        XCTAssertTrue(move.stderr.joined().contains("moveWindowToWorkspace window 17: Couldn't save the pinned split 's'"),
            "\(move.stderr)")
        for asOperation in [true, false] {
            let layout = try await applyAgentLayout("n", [18], asOperation: asOperation)
            XCTAssertEqual(layout.exitCode, 1, "\(asOperation)")
            XCTAssertTrue(layout.stderr.joined().contains("Couldn't save the pinned split 's'"), "\(layout.stderr)")
        }
        _ = try window(17).focusWindow()
        try await assertMove(to: "d", refused: true)
        XCTAssertEqual(ids(s), [17, 18], "Nothing moved")
        XCTAssertEqual(ids(d), [4])
        XCTAssertEqual(workspaceSidebarOrganizationStore.state, saved)

        // A move no pinned split depends on isn't held up.
        let ordinary = try await agentApply(#"{"operations": [{"type": "moveWindowToWorkspace", "windowId": 5, "workspace": "d"}]}"#)
        XCTAssertEqual(ordinary.exitCode, 0, "\(ordinary.stderr)")
        XCTAssertEqual(ids(d), [4, 5])
        XCTAssertEqual(ids(e), [6])

        // Once it can be saved, the moves are made, and the pinned split still knows its windows.
        workspaceSidebarOrganizationStore = .init(state: workspaceSidebarOrganizationStore.state)
        for id: UInt32 in [17, 18] {
            let result = try await agentApply(#"{"operations": [{"type": "moveWindowToWorkspace", "windowId": \#(id), "workspace": "d"}]}"#)
            XCTAssertEqual(result.exitCode, 0, "\(result.stderr)")
        }
        XCTAssertEqual(ids(s), [])
        XCTAssertEqual(appearance("s")?.composition?.layout.windows.map(\.windowId), [17, 18])
        XCTAssertTrue(workspaceSidebarPinRecallsWindows(s), "Its windows are open elsewhere: its saved apps don't open")
    }

    /// A split pinned before pinned splits were recorded, and the file can't be written: moving one of its
    /// windows out, which needs it recorded first, is refused, and it stays a pinned split.
    func testALegacyPinnedSplitThatCantBeRecordedKeepsItsWindows() async throws {
        let (_, _, d, _) = try tabs()
        let s = tab("s", 7, 8)
        try workspaceSidebarOrganizationStore.update { state in
            state.pinnedSplitsRecorded = nil
            state.workspaces["s"] = .init(isFavorite: true)
        }
        workspaceSidebarOrganizationStore = .init(state: workspaceSidebarOrganizationStore.state, url: unwritableOrganizationFile)
        let move = try await agentApply(#"{"operations": [{"type": "moveWindowToWorkspace", "windowId": 7, "workspace": "d"}]}"#)
        XCTAssertEqual(move.exitCode, 1)
        XCTAssertTrue(move.stderr.joined().contains("Couldn't save the pinned split 's'"), "\(move.stderr)")
        XCTAssertEqual(ids(s), [7, 8])
        XCTAssertEqual(ids(d), [4])

        workspaceSidebarOrganizationStore = .init(state: workspaceSidebarOrganizationStore.state)
        let retried = try await agentApply(#"{"operations": [{"type": "moveWindowToWorkspace", "windowId": 7, "workspace": "d"}]}"#)
        XCTAssertEqual(retried.exitCode, 0, "\(retried.stderr)")
        XCTAssertEqual(ids(s), [8])
        XCTAssertEqual(workspaceSidebarPinSplitRole(s), .composition, "Recorded before it lost the window")
    }

    // MARK: Helpers

    /// Pins a and b, with windows 1 and 2; ordinary tabs d, with window 4, and e, a split of 5 and 6.
    private func tabs() throws -> (a: Workspace, b: Workspace, d: Workspace, e: Workspace) {
        let a = tab("a", 1), b = tab("b", 2), d = tab("d", 4), e = tab("e", 5, 6)
        try setWorkspaceSidebarTabsFavorite([a, b], true)
        return (a, b, d, e)
    }

    private func setUp_sync() throws {
        setUpWorkspacesForTests()
        workspaceSidebarOrganizationStore = .init()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
    }

    /// Empty pin z; ordinary tab g, with windows 7 and 8 in a group and 9 beside it.
    private func emptyPinAndGroup() throws -> (z: Workspace, g: Workspace, group: TilingContainer) {
        let z = Workspace.get(byName: "z")
        try setWorkspaceSidebarTabFavorite(z, true)
        let g = Workspace.get(byName: "g")
        let group = TilingContainer(parent: g.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, .v, .tabGroup, index: INDEX_BIND_LAST)
        _ = TestWindow.new(id: 7, parent: group)
        _ = TestWindow.new(id: 8, parent: group)
        _ = TestWindow.new(id: 9, parent: g.rootTilingContainer)
        XCTAssertTrue(try window(7).moveNode === group)
        return (z, g, group)
    }

    /// Pins a, b and c, with windows 1, 2 and 3, lent to the ordinary tab s, which `build` lays out with
    /// them and window 4; then s pinned from its menu. Ordinary tab d holds window 7.
    private func pinnedSplit(_ build: (TilingContainer) -> Void) throws -> Workspace {
        let s = Workspace.get(byName: "s")
        build(s.rootTilingContainer)
        let d = tab("d", 7)
        XCTAssertFalse(workspaceSidebarIsPinned(d))
        try setWorkspaceSidebarTabsFavorite(["a", "b", "c"].map { Workspace.get(byName: $0) }, true)
        try workspaceSidebarOrganizationStore.update { state in
            for (name, id) in [("a", 1), ("b", 2), ("c", 3)] as [(String, UInt32)] {
                state.workspaces[name]?.lentWindow = Window.get(byId: id).map(WorkspaceSidebarPinWindow.init)
            }
        }
        try setWorkspaceSidebarTabFavorite(s, true)
        XCTAssertNotNil(appearance("s")?.composition)
        return s
    }

    private func tab(_ name: String, _ windowIds: UInt32...) -> Workspace {
        let tab = Workspace.get(byName: name)
        for id in windowIds { _ = TestWindow.new(id: id, parent: tab.rootTilingContainer) }
        return tab
    }

    private func window(_ id: UInt32) throws -> AppBundle.Window { try XCTUnwrap(Window.get(byId: id), "window \(id)") }

    private func appearance(_ name: String) -> WorkspaceSidebarItemAppearance? {
        workspaceSidebarOrganizationStore.state.workspaces[name]
    }

    /// An organization file that can't be written, its folder being a device: as a write failing.
    private var unwritableOrganizationFile: URL { URL(fileURLWithPath: "/dev/null/winmux-pin-split-test/sidebar-organization.json") }

    private func display(width: CGFloat) -> Monitor {
        WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Main",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: width, height: 800),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: width, height: 800), isMain: true)
    }

    /// `tab` on its display, laid out there.
    private func layOut(_ tab: Workspace) async throws {
        XCTAssertTrue(tab.workspaceMonitor.setActiveWorkspace(tab))
        try await tab.layoutWorkspace()
    }

    /// Every window of `tab` laid out with room: wider and taller than `length` points.
    private func assertRoom(_ tab: Workspace, atLeast length: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        for window in tab.allLeafWindowsRecursive {
            let rect = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect, "\(window.windowId)", file: file, line: line)
            XCTAssertGreaterThan(rect.width, length, "\(window.windowId): \(rect)", file: file, line: line)
            XCTAssertGreaterThan(rect.height, length, "\(window.windowId): \(rect)", file: file, line: line)
        }
    }

    private func agentApply(_ edit: String) async throws -> CmdResult {
        try await parseCommand("agent apply --stdin").cmdOrDie.run(.defaultEnv,
            CmdStdin(try freshAgentJson(#"{"schemaVersion": 1, "edit": \#(edit)}"#)))
    }

    private func agentLayoutJson(_ name: String, _ windowIds: [UInt32]) -> String {
        let children = windowIds.map { #"{"kind": "window", "windowId": \#($0)}"# }.joined(separator: ", ")
        return #"{"name": "\#(name)", "layout": {"kind": "split", "direction": "horizontal", "children": [\#(children)]}}"#
    }

    /// `name` laid out with `windowIds` side by side, by `setWorkspaceLayout` or by the edit's layout.
    private func applyAgentLayout(_ name: String, _ windowIds: [UInt32], asOperation: Bool) async throws -> CmdResult {
        let layout = agentLayoutJson(name, windowIds)
        return try await agentApply(asOperation
            ? #"{"operations": [{"type": "setWorkspaceLayout", "layout": \#(layout)}]}"#
            : #"{"layout": {"workspaces": [\#(layout)]}}"#)
    }

    private func move(to name: String) async throws -> CmdResult {
        try await MoveNodeToWorkspaceCommand(args: .init(workspace: name)).run(.defaultEnv, .emptyStdin)
    }

    private func assertMove(to name: String, refused: Bool = false, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await move(to: name)
        XCTAssertEqual(result.exitCode != 0, refused, "\(result.stderr)", file: file, line: line)
    }

    /// A window drag released on screen with `kind` shown, as the drag's own release makes it.
    private func dropOnScreen(_ windowId: UInt32, subject: WindowDragSubject = .window, _ kind: WindowDragIntentKind,
                              style: WindowTabDropPreviewStyle = .workspaceMove) -> Bool {
        let everywhere = Rect(topLeftX: -10_000, topLeftY: -10_000, width: 20_000, height: 20_000)
        MousePointerTracker.shared.note(point: CGPoint(x: 10, y: 10))
        _ = setPendingWindowDragIntent(sourceWindowId: windowId, sourceSubject: subject, detachOrigin: .window,
            destination: WindowDragIntentDestination(kind: kind, previewRect: everywhere, interactionRect: everywhere,
                title: "", subtitle: "", previewStyle: style, previewGeometry: .rounded, isGroup: subject == .group))
        return applyPendingWindowDragIntentIfPossible()
    }

    /// Minimized as macOS does it: out of its tab, into the minimized windows.
    private func minimize(_ window: TestWindow) {
        window.rememberMacOsLayoutOrigin(detachFromWorkspace: true)
        window.nativeIsMacosMinimized = true
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }

    private func pins() -> [String] { workspacePinnedTabs(in: workspaceProjectDefaultId).map(\.name) }

    private func occurrences(of windowId: UInt32) -> Int {
        Workspace.all.flatMap(\.allLeafWindowsRecursive).filter { $0.windowId == windowId }.count
    }

    private func allWindowCount() -> Int {
        Workspace.all.flatMap(\.allLeafWindowsRecursive).count + macosMinimizedWindowsContainer.children.count
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private func ids(_ workspace: Workspace) -> [UInt32] { workspace.allLeafWindowsRecursive.map(\.windowId) }
