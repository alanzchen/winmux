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
