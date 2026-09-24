import AppKit
import Common

private let savedWorkspacesFilename = "saved-workspaces.json"
private let savedWorkspacesBackupFilename = "saved-workspaces.previous.json"

/// Saved workspaces live in Application Support rather than the TOML config: the layout is a
/// tree, it changes often, and every TOML write triggers a full config reload.
@MainActor
final class SavedWorkspaceStore {
    private(set) var file: SavedWorkspacesFile
    /// nil keeps the store in memory only (unit tests).
    let url: URL?
    /// Set when the file came from a newer WinMux or when WinMux runs with --read-only.
    let readOnlyReason: String?
    let fileWasAbsentAtLoad: Bool
    private var indexByName: [String: Int] = [:]
    private var bundleIdsWithSlots: Set<String> = []
    private var lastWrittenData: Data?
    private var didBackUpThisSession = false
    private var writeTask: Task<Void, Never>?

    init(file: SavedWorkspacesFile = .init(), url: URL?, readOnlyReason: String? = nil, fileWasAbsentAtLoad: Bool = false) {
        self.file = file
        self.url = url
        self.readOnlyReason = readOnlyReason
        self.fileWasAbsentAtLoad = fileWasAbsentAtLoad
        rebuildIndexes()
        lastWrittenData = fileWasAbsentAtLoad ? nil : try? encodeSavedWorkspacesFile(self.file)
    }

    var isReadOnly: Bool { readOnlyReason != nil }
    var records: [SavedWorkspaceRecord] { file.workspaces }
    var isEmpty: Bool { file.workspaces.isEmpty }

    func record(named workspaceName: String) -> SavedWorkspaceRecord? {
        indexByName[workspaceName].map { file.workspaces[$0] }
    }

    func contains(workspaceName: String) -> Bool {
        indexByName[workspaceName] != nil
    }

    func hasSlots(bundleId: String) -> Bool {
        bundleIdsWithSlots.contains(bundleId)
    }

    @discardableResult
    func insert(_ record: SavedWorkspaceRecord) -> Bool {
        guard indexByName[record.workspaceName] == nil else { return false }
        file.workspaces.append(record)
        rebuildIndexes()
        return true
    }

    @discardableResult
    func update(named workspaceName: String, _ body: (inout SavedWorkspaceRecord) -> Void) -> Bool {
        guard let index = indexByName[workspaceName] else { return false }
        var record = file.workspaces[index]
        body(&record)
        guard record != file.workspaces[index] else { return false }
        check(record.workspaceName == workspaceName, "A saved workspace record can't change its workspace name")
        file.workspaces[index] = record
        rebuildIndexes()
        return true
    }

    @discardableResult
    func remove(named workspaceName: String) -> SavedWorkspaceRecord? {
        guard let index = indexByName[workspaceName] else { return nil }
        let removed = file.workspaces.remove(at: index)
        rebuildIndexes()
        return removed
    }

    /// Records follow the given order. Names the list doesn't mention keep their relative order
    /// and go last.
    func reorder(workspaceNamesInOrder names: [String]) {
        var positions: [String: Int] = [:]
        for (index, name) in names.enumerated() where positions[name] == nil {
            positions[name] = index
        }
        let reordered = file.workspaces.enumerated().sorted { lhs, rhs in
            let lhsPosition = positions[lhs.element.workspaceName] ?? Int.max
            let rhsPosition = positions[rhs.element.workspaceName] ?? Int.max
            return lhsPosition != rhsPosition ? lhsPosition < rhsPosition : lhs.offset < rhs.offset
        }.map(\.element)
        guard reordered != file.workspaces else { return }
        file.workspaces = reordered
        rebuildIndexes()
    }

    func takeVisibilitySequence() -> Int {
        defer { file.nextVisibilitySequence += 1 }
        return file.nextVisibilitySequence
    }

    /// Writes at most once per second. Explicit user actions call ``flushNow()`` instead.
    func scheduleWrite() {
        guard url != nil, !isReadOnly, writeTask == nil else { return }
        writeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            self.writeTask = nil
            self.flushNow()
        }
    }

    func flushNow() {
        writeTask?.cancel()
        writeTask = nil
        guard let url, !isReadOnly else { return }
        do {
            let data = try encodeSavedWorkspacesFile(file)
            guard data != lastWrittenData else { return }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !didBackUpThisSession, FileManager.default.fileExists(atPath: url.path) {
                let backupUrl = directory.appendingPathComponent(savedWorkspacesBackupFilename, isDirectory: false)
                try? FileManager.default.removeItem(at: backupUrl)
                try? FileManager.default.copyItem(at: url, to: backupUrl)
            }
            didBackUpThisSession = true
            try data.write(to: url, options: .atomic)
            lastWrittenData = data
        } catch {
            // Best effort, like window-state.json. The next change retries the write.
        }
    }

    /// Loads the file. A newer file is used read-only; an unreadable one is moved aside so it
    /// can never be overwritten.
    static func load(from url: URL, readOnlyReason: String? = nil) -> (store: SavedWorkspaceStore, notice: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (SavedWorkspaceStore(url: url, readOnlyReason: readOnlyReason, fileWasAbsentAtLoad: true), nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let reason = "WinMux couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            return (SavedWorkspaceStore(url: url, readOnlyReason: reason), reason)
        }
        // A newer WinMux may change the format in ways this build can't decode. Its file must
        // never be treated as corrupt and moved aside.
        let version = (try? JSONDecoder().decode(SavedWorkspacesFileVersionProbe.self, from: data))?.version
        if let version, version > savedWorkspacesFileVersion {
            let reason = "\(url.lastPathComponent) was written by a newer version of WinMux. Saved workspaces won't change until you update WinMux."
            let file = (try? JSONDecoder().decode(SavedWorkspacesFile.self, from: data)) ?? SavedWorkspacesFile()
            return (SavedWorkspaceStore(file: deduplicatedSavedWorkspacesFile(file), url: url, readOnlyReason: reason), reason)
        }
        let decoded: SavedWorkspacesFile
        do {
            decoded = try JSONDecoder().decode(SavedWorkspacesFile.self, from: data)
        } catch {
            let movedTo = moveCorruptSavedWorkspacesFileAside(url)
            let notice = "\(url.lastPathComponent) couldn't be read and was moved to \(movedTo ?? "a backup"). Saved workspaces start empty."
            return (SavedWorkspaceStore(url: url, readOnlyReason: readOnlyReason, fileWasAbsentAtLoad: true), notice)
        }
        var file = deduplicatedSavedWorkspacesFile(decoded)
        file.version = savedWorkspacesFileVersion
        return (SavedWorkspaceStore(file: file, url: url, readOnlyReason: readOnlyReason), nil)
    }

    private func rebuildIndexes() {
        indexByName = [:]
        bundleIdsWithSlots = []
        for (index, record) in file.workspaces.enumerated() {
            indexByName[record.workspaceName] = index
            for slot in record.layout.allSlots {
                bundleIdsWithSlots.insert(slot.bundleId)
            }
        }
    }
}

private struct SavedWorkspacesFileVersionProbe: Decodable {
    let version: Int?
}

/// The first record wins when two share a workspace name.
private func deduplicatedSavedWorkspacesFile(_ file: SavedWorkspacesFile) -> SavedWorkspacesFile {
    var result = file
    var seenNames: Set<String> = []
    result.workspaces = file.workspaces.filter { seenNames.insert($0.workspaceName).inserted }
    return result
}

func encodeSavedWorkspacesFile(_ file: SavedWorkspacesFile) throws -> Data {
    try JSONEncoder.winMuxDefault.encode(file)
}

private func moveCorruptSavedWorkspacesFileAside(_ url: URL) -> String? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let name = "saved-workspaces.corrupt-\(formatter.string(from: Date())).json"
    let destination = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    do {
        try FileManager.default.moveItem(at: url, to: destination)
        return name
    } catch {
        return nil
    }
}

@MainActor var savedWorkspaceStore = SavedWorkspaceStore(url: nil)

@MainActor
func savedWorkspacesFileUrl() throws -> URL {
    let appSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true,
    )
    let directory = appSupport.appendingPathComponent(winMuxAppName, isDirectory: true)
    return directory.appendingPathComponent(savedWorkspacesFilename, isDirectory: false)
}

@MainActor
func loadSavedWorkspaceStoreForStartup() {
    guard let url = try? savedWorkspacesFileUrl() else { return }
    let readOnlyReason = serverArgs.isReadOnly ? "WinMux is running with --read-only." : nil
    let (store, notice) = SavedWorkspaceStore.load(from: url, readOnlyReason: readOnlyReason)
    savedWorkspaceStore = store
    if let notice {
        Task { @MainActor in
            MessageModel.shared.message = Message(description: "Saved Workspaces", body: notice)
        }
    }
}
