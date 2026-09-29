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
    /// Where playback was at `positionDate`; nil until Music has been asked, except that a new
    /// track is assumed to start at zero while Music answers.
    var position: TimeInterval?
    var positionDate: Date
    /// Music's own identifier for the track, alike in its notifications and its replies.
    var persistentId: String?

    var trackKey: String { [title, artist, album].joined(separator: "\u{1F}") }

    /// Whether this is the same track, by Music's identifier when both have it: a notification
    /// and a reply needn't spell a track's name, artist, and album alike.
    func isSameTrack(as other: AppleMusicNowPlaying) -> Bool {
        if let persistentId, let otherId = other.persistentId { return persistentId == otherId }
        return trackKey == other.trackKey
    }

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
        // The notification's number is the reply's hexadecimal identifier.
        persistentId: (info["PersistentID"] as? NSNumber).map { String(format: "%016llX", UInt64(bitPattern: $0.int64Value)) },
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
        set trackId to ""
        try
            set trackId to persistent ID of t
        end try
        return s & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & ((duration of t) as string) & sep & ((player position) as string) & sep & trackId
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
    // A stream or an untagged track has no duration, artist, or album; AppleScript spells that out.
    let fields = text.components(separatedBy: appleMusicFieldSeparator).map { $0 == "missing value" ? "" : $0 }
    guard fields.count == 7 else { return nil }
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
        duration: seconds(fields[4]).flatMap { $0 > 0 ? $0 : nil }, position: seconds(fields[5]), positionDate: date,
        persistentId: fields[6].isEmpty ? nil : fields[6].uppercased())
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
        // Read both while it runs: artwork can be larger than a pipe's buffer, and a full
        // pipe would stall the script.
        let errorOutput = AppleMusicScriptError()
        let errorRead = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: errorRead) {
            errorOutput.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .utility).async {
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            errorRead.wait()
            process.waitUntilExit()
            let stderr = String(data: errorOutput.data, encoding: .utf8) ?? ""
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

/// Written once by the stderr reader before the group it runs in finishes.
private final class AppleMusicScriptError: @unchecked Sendable {
    var data = Data()
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
    /// Music is open, as of its last launch or quit, whether or not it has a window.
    @Published private(set) var isRunning = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var generation = 0
    /// Bumped by every newer piece of state, so a slower reply from Music never overwrites it.
    private(set) var stateSequence = 0
    /// Music's last status reply said where it is, so a new track's start may be assumed.
    private var musicAnswers = false
    /// The position is that assumption, which Music hasn't confirmed yet.
    private var positionIsGuess = false
    /// What Music's latest notification said, as it said it.
    private var lastNotified: AppleMusicNowPlaying?
    private let isMusicRunning: @MainActor () -> Bool
    /// Music's status, or nil when WinMux may not ask it without prompting.
    private let requestStatus: @Sendable (_ askingMusic: Bool) async -> AppleMusicScriptOutput?
    private let requestArtwork: @Sendable () async -> AppleMusicScriptOutput

    init(
        isMusicRunning: @escaping @MainActor () -> Bool = {
            !NSRunningApplication.runningApplications(withBundleIdentifier: appleMusicBundleId).isEmpty
        },
        requestStatus: @escaping @Sendable (_ askingMusic: Bool) async -> AppleMusicScriptOutput? = { askingMusic in
            let allowed = await Task.detached(priority: .utility) { appleMusicAutomationIsAllowed() }.value
            guard allowed || askingMusic else { return nil }
            return await runAppleMusicScript(appleMusicStatusScript)
        },
        requestArtwork: @escaping @Sendable () async -> AppleMusicScriptOutput = {
            await runAppleMusicScript(appleMusicArtworkScript)
        },
    ) {
        self.isMusicRunning = isMusicRunning
        self.requestStatus = requestStatus
        self.requestArtwork = requestArtwork
    }
    /// The track the artwork belongs to, whether loaded, loading, or failing to load.
    private var artworkTrackKey: String?
    private var artworkLoaded = false
    private var artworkFailures = 0
    private var artworkRequest: Int?
    private var nextArtworkRequest = 0

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

    /// Brings Music forward. Opening it again shows its window when none is open.
    func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appleMusicBundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func receive(_ next: AppleMusicNowPlaying) {
        var next = next
        var guessed = false
        // Music repeats what it last said about a track each time it plays or pauses; different
        // details for it are news, as a stream's next song under one identifier is.
        let isNews = lastNotified.map { $0.isSameTrack(as: next) && $0.trackKey != next.trackKey } ?? false
        lastNotified = next
        // The notification has no position; keep counting from the last one Music gave. While
        // Music answers, its replies say what the track is, so a notification for the track shown
        // only says whether it plays and pausing redraws nothing else. Otherwise the notification's
        // details show, keeping a length it leaves out. While Music answers, a new track starts
        // from its beginning until its reply says otherwise, so the progress bar doesn't drop out.
        if next.state != .stopped, let current = nowPlaying, current.isSameTrack(as: next) {
            let position = current.elapsed(at: next.positionDate)
            if musicAnswers, !isNews {
                let (state, date, id) = (next.state, next.positionDate, next.persistentId)
                next = current
                next.state = state
                next.positionDate = date
                next.persistentId = current.persistentId ?? id
            } else {
                next.duration = next.duration ?? current.duration
                next.persistentId = next.persistentId ?? current.persistentId
            }
            next.position = position
            guessed = positionIsGuess
        } else if next.state != .stopped, musicAnswers {
            next.position = 0
            guessed = true
        }
        positionIsGuess = guessed && next.position != nil
        stateSequence += 1
        apply(next)
        refresh()
    }

    /// Asks Music for the position and artwork, only once it may be automated. Only the latest
    /// request's reply is used: one sent before a pause may arrive after it.
    private func refresh(askingMusic: Bool = false) {
        guard isMusicRunning() else { return clear() }
        if !isRunning { isRunning = true }
        stateSequence += 1
        let sequence = stateSequence
        let requestStatus = requestStatus
        _ = Task { [weak self] in
            let result = await requestStatus(askingMusic)
            self?.receive(statusResult: result, sequence: sequence)
        }
    }

    /// `result` is nil when Music may not be asked without prompting.
    func receive(statusResult result: AppleMusicScriptOutput?, sequence: Int) {
        guard sequence == stateSequence else { return }
        guard case .success(let output) = result else { return statusFailed() }
        needsAutomationPermission = false
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return clear() }
        if var next = appleMusicNowPlaying(statusOutput: output) {
            // A reply that can't name the track keeps the identifier its notification gave.
            if next.persistentId == nil, let current = nowPlaying, current.isSameTrack(as: next) {
                next.persistentId = current.persistentId
            }
            musicAnswers = true
            positionIsGuess = false
            apply(next)
        } else {
            statusFailed()
        }
        loadArtworkIfNeeded()
    }

    /// Music didn't say where it is: a new track's assumed start goes rather than count on
    /// unchecked, and none is assumed until Music answers again.
    private func statusFailed() {
        musicAnswers = false
        guard positionIsGuess, var current = nowPlaying else { return }
        positionIsGuess = false
        current.position = nil
        nowPlaying = current
    }

    func apply(_ next: AppleMusicNowPlaying) {
        if next.state == .stopped || next.trackKey != artworkTrackKey { resetArtwork() }
        if nowPlaying != next { nowPlaying = next }
    }

    /// A failed fetch is retried on Music's next update, a few times per track.
    private func loadArtworkIfNeeded() {
        guard let nowPlaying, nowPlaying.state != .stopped else { return }
        let key = nowPlaying.trackKey
        if artworkTrackKey != key {
            resetArtwork()
            artworkTrackKey = key
        }
        guard !artworkLoaded, artworkRequest == nil, artworkFailures < 3 else { return }
        nextArtworkRequest += 1
        let request = nextArtworkRequest
        artworkRequest = request
        let requestArtwork = requestArtwork
        _ = Task { [weak self] in
            let result = await requestArtwork()
            let data: Data? = if case .success(let output) = result {
                await Task.detached(priority: .utility) { appleScriptRawData(output) }.value
            } else { nil }
            self?.receive(artworkResult: result, data: data, request: request)
        }
    }

    func receive(artworkResult result: AppleMusicScriptOutput, data: Data?, request: Int) {
        guard artworkRequest == request else { return }
        artworkRequest = nil
        // Music printing nothing means the track has no artwork: it keeps the placeholder.
        if case .success(let output) = result, output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            artworkLoaded = true
            return
        }
        guard case .success = result, let image = data.flatMap(NSImage.init(data:)) else {
            artworkFailures += 1
            return
        }
        artworkLoaded = true
        artwork = image
    }

    private func resetArtwork() {
        artworkTrackKey = nil
        artworkLoaded = false
        artworkFailures = 0
        artworkRequest = nil
        if artwork != nil { artwork = nil }
    }

    /// Every caller means Music isn't running: it quit, never started, or isn't followed.
    private func clear() {
        stateSequence += 1
        musicAnswers = false
        positionIsGuess = false
        lastNotified = nil
        resetArtwork()
        if nowPlaying != nil { nowPlaying = nil }
        if isRunning { isRunning = false }
    }
}
