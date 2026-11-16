import Foundation

/// A key in a config file, one component per TOML key: `["workspace-sidebar", "workspace-labels", "1"]`.
typealias ConfigKeyPath = [String]

struct ConfigEditRefused: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The one way WinMux edits a config file's text. The loader must read `after` without adding an error `before`
/// didn't have. When the edit names the keys it changes (`changing`), every other key must keep its value, as the
/// loader reads both texts. Then `replaceConfigFileOnDisk` writes it. nil means the whole document is the edit (the
/// TOML Editor, undo).
@MainActor
func writeConfigFile(_ after: String, replacing before: String, at url: URL, changing: [ConfigKeyPath]?) throws {
    try validateConfigEdit(before: before, after: after, changing: changing)
    try replaceConfigFileOnDisk(after, at: url)
}

/// The only code that puts config text on disk (`writeConfigFile`, `SettingsPersistence`, first-launch files). A config
/// symlinked into a dotfiles repository stays a symlink: the chain is followed to the real file, which is replaced
/// atomically, keeping its permissions and extended attributes.
func replaceConfigFileOnDisk(_ text: String, at url: URL) throws {
    let fileManager = FileManager.default
    let target = try configFileTarget(url)
    let parent = target.deletingLastPathComponent()
    if parent.path != target.path { try fileManager.createDirectory(at: parent, withIntermediateDirectories: true) }
    guard fileManager.fileExists(atPath: target.path) else {
        try text.write(to: target, atomically: true, encoding: .utf8)
        return
    }
    // An existing file is replaced with `replaceItemAt`, which keeps the original's metadata: permissions and extended
    // attributes (Astra S2 nit; a plain atomic write dropped the attributes). The new text is staged on the same volume.
    let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
    defer { try? fileManager.removeItem(at: staging) }
    let staged = staging.appending(path: target.lastPathComponent)
    try text.write(to: staged, atomically: false, encoding: .utf8)
    _ = try fileManager.replaceItemAt(target, withItemAt: staged)
}

/// `url` with its symlink chain followed, one link at a time: relative destinations are relative to the link's own
/// directory and are left for the file system to resolve, so a link inside a symlinked directory resolves as the OS
/// resolves it. A dangling chain gives the path the last link names, which writing then creates.
func configFileTarget(_ url: URL) throws -> URL {
    var path = url.path
    for _ in 0 ..< 32 {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return URL(fileURLWithPath: path)
        }
        path = destination.hasPrefix("/") ? destination : (path as NSString).deletingLastPathComponent + "/" + destination
    }
    throw ConfigEditRefused("WinMux didn't save this change: \(url.path.singleQuoted) is a symlink loop.")
}

@MainActor
func validateConfigEdit(before: String, after: String, changing: [ConfigKeyPath]?) throws {
    let beforeErrors = Set(parseConfig(before).errors.map { $0.description(.error) })
    let added = parseConfig(after).errors.map { $0.description(.error) }.filter { !beforeErrors.contains($0) }
    guard added.isEmpty else {
        throw ConfigEditRefused("WinMux didn't save this change: the configuration would no longer load.\n"
            + added.joined(separator: "\n"))
    }
    if let changing { try checkConfigEditKeepsOtherKeys(before: before, after: after, changing: changing) }
}

/// Refuses an edit that changes, adds or removes any key outside `changing` (a key under a listed path counts as inside).
/// An empty table may also appear or go at a listed path's ancestor: removing a table's last key removes its header.
func checkConfigEditKeepsOtherKeys(before: String, after: String, changing: [ConfigKeyPath]) throws {
    guard let old = configLeaves(before), let new = configLeaves(after) else {
        throw ConfigEditRefused("WinMux didn't save this change: it couldn't read the configuration to check the edit. "
            + "Fix it in Advanced → TOML Editor.")
    }
    func allowed(_ path: ConfigKeyPath) -> Bool {
        changing.contains { path.starts(with: $0) } ||
            (old[path] ?? new[path]) == .dict([:]) && changing.contains { $0.starts(with: path) }
    }
    let touched = Set(old.keys).union(new.keys).filter { path in old[path] != new[path] && !allowed(path) }
    if let first = touched.sorted(by: { $0.joined(separator: ".") < $1.joined(separator: ".") }).first {
        throw ConfigEditRefused("WinMux didn't save this change: it would also have changed "
            + "\(first.joined(separator: ".").singleQuoted). Edit the file in Advanced → TOML Editor.")
    }
}

/// Every value the loader reads from `text`, by key path. Tables are walked; arrays and scalars are values, and so is an
/// empty table: its presence can matter (an empty `[exec]` changes `PATH`, an empty `[mode.service]` defines a mode).
/// nil when the text doesn't parse.
func configLeaves(_ text: String) -> [ConfigKeyPath: OrderedJson]? {
    var conversionErrors: [ConfigParseDiagnostic] = []
    guard let table = try? WinMuxToml.table(text),
          let json = tomlAnyToOrderedJsonRecursive(any: table, .emptyRoot, &conversionErrors),
          conversionErrors.isEmpty
    else { return nil }
    var leaves: [ConfigKeyPath: OrderedJson] = [:]
    func walk(_ value: OrderedJson, _ path: ConfigKeyPath) {
        if case .dict(let dict) = value, !dict.isEmpty || path.isEmpty {
            for (key, child) in dict { walk(child, path + [key]) }
        } else {
            leaves[path] = value
        }
    }
    walk(json, [])
    return leaves
}
