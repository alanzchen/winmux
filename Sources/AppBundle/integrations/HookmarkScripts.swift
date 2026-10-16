import AppKit
import Common

// Hookmark-compatible integration scripts: what they are, what they need, and how WinMux runs them.
//
// The contract is Hookmark's published one (Creating Integration Scripts): per app, Get Address returns
// the address of the item in front, a URL or a Markdown link `[name](url)`; Get Name, optional, its name
// when the address carries none; Open Item, optional, opens an address, given as `$0`; New Item makes an
// item named `$title`. A script is JavaScript when it starts with `//JavaScript`, otherwise AppleScript.
// Get Address may also answer with JSON whose `address` and `name` are base64.
//
// WinMux runs these scripts as the user's own code, in `osascript`, only once the user has turned the
// integration on. An address is never pasted into a script: `$0` and `$$` read it from the environment,
// as data, so an address can't become code. What a script does with it, a shell command included, is the
// script's own doing, as in Hookmark.

enum HookmarkScriptLanguage: String, Codable, Equatable {
    case appleScript
    case javaScript

    var label: String { self == .appleScript ? "AppleScript" : "JavaScript" }
}

/// Hookmark's rule: a script that starts with `//JavaScript` is JavaScript; any other is AppleScript.
func hookmarkScriptLanguage(_ source: String) -> HookmarkScriptLanguage {
    let start = source.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
    return start.hasPrefix("//JavaScript") || start.hasPrefix("// JavaScript") ? .javaScript : .appleScript
}

// MARK: - What a script needs

/// One script slot's needs and limits, read from its text.
struct HookmarkScriptTraits: Equatable {
    var language: HookmarkScriptLanguage
    var usesAddress = false
    var usesAppName = false
    var usesTitle = false
    /// Talks to Hookmark itself, its links, or its callbacks: only Hookmark can answer.
    var needsHookmark = false
    /// Waits for the app to call Hookmark back.
    var usesCallback = false
    var usesClipboard = false
    var usesShell = false
    /// Presses keys or clicks through System Events: acts on whatever is in front.
    var usesUIScripting = false
    /// `$0` inside a JavaScript template string, which WinMux can't bind safely.
    var placeholderInTemplate = false
    /// The apps it addresses by name or id, as written.
    var apps: [String] = []
}

func hookmarkScriptTraits(_ source: String) -> HookmarkScriptTraits {
    let language = hookmarkScriptLanguage(source)
    let lower = source.lowercased()
    var traits = HookmarkScriptTraits(language: language)
    let scan = (try? hookmarkScanPlaceholders(source, language: language)) ?? HookmarkPlaceholderScan()
    traits.usesAddress = scan.address
    traits.usesAppName = scan.appName
    traits.usesTitle = source.contains("$title")
    traits.placeholderInTemplate = scan.inTemplate
    traits.needsHookmark = lower.contains("hook://") || lower.contains("hookmark://") || lower.contains("com.cogsciapps.hook")
        || lower.range(of: #"application\s+"hookmark""#, options: .regularExpression) != nil
        || lower.range(of: #"application\(\s*["']hookmark["']\s*\)"#, options: .regularExpression) != nil
    traits.usesCallback = lower.contains("x-callback-url") || lower.contains("setcurrentnode")
    traits.usesClipboard = lower.contains("the clipboard") || lower.contains("set clipboard") || lower.contains("nspasteboard")
        || lower.contains("pbcopy") || lower.contains("pbpaste") || lower.contains("setthe clipboard")
        || lower.contains("theclipboard") || lower.contains("setclipboard")
    traits.usesShell = lower.contains("do shell script") || lower.contains("doshellscript")
    traits.usesUIScripting = lower.contains("system events") && (lower.contains("keystroke") || lower.contains("key code")
        || lower.contains("click ") || lower.contains(".click(") || lower.contains("perform action") || lower.contains("keycode("))
    var apps: [String] = []
    for pattern in [#"application\s+(?:id\s+)?"([^"]+)""#, #"Application\(\s*["']([^"']+)["']\s*\)"#] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            if let range = Range(match.range(at: 1), in: source) {
                let app = String(source[range])
                if !apps.contains(app) { apps.append(app) }
            }
        }
    }
    traits.apps = apps
    return traits
}

/// What WinMux can and can't do with an integration, and why, in words the user reads before turning it on.
struct LinkIntegrationAnalysis: Equatable {
    enum Verdict: Hashable {
        /// Runs as written.
        case runsUnchanged
        /// Runs as written, with something to know first: what it may do.
        case runsWithNotes
        /// Turned on, part of it won't work as written.
        case needsAdaptation
        /// Can't run in WinMux.
        case unsupported

        var label: String {
            switch self {
                case .runsUnchanged: "Runs unchanged"
                case .runsWithNotes: "Runs unchanged, with notes"
                case .needsAdaptation: "Needs adaptation"
                case .unsupported: "Unsupported"
            }
        }
    }

    var verdict: Verdict
    /// What it may do, once on.
    var notes: [String]
    /// Why some or all of it won't work.
    var problems: [String]
    /// Get Address can run.
    var canCapture: Bool
    /// Get Name can run, when Get Address gives no name.
    var canName: Bool
    /// Open Item can run.
    var canOpen: Bool
}

func analyzeLinkIntegration(_ integration: LinkIntegration) -> LinkIntegrationAnalysis {
    var notes: [String] = []
    var problems: [String] = []
    var blocked = false
    var adapted = false
    let getAddress = integration.getAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    let slots: [(String, String?)] = [("Get Address", integration.getAddress), ("Get Name", integration.getName),
                                      ("Open Item", integration.openItem)]
    let traits = slots.compactMap { name, source in source.flatMap { $0.isEmpty ? nil : (name, hookmarkScriptTraits($0)) } }
    var canCapture = !getAddress.isEmpty
    var canName = integration.getName?.isEmpty == false
    var canOpen = integration.openItem?.isEmpty == false
    /// The slot can't run as written: Get Address blocks the integration, Get Name is skipped, and an
    /// Open Item's links open as macOS opens them.
    func cannotRun(_ name: String, _ why: String) {
        switch name {
            case "Get Address": canCapture = false
            case "Get Name": canName = false
            default: canOpen = false
        }
        problems.append(why + (name == "Get Name" ? " WinMux skips Get Name, and names the link by its address."
            : name == "Open Item" ? " Its links open as macOS opens them instead." : ""))
        blocked = blocked || name == "Get Address"
        adapted = true
    }
    if getAddress.isEmpty {
        problems.append("It has no Get Address script, so it can't take a link from a window.")
        blocked = true
    }
    for (name, trait) in traits {
        if trait.usesCallback {
            cannotRun(name, "\(name) asks the app to call Hookmark back (x-callback-url), and only Hookmark receives that call.")
        } else if trait.needsHookmark {
            cannotRun(name, "\(name) uses Hookmark itself (its app, its hook:// links or its database), which WinMux can't stand in for.")
        } else if trait.placeholderInTemplate {
            cannotRun(name, "\(name) puts $0 inside a JavaScript template string (`…`), which WinMux can't fill safely. "
                + "Put it in an ordinary \"…\" string instead.")
        }
        if trait.usesAddress, name != "Open Item" {
            notes.append("\(name) mentions $0, which only Open Item is given; there it stays as written.")
        }
        if trait.usesUIScripting {
            notes.append("\(name) presses keys or clicks through System Events: it acts on whatever is in front. "
                + "WinMux brings this tab's window to the front first and checks it's still there afterwards. "
                + "WinMux needs Accessibility for it, which it already has.")
        }
        if trait.usesClipboard {
            notes.append("\(name) uses the clipboard. WinMux puts back what was on it, unless something else changed it after the script.")
        }
        if trait.usesShell { notes.append("\(name) runs shell commands, with your permissions.") }
    }
    if integration.scriptingMethod?.lowercased() == "x-callback-url", !blocked {
        problems.append("It's marked as an x-callback-url integration, which only Hookmark can receive.")
        canCapture = false
        blocked = true
    }
    if let converter = integration.urlConverter, !converter.isEmpty {
        problems.append("Its URL converter isn't supported: WinMux keeps addresses as Get Address returns them.")
        adapted = true
    }
    if integration.newItem?.isEmpty == false {
        notes.append("New Item is kept as imported, but WinMux has nothing that runs it.")
    }
    if canOpen, let scheme = integration.scheme, !scheme.isEmpty {
        notes.append("Open Item opens the links this integration took, and links typed or pasted whose “\(scheme):” no app opens.")
    } else if canOpen {
        notes.append("Open Item opens the links this integration took. Without a scheme, links typed or pasted aren't sent to it.")
    }
    if !canOpen, integration.openItem?.isEmpty != false {
        notes.append("Without Open Item, its links open as macOS opens them.")
    }
    notes.insert("It controls \(integration.appName) with Apple events: macOS asks once whether WinMux may.", at: 0)
    let verdict: LinkIntegrationAnalysis.Verdict = blocked || !canCapture ? .unsupported : adapted ? .needsAdaptation
        : traits.contains { $0.1.usesUIScripting || $0.1.usesClipboard || $0.1.usesShell } ? .runsWithNotes : .runsUnchanged
    return .init(verdict: verdict, notes: notes, problems: problems, canCapture: canCapture && !blocked, canName: canName,
        canOpen: canOpen)
}

// MARK: - Placeholders, bound as data

struct HookmarkPlaceholderScan: Equatable {
    var address = false
    var appName = false
    var inTemplate = false
}

enum HookmarkPlaceholderError: Error, Equatable {
    case templateString
    case unterminated
}

/// The values a script's placeholders take, passed through the environment, never into its text.
struct HookmarkPlaceholderValues: Equatable {
    /// `$0`: the address an Open Item opens.
    var address: String?
    /// `$$`: the app's name, as Hookmark's default script uses it.
    var appName: String?
}

private let hookmarkAddressVariable = "winmuxHookmarkAddress"
let hookmarkAddressEnvironment = "WINMUX_HM_ADDRESS_HEX"

func hookmarkScanPlaceholders(_ source: String, language: HookmarkScriptLanguage) throws -> HookmarkPlaceholderScan {
    var scan = HookmarkPlaceholderScan()
    _ = try hookmarkRewrite(source, language: language, address: true, appName: "", refusesTemplates: false, scan: &scan)
    return scan
}

/// The script as it runs, outside comments: `$0` replaced by a read of the address, in code and in strings
/// alike, so an address is only ever data; `$$` by the app's name, from the user's own integration, as an
/// escaped literal, so the app is known when the script compiles, as Hookmark's default script needs.
/// Unchanged when it uses neither.
func hookmarkExecutableSource(_ source: String, values: HookmarkPlaceholderValues) throws -> String {
    let language = hookmarkScriptLanguage(source)
    var scan = HookmarkPlaceholderScan()
    let body = try hookmarkRewrite(source, language: language, address: values.address != nil, appName: values.appName,
        refusesTemplates: true, scan: &scan)
    guard scan.address || scan.appName else { return source }
    switch language {
        case .javaScript:
            return body
        case .appleScript:
            return scan.address ? hookmarkAppleScriptWithPrelude(body) : body
    }
}

/// The environment a run passes the address in: UTF-8, as hex, so AppleScript reads it exactly.
func hookmarkEnvironment(_ values: HookmarkPlaceholderValues) -> [String: String] {
    values.address.map { [hookmarkAddressEnvironment: hookmarkHex($0)] } ?? [:]
}

func hookmarkHex(_ text: String) -> String { Data(text.utf8).map { String(format: "%02X", $0) }.joined() }

private func javaScriptRead(_ environment: String) -> String {
    // Decoded from hex in this process, as UTF-8: the value never passes through the script's text.
    "(function(h){var b=[];for(var i=0;i<h.length;i+=2)b.push(parseInt(h.substr(i,2),16));"
        + "return decodeURIComponent(b.map(function(x){return '%'+('0'+x.toString(16)).slice(-2)}).join(''))})"
        + "(ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey('\(environment)'))||'')"
}

/// Rewrites `$0` (when asked) outside comments: in code, to a read of the address; inside a string, to a
/// concatenation with it. And `$$` (when given a name): to that name, escaped, as a literal in code or as
/// text inside a string. JavaScript template strings holding `$0` refuse, or, only scanned, are noted.
private func hookmarkRewrite(_ source: String, language: HookmarkScriptLanguage, address: Bool, appName: String?,
                             refusesTemplates: Bool, scan: inout HookmarkPlaceholderScan) throws -> String {
    let chars = Array(source)
    var out = ""
    out.reserveCapacity(chars.count + 64)
    var index = 0
    func placeholder(at i: Int) -> (kind: Character, length: Int)? {
        guard chars[i] == "$", i + 1 < chars.count else { return nil }
        if chars[i + 1] == "0" { return ("0", 2) }
        if chars[i + 1] == "$" { return ("$", 2) }
        return nil
    }
    func wanted(_ kind: Character) -> Bool { kind == "0" ? address : appName != nil }
    func note(_ kind: Character) { if kind == "0" { scan.address = true } else { scan.appName = true } }
    let name = appName ?? ""
    /// The name as text inside a string closed by `quote`.
    func escaped(_ quote: Character) -> String {
        var text = ""
        for c in name {
            switch c {
                case "\\": text += "\\\\"
                case quote: text += "\\" + String(c)
                case "\n": text += "\\n"
                case "\r": text += "\\r"
                default: text.append(c)
            }
        }
        return text
    }
    /// A placeholder in code.
    func code(_ kind: Character) -> String {
        if kind == "$" { return "\"\(escaped("\""))\"" }
        return language == .appleScript ? "(\(hookmarkAddressVariable))" : "(\(javaScriptRead(hookmarkAddressEnvironment)))"
    }
    /// A placeholder inside a string closed by `quote`.
    func inString(_ kind: Character, _ quote: Character) -> String {
        if kind == "$" { return escaped(quote) }
        let joiner = language == .appleScript ? "&" : "+"
        let read = language == .appleScript ? hookmarkAddressVariable : javaScriptRead(hookmarkAddressEnvironment)
        return "\(quote) \(joiner) \(read) \(joiner) \(quote)"
    }
    switch language {
        case .appleScript:
            var depth = 0 // block comments (* … *) nest
            while index < chars.count {
                let c = chars[index]
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                if depth > 0 {
                    if c == "(" && next == "*" { depth += 1; out += "(*"; index += 2; continue }
                    if c == "*" && next == ")" { depth -= 1; out += "*)"; index += 2; continue }
                    out.append(c); index += 1; continue
                }
                if c == "(" && next == "*" { depth = 1; out += "(*"; index += 2; continue }
                if (c == "-" && next == "-") || c == "#" {
                    while index < chars.count, chars[index] != "\n", chars[index] != "\r" { out.append(chars[index]); index += 1 }
                    continue
                }
                if c == "|" { // an identifier between bars is a name, never a placeholder
                    out.append(c); index += 1
                    while index < chars.count, chars[index] != "|" { out.append(chars[index]); index += 1 }
                    if index < chars.count { out.append(chars[index]); index += 1 }
                    continue
                }
                if c == "\"" {
                    out.append(c); index += 1
                    var closed = false
                    while index < chars.count {
                        let s = chars[index]
                        if s == "\\", index + 1 < chars.count { out.append(s); out.append(chars[index + 1]); index += 2; continue }
                        if s == "\"" { out.append(s); index += 1; closed = true; break }
                        if let p = placeholder(at: index), wanted(p.kind) {
                            note(p.kind)
                            out += inString(p.kind, "\"")
                            index += p.length; continue
                        }
                        out.append(s); index += 1
                    }
                    if !closed { throw HookmarkPlaceholderError.unterminated }
                    continue
                }
                if let p = placeholder(at: index), wanted(p.kind) {
                    note(p.kind)
                    out += code(p.kind)
                    index += p.length; continue
                }
                out.append(c); index += 1
            }
        case .javaScript:
            while index < chars.count {
                let c = chars[index]
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                if c == "/" && next == "/" {
                    while index < chars.count, chars[index] != "\n" { out.append(chars[index]); index += 1 }
                    continue
                }
                if c == "/" && next == "*" {
                    out += "/*"; index += 2
                    while index < chars.count, !(chars[index] == "*" && index + 1 < chars.count && chars[index + 1] == "/") {
                        out.append(chars[index]); index += 1
                    }
                    if index < chars.count { out += "*/"; index += 2 }
                    continue
                }
                if c == "\"" || c == "'" || c == "`" {
                    let quote = c
                    out.append(c); index += 1
                    var closed = false
                    while index < chars.count {
                        let s = chars[index]
                        if s == "\\", index + 1 < chars.count { out.append(s); out.append(chars[index + 1]); index += 2; continue }
                        if s == quote { out.append(s); index += 1; closed = true; break }
                        if let p = placeholder(at: index), wanted(p.kind) {
                            note(p.kind)
                            if quote == "`", p.kind == "0" {
                                scan.inTemplate = true
                                if refusesTemplates { throw HookmarkPlaceholderError.templateString }
                            }
                            out += inString(p.kind, quote)
                            index += p.length; continue
                        }
                        out.append(s); index += 1
                    }
                    if !closed { throw HookmarkPlaceholderError.unterminated }
                    continue
                }
                if let p = placeholder(at: index), wanted(p.kind) {
                    note(p.kind)
                    out += code(p.kind)
                    index += p.length; continue
                }
                out.append(c); index += 1
            }
    }
    return out
}

/// AppleScript reads the address once, at its own top level, where `system attribute` reads this run's
/// environment rather than a `tell` target's: into a global, so handlers see it too. Hex decodes as UTF-8
/// through a data literal made only of hex digits WinMux wrote.
private func hookmarkAppleScriptWithPrelude(_ body: String) -> String {
    let declarations = ["global \(hookmarkAddressVariable)"]
    let assignments = ["set \(hookmarkAddressVariable) to \"\"",
                       "if (system attribute \"\(hookmarkAddressEnvironment)\") is not \"\" then set \(hookmarkAddressVariable) to "
                           + "run script (\"«data utf8\" & (system attribute \"\(hookmarkAddressEnvironment)\") & \"» as text\")"]
    var lines = body.components(separatedBy: "\n")
    // `use` statements come first; then the declarations. A script with its own run handler sets the values
    // first thing in it; any other sets them at its top level.
    var insertAt = 0
    while insertAt < lines.count {
        let line = lines[insertAt].trimmingCharacters(in: .whitespaces).lowercased()
        if line.isEmpty || line.hasPrefix("--") || line.hasPrefix("#") || line.hasPrefix("use ") { insertAt += 1 } else { break }
    }
    let runHandler = lines.firstIndex { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed == "on run" || trimmed.hasPrefix("on run ") || trimmed == "on run argv"
    }
    if let runHandler, runHandler >= insertAt {
        lines.insert(contentsOf: assignments, at: runHandler + 1)
        lines.insert(contentsOf: declarations, at: insertAt)
    } else {
        lines.insert(contentsOf: declarations + assignments, at: insertAt)
    }
    return lines.joined(separator: "\n")
}

// MARK: - Running

enum HookmarkScriptResult: Equatable {
    case success(String)
    /// The user hasn't let WinMux control the app.
    case notAuthorized
    case failed(String)
    case timedOut
}

/// How long an integration script may take, including a first-time permission prompt the user reads.
let hookmarkScriptTimeout: TimeInterval = 30

/// Runs a script with its values in `osascript`, as its own process, given the script on standard input.
/// Replaceable for tests.
@MainActor
var runHookmarkScript: @MainActor (_ source: String, _ values: HookmarkPlaceholderValues) async -> HookmarkScriptResult = { source, values in
    let executable: String
    do {
        executable = try hookmarkExecutableSource(source, values: values)
    } catch HookmarkPlaceholderError.templateString {
        return .failed("It puts $0 inside a JavaScript template string, which WinMux can't fill safely.")
    } catch {
        return .failed("Its text has an unterminated string, so WinMux didn't run it.")
    }
    return await runOsaScript(executable, language: hookmarkScriptLanguage(source), environment: hookmarkEnvironment(values),
        timeout: hookmarkScriptTimeout)
}

/// Off the main actor: the script is written to osascript's input as it reads it.
@concurrent
func runOsaScript(_ source: String, language: HookmarkScriptLanguage, environment: [String: String], timeout: TimeInterval) async
    -> HookmarkScriptResult
{
    await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", language == .javaScript ? "JavaScript" : "AppleScript", "-"]
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let state = HookmarkRunState(continuation)
        process.terminationHandler = { finished in
            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if finished.terminationStatus == 0 {
                state.resume(.success(stdout.hasSuffix("\n") ? String(stdout.dropLast()) : stdout))
            } else if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized") {
                state.resume(.notAuthorized)
            } else {
                state.resume(.failed(hookmarkErrorSummary(stderr, status: finished.terminationStatus)))
            }
        }
        do {
            try process.run()
        } catch {
            state.resume(.failed(error.localizedDescription))
            return
        }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                process.terminate()
                state.resume(.timedOut)
            }
        }
    }
}

/// The error osascript reported, without the script's text it quotes: its last line, short.
func hookmarkErrorSummary(_ stderr: String, status: Int32) -> String {
    let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    // "-:120:140: execution error: Mail got an error: … (-1728)" → the part after the position.
    let message = last.range(of: "error: ").map { String(last[$0.upperBound...]) } ?? last
    let trimmed = message.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return "The script ended with status \(status)." }
    return String(trimmed.prefix(240))
}

private final class HookmarkRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HookmarkScriptResult, Never>?

    init(_ continuation: CheckedContinuation<HookmarkScriptResult, Never>) { self.continuation = continuation }

    func resume(_ result: HookmarkScriptResult) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

// MARK: - What Get Address answered

enum HookmarkAddress: Equatable {
    /// An address other than a file, with the name the answer gave, if any.
    case link(url: String, name: String?)
    /// A file on disk.
    case file(URL, name: String?)
    /// Nothing: no item in front.
    case empty
    /// A Hookmark callback, which only Hookmark receives.
    case callback
    /// A hook:// link, which only Hookmark opens.
    case hookmarkLink
    case invalid(String)
}

private let hookmarkRefusedSchemes: Set<String> = ["javascript", "data", "about", "blob", "vbscript"]

/// What a Get Address answer means: a Markdown link `[name](url)`, JSON with base64 `address` and
/// `name`, a file path or file URL, or any other URL. Treated as untrusted text: kept only once it's a
/// well-formed address of an allowed kind.
func parseHookmarkAddress(_ output: String) -> HookmarkAddress {
    var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    var name: String?
    if text.isEmpty { return .empty }
    guard text.count <= 16384 else { return .invalid("The answer is too long to be an address.") }
    if text.hasPrefix("{"), let data = text.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let address = object["address"] as? String {
        func decoded(_ value: String) -> String {
            Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) } ?? value
        }
        text = decoded(address).trimmingCharacters(in: .whitespacesAndNewlines)
        name = (object["name"] as? String).map(decoded)
    } else if text.hasPrefix("["), text.hasSuffix(")"), let split = text.range(of: "](", options: .backwards) {
        name = String(text[text.index(after: text.startIndex) ..< split.lowerBound])
        text = String(text[split.upperBound ..< text.index(before: text.endIndex)]).trimmingCharacters(in: .whitespaces)
    }
    name = name.map(hookmarkCleanName).flatMap { $0.isEmpty ? nil : $0 }
    let lower = text.lowercased()
    if lower.hasPrefix("hook://x-callback-url/setcurrentnode") { return .callback }
    if lower.hasPrefix("hook:") || lower.hasPrefix("hookmark:") { return .hookmarkLink }
    if text.isEmpty { return .empty }
    if text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
        // A path may hold spaces; a URL may not.
        if text.hasPrefix("/") || text.hasPrefix("~/") { return hookmarkFile(text, name: name) }
        return .invalid("The answer isn't an address: it has spaces or line breaks.")
    }
    if text.hasPrefix("/") || text.hasPrefix("~/") { return hookmarkFile(text, name: name) }
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
          scheme.range(of: #"^[a-z][a-z0-9+.\-]*$"#, options: .regularExpression) != nil
    else { return .invalid("The answer isn't an address WinMux can keep.") }
    if url.isFileURL { return hookmarkFile(url.path, name: name) }
    if hookmarkRefusedSchemes.contains(scheme) { return .invalid("WinMux doesn't keep “\(scheme):” addresses.") }
    if (scheme == "http" || scheme == "https"), url.host?.isEmpty != false { return .invalid("The web address has no site in it.") }
    guard text.count <= 8192 else { return .invalid("The address is too long to pin.") }
    return .link(url: text, name: name)
}

private func hookmarkFile(_ path: String, name: String?) -> HookmarkAddress {
    let expanded = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { return .invalid("The file it names isn't on disk.") }
    return .file(url, name: name)
}

/// A name as one short line.
func hookmarkCleanName(_ name: String) -> String {
    let line = name.components(separatedBy: .newlines).joined(separator: " ")
        .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    return String(String(String.UnicodeScalarView(line)).trimmingCharacters(in: .whitespaces).prefix(200))
}
