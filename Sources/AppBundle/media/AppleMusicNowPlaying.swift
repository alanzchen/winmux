import AppKit
import CoreServices

let appleMusicBundleId = "com.apple.Music"

/// What Music is playing, from its player notifications or, once WinMux may control Music,
/// from asking it.
struct AppleMusicNowPlaying: Equatable {
    enum State: Equatable {
        case playing, paused, stopped
    }

    var state: State
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    /// Where playback was at `positionDate`; nil until Music has been asked.
    var position: TimeInterval?
    var positionDate: Date

    /// Changes with the track, so its artwork is fetched once.
    var trackKey: String { [title, artist, album].joined(separator: "\u{1F}") }

    /// Playback position now, counting on while playing.
    func elapsed(at date: Date) -> TimeInterval? {
        guard let position else { return nil }
        let elapsed = state == .playing ? position + max(0, date.timeIntervalSince(positionDate)) : position
        return duration.map { min(elapsed, $0) } ?? elapsed
    }
}

/// Reads Music's `com.apple.Music.playerInfo` notification, which carries the track and the
/// player state but not the position.
func appleMusicNowPlaying(playerInfo info: [AnyHashable: Any], date: Date = Date()) -> AppleMusicNowPlaying? {
    let state: AppleMusicNowPlaying.State
    switch (info["Player State"] as? String)?.lowercased() {
        case "playing": state = .playing
        case "paused": state = .paused
        case "stopped": state = .stopped
        default: return nil
    }
    guard state != .stopped else {
        return AppleMusicNowPlaying(state: .stopped, title: "", artist: "", album: "", positionDate: date)
    }
    let totalTime = (info["Total Time"] as? NSNumber)?.doubleValue
    return AppleMusicNowPlaying(
        state: state,
        title: info["Name"] as? String ?? "",
        artist: info["Artist"] as? String ?? "",
        album: info["Album"] as? String ?? "",
        duration: totalTime.flatMap { $0 > 0 ? $0 / 1000 : nil },
        position: nil,
        positionDate: date,
    )
}

private let appleMusicFieldSeparator = "\u{1F}"

/// Asks Music for its state without launching it: nothing when it isn't running.
let appleMusicStatusScript = """
    if application "Music" is not running then return ""
    tell application "Music"
        set s to player state as string
        if s is "stopped" then return s
        set sep to character id 31
        set t to current track
        return s & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & ((duration of t) as string) & sep & ((player position) as string)
    end tell
    """

/// Music's artwork for the current track, printed by osascript as `«data tdta…»` hex.
let appleMusicArtworkScript = """
    if application "Music" is not running then return ""
    tell application "Music"
        if player state is stopped then return ""
        if (count of artworks of current track) is 0 then return ""
        return raw data of artwork 1 of current track
    end tell
    """

/// Parses `appleMusicStatusScript`'s output. Numbers may use the locale's decimal comma.
func appleMusicNowPlaying(statusOutput output: String, date: Date = Date()) -> AppleMusicNowPlaying? {
    let text = output.trimmingCharacters(in: .newlines)
    if text == "stopped" {
        return AppleMusicNowPlaying(state: .stopped, title: "", artist: "", album: "", positionDate: date)
    }
    let fields = text.components(separatedBy: appleMusicFieldSeparator)
    guard fields.count == 6 else { return nil }
    let state: AppleMusicNowPlaying.State
    switch fields[0] {
        case "playing", "fast forwarding", "rewinding": state = .playing
        case "paused": state = .paused
        default: return nil
    }
    func seconds(_ field: String) -> TimeInterval? {
        TimeInterval(field.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    return AppleMusicNowPlaying(state: state, title: fields[1], artist: fields[2], album: fields[3],
        duration: seconds(fields[4]).flatMap { $0 > 0 ? $0 : nil }, position: seconds(fields[5]), positionDate: date)
}

/// Decodes osascript's `«data XXXX0123…»` rendering of raw data.
func appleScriptRawData(_ output: String) -> Data? {
    guard let start = output.range(of: "«data "), let end = output.range(of: "»", range: start.upperBound..<output.endIndex)
    else { return nil }
    let body = output[start.upperBound..<end.lowerBound]
    guard body.count > 4 else { return nil }
    let hex = body.dropFirst(4).utf8
    guard hex.count.isMultiple(of: 2) else { return nil }
    var data = Data(capacity: hex.count / 2)
    var high: UInt8?
    for char in hex {
        let nibble: UInt8
        switch char {
            case 0x30...0x39: nibble = char - 0x30
            case 0x41...0x46: nibble = char - 0x41 + 10
            case 0x61...0x66: nibble = char - 0x61 + 10
            default: return nil
        }
        if let pending = high {
            data.append(pending << 4 | nibble)
            high = nil
        } else {
            high = nibble
        }
    }
    return data.isEmpty ? nil : data
}

enum AppleMusicCommand: String {
    case playPause = "playpause"
    /// Music's back button: the track's start, or the previous track right at its start.
    case previous = "back track"
    case next = "next track"
}

enum AppleMusicScriptOutput: Equatable {
    case success(String)
    case notAuthorized
    case failed
}

/// Runs a script in `osascript`, off the main thread, so a slow Music or a first-time
/// permission prompt never blocks WinMux.
func runAppleMusicScript(_ source: String, timeout: TimeInterval = 10) async -> AppleMusicScriptOutput {
    await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let state = AppleMusicScriptState(continuation)
        do {
            try process.run()
        } catch {
            state.resume(.failed)
            return
        }
        // Read while it runs: artwork can be larger than a pipe's buffer.
        DispatchQueue.global(qos: .utility).async {
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let stderr = String(data: error, encoding: .utf8) ?? ""
            switch newWindowScriptResult(exitStatus: process.terminationStatus, stderr: stderr) {
                case .success: state.resume(.success(String(data: output, encoding: .utf8) ?? ""))
                case .notAuthorized: state.resume(.notAuthorized)
                case .failed: state.resume(.failed)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
            state.resume(.failed)
        }
    }
}

private final class AppleMusicScriptState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppleMusicScriptOutput, Never>?

    init(_ continuation: CheckedContinuation<AppleMusicScriptOutput, Never>) { self.continuation = continuation }

    func resume(_ result: AppleMusicScriptOutput) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

/// Whether WinMux may already send Music Apple events, checked without ever asking the user.
nonisolated func appleMusicAutomationIsAllowed() -> Bool {
    let target = NSAppleEventDescriptor(bundleIdentifier: appleMusicBundleId)
    guard let descriptor = target.aeDesc else { return false }
    return AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, false) == noErr
}

/// Music's now playing for the Tabs sidebar. Its notifications need no permission; asking for
/// the position and artwork, or controlling playback, needs permission to automate Music. Only
/// a control the user clicks asks for that permission, never the sidebar on its own.
@MainActor
final class AppleMusicNowPlayingModel: ObservableObject {
    static let shared = AppleMusicNowPlayingModel()
    @Published private(set) var nowPlaying: AppleMusicNowPlaying?
    @Published private(set) var artwork: NSImage?
    /// The user declined to let WinMux control Music.
    @Published private(set) var needsAutomationPermission = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var artworkTrackKey: String?
    private var generation = 0

    var isEnabled: Bool { !observers.isEmpty }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        generation += 1
        guard enabled else {
            for (center, observer) in observers { center.removeObserver(observer) }
            observers = []
            clear()
            return
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil,
            queue: .main) { [weak self] notification in
            guard let next = appleMusicNowPlaying(playerInfo: notification.userInfo ?? [:]) else { return }
            MainActor.assumeIsolated { self?.receive(next) }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == appleMusicBundleId else { return }
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated { launched ? self?.refresh() : self?.clear() }
            }))
        }
        refresh()
    }

    func send(_ command: AppleMusicCommand) {
        let generation = generation
        _ = Task { [weak self] in
            let result = await runAppleMusicScript("""
                if application "Music" is not running then return ""
                tell application "Music" to \(command.rawValue)
                """, timeout: 60)
            guard let self, self.generation == generation else { return }
            self.needsAutomationPermission = result == .notAuthorized
            if result != .notAuthorized { self.refresh(askingMusic: true) }
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func receive(_ next: AppleMusicNowPlaying) {
        var next = next
        // The notification has no position; keep counting from the last one Music gave.
        if let current = nowPlaying, current.trackKey == next.trackKey, next.state != .stopped {
            next.position = current.elapsed(at: next.positionDate)
        }
        apply(next)
        refresh()
    }

    /// Asks Music for the position and artwork, only once it may be automated.
    private func refresh(askingMusic: Bool = false) {
        guard isRunning else { return clear() }
        let generation = generation
        _ = Task { [weak self] in
            let allowed = await Task.detached(priority: .utility) { appleMusicAutomationIsAllowed() }.value
            guard allowed || askingMusic else { return }
            guard case .success(let output) = await runAppleMusicScript(appleMusicStatusScript) else { return }
            guard let self, self.generation == generation else { return }
            self.needsAutomationPermission = false
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return self.clear() }
            if let next = appleMusicNowPlaying(statusOutput: output) { self.apply(next) }
            self.loadArtworkIfNeeded()
        }
    }

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: appleMusicBundleId).isEmpty
    }

    func apply(_ next: AppleMusicNowPlaying) {
        if next.state == .stopped || next.trackKey != artworkTrackKey {
            artworkTrackKey = nil
            if artwork != nil { artwork = nil }
        }
        if nowPlaying != next { nowPlaying = next }
    }

    private func loadArtworkIfNeeded() {
        guard let nowPlaying, nowPlaying.state != .stopped, artworkTrackKey != nowPlaying.trackKey else { return }
        let key = nowPlaying.trackKey
        artworkTrackKey = key
        let generation = generation
        _ = Task { [weak self] in
            guard case .success(let output) = await runAppleMusicScript(appleMusicArtworkScript) else { return }
            let data = await Task.detached(priority: .utility) { appleScriptRawData(output) }.value
            guard let self, self.generation == generation, self.artworkTrackKey == key else { return }
            self.artwork = data.flatMap(NSImage.init(data:))
        }
    }

    private func clear() {
        artworkTrackKey = nil
        if nowPlaying != nil { nowPlaying = nil }
        if artwork != nil { artwork = nil }
    }
}
