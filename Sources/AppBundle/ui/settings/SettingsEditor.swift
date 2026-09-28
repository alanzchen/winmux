import AppKit
import SwiftUI

let settingsConfigurationDidReload = Notification.Name("WinMux.settingsConfigurationDidReload")

enum SettingsValue: Equatable {
    case bool(Bool), integer(Int), number(Double), text(String)

    var bool: Bool { if case .bool(let value) = self { return value }; return false }
    var integer: Int { if case .integer(let value) = self { return value }; return 0 }
    var number: Double { if case .number(let value) = self { return value }; return Double(integer) }
    var text: String { if case .text(let value) = self { return value }; return "" }
    var toml: String {
        switch self {
            case .bool(let value): return value ? "true" : "false"
            case .integer(let value): return String(value)
            case .number(let value): return String(value)
            case .text(let value):
                // JSON basic strings are valid TOML basic strings for these scalar settings.
                let encoder = JSONEncoder()
                encoder.outputFormatting = .withoutEscapingSlashes
                return String(data: try! encoder.encode(value), encoding: .utf8)!
        }
    }
}

struct SettingsFileEdit {
    var section: String?
    var values: [String: String]
    var preservingDockAppearance = false
}

struct SettingsFileUndo {
    let url: URL
    let before: String
    let after: String
}

/// All form writes pass through the editor's serial queue. Read the current file
/// for each transaction, including retry/reset, so unrelated TOML edits survive.
@MainActor
struct SettingsPersistence {
    var target: () -> URL = { preferredEditableConfigUrl() }
    var read: (URL) throws -> String = { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return starterConfigText() }
        return try String(contentsOf: url, encoding: .utf8)
    }
    var write: (URL, String) throws -> Void = { url, text in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    var reload: (URL) async throws -> Bool = { try await reloadConfig(forceConfigUrl: $0) }

    func save(_ edits: [SettingsFileEdit]) async throws -> SettingsFileUndo {
        let url = target()
        let before = try read(url)
        guard parseConfig(before).errors.isEmpty else {
            throw SettingsEditError("The configuration on disk contains errors. Open Advanced → TOML Editor to fix them before changing form settings. The file has not been changed.")
        }
        let after = edits.reduce(before) { text, edit in
            updateSettingsAppearanceConfig(in: text, section: edit.section, values: edit.values,
                preservingDockAppearance: edit.preservingDockAppearance)
        }
        try await apply(after, replacing: before, at: url)
        return SettingsFileUndo(url: url, before: before, after: after)
    }

    func undo(_ record: SettingsFileUndo) async throws {
        guard target() == record.url, try read(record.url) == record.after else {
            throw SettingsEditError("The configuration changed after this edit. Undo history was cleared to preserve those changes.", invalidatesUndo: true)
        }
        try await apply(record.before, replacing: record.after, at: record.url)
    }

    func saveDocument(_ text: String, expected: String, expectedURL: URL? = nil) async throws -> SettingsFileUndo {
        let url = target()
        guard expectedURL == nil || expectedURL == url else {
            throw SettingsEditError("The active configuration file changed. Reload from disk before saving this document.")
        }
        guard try read(url) == expected else {
            throw SettingsEditError("The configuration changed since you loaded it. Reload from disk before saving to preserve those changes.")
        }
        try await apply(text, replacing: expected, at: url)
        return SettingsFileUndo(url: url, before: expected, after: text)
    }

    private func apply(_ text: String, replacing before: String, at url: URL) async throws {
        let errors = parseConfig(text).errors
        guard errors.isEmpty else {
            throw SettingsEditError("This edit could not be applied to the current TOML. Open Advanced → TOML Editor to resolve these errors:\n" + errors.map(\.description).joined(separator: "\n"))
        }
        try write(url, text)
        do {
            guard try await reload(url) else { throw SettingsEditError("The setting could not be applied.") }
        } catch {
            // Never roll back over a file changed by another editor during reload.
            if (try? read(url)) == text {
                do {
                    try write(url, before)
                    guard try await reload(url) else { throw SettingsEditError("The previous configuration could not be reloaded.") }
                } catch let rollbackError {
                    throw SettingsEditError("\(error.localizedDescription) Recovery also failed: \(rollbackError.localizedDescription)")
                }
            }
            throw error
        }
    }
}

struct SettingsEditError: LocalizedError {
    let errorDescription: String?
    var invalidatesUndo = false
    init(_ message: String, invalidatesUndo: Bool = false) {
        errorDescription = message; self.invalidatesUndo = invalidatesUndo
    }
}

@MainActor
final class SettingsEditor: ObservableObject {
    @Published private(set) var configuration: Config { didSet { updateProjection() } }
    @Published private(set) var drafts: [String: SettingsValue] = [:] { didSet { updateProjection() } }
    /// Drafts restored by removing their key; their value follows the projection.
    @Published private(set) var unsetDrafts: Set<String> = [] { didSet { updateProjection() } }
    /// The configuration with unsaved drafts applied, for availability and the preview.
    private(set) var projection: Config
    /// Turning on Tabs mode's panel moves window stack entries into separate workspaces,
    /// which Undo can't rebuild. Such a change waits here until the user confirms it.
    @Published private(set) var pendingTabsSwitch: PendingTabsSwitch?
    enum PendingTabsSwitch: Equatable { case commit(String), undo }
    var hasWindowStacks: () -> Bool = { workspacesHaveWindowStacks() }
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?
    @Published private(set) var undoTitle: String?
    @Published private(set) var status = "Changes save automatically"
    private let persistence: SettingsPersistence
    private var queue: [Request] = []
    private var worker: Task<Void, Never>?
    private var failedRequest: Request?
    private var history: [History] = []
    var canRetry: Bool { failedRequest != nil }
    var hasPendingDocument: Bool { failedRequest?.document != nil || queue.contains { $0.document != nil } }

    private struct Request {
        var title: String
        var fields: [SettingsField]
        var values: [String: SettingsValue]
        var edits: [SettingsFileEdit] = []
        var document: (text: String, expected: String, expectedURL: URL?)?
        var onSuccess: (() -> Void)?
        /// Fields restored by removing their key.
        var unsetting: Set<String> = []
    }
    private struct History {
        var title: String
        var file: SettingsFileUndo?
        var preferences: [(field: SettingsField, before: SettingsValue, after: SettingsValue)]
    }

    init(configuration: Config? = nil, persistence: SettingsPersistence = .init()) {
        let configuration = configuration ?? config
        self.configuration = configuration
        projection = configuration
        self.persistence = persistence
    }

    private func updateProjection() { projection = SettingsProjection.apply(drafts, unsetting: unsetDrafts, to: configuration) }

    /// An undrafted value comes from the projection, so a default that depends on another
    /// drafted setting shows what the running app would do.
    func value(_ field: SettingsField) -> SettingsValue {
        unsetDrafts.contains(field.id) ? field.read(projection) : drafts[field.id] ?? field.read(projection)
    }

    func setDraft(_ value: SettingsValue, for field: SettingsField) {
        drafts[field.id] = value
        unsetDrafts.remove(field.id)
    }

    func commit(_ field: SettingsField) {
        guard let value = drafts[field.id] else { return }
        if turnsOnTabs(field.id) {
            pendingTabsSwitch = .commit(field.id)
            return
        }
        enqueue(Request(title: field.title, fields: [field], values: [field.id: value]))
    }

    private func turnsOnTabs(_ id: String) -> Bool {
        var others = drafts
        others.removeValue(forKey: id)
        let before = SettingsProjection.apply(others, unsetting: unsetDrafts, to: configuration)
        return !before.usesBrowserTabs && projection.usesBrowserTabs && hasWindowStacks()
    }

    func confirmTabsSwitch() {
        guard let pending = pendingTabsSwitch else { return }
        pendingTabsSwitch = nil
        switch pending {
            case .commit(let id):
                let field = SettingsCatalog.field(id)
                if let value = drafts[id] { enqueue(Request(title: field.title, fields: [field], values: [id: value])) }
            case .undo: performUndo()
        }
    }

    func cancelTabsSwitch() {
        guard let pending = pendingTabsSwitch else { return }
        pendingTabsSwitch = nil
        if case .commit(let id) = pending { drafts.removeValue(forKey: id) }
    }

    func reset(_ group: SettingsGroup) {
        reset(SettingsCatalog.fields.filter { $0.group == group }, title: group.title)
    }

    /// Restores `fields`, one Undo entry. A Workspace Panel section passes only its own rows,
    /// so settings other modes use elsewhere keep their values.
    func reset(_ fields: [SettingsField], title: String) {
        let fields = fields.filter { $0.key != "persistent-workspaces" || configuration.configVersion >= 2 }
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.defaultValue(for: projection)) })
        let unsetting = Set(fields.filter { $0.unsetValue != nil }.map(\.id))
        drafts.merge(values) { _, next in next }
        unsetDrafts.formUnion(unsetting)
        enqueue(Request(title: "Restore \(title)", fields: fields, values: values, unsetting: unsetting))
    }

    func saveRaw(_ edits: [SettingsFileEdit], title: String) {
        enqueue(Request(title: title, fields: [], values: [:], edits: edits))
    }

    func saveDocument(_ text: String, expected: String, expectedURL: URL? = nil, onSuccess: (() -> Void)? = nil) {
        enqueue(Request(title: "TOML edit", fields: [], values: [:], document: (text, expected, expectedURL), onSuccess: onSuccess))
    }

    func synchronize(_ next: Config) { configuration = next }

    func retry() {
        guard let failedRequest, !isSaving else { return }
        self.failedRequest = nil
        error = nil
        queue.insert(failedRequest, at: 0)
        startWorkerIfNeeded()
    }

    func revertDrafts() {
        guard !isSaving else { return }
        drafts = [:]
        unsetDrafts = []
        queue = []
        error = nil
        failedRequest = nil
        status = "Using the current configuration"
    }

    func undo() {
        guard !isSaving, failedRequest == nil, queue.isEmpty, let entry = history.last else { return }
        if let file = entry.file, !configuration.usesBrowserTabs, parseConfig(file.before).config.usesBrowserTabs, hasWindowStacks() {
            pendingTabsSwitch = .undo
            return
        }
        performUndo()
    }

    private func performUndo() {
        guard !isSaving, failedRequest == nil, queue.isEmpty, let entry = history.last else { return }
        isSaving = true
        error = nil
        worker = Task {
            do {
                for change in entry.preferences where change.field.read(configuration) != change.after {
                    throw SettingsEditError("\(change.field.title) changed after this edit. Undo history was cleared to preserve that change.", invalidatesUndo: true)
                }
                if let file = entry.file { try await persistence.undo(file) }
                for change in entry.preferences { change.field.writePreference?(change.before) }
                history.removeLast()
                drafts = [:]
                unsetDrafts = []
                configuration = config
                failedRequest = nil
                status = "Undid \(entry.title)"
                updateUndoTitle()
            } catch {
                self.error = error.localizedDescription
                if (error as? SettingsEditError)?.invalidatesUndo == true { history = []; updateUndoTitle() }
            }
            isSaving = false
            worker = nil
            startWorkerIfNeeded()
        }
    }

    func waitUntilIdle() async { while let worker { await worker.value } }

    private func enqueue(_ request: Request) {
        // Do not write for draft synchronization or an unchanged control. A key restored by
        // removing it still has work to do while the file sets it.
        guard worker != nil || failedRequest != nil || !queue.isEmpty || request.fields.isEmpty
            || request.fields.contains(where: { request.values[$0.id] != $0.read(configuration) })
            || request.fields.contains(where: { request.unsetting.contains($0.id) && $0.isSet?(configuration) == true })
        else {
            for field in request.fields { drafts.removeValue(forKey: field.id); unsetDrafts.remove(field.id) }
            return
        }
        queue.append(request)
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, failedRequest == nil, !queue.isEmpty else { return }
        isSaving = true
        worker = Task {
            while !queue.isEmpty {
                let request = queue.removeFirst()
                error = nil
                failedRequest = nil
                status = "Saving…"
                do {
                    var edits = request.edits
                    var preferences: [(field: SettingsField, before: SettingsValue, after: SettingsValue)] = []
                    for field in request.fields {
                        guard let value = request.values[field.id] else { continue }
                        if field.writePreference != nil {
                            preferences.append((field, field.read(configuration), value))
                        } else {
                            let rendered = request.unsetting.contains(field.id) ? settingsUnsetRenderedValue : field.render(value)
                            edits.append(SettingsFileEdit(section: field.section, values: [field.key: rendered],
                                preservingDockAppearance: field.preservingDockAppearance))
                        }
                    }
                    let file: SettingsFileUndo?
                    if let document = request.document {
                        file = try await persistence.saveDocument(document.text, expected: document.expected, expectedURL: document.expectedURL)
                    } else { file = edits.isEmpty ? nil : try await persistence.save(edits) }
                    for change in preferences { change.field.writePreference?(change.after) }
                    if let file, !parseConfig(file.before).errors.isEmpty {
                        // The raw editor may repair an invalid file; restoring it
                        // cannot be a valid, applied Undo transaction.
                        history = []
                    } else if file?.before != file?.after || !preferences.isEmpty {
                        history.append(History(title: request.title, file: file, preferences: preferences))
                        if history.count > 30 { history.removeFirst() }
                    }
                    configuration = config
                    // A newer edit may have the same value but not the same intent: explicit
                    // false and "unset, currently false" save differently.
                    for (id, value) in request.values where drafts[id] == value && request.unsetting.contains(id) == unsetDrafts.contains(id) {
                        drafts.removeValue(forKey: id)
                        unsetDrafts.remove(id)
                    }
                    status = "Saved"
                    updateUndoTitle()
                    request.onSuccess?()
                } catch {
                    self.error = error.localizedDescription
                    failedRequest = request
                    status = "Not saved"
                    // Keep later user edits queued until retry/revert resolves the failure.
                    break
                }
            }
            isSaving = false
            worker = nil
        }
    }

    private func updateUndoTitle() { undoTitle = history.last.map { "Undo \($0.title)" } }
}
