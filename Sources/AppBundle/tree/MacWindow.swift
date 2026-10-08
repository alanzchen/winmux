import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp
    private var popupPresentationState: PopupWindowPresentationState
    override var wasFirstSeenDuringStartupOrRestored: Bool {
        popupPresentationState.firstSeenDuringStartup || popupPresentationState.wasRestored
    }
    private let cornerParking = CornerParkingState()

    @MainActor
    private init(_ id: UInt32, _ actor: MacApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int, firstSeenInActiveApp: Bool) {
        self.macApp = actor
        self.popupPresentationState = PopupWindowPresentationState(firstSeenDuringStartup: isStartup, firstSeenInActiveApp: firstSeenInActiveApp, wasInitiallyPopup: parent is MacosPopupWindowsContainer)
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [UInt32: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: UInt32, macApp: MacApp) async throws -> MacWindow? {
        if let existing = allWindowsMap[windowId] {
            // No AX round-trip for known windows: this runs for every window on every refresh
            // barrier, and lastKnownActualRect stays correct without polling because moved /
            // resized AX events invalidate it and consumers re-fetch on demand.
            return existing
        }
        // Before any AX round-trip: a launcher request counts only windows first seen after it.
        let observedAt = ProcessInfo.processInfo.systemUptime
        let firstSeenInActiveApp = macApp.nsApp.isActive
        let rect = try await macApp.getAxRect(windowId)
        let (data, windowType, claimed) = try await classifyAndGetBindingDataForNewWindow(
            windowId,
            macApp,
            isStartup
                ? (rect?.center.monitorApproximation ?? mainMonitor).activeWorkspace
                : focus.workspace,
            window: nil,
            observedAt: observedAt,
        )

        // atomic synchronous section
        if let existing = allWindowsMap[windowId] {
            // Registered meanwhile. Only a claim this call made is settled here.
            if claimed { settleClaimAfterConcurrentRegistration(existing) }
            return existing
        }
        let window = MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index, firstSeenInActiveApp: firstSeenInActiveApp)
        window.recordAuthoritativeActualRect(rect)
        allWindowsMap[windowId] = window
        NewWindowIntentRegistry.shared.windowsBeingDetected.insert(windowId)
        defer { NewWindowIntentRegistry.shared.windowsBeingDetected.remove(windowId) }

        try await debugWindowsIfRecording(window)
        let focusBeforeDetectionCallbacks = focusChangeGeneration
        let wasRestored = try await restoreOrDetectNewWindow(window, isRegularWindow: windowType == .window)
        // A concurrent registration may have claimed it after detection checked for a claim.
        settleClaimLeftAfterDetection(window)
        window.popupPresentationState.wasRestored = wasRestored
        newFloatingWindowPresentation?.recordDetection(
            window,
            wasRestored: wasRestored,
            focusGenerationBeforeCallbacks: focusBeforeDetectionCallbacks,
        )
        return window
    }

    @MainActor
    func consumePendingPopupPresentation() -> Bool {
        popupPresentationState.consume()
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    func isWindowHeuristic(_ windowLevel: MacOsWindowLevel?) async throws -> Bool { // todo cache
        try await macApp.isWindowHeuristic(windowId, windowLevel)
    }

    func isDialogHeuristic(_ windowLevel: MacOsWindowLevel?) async throws -> Bool { // todo cache
        try await macApp.isDialogHeuristic(windowId, windowLevel)
    }

    func dumpAxInfo() async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId)
    }

    func setNativeFullscreen(_ value: Bool) {
        macApp.setNativeFullscreen(windowId, value)
    }

    func setNativeMinimized(_ value: Bool) {
        macApp.setNativeMinimized(windowId, value)
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
        removeClosedWindowFromTree()
        // Closed: no pin lends it, and no pinned split brings it back, any more.
        let (windowId, pid) = (windowId, macApp.pid)
        forgetWorkspaceSidebarPinWindows { $0.windowId == windowId && $0.pid == pid }
    }

    @MainActor override var title: String { get async throws { try await macApp.getAxTitle(windowId) ?? "" } }
    @MainActor override var isMacosFullscreen: Bool { get async throws { try await macApp.isMacosNativeFullscreen(windowId) == true } }
    @MainActor override var isMacosMinimized: Bool { get async throws { try await macApp.isMacosNativeMinimized(windowId) == true } }

    @MainActor
    override func nativeFocus() {
        macApp.nativeFocus(windowId)
    }

    @MainActor
    func requestCloseForProjectDeletion(timeout: TimeInterval = 1.5) async -> Bool {
        guard (try? await macApp.pressCloseButton(windowId)) == true else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await macApp.containsAxWindow(windowId)) == false {
                garbageCollect(skipClosedWindowsCache: true)
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    override func closeAxWindow() {
        garbageCollect(skipClosedWindowsCache: true)
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner, reassert: Bool = false, ifStillValid: () -> Bool = { true }) async throws {
        // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/WinMux/issues/527
        // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
        try await parkInCorner(corner, cornerParking, reassert: reassert, onePixelOffset: macApp.appId != .zoom, ifStillValid: ifStillValid)
    }

    @MainActor
    func unhideFromCorner() {
        restoreFromCorner(cornerParking)
    }

    override var isHiddenInCorner: Bool {
        cornerParking.isHiddenInCorner
    }

    override func getAxSize() async throws -> CGSize? {
        try await macApp.getAxSize(windowId)
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        macApp.setAxFrame(windowId, topLeft, size)
    }

    func setAxFrameBlocking(_ topLeft: CGPoint?, _ size: CGSize?) async throws {
        try await macApp.setAxFrameBlocking(windowId, topLeft, size)
    }

    override func getAxRect() async throws -> Rect? {
        let windowId = self.windowId
        let observationToken = await MainActor.run {
            Window.get(byId: windowId)?.nativeStateObservationToken()
        }
        let rect = try await macApp.getAxRect(windowId)
        if let observationToken {
            await MainActor.run {
                Window.get(byId: windowId)?.recordObservedActualRect(rect, token: observationToken)
            }
        }
        return rect
    }
}
