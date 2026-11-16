public struct ListProjectsCmdArgs: CmdArgs, JsonFormattableListCmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .listProjects,
        allowInConfig: false,
        help: list_projects_help_generated,
        flags: [
            "--focused": boolFlag(\.focused),
            "--visible": boolFlag(\.visible),
            "--format": formatParser(\._format, for: .project),
            "--count": trueBoolFlag(\.outputOnlyCount),
            "--json": trueBoolFlag(\.json),
        ],
        posArgs: [],
        conflictingOptions: [
            ["--count", "--format"],
            ["--count", "--json"],
        ],
    )

    public var focused: Bool?
    public var visible: Bool?
    public var _format: [InterToken<InterVar>] = []
    public var outputOnlyCount = false
    public var json = false
}

extension ListProjectsCmdArgs {
    public var format: [InterToken<InterVar>] {
        if !_format.isEmpty { return _format }
        if json {
            return FormatVar.ProjectFormatVar.allCases.map { .interVar(.formatVar(.project($0))) }
        }
        return [
            .interVar(.formatVar(.project(.projectIndex))), .interVar(.plainInterVar(.rightPadding)), .literal(" | "),
            .interVar(.formatVar(.project(.projectId))), .interVar(.plainInterVar(.rightPadding)), .literal(" | "),
            .interVar(.formatVar(.project(.projectName))),
        ]
    }
}

func parseListProjectsCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ListProjectsCmdArgs> {
    parseSpecificCmdArgs(ListProjectsCmdArgs(rawArgs: args), args)
        .validateJsonFormat()
}
