
private let windowTabsParser: [String: any ParserProtocol<WindowTabsConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "height": Parser(\.height, parseWindowTabsHeight),
]

func parseWindowTabs(
    _ raw: OrderedJson,
    _ backtrace: ConfigBacktrace,
    _ errors: inout [ConfigParseDiagnostic],
) -> WindowTabsConfig {
    parseTable(raw, WindowTabsConfig(), windowTabsParser, backtrace, &errors)
}

private func parseWindowTabsHeight(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ParsedConfig<Int> {
    parseInt(raw, backtrace)
        .filter(.init(backtrace, "Must be greater than 20")) { $0 > 20 }
}
