@testable import AppBundle
import AppKit
import Common
import XCTest

/// Tabs mode: Mail's message and compose windows, and dialogs, float in the tab of the window the
/// context points to, listed under it. The context is an inference, not proof of what opened them.
@MainActor
final class AuxiliaryWindowsTest: XCTestCase {
    private let mail = TestApp(pid: 41, bundleId: "com.apple.mail", name: "Mail")
    private var defaultAppIsFrontmost: (@MainActor (Window) -> Bool)?
    private var savedConfirm: (@MainActor (String, String) -> Bool)!
    private var savedNotice: (@MainActor (String, String) -> Void)!
    private var savedCloseIO: (@MainActor (Window) -> WindowCloseIO?)!
    private var asked: [(message: String, informative: String)] = []
    private var notices: [String] = []

    override func setUp() async throws {
        defaultAppIsFrontmost = newWindowAppIsFrontmost
        savedConfirm = workspaceTabCloseConfirm
        savedNotice = workspaceSidebarPinRecallNotice
        savedCloseIO = workspaceTabCloseIO
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        AuxiliaryWindowRegistry.shared.removeAll()
        newWindowAppIsFrontmost = { _ in true }
        workspaceTabCloseConfirm = { _, _ in XCTFail("Nothing should ask"); return false }
        workspaceSidebarPinRecallNotice = { [unowned self] title, body in notices.append("\(title): \(body)") }
    }

    override func tearDown() async throws {
        if let defaultAppIsFrontmost { newWindowAppIsFrontmost = defaultAppIsFrontmost }
        workspaceTabCloseConfirm = savedConfirm
        workspaceSidebarPinRecallNotice = savedNotice
        workspaceTabCloseIO = savedCloseIO
        AuxiliaryWindowRegistry.shared.removeAll()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    // MARK: - Recognizing Mail's windows

    func testCapturedMailWindowsAreToldApartByTheirOwnFields() throws {
        let url = projectRoot.appending(path: "test-fixtures/accessibility/mail-16.0-auxiliary-windows.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func window(_ key: String) throws -> CapturedAxElement { try CapturedAxElement(XCTUnwrap(fixture[key] as? [String: Any])) }

        XCTAssertNil(try window("mainViewer").mailAuxiliaryWindowRole(), "The main viewer stays a regular window")
        XCTAssertEqual(try window("messageWindow").mailAuxiliaryWindowRole(), .mailMessage)
        XCTAssertEqual(try window("newMessage").mailAuxiliaryWindowRole(), .mailCompose)
        XCTAssertEqual(try window("reply").mailAuxiliaryWindowRole(), .mailCompose)

        // What alone proves nothing: the viewer's prefix, `_NS:41`, or a window not built yet.
        let prefixOnly = try window("messageWindow")
        prefixOnly.children = [CapturedAxElement(["AXRole": "AXToolbar"])]
        XCTAssertNil(prefixOnly.mailAuxiliaryWindowRole(), "A viewer's identifier without the message as its own child")
        let bareCompose = try window("newMessage")
        bareCompose.children = []
        XCTAssertNil(bareCompose.mailAuxiliaryWindowRole(), "_NS:41 without its fields")
        let toOnly = try window("newMessage")
        toOnly.children = toOnly.children.filter { $0.identifier != "Mail.subjectField" }
        XCTAssertNil(toOnly.mailAuxiliaryWindowRole(), "Both the To and Subject fields")
        let dialog = try window("newMessage")
        dialog.subrole = kAXDialogSubrole
        XCTAssertNil(dialog.mailAuxiliaryWindowRole(), "Only standard windows")
    }

    // MARK: - The window server's order

    func testTheCollectorFindsTheNewWindowItselfAndTheOneRightBelowIt() {
        let (c, v, v2, sheet, other) = (UInt32(11), UInt32(10), UInt32(12), UInt32(90), UInt32(70))
        func stacking(_ windows: [AuxiliaryOrderedWindow]) -> AuxiliaryWindowStacking {
            auxiliaryWindowStacking(windows, newWindowId: c, pid: 41, isRegistered: { [v, v2].contains($0) })
        }
        func mail(_ id: UInt32, layer: Int = 0) -> AuxiliaryOrderedWindow { .init(id: id, pid: 41, layer: layer) }
        let safari = AuxiliaryOrderedWindow(id: other, pid: 42, layer: 0)
        XCTAssertEqual(stacking([mail(c), mail(v)]), .front(below: v), "In front, the viewer right below")
        XCTAssertEqual(stacking([safari, mail(500, layer: 25), mail(c), safari, mail(sheet), mail(v)]), .front(below: v),
            "Other apps' windows, the app's menus above the normal level, and a sheet it doesn't know are passed over")
        XCTAssertEqual(stacking([mail(v), mail(c)]), .notFront, "Made behind the viewer")
        XCTAssertEqual(stacking([mail(sheet), mail(c), mail(v)]), .notFront, "Anything of the app above it")
        XCTAssertEqual(stacking([mail(v)]), .absent, "Not on screen yet")
        XCTAssertEqual(stacking([]), .absent)
        XCTAssertEqual(stacking([mail(c), mail(v2), mail(v)]), .front(below: v2), "Another viewer between them")
        XCTAssertEqual(stacking([mail(c)]), .front(below: nil))
    }

    func testTheWindowServersListIsReadInItsOwnOrder() {
        let infos: [[String: Any]] = [
            [kCGWindowNumber as String: NSNumber(value: 11), kCGWindowOwnerPID as String: NSNumber(value: 41),
             kCGWindowLayer as String: NSNumber(value: 0)],
            [kCGWindowNumber as String: NSNumber(value: 5), kCGWindowOwnerPID as String: NSNumber(value: 41),
             kCGWindowLayer as String: NSNumber(value: 25)],
            [kCGWindowOwnerPID as String: NSNumber(value: 41)],
            [kCGWindowNumber as String: NSNumber(value: 10), kCGWindowOwnerPID as String: NSNumber(value: 41)],
        ]
        XCTAssertEqual(auxiliaryOrderedWindows(infos), [.init(id: 11, pid: 41, layer: 0), .init(id: 5, pid: 41, layer: 25),
            .init(id: 10, pid: 41, layer: 0)])
    }

    // MARK: - Where a new window came from

    func testAMailWindowOpenedFromTheViewerInUseFloatsInItsTabInsteadOfANewTab() async throws {
        let (tab, viewer) = viewerTab()
        let tabsBefore = order()
        let compose = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message")

        XCTAssertTrue(compose.nodeWorkspace === tab, "In the viewer's tab")
        XCTAssertTrue(compose.isFloating, "Floating at its own size, not a tiled pane")
        XCTAssertEqual(tab.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [10])
        XCTAssertEqual(order(), tabsBefore, "No new tab")
        XCTAssertTrue(auxiliaryWindowParent(of: compose) === viewer)
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: compose), .mailCompose)

        // The same window when its origin isn't shown goes where any new window goes: its own tab.
        let independent = TestWindow.new(id: 12, parent: tab.rootTilingContainer, app: mail, title: "New Message")
        _ = try await restoreOrDetectNewWindow(independent, isRegularWindow: true)
        XCTAssertFalse(independent.nodeWorkspace === tab, "A regular new window still gets a tab of its own")
        XCTAssertNil(auxiliaryWindowParent(of: independent))
    }

    /// The evidence as registration reads it on first sight, then decided after the role is read.
    private func decide(_ newWindowId: UInt32 = 11, order windowOrder: [UInt32]?, input: TimeInterval?, active: Bool = true,
                        observedAt: TimeInterval? = nil, type: AxUiElementWindowType = .window,
                        role: @escaping () async -> AuxiliaryWindowRole? = { .mailCompose }) async -> (AuxiliaryWindowPlacement?, asked: Int) {
        let since = auxiliaryFocusSpan.since
        let evidence = captureAuxiliaryWindowOriginEvidence(newWindowId: newWindowId, pid: mail.pid, observedAt: observedAt ?? since + 0.2,
            environment: auxiliaryTestEnvironment(order: windowOrder, pid: mail.pid, input: input, active: active))
        var asked = 0
        let placement = await auxiliaryWindowPlacement(evidence, type: type, role: { asked += 1; return await role() })
        return (placement, asked)
    }

    func testOnlyAWindowWhoseContextPointsToTheFocusedViewerIsPlacedUnderIt() async throws {
        let (tab, viewer) = viewerTab()
        let since = auxiliaryFocusSpan.since
        noteAppActivatedForAuxiliaryWindows(pid: mail.pid, at: since - 1)
        let now = since + 0.1

        var result = await decide(order: [11, 10], input: now)
        XCTAssertTrue(result.0?.parent === viewer, "In front of every Mail window, the focused viewer right below it")
        XCTAssertEqual(result.asked, 1)
        result = await decide(order: [11, 10], input: now, type: .dialog)
        XCTAssertEqual(result.0?.role, .dialog, "A dialog, without asking Mail")
        XCTAssertEqual(result.asked, 0)

        let viewer2 = TestWindow.new(id: 12, parent: Workspace.get(byName: "other").rootTilingContainer, app: mail)
        let cases: [(String, [UInt32]?, TimeInterval?, Bool, TimeInterval?)] = [
            ("made behind the viewer, in the background", [10, 11], now, true, nil),
            ("not on screen when first seen", [10], now, true, nil),
            ("the window server gave no list", nil, now, true, nil),
            ("another viewer between them", [11, 12, 10], now, true, nil),
            ("no press since focus came to the viewer", [11, 10], since - 0.05, true, nil),
            ("no press for longer than a person would wait", [11, 10], now, true, now + 6),
            ("no press known", [11, 10], nil, true, nil),
            ("the app isn't active", [11, 10], now, false, nil),
        ]
        for (reason, windowOrder, input, active, observedAt) in cases {
            let result = await decide(order: windowOrder, input: input, active: active, observedAt: observedAt)
            XCTAssertNil(result.0, reason)
            XCTAssertEqual(result.asked, 0, "Mail isn't even asked when \(reason)")
        }

        // The app became active after the last press: a link in another app opened the window.
        noteAppActivatedForAuxiliaryWindows(pid: mail.pid, at: now + 0.05)
        var placement = await decide(order: [11, 10], input: now).0
        XCTAssertNil(placement, "The app came forward after the press")
        noteAppActivatedForAuxiliaryWindows(pid: 42, at: since - 1)
        placement = await decide(order: [11, 10], input: now).0
        XCTAssertNil(placement, "Another app was made active last")
        noteAppActivatedForAuxiliaryWindows(pid: mail.pid, at: since - 1)

        // Only in Tabs mode, never at startup.
        config.workspaceSidebar.mode = .sidebar
        placement = await decide(order: [11, 10], input: now).0
        XCTAssertNil(placement)
        config.workspaceSidebar.mode = .tabs
        placement = await $_isStartup.withValue(true) { await decide(order: [11, 10], input: now).0 }
        XCTAssertNil(placement)
        // A role Mail doesn't have: a second viewer is a window of its own.
        placement = await decide(order: [11, 10], input: now, role: { nil }).0
        XCTAssertNil(placement)
        // Focus on another of the app's windows elsewhere, or on another app's: nothing ties it here.
        XCTAssertTrue(viewer2.focusWindow())
        placement = await decide(order: [11, 10], input: auxiliaryFocusSpan.since + 0.1).0
        XCTAssertNil(placement, "The focused viewer isn't the one right below it")
        let safari = TestWindow.new(id: 21, parent: Workspace.get(byName: "web").rootTilingContainer,
            app: TestApp(pid: 42, bundleId: "com.apple.Safari", name: "Safari"))
        XCTAssertTrue(safari.focusWindow())
        XCTAssertNil(captureAuxiliaryWindowOriginEvidence(newWindowId: 11, pid: mail.pid, observedAt: auxiliaryFocusSpan.since + 0.2,
            environment: auxiliaryTestEnvironment(order: [11, 10], pid: mail.pid, input: auxiliaryFocusSpan.since + 0.1)),
            "Focus on another app's window")
        XCTAssertTrue(tab === viewer.nodeWorkspace)
    }

    func testFocusMovingWhileMailIsAskedLeavesTheWindowItsOwn() async throws {
        let (tab, viewer) = viewerTab()
        let since = auxiliaryFocusSpan.since
        noteAppActivatedForAuxiliaryWindows(pid: mail.pid, at: since - 1)
        let viewer2 = TestWindow.new(id: 12, parent: tab.rootTilingContainer, app: mail)
        var result = await decide(order: [11, 10, 12], input: since + 0.1, role: {
            XCTAssertTrue(viewer2.focusWindow())
            return .mailCompose
        })
        XCTAssertNil(result.0, "Another viewer focused during the accessibility read")
        XCTAssertTrue(viewer.focusWindow())
        let resumed = auxiliaryFocusSpan.since
        result = await decide(order: [11, 10, 12], input: resumed + 0.1, role: {
            viewer.bind(to: Workspace.get(byName: "other").rootTilingContainer, adaptiveWeight: 1, index: 0)
            return .mailCompose
        })
        XCTAssertNil(result.0, "The viewer moved to another tab during it")
    }

    func testSwitchingBetweenViewersCountsOnlyAPressAfterTheSwitch() async throws {
        let (tab, first) = viewerTab()
        noteAppActivatedForAuxiliaryWindows(pid: mail.pid, at: auxiliaryFocusSpan.since - 10)
        let second = TestWindow.new(id: 12, parent: tab.rootTilingContainer, app: mail)
        let firstSince = auxiliaryFocusSpan.since
        XCTAssertTrue(second.focusWindow())
        XCTAssertGreaterThan(auxiliaryFocusSpan.serial, 1)
        let switched = auxiliaryFocusSpan.since
        XCTAssertGreaterThanOrEqual(switched, firstSince)
        let beforeSwitch = await decide(order: [11, 12, 10], input: switched - 0.01).0
        XCTAssertNil(beforeSwitch, "The last press was the click that switched viewers: nothing tied the window to either")
        let result = await decide(order: [11, 12, 10], input: switched + 0.1)
        XCTAssertTrue(result.0?.parent === second, "A press in the second viewer: opened from it")
        XCTAssertFalse(result.0?.parent === first)
    }

    func testAReplyFromAMessageWindowGoesUnderTheSameViewer() async throws {
        let (tab, viewer) = viewerTab()
        let message = try await openAuxiliaryTestWindow(11, app: mail, role: .mailMessage, from: viewer,
            title: "Synthetic loopback probe message — Inbox")
        let reply = try await openAuxiliaryTestWindow(12, app: mail, from: message, title: "Re: Synthetic loopback probe message")
        XCTAssertTrue(auxiliaryWindowParent(of: reply) === viewer, "One level: listed under the viewer, not the message")
        XCTAssertTrue(reply.nodeWorkspace === tab)
    }

    func testItKeepsMailsSizeAndIsMovedOnlyIntoTheTabsArea() async throws {
        let area = Rect(topLeftX: 300, topLeftY: 40, width: 700, height: 600)
        let inside = Rect(topLeftX: 400, topLeftY: 100, width: 384, height: 400)
        XCTAssertEqual(auxiliaryWindowFrame(inside, in: area), inside, "Already in the tab: left alone")
        XCTAssertEqual(auxiliaryWindowFrame(Rect(topLeftX: 43, topLeftY: 73, width: 384, height: 600), in: area),
            Rect(topLeftX: 300, topLeftY: 40, width: 384, height: 600), "Under the sidebar: moved, its size kept")
        XCTAssertEqual(auxiliaryWindowFrame(Rect(topLeftX: 44, topLeftY: 30, width: 836, height: 678), in: area),
            Rect(topLeftX: 300, topLeftY: 40, width: 700, height: 600), "Larger than the tab: made to fit")

        let (tab, viewer) = viewerTab()
        let tabArea = tab.workspaceMonitor.visibleRectPaddedByOuterGaps
        let small = Rect(topLeftX: tabArea.minX - 200, topLeftY: tabArea.minY, width: 200, height: 150)
        let compose = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message", rect: small)
        let frame = try XCTUnwrap(compose.nativeRect)
        XCTAssertEqual(frame.size, small.size, "Mail's size")
        XCTAssertTrue(frame.minX >= tabArea.minX && frame.maxX <= tabArea.maxX, "Clear of the sidebar")
        XCTAssertEqual(compose.setAxFrameCount, 1)
        let fitting = Rect(topLeftX: tabArea.minX + 10, topLeftY: tabArea.minY + 10, width: 200, height: 150)
        let message = try await openAuxiliaryTestWindow(12, app: mail, role: .mailMessage, from: viewer, title: "Message", rect: fitting)
        XCTAssertEqual(message.setAxFrameCount, 0, "One already in the tab isn't touched")
    }

    // MARK: - While it lives

    func testSwitchingTabsKeepsTheDraftAndItsPlaceUnderTheViewer() async throws {
        let (tab, viewer) = viewerTab()
        let compose = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message")
        XCTAssertTrue(TestWindow.new(id: 30, parent: Workspace.get(byName: "other").rootTilingContainer).focusWindow())
        XCTAssertTrue(compose.isBound && compose.nodeWorkspace === tab, "Away from its tab it stays where it is")
        XCTAssertTrue(viewer.focusWindow())
        XCTAssertTrue(auxiliaryWindowParent(of: compose) === viewer, "Back again, still listed under the viewer")
    }

    func testWhenTheViewerClosesTheDraftStaysOpenAsAWindowOfItsOwn() async throws {
        let (tab, viewer) = viewerTab()
        let compose = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message")
        // What closing does to a registered window (MacWindow.garbageCollect).
        viewer.unbindFromParent()
        AuxiliaryWindowRegistry.shared.forget(windowId: viewer.windowId, pid: mail.pid)

        XCTAssertTrue(compose.nodeWorkspace === tab && compose.isFloating, "Still open, floating where it was: never tiled in")
        XCTAssertNil(auxiliaryWindowParent(of: compose))
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: compose), .mailCompose, "Still a draft: a saved tab won't record it")
        XCTAssertTrue(workspaceTabIsShown(tab), "Its tab is still listed")
    }

    func testMovedToANewTabOnPurposeItIsAWindowOfItsOwnForGood() async throws {
        let (tab, viewer) = viewerTab()
        let compose = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message")
        try detachWorkspaceTabWindow(compose)
        XCTAssertFalse(compose.nodeWorkspace === tab)
        XCTAssertTrue(compose.isFloating, "A floating window stays floating in its new tab")
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: compose), "An ordinary window now")
        compose.bindAsFloatingWindow(to: tab)
        XCTAssertNil(auxiliaryWindowParent(of: compose), "Back in the viewer's tab, it's a window of its own")
        XCTAssertFalse(isEphemeralAuxiliaryWindow(compose), "Saved as any window: the user chose to keep it")
    }

    func testOnlyAWindowFloatingInItsParentsTabIsListedUnderIt() async throws {
        let (tab, viewer) = viewerTab()
        let compose = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message")
        compose.bind(to: tab.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertNil(auxiliaryWindowParent(of: compose), "Tiled by the user: one of the tab's own windows")
        compose.bindAsFloatingWindow(to: tab)
        XCTAssertTrue(auxiliaryWindowParent(of: compose) === viewer)
        viewer.bind(to: Workspace.get(byName: "other").rootTilingContainer, adaptiveWeight: 1, index: 0)
        XCTAssertNil(auxiliaryWindowParent(of: compose), "Its viewer moved on alone: the draft didn't follow it")
        let dialog = TestWindow.new(id: 12, parent: tab, app: mail, title: "Dialog")
        XCTAssertNil(auxiliaryWindowParent(of: dialog), "Floating alone isn't auxiliary")
    }

    func testSavedTabsKeepOutDraftsButKeepDialogsAsBefore() async throws {
        let (tab, viewer) = viewerTab()
        _ = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message")
        let dialog = try await openAuxiliaryTestWindow(12, app: mail, role: .dialog, from: viewer, title: "Settings")
        let floating = TestWindow.new(id: 13, parent: tab, app: mail, title: "Not opened from here")
        let snapshot = snapshotLiveSavedLayout(tab, previous: .init(), titleByWindowId: [:])
        XCTAssertEqual(snapshot.layout.floating.map(\.lastWindowId), [dialog.windowId, floating.windowId],
            "A dialog and an ordinary floating window are saved, as they were before; the draft goes when it's done")
        XCTAssertEqual(snapshot.layout.root.allSlots.map(\.lastWindowId), [viewer.windowId])
    }

    // MARK: - Closing: Empty Tab's safeguards, drafts first and named

    func testClosingTheTabAsksNamingTheDraftAndClosesItFirst() async throws {
        let (tab, viewer) = viewerTab()
        _ = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message")
        workspaceTabCloseConfirm = { [unowned self] in asked.append(($0, $1)); return true }
        var closed: [UInt32] = []
        await closeWorkspaceSidebarTabs([tab.name]) { window in
            closed.append(window.windowId)
            window.closeAxWindow()
            return true
        }?.value
        XCTAssertEqual(asked.map(\.message), ["Close this tab and its 2 windows?"])
        XCTAssertEqual(asked.first?.informative,
            "This includes 1 Mail compose window.\nThis closes the application windows. Each app may ask you to save changes.")
        XCTAssertEqual(closed, [11, 10], "The draft first, then the viewer")

        // As many windows as tabs chosen, one of them a draft: it still asks.
        let other = Workspace.get(byName: "second")
        let otherViewer = TestWindow.new(id: 20, parent: other.rootTilingContainer, app: mail)
        _ = try await openAuxiliaryTestWindow(21, app: mail, from: otherViewer, title: "Reply")
        let empty = Workspace.get(byName: "empty")
        try saveWorkspaceSidebarIdentity(empty)
        asked = []
        await closeWorkspaceSidebarTabs([other.name, empty.name]) { window in window.closeAxWindow(); return true }?.value
        XCTAssertEqual(asked.map(\.message), ["Close 2 tabs and their 2 windows?"], "A draft is never closed without asking")
    }

    func testADraftThatWontCloseStopsTheRestWithTheViewerStillOpen() async throws {
        let (tab, viewer) = viewerTab()
        let compose = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message")
        workspaceTabCloseConfirm = { _, _ in true }
        var pressed: [UInt32] = []
        await closeWorkspaceSidebarTabs([tab.name]) { window in pressed.append(window.windowId); return false }?.value
        XCTAssertEqual(pressed, [11], "Mail asked to save the draft: nothing after it is closed")
        XCTAssertTrue(viewer.isBound && compose.isBound)
        XCTAssertTrue(focus.windowOrNil === compose, "The draft that asked comes forward")
    }

    func testAnUnreadableAnswerAfterTheDraftsPressStopsBeforeItsViewer() async throws {
        let (tab, viewer) = viewerTab()
        let compose = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message")
        workspaceTabCloseConfirm = { _, _ in true }
        var pressed: [UInt32] = []
        var forgot: [UInt32] = []
        workspaceTabCloseIO = { window in
            WindowCloseIO(
                press: { isStillValid in
                    guard isStillValid() else { return .invalidated }
                    pressed.append(window.windowId)
                    return .pressed
                },
                presence: { .unknown }, windowServerHasWindow: { nil }, forget: { forgot.append(window.windowId) },
                timeout: 0.2, pause: {})
        }
        await closeWorkspaceSidebarTabs([tab.name])?.value
        XCTAssertEqual(pressed, [11], "The draft's close couldn't be told: the viewer isn't pressed")
        XCTAssertEqual(forgot, [], "Not forgotten: it may be showing a save sheet")
        XCTAssertTrue(Window.get(byId: 11) === compose && viewer.isBound)
        XCTAssertTrue(notices.last?.contains("couldn't tell") == true, "\(notices)")
    }

    func testAQueuedPressForADraftThatMovedOrChangedMeanwhileDoesntCloseIt() async throws {
        for change in ["moved to another tab", "went full screen"] {
            setUpWorkspacesForTests()
            config.workspaceSidebar.enabled = true
            config.workspaceSidebar.mode = .tabs
            AuxiliaryWindowRegistry.shared.removeAll()
            notices = []
            let (tab, viewer) = viewerTab()
            let compose = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message")
            workspaceTabCloseConfirm = { _, _ in true }
            var gate: CheckedContinuation<Void, Never>?
            var pressed: [UInt32] = []
            workspaceTabCloseIO = { window in
                WindowCloseIO(
                    press: { isStillValid in
                        if window.windowId == 11 { await withCheckedContinuation { gate = $0 } }
                        guard isStillValid() else { return .invalidated }
                        pressed.append(window.windowId)
                        return .pressed
                    },
                    presence: { .absent }, windowServerHasWindow: { false }, forget: {}, timeout: 0.2, pause: {})
            }
            let task = closeWorkspaceSidebarTabs([tab.name])
            for _ in 0 ..< 200 where gate == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNotNil(gate, change)
            if change == "moved to another tab" {
                compose.bindAsFloatingWindow(to: Workspace.get(byName: "elsewhere"))
            } else {
                compose.bind(to: tab.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
            }
            gate?.resume()
            await task?.value
            XCTAssertEqual(pressed, [10], "\(change): the draft isn't pressed; the viewer still closes")
            XCTAssertTrue(compose.isBound, change)
            XCTAssertEqual(notices.last, "Some windows stayed open: A window moved or changed while the tab was closing, so it wasn't closed.",
                change)
        }
    }

    func testWhatClosesIsWhatWasConfirmed() async throws {
        let (tab, viewer) = viewerTab()
        let compose = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message")
        workspaceTabCloseConfirm = { _, _ in false }
        XCTAssertNil(closeWorkspaceSidebarTabs([tab.name]) { _ in XCTFail("Cancel closes nothing"); return true })
        XCTAssertNil(closeWorkspaceSidebarTabWindows(tab.name))
        XCTAssertTrue(viewer.isBound && compose.isBound)

        var arrived: TestWindow?
        workspaceTabCloseConfirm = { [mail] _, _ in
            // While the question is up: another window arrives, and the draft is moved to another tab.
            arrived = TestWindow.new(id: 13, parent: tab, app: mail, title: "Arrived")
            compose.bindAsFloatingWindow(to: Workspace.get(byName: "other"))
            return true
        }
        var closed: [UInt32] = []
        await closeWorkspaceSidebarTabs([tab.name]) { window in
            closed.append(window.windowId)
            window.closeAxWindow()
            return true
        }?.value
        XCTAssertEqual(closed, [10], "Only what was confirmed and is still the tab's own")
        XCTAssertTrue(compose.isBound, "The draft that left the tab stays open")
        XCTAssertEqual(arrived?.isBound, true, "A window that arrived meanwhile stays open")
    }

    func testAMinimizedDraftIsCountedNamedAndClosedFirst() async throws {
        let (tab, viewer) = viewerTab()
        let compose = try await openAuxiliaryTestWindow(11, app: mail, from: viewer, title: "New Message")
        compose.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        compose.layoutReason = .macos(prevParentKind: .workspace, prevWorkspaceName: tab.name)
        XCTAssertEqual(workspaceTabMembers(tab).map(\.window.windowId), [10, 11], "Still the tab's, minimized")
        workspaceTabCloseConfirm = { [unowned self] in asked.append(($0, $1)); return true }
        var closed: [UInt32] = []
        await closeWorkspaceSidebarTabs([tab.name]) { window in
            closed.append(window.windowId)
            window.closeAxWindow()
            return true
        }?.value
        let text = try XCTUnwrap(asked.first?.informative)
        XCTAssertTrue(text.contains("1 minimized") && text.contains("This includes 1 Mail compose window."), text)
        XCTAssertEqual(closed, [11, 10])
    }

    func testCloseAllWindowsInTheTabNamesTheDraft() async throws {
        let (tab, viewer) = viewerTab()
        _ = try await openAuxiliaryTestWindow(11, app: mail, role: .mailMessage, from: viewer, title: "Message")
        workspaceTabCloseConfirm = { [unowned self] in asked.append(($0, $1)); return true }
        await closeWorkspaceSidebarTabWindows(tab.name)?.value
        XCTAssertEqual(asked.map(\.message), ["Close all 2 windows in this tab?"])
        XCTAssertEqual(asked.first?.informative.hasPrefix("This includes 1 Mail message window."), true)
        XCTAssertTrue(tab.allLeafWindowsRecursive.isEmpty)
    }

    /// Found in the VM: Mail puts a window whose save question was answered back where it was when it
    /// asked. Pressed in the corner a tab out of sight parks it in, the draft stayed there after Cancel.
    func testADraftClosedFromATabOutOfSightAsksOnScreenAndStaysThere() async throws {
        try await withWinMuxEnabled {
            let (_, current) = viewerTab()
            let (away, viewer, draft, trace) = try await parkedMailTabOutOfSight()
            workspaceTabCloseConfirm = { _, _ in true }
            var atPress: [UInt32: (tabShown: Bool, parked: Bool, frame: Rect?)] = [:]
            workspaceTabCloseIO = { window in
                WindowCloseIO(
                    press: { _ in
                        atPress[window.windowId] = (away.isVisible, window.isHiddenInCorner, try? await window.getAxRect())
                        trace.events.append("press:\(window.windowId)")
                        return .pressed
                    },
                    presence: { .present }, windowServerHasWindow: { true }, forget: {}, timeout: 0.05, pause: {})
            }
            await closeWorkspaceSidebarTabWindows(away.name)?.value
            XCTAssertEqual(Array(atPress.keys), [21], "Mail asked to save the draft: the viewer isn't pressed")
            XCTAssertEqual(atPress[21]?.tabShown, true, "Its tab is on screen when Mail asks")
            XCTAssertEqual(atPress[21]?.parked, false)
            XCTAssertTrue(isOnADisplay(atPress[21]?.frame), "The draft is on screen, not in the corner, when it's pressed: \(trace.events)")
            XCTAssertTrue(trace.isMovedThenWaitedFor(21), "Its move made before the press, which cancels one waiting: \(trace.events)")
            XCTAssertTrue(focus.windowOrNil === draft, "The draft that asked comes forward")
            XCTAssertTrue(viewer.isBound && draft.isBound && current.isBound)
        }
    }

    func testATabOutOfSightIsLaidOutWhileItsWindowsCloseThenTheUserIsBackWhereTheyWere() async throws {
        try await withWinMuxEnabled {
            let (here, current) = viewerTab()
            let (away, _, _, trace) = try await parkedMailTabOutOfSight()
            workspaceTabCloseConfirm = { _, _ in true }
            var frames: [UInt32: Rect?] = [:]
            workspaceTabCloseIO = { window in
                WindowCloseIO(
                    press: { _ in
                        frames[window.windowId] = try? await window.getAxRect()
                        trace.events.append("press:\(window.windowId)")
                        return .pressed
                    },
                    presence: { .absent }, windowServerHasWindow: { false }, forget: { _ = window.unbindFromParent() },
                    timeout: 0.05, pause: {})
            }
            await closeWorkspaceSidebarTabWindows(away.name)?.value
            XCTAssertEqual(trace.events.filter { $0.hasPrefix("press:") }, ["press:21", "press:20"], "The draft first, then the viewer")
            XCTAssertTrue(isOnADisplay(frames[20] ?? nil), "The tiled viewer is laid out on screen before its press: \(trace.events)")
            XCTAssertTrue(trace.isMovedThenWaitedFor(20), "\(trace.events)")
            XCTAssertTrue(away.allLeafWindowsRecursive.isEmpty)
            XCTAssertTrue(focus.windowOrNil === current && here.isVisible, "Back to the window in use before")
        }
    }

    func testClosingATabOutOfSightOnAnotherDisplayGivesThatDisplayItsTabBack() async throws {
        let main = SavedWorkspaceTestMonitor(id: 1, name: "Main", x: 0, isMain: true, uuid: nil)
        let secondary = SavedWorkspaceTestMonitor(id: 2, name: "Secondary", x: 1920, uuid: nil)
        setMonitorsForTests([main, secondary])
        defer { setMonitorsForTests(nil) }
        Workspace.reconcileWorkspaceState()
        try await withWinMuxEnabled {
            let current = TestWindow.new(id: 10, parent: main.activeWorkspace.rootTilingContainer, app: mail, title: "Notes")
            XCTAssertTrue(current.focusWindow())
            let shownThere = secondary.activeWorkspace
            _ = TestWindow.new(id: 30, parent: shownThere.rootTilingContainer, app: mail, title: "Other")
            let away = Workspace.get(byName: "away")
            away.preferredMonitorPoint = secondary.rect.topLeftCorner
            // Kept when empty, as a pin is: nothing takes it off that display once its windows are gone.
            try saveWorkspaceSidebarIdentity(away)
            XCTAssertEqual(away.workspaceMonitor.rect, secondary.rect, "Out of sight, on the second display")
            let (_, _, _, trace) = try await parkedMailTabOutOfSight(away)
            workspaceTabCloseConfirm = { _, _ in true }
            workspaceTabCloseIO = { window in
                WindowCloseIO(
                    press: { _ in trace.events.append("press:\(window.windowId)"); return .pressed },
                    presence: { .absent }, windowServerHasWindow: { false }, forget: { _ = window.unbindFromParent() },
                    timeout: 0.05, pause: {})
            }
            await closeWorkspaceSidebarTabWindows(away.name)?.value
            XCTAssertEqual(trace.events.filter { $0.hasPrefix("press:") }, ["press:21", "press:20"])
            XCTAssertTrue(Workspace.existing(byName: "away") === away, "Kept, now empty")
            XCTAssertTrue(secondary.activeWorkspace === shownThere, "The second display shows its tab again")
            XCTAssertTrue(focus.windowOrNil === current, "Focus is back on the first display's window")
        }
    }

    // MARK: - Helpers

    private func order() -> [String] { orderedWorkspaces(in: focus.workspace.projectId).map(\.name) }

    /// Runs `body` with WinMux on, as layout and parking need.
    private func withWinMuxEnabled(_ body: () async throws -> Void) async throws {
        let wasEnabled = TrayMenuModel.shared.isEnabled
        TrayMenuModel.shared.isEnabled = true
        defer { TrayMenuModel.shared.isEnabled = wasEnabled }
        try await body()
    }

    /// A tab out of sight: Mail's viewer, tiled, and a draft opened from it, floating, both parked in
    /// a corner by a layout, as WinMux parks every window of a tab that isn't shown.
    private func parkedMailTabOutOfSight(_ tab: Workspace? = nil) async throws
        -> (Workspace, ParkedTestWindow, ParkedTestWindow, CloseTrace)
    {
        let away = tab ?? Workspace.get(byName: "away")
        let trace = CloseTrace()
        let app = TracedMailApp(trace: trace)
        let area = away.workspaceMonitor.visibleRect
        let viewer = ParkedTestWindow(id: 20, app: app, parent: away.rootTilingContainer,
            rect: Rect(topLeftX: area.minX, topLeftY: area.minY, width: area.width, height: area.height))
        let draft = ParkedTestWindow(id: 21, app: app, parent: away,
            rect: Rect(topLeftX: area.minX + 40, topLeftY: area.minY + 40, width: 720, height: 654))
        AuxiliaryWindowRegistry.shared.record(21, pid: app.pid, role: .mailCompose, parentWindowId: 20)
        XCTAssertFalse(away.isVisible)
        try await layoutWorkspaces()
        XCTAssertTrue(viewer.isHiddenInCorner && draft.isHiddenInCorner, "Parked, as the tab is out of sight")
        let parkedFrame = try await draft.getAxRect()
        XCTAssertFalse(isOnADisplay(parkedFrame))
        trace.events = []
        return (away, viewer, draft, trace)
    }

    private func isOnADisplay(_ rect: Rect?) -> Bool {
        guard let rect else { return false }
        return monitors.contains { $0.rect.contains(rect.center) }
    }

    /// Mail's viewer in the tab on screen, focused.
    private func viewerTab() -> (Workspace, TestWindow) {
        let tab = focus.workspace
        let viewer = TestWindow.new(id: 10, parent: tab.rootTilingContainer, app: mail, title: "Inbox — Example")
        XCTAssertTrue(viewer.focusWindow())
        return (tab, viewer)
    }
}

/// Moves, waits for queued moves, and presses, in the order they happen.
@MainActor
private final class CloseTrace {
    var events: [String] = []

    /// The window was moved, then its app's queued moves waited for, then it was pressed.
    func isMovedThenWaitedFor(_ windowId: UInt32) -> Bool {
        guard let press = events.firstIndex(of: "press:\(windowId)"),
              let move = events[..<press].lastIndex(of: "frame:\(windowId)") else { return false }
        return events[move ..< press].contains("barrier")
    }
}

/// Mail, whose queued moves the barrier waits for.
private final class TracedMailApp: AbstractApp {
    let pid: Int32 = 43
    let trace: CloseTrace
    var rawAppBundleId: String? { "com.apple.mail" }
    var name: String? { "Mail" }
    var execPath: String? { nil }
    var bundlePath: String? { nil }

    init(trace: CloseTrace) { self.trace = trace }

    @MainActor func getFocusedWindow() async throws -> Window? { nil }
    @MainActor func waitForPendingFrameWrites() async throws { trace.events.append("barrier") }
}

/// A window WinMux parks in a corner and brings back as it does Mail's, its frame where it was last put.
private final class ParkedTestWindow: Window, WorkspaceWindowVisibility {
    nonisolated(unsafe) let cornerParking = CornerParkingState()
    nonisolated(unsafe) private var frame: Rect
    private let trace: CloseTrace

    @MainActor init(id: UInt32, app: TracedMailApp, parent: NonLeafTreeNodeObject, rect: Rect) {
        frame = rect
        trace = app.trace
        super.init(id: id, app, lastFloatingSize: CGSize(width: rect.width, height: rect.height), parent: parent,
                   adaptiveWeight: 1, index: INDEX_BIND_LAST)
        recordAuthoritativeActualRect(rect)
    }

    @MainActor override var title: String { get async { "Window \(windowId)" } }
    override var isHiddenInCorner: Bool { cornerParking.isHiddenInCorner }
    @MainActor override func nativeFocus() {}
    @MainActor override func getAxRect() async throws -> Rect? { frame }
    @MainActor override func getAxSize() async throws -> CGSize? { CGSize(width: frame.width, height: frame.height) }
    @MainActor override func closeAxWindow() { _ = unbindFromParent() }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        frame = Rect(topLeftX: topLeft?.x ?? frame.topLeftX, topLeftY: topLeft?.y ?? frame.topLeftY,
                     width: size?.width ?? frame.width, height: size?.height ?? frame.height)
        // Tests run on the main actor, as WinMux's frame writes are queued from it.
        nonisolated(unsafe) let window = self
        MainActor.assumeIsolated {
            window.trace.events.append("frame:\(window.windowId)")
            window.invalidateLastKnownNativeState()
        }
    }

    func unhideFromCorner() { restoreFromCorner(cornerParking) }
    func hideInCorner(_ corner: OptimalHideCorner, reassert: Bool, ifStillValid: () -> Bool) async throws {
        try await parkInCorner(corner, cornerParking, reassert: reassert, onePixelOffset: true, ifStillValid: ifStillValid)
    }
}

/// A captured AX element: role, subrole, identifier and children.
private final class CapturedAxElement: AxUiElementMock {
    var role: String?
    var subrole: String?
    let identifier: String?
    var children: [CapturedAxElement]

    init(_ record: [String: Any]) {
        role = record["AXRole"] as? String
        subrole = record["AXSubrole"] as? String
        identifier = record["AXIdentifier"] as? String
        children = (record["children"] as? [[String: Any]] ?? []).map(CapturedAxElement.init)
    }

    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T? {
        switch attr.key {
            case Ax.roleAttr.key: role as? Attr.T
            case Ax.subroleAttr.key: subrole as? Attr.T
            case Ax.identifierAttr.key: identifier as? Attr.T
            case Ax.childElementsAttr.key: children.map { $0 as any AxUiElementMock } as? Attr.T
            default: nil
        }
    }

    func containingWindowId() -> CGWindowID? { nil }
}
