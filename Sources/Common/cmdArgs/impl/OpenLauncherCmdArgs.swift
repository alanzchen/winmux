public struct OpenLauncherCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .openLauncher,
        allowInConfig: true,
        help: """
        USAGE: open-launcher [--new-workspace]

        Opens the app launcher. Choosing an app opens a new window of it in the focused
        workspace, even if the app is already running elsewhere.

        OPTIONS:
          --new-workspace   Create an empty workspace first and open the window there.
        """,
        flags: [
            "--new-workspace": trueBoolFlag(\.newWorkspace),
        ],
        posArgs: [],
    )

    public var newWorkspace: Bool = false
}
