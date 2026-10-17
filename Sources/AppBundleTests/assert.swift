@testable import AppBundle
import Common
import XCTest

func assertTrue(_ actual: Bool, file: String = #filePath, line: Int = #line) {
    assertEquals(actual, true, file: file, line: line)
}

func assertNil(_ actual: Any?, file: String = #filePath, line: Int = #line) {
    if let actual {
        failExpectedActual("nil", actual, file: file, line: line)
    }
}

func assertNotNil(_ actual: Any?, file: String = #filePath, line: Int = #line) {
    if actual == nil {
        failExpectedActual("not nil", "nil", file: file, line: line)
    }
}

func assertEquals<T>(_ actual: T, _ expected: T, additionalMsg: String? = nil, file: String = #filePath, line: Int = #line) where T: Equatable {
    if actual != expected {
        failExpectedActual(expected, actual, additionalMsg: additionalMsg, file: file, line: line)
    }
}


func assertSucc<T>(_ actual: Result<T, some Any>, file: String = #filePath, line: Int = #line) {
    switch actual {
        case .failure: failExpectedActual("Result.success", actual, file: file, line: line)
        case .success: break
    }
}

func assertSucc<T>(_ actual: Result<T, some Any>, _ expected: T, file: String = #filePath, line: Int = #line) where T: Equatable {
    switch actual {
        case .failure: failExpectedActual("Result.success", actual, file: file, line: line)
        case .success(let actual): assertEquals(actual, expected, file: file, line: line)
    }
}
func testParseCommandSucc(_ command: String, _ expected: any CmdArgs) {
    let parsed = parseCommand(command)
    switch parsed {
        case .cmd(let command):
            if !command.args.equals(expected) {
                failExpectedActual(expected, command.args)
            }
        case .help: die() // todo test help
        case .failure(let msg): XCTFail(msg)
    }
}

func failExpectedActual(_ expected: Any?, _ actual: Any?, additionalMsg: String? = nil, file: String = #filePath, line: Int = #line) {
    let additionalMsg = additionalMsg.map { "\n    Additional Message:\n        \($0)" } ?? ""
    XCTFail(
        """

        \(file):\(line): Assertion failed\(additionalMsg)
            Expected:
                \(expected.prettyDescription)
            Actual:
                \(actual.prettyDescription)
        """,
    )
}
