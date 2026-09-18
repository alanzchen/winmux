import CoreGraphics
import Foundation

/// Window-server coordinates, like Monitor.rect. Only native fullscreen windows on the
/// current Spaces belong here; an AX fullscreen flag alone also includes inactive Spaces.
struct NativeFullscreenChromeSuppression {
    var windowFrames: [CGRect] = []

    func suppresses(on monitor: Monitor) -> Bool {
        let rect = CGRect(origin: monitor.rect.topLeftCorner, size: CGSize(width: monitor.width, height: monitor.height))
        return windowFrames.contains { rect.contains(CGPoint(x: $0.midX, y: $0.midY)) }
    }
}

@MainActor
var nativeFullscreenChromeSuppression = NativeFullscreenChromeSuppression()

/// Metadata only: no screenshots, window titles, or screen-recording permission requests.
private func onScreenWindowFrames() -> [UInt32: CGRect]? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return nil }
    var frames: [UInt32: CGRect] = [:]
    for window in windows {
        guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              !rect.isEmpty
        else { continue }
        frames[id] = rect
    }
    return frames
}

@MainActor
func updateNativeFullscreenChromeSuppression(
    nativeFocused: Window?,
    readOnScreenFrames: () -> [UInt32: CGRect]? = onScreenWindowFrames,
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
    // The invalidating AX event schedules another refresh. Keep the last visibility decision
    // until it can take a coherent sample instead of revealing chrome mid-transition.
    guard !Task.isCancelled,
          observations.allSatisfy({ window, token in window.nativeStateObservationToken() == token })
    else { return }
    // Avoid a WindowServer query in the common case, and never query on pointer/display ticks.
    guard !fullscreenIds.isEmpty else {
        nativeFullscreenChromeSuppression = NativeFullscreenChromeSuppression()
        return
    }
    // A failed WindowServer query during a Space transition must not reveal hidden chrome.
    guard let frames = readOnScreenFrames() else { return }
    nativeFullscreenChromeSuppression = NativeFullscreenChromeSuppression(
        windowFrames: fullscreenIds.compactMap { frames[$0] }
    )
}

@MainActor
func shouldSuppressChromeForFullscreenContent(on monitor: Monitor) -> Bool {
    nativeFullscreenChromeSuppression.suppresses(on: monitor)
}
