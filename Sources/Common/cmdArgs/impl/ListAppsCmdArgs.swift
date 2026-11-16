protocol JsonFormattableListCmdArgs: Sendable {
    var _format: [InterToken<InterVar>] { get }
    var json: Bool { get }
}

extension ParsedCmd where T: JsonFormattableListCmdArgs & CmdArgs {
    func validateJsonFormat() -> ParsedCmd<T> {
        flatMap { args in
            if args.json, let msg = getErrorIfFormatIsIncompatibleWithJson(args._format) {
                .failure(msg)
            } else {
                .cmd(args)
            }
        }
    }
}

public struct ListAppsCmdArgs: CmdArgs, JsonFormattableListCmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .listApps,
        allowInConfig: false,
        help: list_apps_help_generated,
        flags: [
            "--macos-native-hidden": boolFlag(\.macosHidden),

            // Formatting flags
            "--format": formatParser(\._format, for: .app),
            "--count": trueBoolFlag(\.outputOnlyCount),
            "--json": trueBoolFlag(\.json),
        ],
        posArgs: [],
        conflictingOptions: [
            ["--count", "--format"],
            ["--count", "--json"],
        ],
    )

    public var macosHidden: Bool?
    public var _format: [InterToken<InterVar>] = []
    public var outputOnlyCount: Bool = false
    public var json: Bool = false
}

extension ListAppsCmdArgs {
    public var format: [InterToken<InterVar>] {
        _format.isEmpty
            ? [
                .interVar(.formatVar(.app(.appPid))), .interVar(.plainInterVar(.rightPadding)), .literal(" | "),
                .interVar(.formatVar(.app(.appBundleId))), .interVar(.plainInterVar(.rightPadding)), .literal(" | "),
                .interVar(.formatVar(.app(.appName))),
            ]
            : _format
    }
}

func parseListAppsCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ListAppsCmdArgs> {
    parseSpecificCmdArgs(ListAppsCmdArgs(rawArgs: args), args)
        .validateJsonFormat()
}

func getErrorIfFormatIsIncompatibleWithJson(_ format: [InterToken<InterVar>]) -> String? {
    for x in format {
        switch x {
            case .interVar(.plainInterVar(.rightPadding)):
                return "%{right-padding} interpolation variable is not allowed when --json is used"
            case .interVar: break // skip
            case .literal(let literal):
                if literal.contains(where: { $0 != " " }) {
                    return "Only interpolation variables and spaces are allowed in '--format' when '--json' is used"
                }
        }
    }
    return nil
}
