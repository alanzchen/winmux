public struct LayoutCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .layout,
        allowInConfig: true,
        help: layout_help_generated,
        flags: [
            "--window-id": optionalWindowIdFlag(),
            "--workspace": optionalWorkspaceFlag(),
            "--root": trueBoolFlag(\.root),
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
            "--for-next-detected-window": trueBoolFlag(\.forNextDetectedWindow),
        ],
        posArgs: [newMandatoryPosArgParser(\.toggleBetween, parseToggleBetween, placeholder: LayoutDescription.unionLiteral)],
        conflictingOptions: [
            ["--window-id", "--workspace"],
            ["--for-next-detected-window", "--window-id"],
            ["--for-next-detected-window", "--root"],
            ["--for-next-detected-window", "--fail-if-noop"],
        ],
    )

    public var root = false
    public var failIfNoop = false
    public var forNextDetectedWindow = false

    public var toggleBetween: Lateinit<[LayoutDescription]> = .uninitialized

    public init(rawArgs: [String], toggleBetween: [LayoutDescription]) {
        self.commonState = .init(rawArgs.slice)
        self.toggleBetween = .initialized(toggleBetween)
    }

    public enum LayoutDescription: String, CaseIterable, Equatable, Sendable {
        case tabGroup = "tab-group"
        case tiles
        case horizontal, vertical
        case hTabGroup = "h_tab_group"
        case vTabGroup = "v_tab_group"
        case h_tiles, v_tiles
        case tiling, floating
    }
}

private func parseToggleBetween(input: PosArgParserInput) -> ParsedCliArgs<[LayoutCmdArgs.LayoutDescription]> {
    let args = input.nonFlagArgs()

    var result: [LayoutCmdArgs.LayoutDescription] = []
    var i = 0
    for arg in args {
        if let layout = arg.parseLayoutDescription() {
            result.append(layout)
        } else {
            return .fail(
                "Can't parse '\(arg)'\nPossible values: \(LayoutCmdArgs.LayoutDescription.unionLiteral)",
                advanceBy: i + 1,
            )
        }
        i += 1
    }

    return .succ(result, advanceBy: args.count)
}

func parseLayoutCmdArgs(_ args: StrArrSlice) -> ParsedCmd<LayoutCmdArgs> {
    parseSpecificCmdArgs(LayoutCmdArgs(rawArgs: args), args)
        .map {
            check(!$0.toggleBetween.val.isEmpty)
            return $0
        }
        .filter("layout command: --root and tiling|floating are incompatible") {
            !$0.root || !$0.toggleBetween.val.contains(where: { $0 == .floating || $0 == .tiling })
        }
        .filter("--workspace requires --root or --for-next-detected-window") {
            $0.workspaceName == nil || $0.root || $0.forNextDetectedWindow
        }
        .filter("--fail-if-noop allows only one <target-layout> argument") {
            !$0.failIfNoop || $0.toggleBetween.val.count == 1
        }
        .filter("--for-next-detected-window allows only one tiling|floating argument") {
            !$0.forNextDetectedWindow || $0.toggleBetween.val == [.tiling] || $0.toggleBetween.val == [.floating]
        }
}

extension String {
    fileprivate func parseLayoutDescription() -> LayoutCmdArgs.LayoutDescription? {
        LayoutCmdArgs.LayoutDescription(rawValue: self)
    }
}
