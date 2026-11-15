import AppKit
import Common
import HotKey

func parseBindings(
    _ raw: Json,
    _ backtrace: ConfigBacktrace,
    _ errors: inout [ConfigParseError],
    _ mapping: [String: Key]
) -> (chordBindings: [String: HotkeyBinding], sequenceBindings: [String: SequenceBinding]) {
    guard let rawTable = raw.asDictOrNil else {
        errors += [expectedActualTypeError(expected: .table, actual: raw.tomlType, backtrace)]
        return ([:], [:])
    }
    var chordResult: [String: HotkeyBinding] = [:]
    var seqResult: [String: SequenceBinding] = [:]
    for (binding, rawCommand): (String, Json) in rawTable {
        let backtrace = backtrace + .key(binding)
        if parseSequenceBindingIfPresent(binding, rawCommand, backtrace, mapping, errors: &errors, result: &seqResult) {
            continue
        }
        parseChordBinding(binding, rawCommand, backtrace, mapping, errors: &errors, result: &chordResult)
    }
    return (chordResult, seqResult)
}

func parseBinding(_ raw: String, _ backtrace: ConfigBacktrace, _ mapping: [String: Key]) -> ParsedConfig<(NSEvent.ModifierFlags, Key)> {
    let rawKeys = raw.split(separator: "-")
    let modifiers: ParsedConfig<NSEvent.ModifierFlags> = rawKeys.dropLast()
        .mapAllOrFailure {
            modifiersMap[String($0)].orFailure(.semantic(backtrace, "Can't parse modifiers in '\(raw)' binding"))
        }
        .map { NSEvent.ModifierFlags($0) }
    let key: ParsedConfig<Key> = rawKeys.last.flatMap { mapping[String($0)] }
        .orFailure(.semantic(backtrace, "Can't parse the key in '\(raw)' binding"))
    return modifiers.flatMap { modifiers -> ParsedConfig<(NSEvent.ModifierFlags, Key)> in
        key.flatMap { key -> ParsedConfig<(NSEvent.ModifierFlags, Key)> in
            .success((modifiers, key))
        }
    }
}

private func parseSequenceBindingIfPresent(
    _ binding: String,
    _ rawCommand: Json,
    _ backtrace: ConfigBacktrace,
    _ mapping: [String: Key],
    errors: inout [ConfigParseError],
    result: inout [String: SequenceBinding]
) -> Bool {
    guard looksLikeSequenceBinding(binding, mapping) else { return false }
    let parsedPrefix = tryParseSequenceBinding(binding, backtrace, mapping)
    guard parsedPrefix.isSuccess else { return false }
    let seqBindingResult: ParsedConfig<SequenceBinding> = parsedPrefix.flatMap { prefix, key in
        parseCommandOrCommands(rawCommand).toParsedConfig(backtrace).map { cmds in
            SequenceBinding(prefix: prefix, key: key, commands: cmds, descriptionWithKeyNotation: binding)
        }
    }
    guard let seqBinding = seqBindingResult.getOrNil(appendErrorTo: &errors) else { return true }
    if result.keys.contains(seqBinding.descriptionWithKeyNotation) {
        errors.append(.semantic(backtrace, "'\(seqBinding.descriptionWithKeyNotation)' Sequence binding redeclaration"))
    }
    result[seqBinding.descriptionWithKeyNotation] = seqBinding
    return true
}

private func parseChordBinding(
    _ binding: String,
    _ rawCommand: Json,
    _ backtrace: ConfigBacktrace,
    _ mapping: [String: Key],
    errors: inout [ConfigParseError],
    result: inout [String: HotkeyBinding]
) {
    let parsed: ParsedConfig<HotkeyBinding> = parseBinding(binding, backtrace, mapping).flatMap { modifiers, key in
        parseCommandOrCommands(rawCommand).toParsedConfig(backtrace).map {
            HotkeyBinding(modifiers, key, $0, descriptionWithKeyNotation: binding)
        }
    }
    if let chord = parsed.getOrNil(appendErrorTo: &errors) {
        if result.keys.contains(chord.descriptionWithKeyCode) {
            errors.append(.semantic(backtrace, "'\(chord.descriptionWithKeyCode)' Binding redeclaration"))
        }
        result[chord.descriptionWithKeyCode] = chord
    }
}

private func looksLikeSequenceBinding(_ raw: String, _ mapping: [String: Key]) -> Bool {
    let rawKeys = raw.split(separator: "-")
    guard rawKeys.count == 2 else { return false }
    let first = String(rawKeys[0])
    guard modifiersMap[first] == nil else { return false }
    return mapping[first] != nil
}
