/// A config file's text as every config editor sees it: LF-separated lines with no CR and no byte order mark, plus what
/// `text` restores (the file's line ending and its byte order mark). This is the only place config text is split into
/// lines. The Settings form, sidebar and shortcut editors work on `lines` alone, so a CRLF file looks to them exactly
/// like its LF twin, and is written back with CRLF.
struct EditableConfigText {
    var lines: [String]
    /// `"\r\n"` when the file uses CRLF anywhere; every line is then written with CRLF.
    let lineEnding: String
    let hasByteOrderMark: Bool

    init(_ text: String) {
        var text = text
        hasByteOrderMark = text.hasPrefix("\u{FEFF}")
        if hasByteOrderMark { text.removeFirst() }
        lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    var text: String { (hasByteOrderMark ? "\u{FEFF}" : "") + lines.joined(separator: lineEnding) }

    /// `text` with `edit` applied to its lines.
    static func editing(_ text: String, _ edit: (inout EditableConfigText) -> Void) -> String {
        var config = EditableConfigText(text)
        edit(&config)
        return config.text
    }

    /// Appends a table after one blank line, or as the whole file when the file is empty.
    mutating func appendTable(_ header: String, _ body: [String]) {
        lines = Self.appendingTable(header, body, to: lines)
    }

    static func appendingTable(_ header: String, _ body: [String], to lines: [String]) -> [String] {
        var lines = lines
        if lines == [""] {
            lines = []
        } else if lines.last != "" {
            lines.append("")
        }
        return lines + [header] + body
    }
}
