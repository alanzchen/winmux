import AppKit
import Common

let debugRecordingDurationRange = 1 ... 120
let debugRecordingDefaultDuration = 60
let debugRecordingIntervalRange = 250 ... 60_000
let debugRecordingDefaultInterval = 1000
/// How long a finished recording waits to be fetched before it's discarded.
let debugRecordingKeptAfterFinishing: Duration = .seconds(600)
/// An event's detail value is cut to this many characters: a workspace name can be any length.
let debugRecordingEventValueLimit = 200

/// What a recording captures, and how often.
struct DebugRecordingSettings: Equatable, Sendable {
    var durationSeconds = debugRecordingDefaultDuration
    var intervalMs = debugRecordingDefaultInterval
    /// Frames are captured only if asked for, allowed for the request, and allowed by macOS.
    var frames = true
    var monitorId: Int? = nil
    var maxLongEdge = debugRecordingDefaultLongEdge
    var format = DebugImageFormat.jpeg
    var snapshot = MCPDebugSnapshotOptions()
}

/// The clocks, the timers and the snapshot a recorder uses. Tests replace them.
struct DebugRecorderEnvironment {
    /// The time of day, for the times a recording reports.
    var now: @MainActor () -> Date = { Date() }
    /// A clock that only moves forward, for deadlines: changing the time of day doesn't move them.
    var uptime: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Runs `action` after `delay`, unless the returned cancel runs first.
    var after: @MainActor (Duration, @escaping @MainActor () -> Void) -> (@MainActor () -> Void) = { delay, action in
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { action() }
        }
        return { task.cancel() }
    }
    var snapshot: @MainActor (MCPDebugSnapshotOptions) async -> MCPJSON = { await mcpDebugSnapshot($0) }
}

/// While a recording runs: the menu bar shows it, and its menu offers to stop it.
struct DebugRecordingIndicator: Equatable {
    let id: String
    let endsAt: Date
}

/// One piece of a recording, in the order it was recorded: what fetch pages are made of. Each fits a page alone.
struct DebugRecordingEntry {
    enum Content {
        case state(MCPJSON)
        /// The same state as the one before.
        case unchanged
        case events([WindowLifecycleEvent])
        case frame(DebugCaptureDisplay, DebugCapturedImage)
        case frameError(display: Int, message: String)
        /// What was here was dropped to keep within the recording's memory.
        case evicted(String)
    }

    let sequence: Int
    let tick: Int
    let at: Date
    var content: Content
    /// What it holds: its image's bytes, and its text as fetch sends it.
    var bytes = 0

    var isFrame: Bool { if case .frame = content { true } else { false } }
    var imageBytes: Int { if case .frame(_, let image) = content { image.data.count } else { 0 } }
}

@MainActor
final class DebugRecording {
    enum State: String { case running, finished, discarded }

    let id: String
    let settings: DebugRecordingSettings
    let startedAt: Date
    let endsAt: Date
    /// When it ends on the recorder's uptime clock.
    let deadline: TimeInterval
    /// Why it captures no frames, if it doesn't.
    let framesNote: String?
    var state = State.running
    var endedAt: Date?
    var endReason: String?
    private(set) var entries: [DebugRecordingEntry] = []
    /// What its entries hold, kept as they change.
    private(set) var storedBytes = 0
    var nextSequence = 0
    var ticks = 0
    /// Events since the last tick, with their bytes; they go into the next tick's entries.
    var pendingEvents: [WindowLifecycleEvent] = []
    var pendingEventBytes = 0
    var lastState: MCPJSON?
    var evictedFrames = 0
    var evictedSnapshots = 0
    var droppedEvents = 0
    var droppedFrames = 0
    var eventCount = 0
    /// Its deadline and expiry timers: cancelled when it ends.
    var cancelTimers: [@MainActor () -> Void] = []

    init(id: String, settings: DebugRecordingSettings, startedAt: Date, uptime: TimeInterval, framesNote: String?) {
        self.id = id
        self.settings = settings
        self.startedAt = startedAt
        endsAt = startedAt.addingTimeInterval(TimeInterval(settings.durationSeconds))
        deadline = uptime + TimeInterval(settings.durationSeconds)
        self.framesNote = framesNote
    }

    var capturesFrames: Bool { framesNote == nil }
    var frameCount: Int { entries.count { $0.isFrame } }
    /// Everything it holds, toward its memory limit.
    var bytes: Int { storedBytes + pendingEventBytes }

    func append(_ entry: DebugRecordingEntry) {
        entries.append(entry)
        storedBytes += entry.bytes
    }

    func replace(_ index: Int, with content: DebugRecordingEntry.Content, bytes: Int) {
        storedBytes += bytes - entries[index].bytes
        entries[index].content = content
        entries[index].bytes = bytes
    }

    /// Drops everything it holds, whoever else still has the object.
    func clear() {
        entries = []
        storedBytes = 0
        pendingEvents = []
        pendingEventBytes = 0
        lastState = nil
        for cancel in cancelTimers { cancel() }
        cancelTimers = []
    }
}

/// One debug recording at a time: for up to two minutes, every interval, a debug snapshot and, where allowed, a
/// frame of each display, and every window event between them. Kept in memory only, within `byteLimit`, counting
/// what it holds as fetch sends it: over it, the oldest frames go first, then the oldest states, then the oldest
/// events. Ending it in any way — stop, its last page fetched, ten minutes after it finished, Allow debug screenshots
/// turned off, a new recording — drops everything it holds at once, and a capture still under way is thrown away.
@MainActor
final class DebugRecorder {
    static let shared = DebugRecorder()
    static let maxEvents = 10_000
    /// A fetch page holds at most this much text and this many images and image bytes. Every entry fits a page
    /// alone: a frame larger than a page isn't kept, and events are kept in pieces of at most `eventChunkBytes`.
    static let pageTextBytes = 96 * 1024
    static let pageImages = 8
    static let pageImageBytes = 6 * 1024 * 1024
    static let eventChunkBytes = 16 * 1024

    var environment = DebugRecorderEnvironment()
    var byteLimit = 64 * 1024 * 1024

    private(set) var recording: DebugRecording?
    private(set) var lastDiscarded: (id: String, reason: String)?
    private var task: Task<Void, Never>?

    /// Starts a recording, replacing a finished one. One that's running must be stopped first.
    func start(_ settings: DebugRecordingSettings, refusesImages: Bool) -> Result<MCPJSON, MCPToolArgumentError> {
        if let recording, recording.state == .running {
            return .failure(MCPToolArgumentError(message: "Recording \(recording.id) is running until "
                + "\(debugRecordingTime(recording.endsAt)): stop it first, or wait for it to end."))
        }
        if let recording { release(recording, "a new recording replaced it") }
        let framesNote: String? = if !settings.frames {
            "Frames weren't asked for."
        } else if refusesImages {
            mcpScreenImagesRefusal
        } else if !debugScreenCapture.hasPermission() {
            debugScreenCapturePermissionMissing
        } else {
            nil
        }
        let recording = DebugRecording(id: String(UUID().uuidString.prefix(8)).lowercased(), settings: settings,
                                       startedAt: environment.now(), uptime: environment.uptime(), framesNote: framesNote)
        self.recording = recording
        WindowLifecycleLog.shared.observer = { [weak self] event in self?.note(event) }
        TrayMenuModel.shared.debugRecording = DebugRecordingIndicator(id: recording.id, endsAt: recording.endsAt)
        // Ends it on time even while a capture hangs.
        recording.cancelTimers.append(environment.after(.seconds(settings.durationSeconds)) { [weak self, weak recording] in
            guard let self, let recording, self.recording === recording, recording.state == .running else { return }
            finish(recording, reason: "it ran its \(recording.settings.durationSeconds) seconds")
        })
        task = Task { @MainActor [weak self] in await self?.run(recording) }
        return .success(status())
    }

    func status() -> MCPJSON {
        guard let recording else {
            var object: [String: MCPJSON] = ["state": .string("none")]
            if let lastDiscarded {
                object["lastDiscarded"] = .object(["id": .string(lastDiscarded.id), "reason": .string(lastDiscarded.reason)])
            }
            return .object(object)
        }
        var object: [String: MCPJSON] = [
            "id": .string(recording.id),
            "state": .string(recording.state.rawValue),
            "startedAt": .string(debugRecordingTime(recording.startedAt)),
            "endsAt": .string(debugRecordingTime(recording.endsAt)),
            "durationSeconds": .int(recording.settings.durationSeconds),
            "intervalMs": .int(recording.settings.intervalMs),
            "ticks": .int(recording.ticks),
            "entries": .int(recording.entries.count),
            "frames": .int(recording.frameCount),
            "events": .int(recording.eventCount),
            "bytes": .int(recording.bytes),
            "byteLimit": .int(byteLimit),
            "capturesFrames": .bool(recording.capturesFrames),
        ]
        if let note = recording.framesNote { object["framesNote"] = .string(note) }
        if let endedAt = recording.endedAt {
            object["endedAt"] = .string(debugRecordingTime(endedAt))
            object["discardsAt"] = .string(debugRecordingTime(endedAt.addingTimeInterval(TimeInterval(debugRecordingKeptAfterFinishing.components.seconds))))
        }
        if let reason = recording.endReason { object["endReason"] = .string(reason) }
        if recording.evictedFrames + recording.evictedSnapshots + recording.droppedEvents + recording.droppedFrames > 0 {
            object["truncated"] = .object([
                "evictedFrames": .int(recording.evictedFrames),
                "evictedSnapshots": .int(recording.evictedSnapshots),
                "droppedEvents": .int(recording.droppedEvents),
                "droppedFrames": .int(recording.droppedFrames),
            ])
        }
        return .object(object)
    }

    /// Ends the recording now and drops everything it holds.
    func stop(reason: String, id: String? = nil) -> Result<MCPJSON, MCPToolArgumentError> {
        guard let recording else { return .success(status()) }
        if let id, id != recording.id { return .failure(MCPToolArgumentError(message: "No recording \(id); the recording is \(recording.id).")) }
        release(recording, reason)
        return .success(status())
    }

    /// Allow debug screenshots or the server went off: nothing recorded is kept.
    func revoke(reason: String) {
        if let recording { release(recording, reason) }
    }

    /// The entries after `cursor`, a page at a time. The page that reaches the end of a finished recording drops it,
    /// unless frames were withheld from this request: then it stays for a request that may see them, until it
    /// expires. `refusesImages`: the page carries no frames, and says why. Pages are the same either way.
    func fetch(after cursor: Int?, id: String?, refusesImages: Bool) -> Result<MCPJSON, MCPToolArgumentError> {
        guard let recording else {
            return .failure(MCPToolArgumentError(message: "No recording to fetch."
                + (lastDiscarded.map { " Recording \($0.id) was discarded: \($0.reason)." } ?? "")))
        }
        if let id, id != recording.id { return .failure(MCPToolArgumentError(message: "No recording \(id); the recording is \(recording.id).")) }
        let remaining = recording.entries.filter { $0.sequence > (cursor ?? -1) }
        let withholdsFrames = refusesImages && remaining.contains(where: \.isFrame)
        func document(_ entries: [MCPJSON], next: Int?, complete: Bool) -> MCPJSON {
            var object: [String: MCPJSON] = [
                "schema": .string("winmux-debug-recording/2"),
                "recording": status(),
                "entries": .array(entries),
                "nextCursor": next.map(MCPJSON.int) ?? .null,
                "complete": .bool(complete),
            ]
            if withholdsFrames {
                object["framesOmitted"] = .string(mcpScreenImagesRefusal)
                if complete {
                    object["kept"] = .string("Its frames were withheld from this request, so it's kept for one that may see them "
                        + "until it expires or is stopped.")
                }
            } else if recording.frameCount > 0 {
                object["note"] = .string(debugScreenImagesNote)
            }
            return .object(object)
        }
        var described: [MCPJSON] = []
        var images: [MCPJSON] = []
        var frames = 0
        var imageBytes = 0
        var last: Int?
        // Room for the page's own fields, its cursor and closing note included, as the largest they can be.
        var textBytes = max(document([], next: Int.max, complete: false).encoded().count,
                            document([], next: nil, complete: true).encoded().count)
        for entry in remaining {
            var entryText = describe(entry, contentIndex: refusesImages ? nil : images.count + 1)
            var size = entryText.encoded().count + 1
            // No entry is ever larger than a page; should one be, it's skipped, so fetching always moves on.
            if described.isEmpty, textBytes + size > Self.pageTextBytes || entry.imageBytes > Self.pageImageBytes {
                entryText = .object(["sequence": .int(entry.sequence), "tick": .int(entry.tick), "kind": .string("omitted"),
                                     "omitted": .string("larger than a page")])
                size = entryText.encoded().count + 1
            }
            let sendsFrame = entry.isFrame && entryText["kind"] != .string("omitted")
            let entryImageBytes = sendsFrame ? entry.imageBytes : 0
            if textBytes + size > Self.pageTextBytes || frames + (sendsFrame ? 1 : 0) > Self.pageImages
                || imageBytes + entryImageBytes > Self.pageImageBytes { break }
            described.append(entryText)
            if case .frame(_, let image) = entry.content, !refusesImages, sendsFrame {
                images.append(debugImageContent(image))
            }
            frames += sendsFrame ? 1 : 0
            imageBytes += entryImageBytes
            textBytes += size
            last = entry.sequence
        }
        let reachedEnd = described.count == remaining.count
        let complete = recording.state == .finished && reachedEnd
        let page = document(described, next: complete ? nil : last ?? cursor ?? -1, complete: complete)
        if complete, !withholdsFrames { release(recording, "its last page was fetched") }
        return .success(.object(["content": .array([debugTextContent(page)] + images), "isError": .bool(false)]))
    }

    /// Waits for the running recording's task, for tests.
    func waitForRecording() async {
        await task?.value
    }

    // MARK: Recording

    private func isLive(_ recording: DebugRecording) -> Bool {
        self.recording === recording && recording.state == .running
    }

    private func run(_ recording: DebugRecording) async {
        let interval = TimeInterval(recording.settings.intervalMs) / 1000
        while isLive(recording), environment.uptime() < recording.deadline {
            let started = environment.uptime()
            await tick(recording)
            guard isLive(recording) else { return }
            let now = environment.uptime()
            let remaining = recording.deadline - now
            guard remaining > 0 else { break }
            let wait = min(max(0, interval - (now - started)), remaining)
            await environment.sleep(.milliseconds(Int((wait * 1000).rounded())))
        }
        guard isLive(recording) else { return }
        finish(recording, reason: "it ran its \(recording.settings.durationSeconds) seconds")
    }

    private func tick(_ recording: DebugRecording) async {
        let at = environment.now()
        var options = recording.settings.snapshot
        options.includesEvents = false
        // A state fits a fetch page with room to spare.
        options.byteLimit = Self.pageTextBytes - 8 * 1024
        var document = await environment.snapshot(options)
        // Ended or discarded meanwhile: nothing it read is kept.
        guard isLive(recording) else { return }
        if case .object(var object) = document {
            object.removeValue(forKey: "generatedAt")
            document = .object(object)
        }
        var frames: [(DebugCaptureDisplay, DebugCapturedImage)] = []
        var frameErrors: [(Int, String)] = []
        // No capture starts after the deadline, however long the snapshot took.
        if recording.capturesFrames, environment.uptime() < recording.deadline {
            let displays = debugCaptureDisplays(recording.settings.monitorId)
            let outcomes = await debugScreenCapture.capture(displays, maxLongEdge: recording.settings.maxLongEdge,
                                                            format: recording.settings.format)
            guard isLive(recording) else { return }
            for (display, outcome) in zip(displays, outcomes) {
                switch outcome {
                    case .image(let image) where image.data.count > Self.pageImageBytes:
                        recording.droppedFrames += 1
                        frameErrors.append((display.monitorId, "Not kept: \(image.data.count) bytes, more than a fetch page's "
                            + "\(Self.pageImageBytes). Use jpeg or a smaller max_long_edge."))
                    case .image(let image): frames.append((display, image))
                    case .failed(let message): frameErrors.append((display.monitorId, message))
                }
            }
        }
        store(recording, at: at, state: document, frames: frames, frameErrors: frameErrors)
    }

    /// Adds a tick's entries, making room first: the recording never holds more than `byteLimit`.
    private func store(_ recording: DebugRecording, at: Date, state: MCPJSON,
                       frames: [(DebugCaptureDisplay, DebugCapturedImage)], frameErrors: [(Int, String)]) {
        let tick = recording.ticks
        recording.ticks += 1
        var incoming: [DebugRecordingEntry.Content] = [state == recording.lastState ? .unchanged : .state(state)]
        incoming += eventChunks(recording.pendingEvents).map { .events($0) }
        // The pending events become entries: they're counted there now.
        recording.pendingEvents = []
        recording.pendingEventBytes = 0
        var kept = frames
        func size(_ contents: [DebugRecordingEntry.Content]) -> Int {
            contents.reduce(0) { $0 + entryBytes($1) }
        }
        let errors: [DebugRecordingEntry.Content] = frameErrors.map { .frameError(display: $0.0, message: $0.1) }
        var all = incoming + kept.map { .frame($0.0, $0.1) } + errors
        if !makeRoom(recording, for: size(all)) {
            // Even with everything older gone it doesn't fit: this tick's frames go first.
            recording.droppedFrames += kept.count
            let dropped = kept.map { DebugRecordingEntry.Content.frameError(display: $0.0.monitorId, message: "Not kept: the recording's memory is full.") }
            kept = []
            all = incoming + dropped + errors
            if !makeRoom(recording, for: size(all)) { all = all.map(evicted) }
        }
        if case .state = all.first { recording.lastState = state }
        if case .evicted = all.first { recording.lastState = nil }
        append(all, to: recording, tick: tick, at: at)
    }

    private func append(_ contents: [DebugRecordingEntry.Content], to recording: DebugRecording, tick: Int, at: Date) {
        for content in contents {
            recording.append(DebugRecordingEntry(sequence: recording.nextSequence, tick: tick, at: at, content: content,
                                                 bytes: entryBytes(content)))
            recording.nextSequence += 1
        }
    }

    /// Evicts until `incoming` more bytes fit: the oldest frames, then the oldest states with the unchanged entries that
    /// repeat them, then the oldest events. False if they don't fit even then.
    private func makeRoom(_ recording: DebugRecording, for incoming: Int) -> Bool {
        while recording.bytes + incoming > byteLimit {
            if let index = recording.entries.firstIndex(where: \.isFrame) {
                recording.evictedFrames += 1
                replaceWithEvicted(recording, index)
            } else if let index = recording.entries.firstIndex(where: { if case .state = $0.content { true } else { false } }) {
                recording.evictedSnapshots += 1
                replaceWithEvicted(recording, index)
                var next = index + 1
                while next < recording.entries.count {
                    switch recording.entries[next].content {
                        case .unchanged: replaceWithEvicted(recording, next)
                        case .state: next = recording.entries.count
                        default: break
                    }
                    next += 1
                }
                if !recording.entries.contains(where: { if case .state = $0.content { true } else { false } }) { recording.lastState = nil }
            } else if let index = recording.entries.firstIndex(where: { if case .events = $0.content { true } else { false } }) {
                if case .events(let events) = recording.entries[index].content { recording.droppedEvents += events.count }
                replaceWithEvicted(recording, index)
            } else if !recording.pendingEvents.isEmpty {
                let event = recording.pendingEvents.removeFirst()
                recording.pendingEventBytes -= debugSnapshotEvent(event).encoded().count
                recording.droppedEvents += 1
            } else {
                return false
            }
        }
        return true
    }

    private func replaceWithEvicted(_ recording: DebugRecording, _ index: Int) {
        let content = evicted(recording.entries[index].content)
        recording.replace(index, with: content, bytes: entryBytes(content))
    }

    private func evicted(_ content: DebugRecordingEntry.Content) -> DebugRecordingEntry.Content {
        switch content {
            case .state, .unchanged: .evicted("state")
            case .events(let events): .evicted("\(events.count) events")
            case .frame(let display, _): .evicted("frame of display \(display.monitorId)")
            case .frameError: .evicted("frame error")
            case .evicted: content
        }
    }

    /// Events in pieces no larger than `eventChunkBytes`, so each fits a page.
    private func eventChunks(_ events: [WindowLifecycleEvent]) -> [[WindowLifecycleEvent]] {
        var chunks: [[WindowLifecycleEvent]] = []
        var chunk: [WindowLifecycleEvent] = []
        var bytes = 0
        for event in events {
            let size = debugSnapshotEvent(event).encoded().count + 1
            if !chunk.isEmpty, bytes + size > Self.eventChunkBytes {
                chunks.append(chunk)
                chunk = []
                bytes = 0
            }
            chunk.append(event)
            bytes += size
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    private func note(_ event: WindowLifecycleEvent) {
        guard let recording, recording.state == .running else { return }
        guard recording.eventCount < Self.maxEvents else {
            recording.droppedEvents += 1
            return
        }
        let event = debugRecordingEvent(event)
        let size = debugSnapshotEvent(event).encoded().count
        guard makeRoom(recording, for: size) else {
            recording.droppedEvents += 1
            return
        }
        recording.pendingEvents.append(event)
        recording.pendingEventBytes += size
        recording.eventCount += 1
    }

    private func finish(_ recording: DebugRecording, reason: String) {
        recording.state = .finished
        recording.endedAt = environment.now()
        recording.endReason = reason
        // Events from after the last tick, still in the recording's time.
        if !recording.pendingEvents.isEmpty {
            var contents = eventChunks(recording.pendingEvents).map { DebugRecordingEntry.Content.events($0) }
            recording.pendingEvents = []
            recording.pendingEventBytes = 0
            if !makeRoom(recording, for: contents.reduce(0) { $0 + entryBytes($1) }) { contents = contents.map(evicted) }
            append(contents, to: recording, tick: max(0, recording.ticks - 1), at: environment.now())
        }
        for cancel in recording.cancelTimers { cancel() }
        recording.cancelTimers = [environment.after(debugRecordingKeptAfterFinishing) { [weak self, weak recording] in
            guard let self, let recording, self.recording === recording, recording.state == .finished else { return }
            release(recording, "it wasn't fetched within 10 minutes of ending")
        }]
        stopObserving()
    }

    /// The one way a recording ends for good: whatever ended it, everything it holds goes at once, its timers and task
    /// stop, and a capture still under way finds it discarded and keeps nothing.
    private func release(_ recording: DebugRecording, _ reason: String) {
        recording.state = .discarded
        recording.clear()
        guard self.recording === recording else { return }
        task?.cancel()
        task = nil
        self.recording = nil
        lastDiscarded = (recording.id, reason)
        stopObserving()
    }

    private func stopObserving() {
        WindowLifecycleLog.shared.observer = nil
        TrayMenuModel.shared.debugRecording = nil
    }

    private func entryBytes(_ content: DebugRecordingEntry.Content) -> Int {
        let image = if case .frame(_, let image) = content { image.data.count } else { 0 }
        return image + describe(DebugRecordingEntry(sequence: 0, tick: 0, at: Date(timeIntervalSince1970: 0), content: content),
                                contentIndex: nil).encoded().count
    }

    private func describe(_ entry: DebugRecordingEntry, contentIndex: Int?) -> MCPJSON {
        var object: [String: MCPJSON] = [
            "sequence": .int(entry.sequence),
            "tick": .int(entry.tick),
            "at": .string(debugRecordingTime(entry.at)),
        ]
        switch entry.content {
            case .state(let state):
                object["kind"] = .string("state")
                object["snapshot"] = state
            case .unchanged:
                object["kind"] = .string("state")
                object["snapshot"] = .string("unchanged")
            case .events(let events):
                object["kind"] = .string("events")
                object["events"] = .array(events.map(debugSnapshotEvent))
            case .frame(let display, let image):
                object["kind"] = .string("frame")
                if let contentIndex {
                    object["frame"] = debugCaptureDescription(display, .image(image), imageIndex: contentIndex)
                } else {
                    object["frame"] = .string("omitted")
                    object["display"] = .int(display.monitorId)
                }
            case .frameError(let display, let message):
                object["kind"] = .string("frameError")
                object["display"] = .int(display)
                object["error"] = .string(message)
            case .evicted(let what):
                object["kind"] = .string("evicted")
                object["evicted"] = .string(what)
        }
        return .object(object)
    }
}

/// An event as a recording keeps it: each detail value cut to `debugRecordingEventValueLimit` characters.
func debugRecordingEvent(_ event: WindowLifecycleEvent) -> WindowLifecycleEvent {
    let detail = event.detail.mapValues { value in
        value.count > debugRecordingEventValueLimit ? String(value.prefix(debugRecordingEventValueLimit)) + "…" : value
    }
    return WindowLifecycleEvent(at: event.at, kind: event.kind, windowId: event.windowId, detail: detail)
}

func debugRecordingTime(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}
