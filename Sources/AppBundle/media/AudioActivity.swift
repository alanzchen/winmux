import AppKit
import CoreAudio

/// One process Core Audio knows about: whether it is playing sound, and which app it plays for.
struct AudioProcessSample: Equatable {
    let pid: pid_t
    let isRunningOutput: Bool
    /// The app responsible for the process, such as a browser for its media helper.
    let responsiblePid: pid_t?
}

/// The apps playing sound. A helper that plays for an app, such as a browser's media process,
/// counts for that app. WinMux itself never counts.
func audioPlayingAppPids(_ samples: [AudioProcessSample], ownPid: pid_t = getpid()) -> Set<pid_t> {
    Set(samples.lazy.filter(\.isRunningOutput).map { sample in
        sample.responsiblePid.flatMap { $0 > 0 ? $0 : nil } ?? sample.pid
    }.filter { $0 > 0 && $0 != ownPid })
}

private typealias ResponsiblePidFunction = @convention(c) (pid_t) -> pid_t

/// Private but stable since macOS 10.14; without it a helper counts only for itself.
private let responsiblePidFunction: ResponsiblePidFunction? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
    "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: ResponsiblePidFunction.self) }

private func audioObjectValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr
    } ? value : nil
}

/// Core Audio's per-process state, which needs no permission to read. It exists on macOS 14.2
/// and later; earlier systems report nothing playing.
nonisolated func readAudioProcessSamples() -> [AudioProcessSample] {
    guard #available(macOS 14.2, *) else { return [] }
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
    return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { object in
        guard let pid = audioObjectValue(object, kAudioProcessPropertyPID, pid_t(0)), pid > 0 else { return nil }
        let isRunning = audioObjectValue(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0
        return AudioProcessSample(pid: pid, isRunningOutput: isRunning != 0,
            responsiblePid: isRunning != 0 ? responsiblePidFunction?(pid) : nil)
    }
}

/// Which apps are playing sound, by bundle identifier, so a tab can show a speaker.
@MainActor
final class AudioActivityModel: ObservableObject {
    static let shared = AudioActivityModel()
    @Published private(set) var playingBundleIds: Set<String> = []
    private var pollingTask: Task<Void, Never>?
    private let read: @Sendable () async -> Set<pid_t>

    init(read: @escaping @Sendable () async -> Set<pid_t> = {
        await Task.detached(priority: .utility) { audioPlayingAppPids(readAudioProcessSamples()) }.value
    }) {
        self.read = read
    }

    func isPlaying(bundleId: String?) -> Bool {
        bundleId.map(playingBundleIds.contains) ?? false
    }

    func setPlaying(_ bundleIds: Set<String>) {
        if playingBundleIds != bundleIds { playingBundleIds = bundleIds }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            pollingTask?.cancel()
            pollingTask = nil
            setPlaying([])
            return
        }
        guard pollingTask == nil else { return }
        let read = read
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let pids = await read()
                guard !Task.isCancelled, let self else { return }
                self.setPlaying(Set(pids.compactMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }))
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            }
        }
    }
}
