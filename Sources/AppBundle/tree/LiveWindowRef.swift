import AppKit
import Common

/// One lifetime of a window: its number, its process, that process's app and launch, and the boot it
/// ran in. The same number and process seen in another boot, or in another launch, are another window.
/// macOS keeps a window number unique only within the current user session, so a number saved for
/// later must be saved with this. Pins, auxiliary links and the world saved for a restart all use it.
struct LiveWindowRef: Codable, Hashable {
    var windowId: UInt32
    var pid: Int32
    var bundleId: String? = nil
    var processLaunch: Date? = nil
    /// The boot's time, as recorded before `bootSession` was. It moves with sleep and clock changes, so it
    /// can only ever confirm a boot, never rule one out.
    var boot: Date? = nil
    /// The boot's session id (kern.bootsessionuuid), which nothing changes until the next boot. Nil in
    /// records saved before it was recorded.
    var bootSession: String? = nil
}

/// What WinMux can tell about a recorded window now.
enum LiveWindowRefStanding: Equatable {
    /// Still the same process in the same boot: its window may be open.
    case mayBeOpen
    /// Shown to be gone: its process ended or was replaced, or it was another boot.
    case gone
    /// Nothing decides it either way.
    case unknown
}

/// The boot WinMux runs in, by its session id. Read each time: a test replaces it.
@MainActor var liveWindowBootSession: () -> String? = { liveWindowSystemString("kern.bootsessionuuid") }

/// The boot's time, read each time: it moves with sleep and clock changes.
@MainActor var liveWindowBootTime: () -> Date? = { liveWindowSystemBootTime() }

/// A process's app and launch, while it runs: what tells it from a later process given the same number.
@MainActor var liveWindowRunningProcess: (Int32) -> (bundleId: String?, launch: Date?)? = { pid in
    NSRunningApplication(processIdentifier: pid).map { ($0.bundleIdentifier, $0.launchDate) }
}

private func liveWindowSystemBootTime() -> Date? {
    var mib = [CTL_KERN, KERN_BOOTTIME]
    var time = timeval()
    var size = MemoryLayout<timeval>.stride
    guard sysctl(&mib, 2, &time, &size, nil, 0) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
}

/// A string sysctl, without its terminating NUL; nil when it can't be read or is empty.
func liveWindowSystemString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    let value = String(decoding: buffer.prefix(size).prefix { $0 != 0 }, as: UTF8.self)
    return value.isEmpty ? nil : value
}

private func liveWindowSameInstant(_ a: Date?, _ b: Date?) -> Bool {
    switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?): abs(a.timeIntervalSince(b)) < 0.001
        default: false
    }
}

extension LiveWindowRef {
    @MainActor
    init(_ window: Window) {
        self.init(windowId: window.windowId, pid: window.app.pid, bundleId: window.app.rawAppBundleId,
            processLaunch: window.app.launchDate, boot: liveWindowBootTime(), bootSession: liveWindowBootSession())
    }

    /// The window, if it's still this one: open, in the same process of the same app, launched when
    /// it was, in the same boot.
    @MainActor
    var live: Window? {
        guard let window = Window.get(byId: windowId), refers(to: window) else { return nil }
        return window
    }

    /// Whether `window` is this one: the same number, in the same process of the same app, launched
    /// when it was, in the same boot. Only a match that's established counts.
    @MainActor
    func refers(to window: Window) -> Bool { standing(of: window) == .mayBeOpen }

    /// Whether `window` is this one, isn't, or can't be told.
    @MainActor
    func standing(of window: Window) -> LiveWindowRefStanding {
        guard window.windowId == windowId else { return .gone }
        return standing(ofProcess: (window.app.pid, window.app.rawAppBundleId, window.app.launchDate))
    }

    /// Whether it may still be open as WinMux starts again: the same boot, and its process still
    /// running, the same app, launched when it was. Its window may not be seen yet.
    @MainActor
    var mayStillBeOpen: Bool { standing == .mayBeOpen }

    @MainActor
    var standing: LiveWindowRefStanding {
        guard let process = liveWindowRunningProcess(pid) else { return .gone }
        return standing(ofProcess: (pid, process.bundleId, process.launch))
    }

    @MainActor
    private func standing(ofProcess process: (pid: Int32, bundleId: String?, launch: Date?)) -> LiveWindowRefStanding {
        guard process.pid == pid, process.bundleId == bundleId, liveWindowSameInstant(process.launch, processLaunch) else {
            return .gone
        }
        if let bootSession, let current = liveWindowBootSession() {
            return bootSession == current ? .mayBeOpen : .gone
        }
        // Recorded before boot sessions were, or the session can't be read now. The process's launch instant is
        // its own: a process launched at that instant, with that number and app, is that process, in this boot.
        if processLaunch != nil { return .mayBeOpen }
        // A boot time can confirm a boot, though it moves a little with sleep and clock changes; it can't rule one out.
        if let boot, let current = liveWindowBootTime(), abs(boot.timeIntervalSince(current)) < 1 { return .mayBeOpen }
        return .unknown
    }
}
