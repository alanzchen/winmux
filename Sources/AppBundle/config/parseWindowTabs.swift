
private let windowTabsParser: [String: any ParserProtocol<WindowTabsConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "height": Parser(\.height, parseWindowTabsHeight),
]

func parseWindowTabs(
    _ raw: Json,
    _ backtrace: ConfigBacktrace,
    _ errors: inout [ConfigParseError],
) -> WindowTabsConfig {
    parseTable(raw, WindowTabsConfig(), windowTabsParser, backtrace, &errors)
}

private func parseWindowTabsHeight(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<Int> {
    parseInt(raw, backtrace)
        .filter(.semantic(backtrace, "Must be greater than 20")) { $0 > 20 }
}
