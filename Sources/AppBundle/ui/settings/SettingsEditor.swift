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
        try await save { text in
            edits.reduce(text) { text, edit in
                updateSettingsAppearanceConfig(in: text, section: edit.section, values: edit.values,
                    preservingDockAppearance: edit.preservingDockAppearance)
            }
        }
    }

    /// Saves `edit` applied to the file's current text, for changes a key/value edit can't express.
    func save(_ edit: (String) throws -> String) async throws -> SettingsFileUndo {
        let url = target()
        let before = try read(url)
        guard parseConfig(before).errors.isEmpty else {
            throw SettingsEditError("The configuration on disk contains errors. Open Advanced → TOML Editor to fix them before changing form settings. The file has not been changed.")
        }
        let after = try edit(before)
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
    enum PendingTabsSwitch: Equatable { case save, undo }
    /// The save awaiting confirmation. Its drafts apply only once confirmed, so the page
    /// keeps showing the running mode behind the question.
    private var pendingSave: Request?
    /// The held save's own drafts, set aside; newer edits of the same fields stay in the form.
    private var heldDrafts: [String: SettingsValue] = [:]
    private var heldUnset: Set<String> = []
    var hasWindowStacks: () -> Bool = { workspacesHaveWindowStacks() }
    @Published private(set) var isSaving = false
    @Published private(set) var error: String? {
        didSet {
            errorGeneration += 1
            if let error { reportError(error) }
        }
    }
    private var errorGeneration = 0
    @Published private(set) var undoTitle: String?
    @Published private(set) var status = "Changes save automatically"
    private let persistence: SettingsPersistence
    private var queue: [Request] = []
    private var worker: Task<Void, Never>?
    private var failedRequest: Request?
    private var history: [History] = []
    var canRetry: Bool { failedRequest != nil }
    var hasPendingDocument: Bool {
        failedRequest?.document != nil || pendingSave?.document != nil || queue.contains { $0.document != nil }
    }

    private struct Request {
        var title: String
        var fields: [SettingsField]
        var values: [String: SettingsValue]
        var edits: [SettingsFileEdit] = []
        var document: (text: String, expected: String, expectedURL: URL?)?
        var onSuccess: (() -> Void)?
        /// Fields restored by removing their key.
        var unsetting: Set<String> = []
        /// The user agreed that this save may turn on Tabs mode's panel.
        var tabsApproved = false
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
        enqueue(Request(title: field.title, fields: [field], values: [field.id: value]))
    }

    private func fileEdits(for request: Request) -> [SettingsFileEdit] {
        request.edits + request.fields.compactMap { field in
            guard field.writePreference == nil, let value = request.values[field.id] else { return nil }
            let rendered = request.unsetting.contains(field.id) ? settingsUnsetRenderedValue : field.render(value)
            return SettingsFileEdit(section: field.section, values: [field.key: rendered],
                preservingDockAppearance: field.preservingDockAppearance)
        }
    }

    /// Whether the file this save writes would turn on Tabs mode's panel, which the running app
    /// doesn't use, while window stacks exist. The save starts from the file on disk, which may
    /// hold changes the app hasn't loaded, so the check does too. Checked as each save is about
    /// to run, so queued, retried and TOML Editor saves ask as well.
    private func turnsOnTabs(_ request: Request) -> Bool {
        guard !request.tabsApproved, !configuration.usesBrowserTabs else { return false }
        let text: String
        if let document = request.document {
            text = document.text
        } else {
            let edits = fileEdits(for: request)
            guard !edits.isEmpty, let disk = try? persistence.read(persistence.target()) else { return false }
            text = edits.reduce(disk) { text, edit in
                updateSettingsAppearanceConfig(in: text, section: edit.section, values: edit.values,
                    preservingDockAppearance: edit.preservingDockAppearance)
            }
        }
        return parseConfig(text).config.usesBrowserTabs && hasWindowStacks()
    }

    /// Sets a save aside until the user answers. Its drafts leave the form meanwhile, so the page
    /// keeps showing the running mode behind the question; later saves wait behind it.
    private func hold(_ request: Request) {
        heldDrafts = [:]
        heldUnset = []
        for (id, value) in request.values where drafts[id] == value && request.unsetting.contains(id) == unsetDrafts.contains(id) {
            heldDrafts[id] = value
            if unsetDrafts.remove(id) != nil { heldUnset.insert(id) }
            drafts.removeValue(forKey: id)
        }
        pendingSave = request
        pendingTabsSwitch = .save
    }

    func confirmTabsSwitch() {
        guard let pending = pendingTabsSwitch else { return }
        pendingTabsSwitch = nil
        switch pending {
            case .save:
                guard var request = pendingSave else { return }
                pendingSave = nil
                request.tabsApproved = true
                for (id, value) in heldDrafts where drafts[id] == nil {
                    drafts[id] = value
                    if heldUnset.contains(id) { unsetDrafts.insert(id) }
                }
                heldDrafts = [:]
                heldUnset = []
                queue.insert(request, at: 0)
                startWorkerIfNeeded()
            case .undo: performUndo()
        }
    }

    /// Drops the save or Undo that asked. Saves queued behind it go ahead.
    func cancelTabsSwitch() {
        guard pendingTabsSwitch != nil else { return }
        pendingTabsSwitch = nil
        pendingSave = nil
        heldDrafts = [:]
        heldUnset = []
        startWorkerIfNeeded()
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
        cancelTabsSwitch()
        status = "Using the current configuration"
    }

    func undo() {
        guard !isSaving, failedRequest == nil, pendingTabsSwitch == nil, queue.isEmpty, let entry = history.last else { return }
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
        // A new edit supersedes an Undo still waiting for its answer, so no save queues behind it.
        if pendingTabsSwitch == .undo { cancelTabsSwitch() }
        // Do not write for draft synchronization or an unchanged control. A key restored by
        // removing it still has work to do while the file sets it.
        guard worker != nil || failedRequest != nil || pendingTabsSwitch != nil || !queue.isEmpty || request.fields.isEmpty
            || request.fields.contains(where: { request.values[$0.id] != $0.read(configuration) })
            || request.fields.contains(where: { request.unsetting.contains($0.id) && $0.isSet?(configuration) == true })
        else {
            for field in request.fields { drafts.removeValue(forKey: field.id); unsetDrafts.remove(field.id) }
            return
        }
        // Ask before the page moves on, when nothing is ahead of this save.
        if worker == nil, failedRequest == nil, pendingTabsSwitch == nil, queue.isEmpty, turnsOnTabs(request) { return hold(request) }
        queue.append(request)
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, failedRequest == nil, pendingTabsSwitch == nil, !queue.isEmpty else { return }
        isSaving = true
        worker = Task {
            while !queue.isEmpty {
                let request = queue.removeFirst()
                if turnsOnTabs(request) {
                    hold(request)
                    break
                }
                error = nil
                failedRequest = nil
                status = "Saving…"
                do {
                    let edits = fileEdits(for: request)
                    let preferences: [(field: SettingsField, before: SettingsValue, after: SettingsValue)] = request.fields.compactMap { field in
                        guard field.writePreference != nil, let value = request.values[field.id] else { return nil }
                        return (field, field.read(configuration), value)
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
                    failedRequest = request
                    self.error = error.localizedDescription
                    status = "Not saved"
                    // Keep later user edits queued until retry/revert resolves the failure.
                    break
                }
            }
            isSaving = false
            worker = nil
        }
    }

    private func reportError(_ body: String) {
        let generation = errorGeneration
        let available: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.errorGeneration == generation && self.error != nil && !self.isSaving
        }
        var actions: [MessageAction] = []
        if canRetry {
            actions.append(.init(title: "Retry", isAvailable: available, perform: { [weak self] in
                if available() { self?.retry() }
            }))
        }
        actions.append(.init(title: "Revert unsaved changes", isAvailable: available, perform: { [weak self] in
            guard let self, available() else { return }
            let revertDocument = self.hasPendingDocument
            self.revertDrafts()
            if revertDocument { ShortcutSettingsModel.shared.settingsDocument.loadFromDisk() }
        }))
        MessageModel.shared.message = Message(description: "Settings Error", body: body, actions: actions)
    }

    private func updateUndoTitle() { undoTitle = history.last.map { "Undo \($0.title)" } }
}
