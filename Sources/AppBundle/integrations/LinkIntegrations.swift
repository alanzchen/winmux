import AppKit
import Common
import CryptoKit

// The user's Hookmark-compatible integrations: one app's scripts each, added by pasting them or imported
// from a file of Hookmark integration records. Saved next to WinMux's other state. An integration is off
// until the user turns it on, having seen what it is and may do; changing its scripts turns it off again.
// WinMux ships none, downloads none, and never runs one on its own.

/// One app's integration scripts, in Hookmark's slots.
struct LinkIntegration: Codable, Hashable, Identifiable {
    var id: String
    var bundleId: String
    var appName: String
    /// Get Address: the address of the item in front.
    var getAddress: String
    /// Get Name: its name, when the address gives none.
    var getName: String?
    /// Open Item: opens an address, given as `$0`.
    var openItem: String?
    /// New Item: kept as given; WinMux has nothing that runs it.
    var newItem: String?
    /// The scheme of the addresses its Open Item opens.
    var scheme: String?
    /// Kept as imported: Hookmark's `scripting-method` and `urlConverter`.
    var scriptingMethod: String?
    var urlConverter: String?
    var source: LinkIntegrationSource
    var isEnabled = false
    /// The scripts' digest when the user turned it on. Other scripts aren't trusted: it's off again.
    var trustedDigest: String?
    var addedAt: Date
    /// When the user last changed its scripts in WinMux, if ever: it's no longer as it came.
    var editedAt: Date?

    init(id: String = UUID().uuidString, bundleId: String, appName: String, getAddress: String, getName: String? = nil,
         openItem: String? = nil, newItem: String? = nil, scheme: String? = nil, scriptingMethod: String? = nil,
         urlConverter: String? = nil, source: LinkIntegrationSource, addedAt: Date = Date()) {
        self.id = id
        self.bundleId = bundleId
        self.appName = appName
        self.getAddress = getAddress
        self.getName = getName.flatMap { $0.isEmpty ? nil : $0 }
        self.openItem = openItem.flatMap { $0.isEmpty ? nil : $0 }
        self.newItem = newItem.flatMap { $0.isEmpty ? nil : $0 }
        self.scheme = scheme.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        self.scriptingMethod = scriptingMethod
        self.urlConverter = urlConverter
        self.source = source
        self.addedAt = addedAt
    }

    /// What the user trusts when turning it on: the app, the name its scripts' `$$` stands for, and every
    /// script that runs.
    var digest: String {
        let parts = [bundleId, appName, getAddress, getName ?? "", openItem ?? "", scheme ?? ""]
        let data = Data(parts.joined(separator: "\u{1F}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// On, trusted as it is now.
    var isActive: Bool { isEnabled && trustedDigest == digest }

    var analysis: LinkIntegrationAnalysis { analyzeLinkIntegration(self) }
}

struct LinkIntegrationSource: Codable, Hashable {
    enum Kind: String, Codable { case pasted, imported }
    var kind: Kind
    /// The file it was imported from, by name, and that file's SHA-256 when imported.
    var fileName: String? = nil
    var fileDigest: String? = nil
    /// The record's key in that file.
    var recordKey: String? = nil

    var label: String {
        switch kind {
            case .pasted: "Added by pasting its scripts"
            case .imported: "Imported from “\(fileName ?? "a file")”" + (fileDigest.map { " (SHA-256 \($0.prefix(12))…)" } ?? "")
        }
    }
}

struct LinkIntegrationFile: Codable {
    static let currentVersion = 1
    var version = currentVersion
    var integrations: [LinkIntegration]
}

enum LinkIntegrationError: LocalizedError, Equatable {
    case readOnly(String)
    case notFound
    case duplicateApp(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
            case .readOnly(let reason): reason
            case .notFound: "That integration is gone."
            case .duplicateApp(let app): "\(app) already has an integration. Remove it first, or edit it."
            case .invalid(let reason): reason
        }
    }
}

/// Limits on what's added or imported: generous for real scripts, bounded for files that aren't.
let linkIntegrationScriptLimit = 256 * 1024
let linkIntegrationImportFileLimit = 4 * 1024 * 1024
let linkIntegrationImportRecordLimit = 500

enum LinkIntegrationOpener: Equatable {
    case none
    case one(LinkIntegration)
    /// More than one, by app name: none is chosen.
    case several([String])
}

/// The integrations, kept in `link-integrations.json`. A file it can't fully read is left as it is and
/// nothing is written over it.
@MainActor
final class LinkIntegrationStore: ObservableObject {
    @Published private(set) var integrations: [LinkIntegration]
    let url: URL?
    private(set) var readOnlyReason: String?

    init(integrations: [LinkIntegration] = [], url: URL? = nil, readOnlyReason: String? = nil) {
        self.integrations = integrations
        self.url = url
        self.readOnlyReason = readOnlyReason
    }

    static func load(url: URL, readOnly: Bool) -> LinkIntegrationStore {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LinkIntegrationStore(url: url, readOnlyReason: readOnly ? "WinMux is running with --read-only." : nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(LinkIntegrationFile.self, from: data)
            guard file.version <= LinkIntegrationFile.currentVersion else {
                return LinkIntegrationStore(integrations: file.integrations, url: url,
                    readOnlyReason: "A newer WinMux saved the integrations; this one doesn't change them.")
            }
            return LinkIntegrationStore(integrations: file.integrations, url: url,
                readOnlyReason: readOnly ? "WinMux is running with --read-only." : nil)
        } catch {
            return LinkIntegrationStore(url: url,
                readOnlyReason: "WinMux couldn't read \(url.lastPathComponent), so it changes nothing in it: \(error.localizedDescription)")
        }
    }

    func integration(id: String) -> LinkIntegration? { integrations.first { $0.id == id } }

    /// The integration for an app, if any: one per app.
    func integration(forBundleId bundleId: String?) -> LinkIntegration? {
        guard let bundleId else { return nil }
        return integrations.first { $0.bundleId == bundleId }
    }

    /// Which integration on now opens addresses of `scheme` with its Open Item.
    func opener(forScheme scheme: String) -> LinkIntegrationOpener {
        guard !linkIntegrationSchemeIsHookmarks(scheme) else { return .none }
        let openers = integrations.filter {
            $0.isActive && $0.analysis.canOpen && $0.scheme?.lowercased() == scheme.lowercased()
        }
        switch openers.count {
            case 0: return .none
            case 1: return .one(openers[0])
            default: return .several(openers.map(\.appName))
        }
    }

    /// Adds integrations, off. Fails, adding none, if one is for an app that already has one.
    func add(_ added: [LinkIntegration]) throws {
        if let readOnlyReason { throw LinkIntegrationError.readOnly(readOnlyReason) }
        var all = integrations
        for integration in added {
            if all.contains(where: { $0.bundleId == integration.bundleId }) {
                throw LinkIntegrationError.duplicateApp(integration.appName)
            }
            var off = integration
            off.isEnabled = false
            off.trustedDigest = nil
            all.append(off)
        }
        try save(all)
    }

    /// Replaces an integration's app or scripts, keeping whether it's on: changed scripts turn it off, until
    /// the user trusts them.
    func update(_ integration: LinkIntegration) throws {
        if let readOnlyReason { throw LinkIntegrationError.readOnly(readOnlyReason) }
        guard let index = integrations.firstIndex(where: { $0.id == integration.id }) else { throw LinkIntegrationError.notFound }
        if integrations.contains(where: { $0.id != integration.id && $0.bundleId == integration.bundleId }) {
            throw LinkIntegrationError.duplicateApp(integration.appName)
        }
        let current = integrations[index]
        var updated = integration
        updated.isEnabled = current.isEnabled
        updated.trustedDigest = current.trustedDigest
        if updated.digest != current.digest {
            updated.isEnabled = false
            updated.trustedDigest = nil
        }
        if updated != current { updated.editedAt = Date() }
        var all = integrations
        all[index] = updated
        try save(all)
    }

    /// Turns an integration on, trusting its scripts as they are, or off.
    func setEnabled(id: String, _ enabled: Bool, trustingDigest digest: String? = nil) throws {
        if let readOnlyReason { throw LinkIntegrationError.readOnly(readOnlyReason) }
        guard let index = integrations.firstIndex(where: { $0.id == id }) else { throw LinkIntegrationError.notFound }
        var all = integrations
        if enabled {
            guard let digest, digest == all[index].digest else {
                throw LinkIntegrationError.invalid("Its scripts changed while you looked at them. Look again, then turn it on.")
            }
            guard all[index].analysis.verdict != .unsupported else {
                throw LinkIntegrationError.invalid("WinMux can't run this integration.")
            }
            all[index].isEnabled = true
            all[index].trustedDigest = digest
        } else {
            all[index].isEnabled = false
            all[index].trustedDigest = nil
        }
        try save(all)
    }

    func remove(id: String) throws {
        if let readOnlyReason { throw LinkIntegrationError.readOnly(readOnlyReason) }
        guard integrations.contains(where: { $0.id == id }) else { throw LinkIntegrationError.notFound }
        try save(integrations.filter { $0.id != id })
    }

    private func save(_ all: [LinkIntegration]) throws {
        if let url {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(LinkIntegrationFile(integrations: all))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        }
        integrations = all
    }
}

@MainActor var linkIntegrationStore = LinkIntegrationStore()

@MainActor
func loadLinkIntegrations() {
    guard !isUnitTest, let savedURL = try? savedWorkspacesFileUrl() else { return }
    linkIntegrationStore = .load(url: savedURL.deletingLastPathComponent().appendingPathComponent("link-integrations.json"),
        readOnly: serverArgs.isReadOnly)
}

// MARK: - Adding

/// A script slot's text, checked before it's kept.
func linkIntegrationCheckScript(_ text: String?, slot: String) throws {
    guard let text else { return }
    guard text.utf8.count <= linkIntegrationScriptLimit else {
        throw LinkIntegrationError.invalid("\(slot) is longer than WinMux keeps (\(linkIntegrationScriptLimit / 1024) KB).")
    }
    guard !text.contains("\u{0}") else { throw LinkIntegrationError.invalid("\(slot) isn't text.") }
}

/// A scheme as Hookmark keeps it: letters, then letters, digits, `+`, `-` or `.`.
func linkIntegrationSchemeIsValid(_ scheme: String) -> Bool {
    scheme.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]{0,63}$"#, options: .regularExpression) != nil
}

/// Hookmark's own schemes: its links are Hookmark's to open, never an integration's.
func linkIntegrationSchemeIsHookmarks(_ scheme: String) -> Bool { ["hook", "hookmark"].contains(scheme.lowercased()) }

/// An integration typed or pasted, checked: an app and a Get Address script at least, within limits, with a
/// well-formed scheme if any.
func makePastedLinkIntegration(bundleId: String, appName: String, getAddress: String, getName: String?, openItem: String?,
                               newItem: String?, scheme: String?) throws -> LinkIntegration {
    let bundleId = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard linkIntegrationBundleIdIsValid(bundleId) else {
        throw LinkIntegrationError.invalid("Choose the app, or type its bundle identifier, such as com.example.App.")
    }
    guard !getAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw LinkIntegrationError.invalid("Paste its Get Address script: that's the one that takes a link.")
    }
    for (text, slot) in [(getAddress, "Get Address"), (getName, "Get Name"), (openItem, "Open Item"), (newItem, "New Item")] {
        try linkIntegrationCheckScript(text, slot: slot)
    }
    let scheme = scheme?.trimmingCharacters(in: .whitespaces)
    if let scheme, !scheme.isEmpty, !linkIntegrationSchemeIsValid(scheme) {
        throw LinkIntegrationError.invalid("A scheme is letters, then letters, digits, +, - or ., without :// — for example x-example.")
    }
    if let scheme, linkIntegrationSchemeIsHookmarks(scheme) {
        throw LinkIntegrationError.invalid("“\(scheme):” links are Hookmark's own, so no integration opens them in WinMux.")
    }
    let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
    return LinkIntegration(bundleId: bundleId, appName: name.isEmpty ? bundleId : String(name.prefix(100)),
        getAddress: getAddress, getName: getName, openItem: openItem, newItem: newItem, scheme: scheme,
        source: .init(kind: .pasted))
}

func linkIntegrationBundleIdIsValid(_ bundleId: String) -> Bool {
    bundleId.count <= 255 && bundleId.range(of: #"^[A-Za-z0-9][A-Za-z0-9\-]*(\.[A-Za-z0-9\-]+)+$"#, options: .regularExpression) != nil
}

// MARK: - Importing Hookmark integration records

/// What an import found: integrations to add, and records left out, each with why.
struct LinkIntegrationImport: Equatable {
    var integrations: [LinkIntegration]
    var skipped: [Skipped]

    struct Skipped: Equatable {
        let key: String
        let reason: String
    }
}

/// Integration records in Hookmark's format, from a property list: a `scripts` dictionary of records by
/// bundle identifier, or such records at the top. A record has its app's `name`, its Get Address as `url`,
/// and optionally `title` (Get Name), `open` (Open Item), `new` (New Item), `scheme`, `scripting-method` and
/// `urlConverter`. Every record is checked; none is run. The file is the user's, chosen by them.
func importHookmarkIntegrations(_ data: Data, fileName: String, existingBundleIds: Set<String> = []) throws -> LinkIntegrationImport {
    guard data.count <= linkIntegrationImportFileLimit else {
        throw LinkIntegrationError.invalid("“\(fileName)” is larger than an integrations file WinMux reads (4 MB).")
    }
    let object: Any
    do {
        object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    } catch {
        throw LinkIntegrationError.invalid("“\(fileName)” isn't a property list of Hookmark integration records.")
    }
    guard let top = object as? [String: Any] else {
        throw LinkIntegrationError.invalid("“\(fileName)” isn't a dictionary of Hookmark integration records.")
    }
    let records: [String: Any]
    if let scripts = top["scripts"] as? [String: Any] {
        records = scripts
    } else {
        records = top.filter { ($0.value as? [String: Any])?["url"] != nil }
    }
    guard !records.isEmpty else {
        throw LinkIntegrationError.invalid("“\(fileName)” has no Hookmark integration records: none has a Get Address (url) script.")
    }
    guard records.count <= linkIntegrationImportRecordLimit else {
        throw LinkIntegrationError.invalid("“\(fileName)” has more records than WinMux imports at once (\(linkIntegrationImportRecordLimit)).")
    }
    let fileDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    var imported: [LinkIntegration] = []
    var skipped: [LinkIntegrationImport.Skipped] = []
    var seen = existingBundleIds
    for key in records.keys.sorted() {
        guard let record = records[key] as? [String: Any] else {
            skipped.append(.init(key: key, reason: "It isn't an integration record."))
            continue
        }
        if key == "com.csa.mymeta.default" {
            skipped.append(.init(key: key, reason: "It's Hookmark's script for apps without one, which WinMux doesn't take."))
            continue
        }
        guard linkIntegrationBundleIdIsValid(key) else {
            skipped.append(.init(key: key, reason: "Its key isn't an app's bundle identifier."))
            continue
        }
        guard let getAddress = record["url"] as? String, !getAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            skipped.append(.init(key: key, reason: "It has no Get Address (url) script."))
            continue
        }
        guard !seen.contains(key) else {
            skipped.append(.init(key: key, reason: "That app already has an integration. Remove it first to import this one."))
            continue
        }
        func text(_ field: String) -> String? { (record[field] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let scheme = text("scheme")?.trimmingCharacters(in: .whitespaces)
        if let scheme, !linkIntegrationSchemeIsValid(scheme) {
            skipped.append(.init(key: key, reason: "Its scheme “\(scheme.prefix(40))” isn't a URL scheme."))
            continue
        }
        if let scheme, linkIntegrationSchemeIsHookmarks(scheme) {
            skipped.append(.init(key: key, reason: "It opens Hookmark's own “\(scheme):” links, which stay Hookmark's."))
            continue
        }
        do {
            for (field, slot) in [("url", "Get Address"), ("title", "Get Name"), ("open", "Open Item"), ("new", "New Item")] {
                try linkIntegrationCheckScript(text(field), slot: slot)
            }
        } catch {
            skipped.append(.init(key: key, reason: error.localizedDescription))
            continue
        }
        let name = text("name").map { String($0.prefix(100)) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: key).map { FileManager.default.displayName(atPath: $0.path) }
            ?? key
        imported.append(LinkIntegration(bundleId: key, appName: name.replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards]),
            getAddress: getAddress, getName: text("title"), openItem: text("open"), newItem: text("new"), scheme: scheme,
            scriptingMethod: text("scripting-method"), urlConverter: text("urlConverter"),
            source: .init(kind: .imported, fileName: fileName, fileDigest: fileDigest, recordKey: key)))
        seen.insert(key)
    }
    return LinkIntegrationImport(integrations: imported, skipped: skipped)
}
