import Foundation

/// A key in a config file, one component per TOML key: `["workspace-sidebar", "workspace-labels", "1"]`.
typealias ConfigKeyPath = [String]

struct ConfigEditRefused: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The one way WinMux replaces a config file's text. The loader must read `after` without adding an error `before`
/// didn't have. When the edit names the keys it changes (`changing`), every other key must keep its value, as the
/// loader reads both texts. Then the file is written atomically. nil means the whole document is the edit (the TOML
/// Editor, undo).
@MainActor
func writeConfigFile(_ after: String, replacing before: String, at url: URL, changing: [ConfigKeyPath]?) throws {
    try validateConfigEdit(before: before, after: after, changing: changing)
    if let parent = url.deletingLastPathComponent().takeIf({ $0.path != url.path }) {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    try after.write(to: url, atomically: true, encoding: .utf8)
}

@MainActor
func validateConfigEdit(before: String, after: String, changing: [ConfigKeyPath]?) throws {
    let beforeErrors = Set(parseConfig(before).errors)
    let added = parseConfig(after).errors.filter { !beforeErrors.contains($0) }
    guard added.isEmpty else {
        throw ConfigEditRefused("WinMux didn't save this change: the configuration would no longer load.\n"
            + added.joined(separator: "\n"))
    }
    if let changing { try checkConfigEditKeepsOtherKeys(before: before, after: after, changing: changing) }
}

/// Refuses an edit that changes, adds or removes any key outside `changing` (a key under a listed path counts as inside).
func checkConfigEditKeepsOtherKeys(before: String, after: String, changing: [ConfigKeyPath]) throws {
    guard let old = configLeaves(before), let new = configLeaves(after) else {
        throw ConfigEditRefused("WinMux didn't save this change: it couldn't read the configuration to check the edit. "
            + "Fix it in Advanced → TOML Editor.")
    }
    let touched = Set(old.keys).union(new.keys)
        .filter { path in old[path] != new[path] && !changing.contains { path.starts(with: $0) } }
    if let first = touched.sorted(by: { $0.joined(separator: ".") < $1.joined(separator: ".") }).first {
        throw ConfigEditRefused("WinMux didn't save this change: it would also have changed "
            + "\(first.joined(separator: ".").singleQuoted). Edit the file in Advanced → TOML Editor.")
    }
}

/// Every value the loader reads from `text`, by key path. Tables are walked; arrays and scalars are values. Empty tables
/// carry no setting and are skipped. nil when the text doesn't parse.
func configLeaves(_ text: String) -> [ConfigKeyPath: Json]? {
    guard let table = try? WinMuxToml.table(text),
          case .success(let json) = tomlAnyToParsedConfigRecursive(any: table, .emptyRoot)
    else { return nil }
    var leaves: [ConfigKeyPath: Json] = [:]
    func walk(_ value: Json, _ path: ConfigKeyPath) {
        if case .dict(let dict) = value {
            for (key, child) in dict { walk(child, path + [key]) }
        } else {
            leaves[path] = value
        }
    }
    walk(json, [])
    return leaves
}
