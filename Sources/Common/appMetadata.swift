public let stableWinMuxAppId: String = "com.zimengxiong.winmux"
#if DEBUG
    public let winMuxAppId: String = "com.zimengxiong.winmux.debug"
    public let winMuxAppName: String = "WinMux-Debug"
#else
    public let winMuxAppId: String = stableWinMuxAppId
    public let winMuxAppName: String = "WinMux"
#endif

/// The fork's issue tracker, where users report bugs and runtime errors.
public let winMuxNewIssueURL = "https://github.com/alanzchen/winmux/issues/new"
