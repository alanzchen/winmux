import Common
import HotKey

struct Mode: ConvenienceCopyable, Equatable, Sendable {
    var bindings: [String: HotkeyBinding]
    var tapBindings: [String: TapBinding]
    var sequenceBindings: [String: SequenceBinding]

    init(
        bindings: [String: HotkeyBinding],
        tapBindings: [String: TapBinding],
        sequenceBindings: [String: SequenceBinding] = [:],
    ) {
        self.bindings = bindings
        self.tapBindings = tapBindings
        self.sequenceBindings = sequenceBindings
    }

    static let zero = Mode(bindings: [:], tapBindings: [:], sequenceBindings: [:])
}

func parseModes(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic], _ mapping: [String: Key]) -> [String: Mode] {
    guard let rawTable = raw.asDictOrNil else {
        errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return [:]
    }
    var result: [String: Mode] = [:]
    for (key, value) in rawTable {
        result[key] = parseMode(value, backtrace + .key(key), &errors, mapping)
    }
    if !result.keys.contains(mainModeId) {
        errors += [.init(backtrace, "Please specify '\(mainModeId)' mode")]
    }
    return result
}

func parseMode(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic], _ mapping: [String: Key]) -> Mode {
    guard let rawTable: OrderedJson.JsonDict = raw.asDictOrNil else {
        errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return .zero
    }

    var result: Mode = .zero
    for (key, value) in rawTable {
        let backtrace = backtrace + .key(key)
        switch key {
            case "binding":
                let (chordBindings, seqBindings) = parseBindings(value, backtrace, &errors, mapping)
                result.bindings = chordBindings
                result.sequenceBindings = seqBindings
            case "binding-tap":
                result.tapBindings = parseTapBindings(value, backtrace, &errors)
            default:
                errors += [unknownKeyDiagnostic(backtrace)]
        }
    }
    return result
}
