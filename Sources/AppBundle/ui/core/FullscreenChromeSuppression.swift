import AppKit

/// Window-server coordinates, like Monitor.rect. Only fullscreen content on the current
/// Spaces belongs here; an AX fullscreen flag alone also includes inactive Spaces.
struct NativeFullscreenChromeSuppression {
    var windowFrames: [CGRect] = []
    /// Display-sized popups among windowFrames, kept while their AX frame is unknown.
    var presentationWindowIds: Set<UInt32> = []

    func suppresses(on monitor: Monitor) -> Bool {
        let rect = CGRect(origin: monitor.rect.topLeftCorner, size: CGSize(width: monitor.width, height: monitor.height))
        return windowFrames.contains { rect.contains(CGPoint(x: $0.midX, y: $0.midY)) }
    }
}

@MainActor
var nativeFullscreenChromeSuppression = NativeFullscreenChromeSuppression()

struct OnScreenWindow {
    var frame: CGRect
    var layer: Int = 0
}

/// Metadata only: no screenshots, window titles, or screen-recording permission requests.
private func onScreenWindows() -> [UInt32: OnScreenWindow]? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return nil }
    var result: [UInt32: OnScreenWindow] = [:]
    for window in windows {
        guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              !rect.isEmpty
        else { continue }
        result[id] = OnScreenWindow(frame: rect, layer: (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)
    }
    return result
}

/// Presentation windows such as PowerPoint's slide show never report AX fullscreen. They are
/// buttonless popups sized to the whole display, including the menu bar area.
@MainActor
private func coversMonitor(_ frame: CGRect) -> Bool {
    monitors.contains { monitor in
        let rect = monitor.rect
        return frame.minX <= rect.minX + 1 && frame.minY <= rect.minY + 1 &&
            frame.maxX >= rect.maxX - 1 && frame.maxY >= rect.maxY - 1
    }
}

@MainActor
private func coversMonitor(_ rect: Rect) -> Bool {
    coversMonitor(CGRect(origin: rect.topLeftCorner, size: rect.size))
}

/// Desktop-level wallpapers and overlays above the sidebar (screenshot selection, for
/// example) must not hide chrome: only content the chrome could draw over counts.
@MainActor
private func isBeneathWinMuxChrome(_ window: OnScreenWindow) -> Bool {
    (0 ... workspaceSidebarPanelLevel(stayOnTop: config.workspaceSidebar.stayOnTop).rawValue).contains(window.layer)
}

/// Menu bar utilities' display-sized overlays (dimmers, capture selection) are not
/// presentations. Windows of non-Mac apps (tests) have no policy and are kept.
func isPresentationApp(activationPolicy: NSApplication.ActivationPolicy?) -> Bool {
    activationPolicy.map { $0 == .regular } ?? true
}

@MainActor
func updateNativeFullscreenChromeSuppression(
    nativeFocused: Window?,
    readOnScreenWindows: () -> [UInt32: OnScreenWindow]? = onScreenWindows,
) async {
    var windows = Workspace.all.flatMap(\.allLeafWindowsRecursive)
    if let nativeFocused, !windows.contains(nativeFocused) { windows.append(nativeFocused) }
    let observations = windows.map { ($0, $0.nativeStateObservationToken()) }
    // Normalization has already populated this event-invalidated cache on full refreshes.
    // Focus-only sessions query only invalidated windows, concurrently across apps.
    let fullscreenIds = await withTaskGroup(of: UInt32?.self, returning: Set<UInt32>.self) { group in
        var ids: Set<UInt32> = []
        for (window, token) in observations {
            if let cached = window.lastKnownNativeFullscreen {
                if cached { ids.insert(window.windowId) }
                continue
            }
            group.addTask { @Sendable @MainActor in
                let fullscreen = try? await window.isMacosFullscreen
                guard token == window.nativeStateObservationToken() else { return nil }
                if let fullscreen { window.recordObservedNativeFullscreen(fullscreen, token: token) }
                return fullscreen == true ? window.windowId : nil
            }
        }
        for await id in group { if let id { ids.insert(id) } }
        return ids
    }
    // Only a candidate filter: the WindowServer frame below decides. Moved/resized events
    // invalidate the cached frame and schedule another refresh, so popups need no token guard.
    // An unknown frame keeps the last decision; only the focused app is asked, so a busy
    // background app cannot stall sessions or reveal chrome over its slide show.
    let popups = macosPopupWindowsContainer.children.filterIsInstance(of: Window.self).filter {
        isPresentationApp(activationPolicy: ($0.app as? MacApp)?.nsApp.activationPolicy)
    }
    let presenting = nativeFullscreenChromeSuppression.presentationWindowIds
    let focusedAppPid = nativeFocused?.app.pid
    let displaySizedPopupIds = await withTaskGroup(of: UInt32?.self, returning: Set<UInt32>.self) { group in
        var ids: Set<UInt32> = []
        for popup in popups {
            let id = popup.windowId
            if let cached = popup.lastKnownActualRect {
                if coversMonitor(cached) { ids.insert(id) }
                continue
            }
            guard popup.app.pid == focusedAppPid else {
                if presenting.contains(id) { ids.insert(id) }
                continue
            }
            group.addTask { @Sendable @MainActor in
                guard let rect = try? await popup.getAxRect() else { return presenting.contains(id) ? id : nil }
                return coversMonitor(rect) ? id : nil
            }
        }
        for await id in group { if let id { ids.insert(id) } }
        return ids
    }
    // The invalidating AX event schedules another refresh. Keep the last visibility decision
    // until it can take a coherent sample instead of revealing chrome mid-transition.
    guard !Task.isCancelled,
          observations.allSatisfy({ window, token in window.nativeStateObservationToken() == token })
    else { return }
    // Avoid a WindowServer query in the common case, and never query on pointer/display ticks.
    guard !fullscreenIds.isEmpty || !displaySizedPopupIds.isEmpty else {
        nativeFullscreenChromeSuppression = NativeFullscreenChromeSuppression()
        return
    }
    // A failed WindowServer query during a Space transition must not reveal hidden chrome.
    guard let onScreen = readOnScreenWindows() else { return }
    let presentationIds = displaySizedPopupIds.filter { id in
        onScreen[id].map { isBeneathWinMuxChrome($0) && coversMonitor($0.frame) } ?? false
    }
    nativeFullscreenChromeSuppression = NativeFullscreenChromeSuppression(
        windowFrames: fullscreenIds.union(presentationIds).compactMap { onScreen[$0]?.frame },
        presentationWindowIds: presentationIds,
    )
}

@MainActor
func shouldSuppressChromeForFullscreenContent(on monitor: Monitor) -> Bool {
    nativeFullscreenChromeSuppression.suppresses(on: monitor)
}
