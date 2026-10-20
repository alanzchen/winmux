@testable import Common

// Test-only conveniences over Common types; production code does not use them.

extension ParsedCmd {
    var cmdOrNil: T? {
        switch self {
            case .cmd(let t): t
            default: nil
        }
    }
}

extension WinMuxAny {
    @discardableResult
    func apply(_ block: (Self) -> Void) -> Self {
        block(self)
        return self
    }
}

extension MonitorDescription {
    /// Monitor equality compares only the raw pattern, so the regex here never affects assertions.
    static func caseSensitivePattern(_ raw: String) -> MonitorDescription? {
        (try? Regex(raw)).map { .pattern(raw, SendableRegex($0)) }
    }
}
