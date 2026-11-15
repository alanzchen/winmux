import Foundation
import TOMLDecoder

/// The loader's TOML front end. Everything that reads, scans or validates a WinMux config goes through it, so the
/// Settings window, the sidebar's config edits and the loader always agree on what a file says (hook `tomlSource` in
/// parseConfig.swift).
///
/// `source` hands TOMLDecoder text it reads exactly as the TOML spec and v0.6.421 (TOMLKit) do:
/// - Contiguous UTF-8. TOMLDecoder 0.4.5 force-unwraps contiguous storage when it unpacks values, so a String bridged
///   from `NSTextStorage` (the TOML Editor's text) would trap.
/// - A leading byte order mark is dropped, as TOMLKit did.
/// - CRLF becomes LF. Inside multiline strings TOMLDecoder keeps the CR; TOMLKit and the spec's newline rule give LF.
///   A CR not followed by LF is invalid anywhere in TOML and is reported here, before TOMLDecoder could accept it.
/// - `\\` inside a basic string becomes `\u005C`, the same character. TOMLDecoder 0.4.5 treats any backslash before a
///   closing `"""` as escaping it, so `"""C:\\"""` would never close.
/// - The text ends with a newline. Some TOMLDecoder releases read past the end after a bare value at EOF.
/// None of these changes a line count, so error line numbers stay those of the file.
enum WinMuxToml {
    static func source(_ raw: String) -> Result<String, ConfigParseError> {
        var bytes = Array(raw.utf8)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        switch normalizedLineEndings(bytes) {
            case .failure(let error): return .failure(error)
            case .success(let lfOnly): bytes = rewritingEscapedBackslashes(lfOnly)
        }
        if bytes.last != Byte.lf { bytes.append(Byte.lf) }
        return .success(String(decoding: bytes, as: UTF8.self))
    }

    /// Parses `raw` as the loader does, including unpacking every value: TOMLDecoder checks string escapes only then.
    static func table(_ raw: String) throws -> [String: Any] {
        switch source(raw) {
            case .failure(let error): throw error
            case .success(let source): return try .init(TOMLTable(source: source))
        }
    }

    static func parses(_ raw: String) -> Bool { (try? table(raw)) != nil }
}

/// The line after the TOML statement starting at `lines[index]`: a key/value whose multiline string, array or inline
/// table may span lines. The loader's front end decides where the value ends, so TOML 1.1 values (inline tables over
/// several lines, `\e` escapes) end where the loader ends them. A value that never ends runs to the end of the file.
func tomlStatementEnd(_ lines: [String], from index: Int) -> Int {
    var end = index + 1
    let line = lines[index].trimmingCharacters(in: .whitespaces)
    guard let equal = settingsAssignmentIndex(in: line) else { return end }
    let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
    // Single-line scalars can't continue. For containers and triple-quoted strings, parse only at lines that could
    // close the value.
    let delimiter = value.hasPrefix("\"\"\"") ? "\"\"\"" : value.hasPrefix("'''") ? "'''"
        : value.hasPrefix("[") ? "]" : value.hasPrefix("{") ? "}" : nil
    guard let delimiter else { return end }
    while end < lines.count {
        if lines[end - 1].contains(delimiter), WinMuxToml.parses(lines[index..<end].joined(separator: "\n")) { break }
        end += 1
    }
    return end
}

extension ConfigParseError {
    /// The syntax error `WinMuxToml.source` reports for `raw`, if any.
    static func tomlSource(_ raw: String) -> [ConfigParseError] {
        if case .failure(let error) = WinMuxToml.source(raw) { [error] } else { [] }
    }
}

private enum Byte {
    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
    static let backslash: UInt8 = 0x5C
    static let doubleQuote: UInt8 = 0x22
    static let singleQuote: UInt8 = 0x27
    static let hash: UInt8 = 0x23
}
private let escapedBackslash = Array(#"\u005C"#.utf8)

private func normalizedLineEndings(_ bytes: [UInt8]) -> Result<[UInt8], ConfigParseError> {
    guard bytes.contains(Byte.cr) else { return .success(bytes) }
    var result: [UInt8] = []
    result.reserveCapacity(bytes.count)
    var line = 1
    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        if byte == Byte.cr {
            guard index + 1 < bytes.count, bytes[index + 1] == Byte.lf else {
                return .failure(.syntax("(Line \(line)) Syntax error: carriage return without line feed."))
            }
        } else {
            if byte == Byte.lf { line += 1 }
            result.append(byte)
        }
        index += 1
    }
    return .success(result)
}

/// Walks TOML's lexical states (comments, the four string kinds) on LF-only text. Text that isn't valid TOML is copied
/// unchanged, so TOMLDecoder reports its error.
private func rewritingEscapedBackslashes(_ bytes: [UInt8]) -> [UInt8] {
    guard bytes.contains(Byte.backslash) else { return bytes }
    enum State { case normal, comment, basic, literal, multilineBasic, multilineLiteral }
    var state = State.normal
    var result: [UInt8] = []
    result.reserveCapacity(bytes.count + 16)
    var index = 0
    func run(of quote: UInt8) -> Int {
        var end = index
        while end < bytes.count, bytes[end] == quote { end += 1 }
        return end - index
    }
    while index < bytes.count {
        let byte = bytes[index]
        switch state {
            case .normal:
                switch byte {
                    case Byte.hash: state = .comment
                    case Byte.doubleQuote: state = run(of: Byte.doubleQuote) >= 3 ? .multilineBasic : .basic
                    case Byte.singleQuote: state = run(of: Byte.singleQuote) >= 3 ? .multilineLiteral : .literal
                    default: break
                }
                // An opening triple quote is copied whole, so it can't count as a closing one.
                let width = state == .multilineBasic || state == .multilineLiteral ? 3 : 1
                result.append(contentsOf: bytes[index..<min(index + width, bytes.count)])
                index += width
            case .comment:
                if byte == Byte.lf { state = .normal }
                result.append(byte)
                index += 1
            case .literal:
                if byte == Byte.singleQuote || byte == Byte.lf { state = .normal }
                result.append(byte)
                index += 1
            case .basic, .multilineBasic:
                if byte == Byte.backslash, index + 1 < bytes.count {
                    if bytes[index + 1] == Byte.backslash {
                        result.append(contentsOf: escapedBackslash)
                    } else {
                        result.append(contentsOf: bytes[index...index + 1])
                    }
                    index += 2
                } else if state == .basic {
                    if byte == Byte.doubleQuote || byte == Byte.lf { state = .normal }
                    result.append(byte)
                    index += 1
                } else if byte == Byte.doubleQuote {
                    // Up to two quotes before the closing three belong to the string.
                    let quotes = run(of: Byte.doubleQuote)
                    if quotes >= 3 { state = .normal }
                    result.append(contentsOf: bytes[index..<index + quotes])
                    index += quotes
                } else {
                    result.append(byte)
                    index += 1
                }
            case .multilineLiteral:
                if byte == Byte.singleQuote {
                    let quotes = run(of: Byte.singleQuote)
                    if quotes >= 3 { state = .normal }
                    result.append(contentsOf: bytes[index..<index + quotes])
                    index += quotes
                } else {
                    result.append(byte)
                    index += 1
                }
        }
    }
    return result
}
